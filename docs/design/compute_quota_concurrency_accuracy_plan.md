# GPU 算力配额并发精度问题分析与改造方案

## 1. 背景与现象

基线任务：`tests/pytorch-add-small.py`，单任务无配额完成时间约 `392s`。

根据提供的实测数据，当前实现在多数场景下趋势正确，但在“混合配额 + 并发”场景出现明显偏差：

- 单任务：`75%/50%/25%` 对应 `592s/845s/1617s`，趋势符合预期。
- 双任务同 GPU（相同配额）：`50%/75%/不限` 都约 `860s` 左右，行为稳定。
- 双任务不同 GPU：`25%/50%/75%` 基本符合单任务对应配额趋势。
- **异常场景**：4 个任务分布在 2 张 GPU，每张 GPU 上 `30% + 60%`。
  - `30%` 任务约 `1400s`（接近预期）。
  - `60%` 任务约 `800s`（显著慢于“60% 基准”）。

从基线换算有效算力份额：

- `30%` 任务：`392 / 1400 ≈ 28%`（接近目标）。
- `60%` 任务：`392 / 800 ≈ 49%`（明显低于目标）。

这说明问题不是“系统完全失效”，而是**在混合配额并发时，高配额任务被系统性低估/压缩**。

---

## 2. 当前实现复盘（代码路径）

### 2.1 调度侧（`src/scheduler.c`）

1. 配额窗口：`COMPUTE_WINDOW_SIZE_MS = 2000`。
2. 计费方式：`pending_billed = pending_wall_time / n`（加权计费）。
3. 并发计数：`count_running_clients()` 当前统计“该 GPU 上已注册的限额 client（core_limit < 100）”，而不是严格的运行态集合。
4. 超额处理：达到配额后发送 `DROP_LOCK`，等待 client 回 `LOCK_RELEASED` 再从 `running_list` 移除。
5. 窗口重置：`check_and_reset_window()` 当前基于 `time(NULL)` 秒级时间。

### 2.2 客户端侧（`src/client.c` + `src/hook.c`）

1. `hook.c` 使用 `client_core_limit` 影响 `pending_kernel_window` 上限（quota-aware kernel window）。
2. `client_core_limit` 仅在注册时从 `SCHED_ON/SCHED_OFF` 消息读取。
3. 调度器在 annotation 动态变更配额时，当前只更新 `scheduler` 内存态 `target_client->core_limit`，**没有下发“compute limit update”消息到 client**。

结论：调度器侧配额已动态更新，但 client 侧流控窗口可能仍停留在旧值（常见是 100%）。

---

## 3. 根因分析（针对 30% + 60% 偏差）

## 3.1 根因 A：加权计费模型与真实 GPU 分享不一致

当前模型隐含假设是“并发时每个任务可近似按 `1/n` 获得算力”。
在 `30% + 60%` 这种混合配额下，实际会叠加：

- kernel 形态差异
- 同步/切换开销
- UVM 页迁移与带宽竞争

导致“墙钟时间 -> 实际完成工作量”并不线性。结果是高配额任务经常拿不到应有吞吐。

## 3.2 根因 B：`DROP_LOCK -> LOCK_RELEASED` 控制环延迟

低配额任务被 throttle 后不会瞬时让出 GPU，而是要经历 client 侧同步与释放路径。
这段延迟在 2s 窗口里占比不小，会侵蚀高配额任务的有效独占时间。

## 3.3 根因 C：窗口粒度过短且重置为秒级

当前窗口 `2000ms`，但重置依据是 `time(NULL)` 秒级；在并发+频繁限流时，会放大窗口边界误差和调度抖动。
窗口越短，误差与切换成本占比越大。

## 3.4 根因 D：动态配额未同步到 client 流控层

`hook.c` 的 quota-aware window 依赖 `client_core_limit`，但动态 annotation 更新不会推送到 client，造成：

- scheduler 认为配额已变；
- client 的 kernel 提交窗口可能还是旧值；
- 两侧控制策略不一致，进一步放大并发偏差。

---

## 4. 改造目标

1. 混合配额并发场景（如 `30% + 60%`）下任务完成时间偏差控制在 `±10%`。
2. 不破坏已验证的基线能力（单任务、双任务同配额、不同 GPU 并发）。
3. 改造分阶段可回滚，优先低风险增量修复。

---

## 5. 建议修改方案（分阶段）

## 5.1 Phase-1（必须，低风险）

### 5.1.1 新增 compute limit 动态下发通道

在消息协议中新增 `UPDATE_CORE_LIMIT`：

- scheduler annotation watcher 发现 `core_limit` 变化后，除了更新本地结构，也发送 `UPDATE_CORE_LIMIT` 给 client。
- client 收到后更新 `client_core_limit`。
- `hook.c` 的 `get_kernel_window_max()` 立即生效新配额。

