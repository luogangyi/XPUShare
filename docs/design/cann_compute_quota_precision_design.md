# CANN 算力配额精度提升方案（精准控制版）

## 1. 背景与目标

当前 CANN 场景下，`xpushare` 的算力配额已可生效，但在多任务并发下仍存在明显偏差（尤其是混合配额场景）。本方案目标：

1. 将 CANN 配额误差从“可见偏大”收敛到工程可控区间。
2. 在不依赖私有驱动接口的前提下，优先使用开源 runtime/driver 能力落地。
3. 保持与现有 CUDA 路径一致的调度语义（动态配额、并发共享、可观测性）。

验收目标（建议）：

- 单卡并发 2~8 任务时，任务 `bench` 时间折算的有效份额误差 `<= ±10%`（P50），`<= ±15%`（P95）。
- 动态调额后的收敛时间 `< 2` 个控制窗口。

---

## 2. 现状与根因（基于当前代码 + CANN 源码）

## 2.1 现有 xpushare 控制链路（CANN）

当前 `xpushare` 对 CANN 的算力控制主要由三部分组成：

1. 进程级资源限制：`aclrtSetDeviceResLimit`（`CUBE/VECTOR`）。
2. 可选流级资源限制：`aclrtSetStreamResLimit + aclrtUseStreamResInCurrentThread`。
3. 调度器侧 wall-time 计费 + `DROP_LOCK` 抢占 + 本地补偿 sleep。

对应实现位于：

- `/Users/luogangyi/Code/xpushare/src/hook.c`
- `/Users/luogangyi/Code/xpushare/src/client.c`
- `/Users/luogangyi/Code/xpushare/src/scheduler.c`

## 2.2 导致“配额不准”的主要原因

1. `scheduler` 以 wall-time 近似 active-time。
- 当前核心计费是 `duration / n_running`，并非设备真实执行时长。
- 在 NPU 上，host 阻塞/异步队列/不同算子形态会导致 wall-time 与真实算力占用偏离。

2. 流级硬限制在部分运行时不可用或不可稳定命中。
- 现场日志已多次出现 `aclrtSetStreamResLimit`、`aclrtUseStreamResInCurrentThread` 符号不可用。
- 即使符号可用，`UseStreamResInCurrentThread` 是线程局部语义；框架跨线程提交时，可能导致限额绑定遗漏。

3. 进程级 `SetDeviceResLimit` 仅对“后续任务”生效。
- CANN 官方文档明确该接口只影响后续下发任务，不会回溯已在队列中的任务。
- 动态调额会出现生效滞后，造成窗口内误差。

4. 当前补偿策略偏启发式。
- `post-sync sleep` 属于 host 侧节流，不等价于设备 active-time 配额，容易出现过抑制或欠抑制。

## 2.3 driver/runtime 能力边界（关键结论）

结合 `/Users/luogangyi/Code/cann` 源码：

1. 开源 driver 中 `MODULE_TYPE_COMPUTING` 主要为查询路径。
- `halGetDeviceInfo(... MODULE_TYPE_COMPUTING ...)` 存在。
- 但 `halSetDeviceInfoByBuff` 在当前实现仅支持 `LP/L2BUFF/SYSTEM`，不支持 `MODULE_TYPE_COMPUTING` 写入。
- 结论：当前开源路径不能把“token 写入”作为主方案。

2. runtime 对 `ResLimit` 的支持是明确可用的。
- `aclrtSetDeviceResLimit`、`aclrtSetStreamResLimit`、`aclrtUseStreamResInCurrentThread` 存在实现。
- 资源维度仅 `CUBE_CORE` 和 `VECTOR_CORE`。

3. 事件计量能力完备。
- `aclrtRecordEvent`、`aclrtQueryEventStatus`、`aclrtEventElapsedTime`、`aclrtEventGetTimestamp` 可用于低侵入 active-time 计量。

---

## 3. 精准控制总体方案（双闭环）

构建“硬限制 + 精计量 + 软校正”双闭环：

1. 内环（硬限制）：
- 优先使用 stream 级 `ResLimit`。
- 不可用时退化到 device 级 `ResLimit`。

2. 外环（精准校正）：
- 基于事件的 active-time 计量替代 wall-time 近似。
- 用 token-bucket/PI 控制器对限额误差做闭环修正。

3. 调度协同：
- `scheduler` 从“按 wall-time 主导抢占”转为“按 active-time 主导配额”，`DROP_LOCK` 仅保留为兜底机制。

---

## 4. 详细设计

## 4.1 Capability Probe（启动时能力探测）

客户端启动后上报能力位图：

- `support_device_reslimit`
- `support_stream_reslimit`
- `support_stream_bind_thread`（`UseStreamResInCurrentThread`）
- `support_event_meter`（Record/Query/Elapsed）

调度器根据 capability 决定控制档位：

- `Tier-A`：stream + event（最佳）
- `Tier-B`：device + event（主兼容）
- `Tier-C`：device only（低精度降级）

## 4.2 提交路径全覆盖与线程绑定修正

在现有 hook 基础上，继续做两件事：

1. 提交路径覆盖检查（必须落地到探测结果）。
- 统计实际命中的 launch/execute API（已有 `XPUSHARE_NPU_API_TRACE` 可复用）。
- 若存在未命中的主提交路径，补拦截。

2. 每次提交前执行“流限制重绑定”。
- 对每个 intercepted launch 调用前执行：
  - `aclrtSetStreamResLimit(stream, ...)`（必要时按版本降频）
  - `aclrtUseStreamResInCurrentThread(stream)`
- 防止框架线程漂移导致 stream 限额失效。

## 4.3 Active-time 精计量（替代 wall-time）

为每个 client 的活跃 stream 维护轻量事件计量器：

1. 计量周期：`200~500ms`（可配）。
2. 每周期记录一对事件（start/end），使用 `aclrtQueryEventStatus` 异步轮询完成。
3. 用 `aclrtEventElapsedTime` 得到周期内设备活跃时间 `active_ms`。
4. 汇总得到：
- `client_active_ms_window`
- `client_active_ms_total`

说明：

- 这是“设备执行时间”口径，比 wall-time 对配额控制更直接。
- 不依赖私有驱动 perf counter。

## 4.4 配额控制器（外环）

以控制窗口 `W`（默认 `2000ms`）定义目标：

- `target_i = W * quota_i / sum(quota_on_same_device)`（sum<=100 时等价于常规配额）

每窗口计算误差：

- `err_i = active_i - target_i`

控制动作：

1. 基础硬限制（内环）
- 计算 `base_percent_i = quota_i`（或 oversub 归一后百分比）。
- 映射为 `cube/vector target` 并下发。

2. 精调补偿（外环）
- 维护 `bias_i`，按 PI（或先 P）更新：
  - `bias_i(t+1) = clamp(bias_i(t) + Kp*err_i + Ki*sum_err_i, [-B, +B])`
- 最终下发：`applied_percent_i = clamp(base_percent_i - bias_i, min=1, max=100)`

3. 强制限流兜底
- 若连续 `N` 个窗口超配额且误差超阈值，触发 `DROP_LOCK`。
- 但 `DROP_LOCK` 不再作为主控制手段，仅用于异常收敛。

## 4.5 调度器计费模型改造

`scheduler` 从“wall-time 主计费”改为“active-time 主计费”：

1. 新增消息 `ACTIVE_TIME_UPDATE`（client -> scheduler）。
2. `run_time_in_window_ms` 替换/并行为 `active_time_in_window_ms`。
3. `check_and_reset_window` 基于 active-time 重置、欠债与 carryover。
4. `DROP_TAIL_BILLING` 仅在无 event 计量时启用。

## 4.6 动态调额语义修正

动态更新 `core_limit` 后：