收益：先解决“调度与客户端控制面不一致”的结构性问题。

### 5.1.2 窗口时间统一改为 monotonic 毫秒

- 将 `window_start_time` 从 `time_t`（秒）改为 `long window_start_ms`（`CLOCK_MONOTONIC`）。
- 用毫秒精度判断窗口到期，避免 2s 窗口下的秒级抖动。

### 5.1.3 增加关键可观测指标

在 scheduler 增加日志/指标（至少 debug 级）：

- `drop_to_release_ms`（每次 throttle 的释放延迟）
- `effective_limit_ms` / `current_usage_ms`
- 每窗口 `idle_ms`、`throttled_wait_ms`

收益：把“偏差”分解为可定位的指标，避免盲调。

## 5.2 Phase-2（并发精度修复）

### 5.2.1 引入“释放延迟补偿计费”

新增字段：

- `drop_sent_ms`
- `pending_drop`

策略：

1. 发送 `DROP_LOCK` 时记录 `drop_sent_ms`。
2. 收到 `LOCK_RELEASED` 时计算 `release_delay_ms = now - drop_sent_ms`。
3. 该延迟段按“保守权重”计费到被 throttle 任务（建议先按 `wall_time` 或 `wall_time * 0.75` 计费，可配置）。

目的：防止低配额任务因释放迟滞持续占用 GPU，却只按理想并发系数低价计费。

### 5.2.2 窗口长度改为可配置并提高默认值

- 增加 `NVSHARE_COMPUTE_WINDOW_MS`（默认建议 `4000~6000`）。
- 2s 对重负载任务切换过于频繁，窗口稍拉长可显著降低控制面损耗。

> 经验：对于 `pytorch-add-small` 这类长时间稳定负载，稍长窗口通常比高频抢占更准确。

## 5.3 Phase-3（兜底策略，建议）

### 5.3.1 引入“配额精度保护模式（quota-serial fallback）”

触发条件（示例）：

- 连续 N 个窗口（如 5）观测到 `sum(quota_error) > 15%`；或
- `drop_to_release_ms` 的 P95 高于阈值（如 200ms）。

动作：

- 对该 GPU context 暂时切换到“按配额比例串行轮转”（非全局串行）。
- 按 `slice_i = window_ms * quota_i / sum_quota` 分配运行片段。

收益：牺牲部分并发，换取更可预测的配额精度；可作为复杂负载场景兜底。

---

## 6. 参考实现要点

## 6.1 协议扩展

- `comm.h` 新增 message type：`UPDATE_CORE_LIMIT`。
- `struct message` 复用已有 `core_limit` 字段。

## 6.2 Scheduler 关键改动点

1. `annotation_watcher_fn`：core_limit 变化时发送 `UPDATE_CORE_LIMIT`。
2. `check_and_reset_window`：改为 `window_start_ms` 毫秒比较。
3. throttle 流程中记录 `drop_sent_ms`，`LOCK_RELEASED` 时做延迟计费。
4. `COMPUTE_WINDOW_SIZE_MS` 改为运行时配置项。

## 6.3 Client/Hook 关键改动点

1. `client_fn` 新增 `UPDATE_CORE_LIMIT` case：更新 `client_core_limit`。
2. `hook.c` 维持 `get_kernel_window_max()`，但确保读取的是最新 `client_core_limit`。

---

## 7. 验证方案（针对你的测试矩阵）

## 7.1 必测场景

1. 单任务：`25/50/60/75`。
2. 同 GPU 双任务：
   - `50+50`
   - `30+60`
   - `75+75`
3. 双 GPU 四任务：每 GPU `30+60`（你提到的关键异常）。

## 7.2 验收指标

1. 完成时间折算算力误差：
   - `|effective_share - target_share| <= 10%`（关键场景）
2. `drop_to_release_ms`：P95 显著下降。
3. 同 GPU 双任务总有效算力接近配额总和（如 `30+60` 接近 `90%`，允许小幅损耗）。

---

## 8. 风险与回滚

1. 协议新增消息需 client/scheduler 同步升级；若版本不一致，需兼容处理（未知消息忽略）。
2. 释放延迟补偿计费可能让低配额任务更慢，建议先灰度并提供开关。
3. quota-serial fallback 仅在误差持续超阈值时触发，避免影响正常并发场景。

---

## 9. 建议落地顺序

1. 先做 Phase-1（协议补齐 + 毫秒窗口 + 可观测性）。
2. 用你现有脚本复测 `30+60` 关键场景，确认偏差主要来源。
3. 再做 Phase-2（释放延迟补偿 + 窗口参数化）。
4. 若仍不达标，再启用 Phase-3 兜底。

这条路线对现有架构侵入最小，且每一步都有可量化回归标准，便于快速迭代与回滚。