1. 立即刷新控制器目标（`target_i`）。
2. 立即触发一次 `ResLimit` 下发。
3. 对“已入队未执行任务”的滞后影响，用下一窗口 `bias` 自动纠偏。

## 4.7 版本兼容与降级策略

1. 若 stream-level API 缺失：
- 自动降级到 `Tier-B`（device + event）。

2. 若 event API 缺失：
- 降级到 `Tier-C`（device + wall-time），并打出明确告警。

3. 若 runtime 行为异常（频繁 107002/507000）：
- 不启用激进抢占，避免放大抖动；优先降低控制频率并保守收敛。

---

## 5. 协议与数据结构变更

## 5.1 新增消息

1. `ACTIVE_TIME_UPDATE`
- 字段：`client_id`, `device_uuid`, `active_ms_delta`, `window_id`, `capability_flags`

2. （可选）`QUOTA_CONTROL_HINT`
- scheduler 下发精调参数（`bias`/`kp`/`ki`）用于在线调参。

## 5.2 client 侧状态

- `capability_flags`
- `active_meter_state`（event 对、最近完成戳）
- `quota_bias`
- `quota_err_integral`

## 5.3 scheduler 侧状态

- `active_time_in_window_ms`
- `active_time_total_ms`
- `quota_error_window`
- `control_tier`

---

## 6. 监控指标（Prometheus）

新增建议指标：

1. `xpushare_npu_client_quota_target_percent`
2. `xpushare_npu_client_quota_applied_percent`
3. `xpushare_npu_client_active_time_ms_total`
4. `xpushare_npu_client_active_time_ms_window`
5. `xpushare_npu_client_quota_error_ratio`
6. `xpushare_npu_client_drop_lock_total`
7. `xpushare_npu_client_reslimit_apply_fail_total`
8. `xpushare_npu_client_control_tier`（A/B/C）
9. `xpushare_npu_client_stream_reslimit_bind_fail_total`

---

## 7. 实施阶段

## Phase-1（最小可落地，先止偏差）

1. capability probe + tier 上报。
2. event active-time 计量（只做采集，不改调度判定）。
3. 指标接入，输出“wall-time vs active-time 偏差”。

## Phase-2（主功能）

1. scheduler 切换为 active-time 主计费。
2. stream/device 级 `ResLimit` 统一下发与降级逻辑。
3. PI/P 控制器上线，`DROP_LOCK` 降级为兜底。

## Phase-3（精调与稳态优化）

1. 控制参数自适应（不同模型/节点）。
2. 补充异常保护（队列拥塞、初始化抖动、超时恢复）。

---

## 8. 验证方案（针对“精度”）

核心验证场景：

1. 单卡 2/4/8 并发，配额组合：
- `25/25`、`50/50`、`25/75`、`30/60`、`20/40/40` 等。

2. 动态调额：
- 运行中 `25 -> 50 -> 75`，观察收敛窗口数。

3. 兼容降级：
- 强制关闭 stream API / event API，验证 tier 降级与告警正确。

判定指标：

- 以 `bench` 时间折算份额与目标份额比对。
- 收敛期外（预热 1~2 窗口后）统计 P50/P95 误差。

---

## 9. 风险与边界

1. 无公开“process-level 硬 token 写入”接口。
- 在当前开源 driver 约束下，本方案不把 token 写入作为依赖。

2. event 计量引入少量开销。
- 需控制采样周期与事件复用策略，避免影响吞吐。

3. 框架内部多线程提交路径复杂。
- 必须持续做 API 命中率观测，防止漏拦截。

---

## 10. 结论

在当前开源 CANN driver/runtime 能力下，最现实且可精准落地的路线是：

- 以 `ResLimit` 做硬约束基线；
- 以 `Event active-time` 做计量闭环；
- 以 `PI/P + 最小化 DROP_LOCK` 做精度修正。

该路线可在不依赖私有内核接口的前提下显著降低 CANN 算力配额偏差，并与现有 xpushare 架构平滑融合。
