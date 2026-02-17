# NVShare 多集群全功能测试方案（T4 + A800）

## 1. 背景与目标

你当前需要系统验证近期核心改动在两套异构 K8s 集群上的正确性、性能和稳定性：

1. 显存超分（`NVSHARE_ENABLE_SINGLE_OVERSUB`）
2. 显存配额（静态）
3. GPU 算力配额（静态）
4. 显存配额动态调整（Annotation）
5. 算力配额动态调整（Annotation）
6. Metrics 采集（调度器、GPU、进程/Pod、配额、利用率）

本方案给出可执行的分阶段测试矩阵，覆盖功能、组合、性能、稳定性、泄漏与可观测性。

## 2. 集群资源画像

| 集群 | 节点 | GPU 型号 | 每卡显存 | 总卡数 | 重点验证方向 |
|---|---|---|---|---|---|
| Cluster-1 | 2 节点（2 卡 + 8 卡） | Tesla T4 | 16GiB | 10 | 低显存场景、配额边界、超分触发频率高 |
| Cluster-2 | 2 节点（8 卡 + 8 卡） | A800 | 40GiB | 16 | 大显存场景、高并发规模、动态配额平滑性 |

说明：

1. Cluster-1 更容易暴露显存边界、超分抖动、配额冲突问题。
2. Cluster-2 更适合做大规模并发与长稳压测。

## 3. 工作负载定义

| 负载 ID | 脚本 | 特征 | 典型用途 |
|---|---|---|---|
| W1 | `tests/pytorch-add.py` | 大显存 + 中高算力 | 超分、配额边界、性能基线 |
| W2 | `tests/pytorch-add-small.py` | 中显存 + 持续算力 | 组合功能、配额精度、并发公平性 |
| W3 | `tests/pytorch-add-idle-small.py` | 中显存 + 低算力长时 | 动态配额、调度切换、稳定性 |
| W4（建议新增） | `tests/pytorch-alloc-free-loop.py` | 周期性申请释放 | 内存泄漏/碎片化验证 |
| W5（建议新增） | `tests/pytorch-quota-probe.py` | 固定周期输出吞吐 | 动态算力配额生效延迟与精度 |

建议新增说明：

1. `W4`：循环 allocate/free + `torch.cuda.synchronize()`，用于泄漏与回收验证。
2. `W5`：每 10s 输出一次吞吐统计，便于动态配额切换后的响应时间分析。

## 4. 复用与新增脚本策略

优先复用现有脚本：

1. `tests/remote-test-complex2.sh`（并发综合）
2. `tests/remote-test-memlimit.sh`（静态显存配额）
3. `tests/remote-test-dynamic-limit.sh`（动态显存配额）
4. `tests/remote-test-compute-limit.sh`（动态算力配额）
5. `tests/remote-test-small.sh` / `tests/remote-test-idle-small.sh`（小负载并发）

建议新增脚本（用于规模化执行本方案）：

1. `tests/remote-test-multicluster-matrix.sh`：按 Case ID 执行矩阵并自动采集日志。
2. `tests/remote-test-metrics-validation.sh`：专门验证 `/metrics` 指标一致性。
3. `tests/remote-test-soak.sh`：6h/24h 稳定性与泄漏测试。
4. `tests/remote-test-churn.sh`：高频创建/删除 + Annotation 抖动测试。

## 5. 测试前准备

## 5.1 通用准备

1. 两集群都完成最新镜像部署（scheduler、device-plugin、libnvshare）。
2. 统一记录版本信息：git commit、镜像 tag、配置项。
3. 打通日志采集目录：
   - 建议：`.tmplog/<date>/<cluster>/<case-id>/`
4. 开启基础观测：
   - scheduler 日志
   - Pod 日志
   - `nvidia-smi` 周期采样
   - `nvidia-smi dmon -s u -d 1`
   - `/metrics` 抓取快照

## 5.2 基线采样（每个 Case 前）

1. 空闲状态下每 GPU 的 `nvidia-smi` 显存占用基线。
2. scheduler Pod 的 RSS、FD 基线：
   - `/proc/1/status`（VmRSS）
   - `/proc/1/fd` 数量
3. `/metrics` 可用性基线（`GET /healthz`，`GET /metrics`）。

## 6. 通过标准（总体验收门槛）

P0（必须通过）：

1. 所有功能 Case 无崩溃、无死锁、无“任务永久 Pending”。
2. 动态显存/算力配额在不重启 Pod 前提下生效。
3. Metrics 端点稳定可抓，核心指标完整。

P1（性能与精度）：

1. 算力配额精度：
   - 单任务：误差不超过 ±8%
   - 同卡混合配额并发：误差不超过 ±10%（T4 可放宽至 ±12%）
2. 动态配额变更生效延迟：不超过 15s（含采样与调度传播）。

P2（稳定性）：

1. 24h 压测期间 scheduler 无重启、无显著 RSS/FD 单调增长。
2. 任务清空后 GPU 显存回落到“空闲基线 + 合理浮动范围”。

## 7. 功能测试矩阵（Functional）

| Case ID | 功能点 | 集群 | 负载 | 场景与步骤 | 预期结果 |
|---|---|---|---|---|---|
| FUNC-001 | 基线单任务 | C1+C2 | W2 | 1 Pod 无任何 quota | 任务 PASS，记录基线耗时/吞吐 |
| FUNC-002 | 同卡双任务并发 | C1+C2 | W2 | 2 Pod 定向同 1 GPU | 两任务都推进，无长期饥饿 |
| FUNC-003 | 跨卡分布 | C1 | W2 | 12 Pod（超过单卡承载） | 任务分散到多 GPU，调度无异常 |
| FUNC-004 | 显存超分关闭 | C1 | W1 | `oversub=0`，触发超物理申请 | 按预期 OOM/拒绝分配 |
| FUNC-005 | 显存超分开启 | C1+C2 | W1 | `oversub=1` 同场景重测 | 可运行但性能可能下降，无崩溃 |
| FUNC-006 | 静态显存配额-不足 | C1+C2 | W2 | 设置低于需求（如 1Gi） | 明确失败（OOM/拒绝） |
| FUNC-007 | 静态显存配额-充足 | C1+C2 | W2 | 设置 4Gi（T4）/8Gi（A800） | 稳定通过 |
| FUNC-008 | 静态算力配额单任务 | C1+C2 | W2 | 25/50/75% 分别运行 | 耗时与配额单调一致 |
| FUNC-009 | 静态算力配额混合并发 | C1+C2 | W2 | 同卡 30% + 60% | 高配额任务明显更快 |
| FUNC-010 | 动态显存配额上调 | C1+C2 | W2 | 2Gi -> 4Gi（运行中） | 后续分配成功，任务继续 |
| FUNC-011 | 动态显存配额下调 | C1+C2 | W2 | 4Gi -> 2Gi（运行中） | 新增分配受限，系统不崩溃 |
| FUNC-012 | 动态算力配额调整 | C1+C2 | W3/W5 | 30% -> 80% -> 100% | 吞吐按阶段提升，延迟 < 15s |

## 8. 组合功能测试矩阵（Combination）

| Case ID | 组合 | 集群 | 负载 | 场景与步骤 | 预期结果 |
|---|---|---|---|---|---|
| COMBO-001 | 超分 + 静态显存配额 | C1 | W1 | `oversub=1` + quota=10Gi | 配额优先约束，超限拒绝 |
| COMBO-002 | 超分 + 算力配额 | C1+C2 | W2 | 同卡 2~4 Pod 不同比例 | 配额生效，调度稳定 |
| COMBO-003 | 静态显存 + 静态算力配额 | C1+C2 | W2 | 同时配置二者 | 两种配额都可观测且生效 |
| COMBO-004 | 动态显存 + 动态算力 | C1+C2 | W3/W5 | 双 annotation 交替修改 | 生效顺序正确，无卡死 |
| COMBO-005 | 超分 + 动态显存 | C1 | W1/W2 | 运行中反复调高调低 | 行为可预期，不崩溃 |
| COMBO-006 | 超分 + 动态算力 | C1+C2 | W2 | 配额变化期间并发切换 | 吞吐变化连续、无长尾卡死 |
| COMBO-007 | 全开组合（全部功能） | C1+C2 | W2/W3 | 4~8 Pod 混合配置 | 全链路可运行并可观测 |
| COMBO-008 | 多 GPU + 混合配置 | C1/C2 大规模 | W2 | 不同 GPU 不同配额策略 | GPU 之间互不污染 |

## 9. 性能测试方案（Performance）

## 9.1 关键指标

1. 单任务完成时间（E2E）
2. 吞吐（it/s）
3. GPU 利用率（平均/95 分位）
4. 调度开销（LOCK/DROP 频率）
5. 配额精度误差（实际算力占比 vs 配置）

## 9.2 性能 Case

| Case ID | 集群 | 负载 | 场景 | 指标与判定 |
|---|---|---|---|---|
| PERF-001 | C1+C2 | W2 | 无 quota 基线 | 建立每 GPU 型号基线 |
| PERF-002 | C1+C2 | W2 | 开启 metrics vs 关闭 metrics | 性能回退 < 5% |
| PERF-003 | C1+C2 | W2 | 单任务 25/50/75% quota | 单调性正确，误差阈值满足 |
| PERF-004 | C1+C2 | W2 | 同卡 30%+60% | 完成时间比值接近配额倒数比 |
| PERF-005 | C1 | W1 | 超分关闭/开启对比 | 记录超分性能代价曲线 |
| PERF-006 | C2 | W1 | A800 大显存下超分影响 | 观察大显存场景是否更平滑 |
| PERF-007 | C1+C2 | W3 | 低算力长跑 + 动态算力 | 生效延迟和稳定性达标 |
| PERF-008 | C1+C2 | W2 | 并发规模阶梯（2/4/8/16 Pod） | 吞吐不出现异常断崖 |

## 10. 稳定性与泄漏测试（Stability）

## 10.1 长稳 Case

| Case ID | 时长 | 集群 | 负载 | 场景 | 通过标准 |
|---|---|---|---|---|---|
| STAB-001 | 6h | C1 | W2 | 固定 4 Pod 同卡轮转 | 无崩溃，无卡死 |
| STAB-002 | 24h | C2 | W2/W3 | 16~32 Pod 持续混合负载 | 调度稳定，日志无异常风暴 |
| STAB-003 | 6h | C1+C2 | W3 | 动态算力每 5min 调整 | 生效稳定，无失控抖动 |
| STAB-004 | 6h | C1+C2 | W2 | 动态显存每 5min 调整 | 无协议异常/僵尸 client |

## 10.2 泄漏与资源回收 Case

| Case ID | 集群 | 负载 | 检查项 | 通过标准 |
|---|---|---|---|---|
| LEAK-001 | C1+C2 | W4 | scheduler RSS 斜率 | 无持续上升趋势（可微幅波动） |
| LEAK-002 | C1+C2 | W4 | scheduler FD 数量 | 不持续单调增长 |
| LEAK-003 | C1+C2 | W2/W4 | GPU 显存回收 | 清空负载后回落至基线附近 |
| LEAK-004 | C1+C2 | W2/W3 | client 生命周期 | 大量创建删除后无幽灵 client |
| LEAK-005 | C1+C2 | W2 | metrics series 数量 | Pod 删除后 series 不无界增长 |

## 10.3 干扰与故障注入

| Case ID | 集群 | 场景 | 预期结果 |
|---|---|---|---|
| FAIL-001 | C1+C2 | 压测中重启 scheduler DS | 任务可恢复，系统无雪崩 |
| FAIL-002 | C1+C2 | 压测中重启 device-plugin DS | 新老任务行为可预期 |
| FAIL-003 | C1 | drain 2 卡节点 | 任务重调度，不出现永久 Pending |
| FAIL-004 | C2 | 单节点 GPU 大规模负载后恢复 | 指标与调度状态恢复正常 |

## 11. Metrics 专项测试（Observability）

## 11.1 指标完整性

| Case ID | 验证内容 | 方法 | 通过标准 |
|---|---|---|---|
| MET-001 | `/healthz` 与 `/metrics` 可用 | curl/port-forward | 100% 成功 |
| MET-002 | 指标存在性 | 对照清单检查 | 核心指标齐全 |
| MET-003 | 显存指标一致性 | 对比 scheduler 日志、NVML、metrics | 趋势一致，语义一致 |
| MET-004 | quota 指标一致性 | annotation/env 与指标值对比 | 配置和指标一致 |
| MET-005 | 动态变更延迟 | 修改 annotation 后观察指标更新时间 | < 15s |
| MET-006 | GPU 利用率指标 | 与 `nvidia-smi dmon` 对比 | 趋势一致 |
| MET-007 | 高并发抓取 | 2s 抓取间隔压力 | 无明显超时/崩溃 |
| MET-008 | 告警演练 | 人工触发高显存/throttle | 规则能正确触发 |

## 11.2 推荐 PromQL 验证

1. GPU 显存使用率：

```promql
nvshare_gpu_memory_used_bytes / nvshare_gpu_memory_total_bytes
```

2. Pod 估算内存峰值：

```promql
max_over_time(nvshare_client_memory_need_estimated_bytes[10m])
```

3. 算力配额使用率：

```promql
nvshare_client_core_window_usage_ms / nvshare_client_core_window_limit_ms
```

4. 节流状态：

```promql
avg_over_time(nvshare_client_throttled[5m])
```

## 12. 执行顺序（建议）

1. 阶段 A：基础功能（FUNC-001~012）
2. 阶段 B：组合功能（COMBO-001~008）
3. 阶段 C：性能（PERF-001~008）
4. 阶段 D：可观测性（MET-001~008）
5. 阶段 E：稳定性与泄漏（STAB/LEAK/FAIL）

建议策略：

1. 先在 Cluster-1（T4）跑完功能与组合。
2. 再在 Cluster-2（A800）跑性能与规模。
3. 最后双集群并行执行 24h 稳定性。

## 13. 日志与结果归档规范

每个 Case 固定保存：

1. scheduler 日志（完整）
2. 相关 Pod 日志
3. `nvidia-smi` 快照与 `dmon` 数据
4. `/metrics` 快照（开始/中间/结束）
5. 测试结论 JSON（建议字段：case_id、cluster、start/end、pass/fail、reason、关键指标）

目录建议：

```text
.tmplog/<run-id>/xpushare/<cluster>/<suite>/<case-id>/
  result.json
  analysis.txt
  scheduler.log
  device-plugin.log
  metrics.txt
  metrics_health.txt
  pods/
  remote_*_dmon.txt
  remote_*_nvidia_smi.txt
```

## 14. 典型风险与应对

1. UVM 进程驻留显存口径偏差：
   - 统一使用多口径并行验证（managed/NVML/估算）。
2. 不同 GPU 型号基线差异大：
   - 使用“相对基线”而非绝对耗时阈值。
3. 动态配额高频更新导致日志噪声：
   - 增加采样窗口统计，避免仅凭瞬时值判定。
4. 长稳测试误判泄漏：
   - 以趋势线和回收后基线复位联合判定，不以单点波动判定。

## 15. 最终交付物

执行完本方案后，建议输出：

1. `多集群测试总报告`（功能通过率、性能对比、稳定性结论）
2. `问题清单`（按 P0/P1/P2 分级）
3. `回归基线快照`（后续版本对比使用）
4. `可复用自动化脚本`（矩阵执行 + 日志归档 + 基础判定）

## 16. 用例逐项设计说明与结果分析方法

本节用于补充“每个用例为什么这样设计、预期达到什么效果、如何分析结果”。

## 16.1 统一结果查看入口（适用于所有 Case）

推荐先看 run 级汇总，再下钻到 case 目录：

1. run 总结：`.tmplog/<run-id>/xpushare/run-summary.tsv`
2. case 总结：`.tmplog/<run-id>/xpushare/case-summary.tsv`
3. case 目录：
   - `result.json`：PASS/FAIL 与 summary
   - `analysis.env` / `analysis.txt`：自动分析摘要
   - `scheduler.log`、`device-plugin.log`
   - `pods/*.log`
   - `metrics*.txt`、`metrics_health*.txt`
   - `cluster_snapshot.txt`、`scheduler_proc.txt`

常用复盘命令（示例）：

```bash
RUN_ID=20260215-xxxxxx
cat .tmplog/$RUN_ID/xpushare/run-summary.tsv
cat .tmplog/$RUN_ID/xpushare/case-summary.tsv
```

## 16.2 Functional（FUNC）逐项说明

| Case | 设计意图 | 预期效果 | 结果查看/分析方法 |
|---|---|---|---|
| FUNC-001 | 建立“无 quota”单任务基线 | Pod 成功，产出耗时基线 | 看 `pods/*.log` 的 `PASS` 与 `--- x seconds ---`；记录 `metrics.txt` 基线值 |
| FUNC-002 | 验证同卡并发基本公平性 | 两任务都可推进并完成，无长期饥饿 | 看两 Pod 均 `Succeeded`；`gpu_mapping.txt` 检查是否同 GPU（best effort） |
| FUNC-003 | 验证跨卡分布能力 | 大并发下可分散到多 GPU，调度稳定 | 看 `cluster_snapshot.txt`、`metrics.txt`（`client_info` 的 `gpu_index` 分布） |
| FUNC-004 | 验证超分关闭时的保护 | 超物理申请时被拒绝或 OOM | 看 `pods/*.log` 中 OOM/拒绝分配关键字；Pod phase 有 `Failed` |
| FUNC-005 | 验证超分开启后的可运行性 | 相同压力下可运行或受压退化，但系统不崩溃 | 看 `scheduler.log` 无崩溃；`xp_count_running_scheduler` 对应运行中 |
| FUNC-006 | 验证显存配额不足会失败 | 低配额触发失败（OOM/拒绝） | 看 `pods/*.log` 与 `Failed` 计数 |
| FUNC-007 | 验证显存配额充足可通过 | T4=4Gi/A800=8Gi 时稳定通过 | 看 Pod `Succeeded`；日志 `PASS` |
| FUNC-008 | 验证单任务算力配额单调性 | 25% 比 50% 慢，50% 比 75% 慢 | 看 `durations.txt`；检查 `d25>d50>d75` |
| FUNC-009 | 验证混合算力并发差异 | 同卡 30% 任务显著慢于 60% | 看 `runtime_compare.txt` 与两 Pod 耗时比 |
| FUNC-010 | 验证运行中显存配额上调 | 上调后更新信号出现，任务可继续 | 看 `scheduler.log` 中 `UPDATE_LIMIT/Memory limit changed` |
| FUNC-011 | 验证运行中显存配额下调 | 下调后限制生效，系统稳定 | 看 `scheduler.log` 更新信号；Pod 无异常崩溃 |
| FUNC-012 | 验证运行中算力配额调整 | 30%->80%->100% 更新链路正确 | 看 `scheduler.log` 中 `UPDATE_CORE_LIMIT/Compute limit changed` |

## 16.3 Combination（COMBO）逐项说明

| Case | 设计意图 | 预期效果 | 结果查看/分析方法 |
|---|---|---|---|
| COMBO-001 | 验证“超分+显存配额”优先级 | 配额仍应是硬约束，超限受控 | 看 `pods/*.log` OOM/拒绝；`scheduler.log` 配额限制痕迹 |
| COMBO-002 | 验证“超分+算力配额”并发行为 | 配额仍生效，较高配额更快 | 看两 Pod 耗时；同卡时运行时长满足高配额更优 |
| COMBO-003 | 验证“静态显存+静态算力”同时生效 | 任务通过；两类配额指标可观测 | 重点看 `metrics_mid.txt` 与 `metrics.txt`；检查 `nvshare_client_memory_quota_bytes` 与 `nvshare_client_core_quota_effective_percent` |
| COMBO-004 | 验证双动态配额交替更新 | 更新顺序正确、无卡死 | 看 `scheduler.log` 中 memory/core 两类更新日志 |
| COMBO-005 | 验证“超分+动态显存”稳定性 | 反复调高调低仍稳定 | 看 `scheduler.log` 更新次数与 scheduler 存活状态 |
| COMBO-006 | 验证“超分+动态算力”稳定性 | 吞吐随配额变化，且无长尾卡死 | 看 `pods/*.log` 的 `QUOTA_PROBE` 与 `scheduler.log` 更新日志 |
| COMBO-007 | 验证“全开组合”可用性 | 4~8 Pod 混合配置整体可运行且可观测 | 看成功数、关键 metrics 是否存在、日志是否有系统性异常 |
| COMBO-008 | 验证多 GPU 配置隔离 | 不同 GPU 策略互不污染 | 看 `metrics_mid.txt` 中 `gpu_index` 去重数量、分布是否合理 |

## 16.4 Performance（PERF）逐项说明

| Case | 设计意图 | 预期效果 | 结果查看/分析方法 |
|---|---|---|---|
| PERF-001 | 建立各 GPU 型号性能基线 | 输出可复用 baseline | 看 `baseline_runtime_sec`、`pods/*.log` |
| PERF-002 | 度量 metrics 采样开销 | 开启采样回退不超过阈值（默认 5%） | 看 `runtime_metrics_off/on` 与 `metrics_overhead_pct` |
| PERF-003 | 验证单任务算力配额精度趋势 | 25/50/75 单调正确 | 看 `quota_runtime.txt` |
| PERF-004 | 验证同卡混合配额收益 | 30/60 比值接近预期 | 看 `runtime_ratio_30_over_60` |
| PERF-005 | T4 上超分性能代价曲线 | 形成 off/on 对比记录 | 看 `oversub_off/on_phase` 与运行时长 |
| PERF-006 | A800 上超分影响 | 观察大显存场景平滑性 | 看 `a800_oversub_*` 记录 |
| PERF-007 | 动态算力生效延迟 | 指标层面延迟 <= 15s | 看 `dynamic_compute_metric_latency_sec` |
| PERF-008 | 并发规模阶梯稳定性 | 2/4/8/16 不出现断崖异常 | 看 `scale_results.txt` 的成功数与耗时曲线 |

## 16.5 Metrics（MET）逐项说明

| Case | 设计意图 | 预期效果 | 结果查看/分析方法 |
|---|---|---|---|
| MET-001 | 端点可用性基线 | `/healthz`=200，`/metrics` 有 `nvshare_` 指标 | 看 `metrics_health.txt` 的 `HTTP_CODE` 与 `metrics.txt` |
| MET-002 | 指标完整性校验 | 核心指标全存在 | 看 `missing_metrics.txt`、`missing_metric_count` |
| MET-003 | 显存指标语义一致性 | `nvml/need/gpu_used` 均为正，趋势一致 | 看 `metrics_mid.txt` 与 case kv 三个 sum 值 |
| MET-004 | quota 指标值一致性 | 指标值与 annotation/env 配置一致 | 看 `metric_memory_quota_bytes`、`metric_core_quota_percent` |
| MET-005 | 动态变更传播延迟 | 配额变更后指标在阈值内更新 | 看 `dynamic_quota_metric_latency_sec` |
| MET-006 | GPU 利用率指标有效性 | 负载期间 util 指标明显上升 | 看 `metrics_series.txt` 与 `max_gpu_util_ratio` |
| MET-007 | 高频抓取稳定性 | 2s 抓取无明显超时或崩溃 | 看 `metrics_stress_sample_count` 与健康检查结果 |
| MET-008 | 告警演练可触发性 | 高显存占用阈值可触达 | 看 `peak_gpu_memory_used_ratio` 是否超过阈值 |

## 16.6 Stability / Leak / Fail 逐项说明

| Case | 设计意图 | 预期效果 | 结果查看/分析方法 |
|---|---|---|---|
| STAB-001 | C1 固定负载长期轮转稳定性 | 无崩溃、无卡死 | 看 `scheduler_series.txt`、`iterations`、scheduler 存活 |
| STAB-002 | C2 大规模长稳能力 | 长时混合负载可稳定推进 | 看 `scheduler_series.txt` 与每轮成功情况 |
| STAB-003 | 动态算力频繁调整稳定性 | 周期调整无失控抖动 | 看 `update_timeline.txt`、`scheduler.log` 更新日志 |
| STAB-004 | 动态显存频繁调整稳定性 | 周期调整无协议异常/僵尸 | 看 `update_timeline.txt`、`scheduler.log` |
| LEAK-001 | scheduler RSS 泄漏检测 | RSS 增长不超过阈值 | 看 `rss_series.txt`、`rss_growth_kb` |
| LEAK-002 | FD 泄漏检测 | FD 增长不超过阈值 | 看 `fd_series.txt`、`fd_growth` |
| LEAK-003 | GPU 显存回收验证 | 清空后回落至基线附近 | 对比 `metrics_before/after.txt` 的 GPU used sum |
| LEAK-004 | client 生命周期回收 | churn 后无 ghost client | 看 `client_info_series_after_churn` |
| LEAK-005 | metrics series 回收 | series 不无界增长 | 看 `series_before/after/growth` |
| FAIL-001 | 压测中重启 scheduler | 系统恢复，无雪崩 | 看 `rollout` 状态与任务终态 |
| FAIL-002 | 压测中重启 device-plugin | 行为可预期并恢复 | 看 `rollout` 状态、任务成功率 |
| FAIL-003 | 节点 drain 干扰恢复 | 重调度后无永久 Pending | 看 pod phase 变化与最终终态 |
| FAIL-004 | 单节点高负载恢复 | 压力后调度/指标恢复正常 | 看成功数、`scheduler.log`、`metrics` 回落 |

## 16.7 失败定位建议（按现网执行顺序）

当某个 case FAIL，建议按以下顺序排查：

1. `result.json` + `analysis.txt`：先看失败摘要与自动分析指标。
2. `pods/*.log`：确认业务错误（OOM、CUDA、超时、无 PASS）。
3. `scheduler.log`：确认调度事件、配额更新、异常堆栈。
4. `metrics*.txt`：确认指标存在性、标签维度、数值趋势。
5. `cluster_snapshot.txt` + `scheduler_proc.txt`：确认节点状态、scheduler 资源状态。
6. `remote_*_nvidia_smi.txt` / `remote_*_dmon.txt`：与 metrics 交叉验证 GPU 使用趋势。

## 17. 脚本级执行细节（逐 Case，可直接对照代码）

本节按 `tests/xpushare/suites/*.sh` 当前实现说明每个 case 的“实际操作、采集数据、判定规则”。

## 17.1 共用执行与采集动作（默认）

除个别特殊 case 外，通用动作如下：

1. `xp_cleanup_app`：删除历史 Pod，并轮询确认删除完成。
2. `xp_apply_workload_pod/group`：下发工作负载（`w1~w5`），并轮询确认创建成功。
3. `xp_wait_for_pod_phase/terminal` 或 `xp_wait_for_label_terminal`：等待运行或结束状态。
4. `xp_collect_common_artifacts`：采集：
   - `cluster_snapshot.txt`
   - `scheduler.log`
   - `device-plugin.log`
   - `scheduler_proc.txt`
   - `metrics_health.txt`
   - `metrics.txt`
   - `pods/*.log`
   - `remote_*_nvidia_smi.txt` / `remote_*_dmon.txt`（配置 SSH 时）
5. `xp_case_end`：输出 `result.json`、`analysis.env`、`analysis.txt` 并汇总到 `case-summary.tsv`。

说明：若 case 只校验 metrics 端点（如 `MET-001`），可能不走完整 `xp_collect_common_artifacts`。

## 17.2 Functional（FUNC）逐 Case 细节

| Case | 脚本实际执行动作（按顺序） | 重点采集数据 | PASS 判定 |
|---|---|---|---|
| FUNC-001 | 清理 -> 起 1 个 `w2`（无 quota） -> 等待结束 -> 采集通用数据 | `pods/*.log`、`metrics.txt` | 1/1 Pod `Succeeded` |
| FUNC-002 | 清理 -> 起 2 个 `w2` -> 等待结束 -> 采集 -> 记录两 Pod GPU UUID 映射 | `pods/*.log`、`gpu_mapping.txt` | 2/2 Pod `Succeeded`（是否同卡仅告警，不影响 PASS） |
| FUNC-003 | 清理 -> 起 12 个 `w2` -> 等待结束 -> 采集 | `cluster_snapshot.txt`、`metrics.txt` | 12/12 `Succeeded` |
| FUNC-004 | 清理 -> 起 1 个 `w4`（`oversub=0`） -> 等待结束 -> 采集 | `pods/*.log` | 出现失败 Pod，或日志含 OOM/拒绝关键字 |
| FUNC-005 | 清理 -> 起 1 个 `w4`（`oversub=1`） -> 等待结束 -> 采集 | `pods/*.log`、`scheduler.log` | 日志含 `PASS`/OOM 压力信号，且 scheduler 仍在运行 |
| FUNC-006 | 清理 -> 起 1 个 `w2`（`NVSHARE_GPU_MEMORY_LIMIT=1Gi`） -> 等待结束 -> 采集 | `pods/*.log` | 失败信号（Failed 或 OOM/拒绝） |
| FUNC-007 | 清理 -> 起 1 个 `w2`（C1=4Gi、C2=8Gi）-> 等待结束 -> 采集 | `pods/*.log` | 1/1 `Succeeded` |
| FUNC-008 | 循环 25/50/75：每轮起 1 个 `w2`（`gpu-core-limit=q`）-> 等待结束 -> 采集 -> 记录耗时 | `durations.txt` | 三组耗时齐全且 `d25>d50>d75` |
| FUNC-009 | 清理 -> 同时起 `w2@30%` 与 `w2@60%` -> 等待各自结束 -> 采集 -> 对比耗时 | `runtime_compare.txt` | 两耗时存在且 `runtime_30 > runtime_60` |
| FUNC-010 | 清理 -> 起 1 个 `w5`（`gpu-memory-limit=4Gi`）-> Running 后改注解到 `8Gi` -> 采集 | `scheduler.log` | 命中 `Memory limit changed/UPDATE_LIMIT` |
| FUNC-011 | 清理 -> 起 1 个 `w5`（`8Gi`）-> Running 后改 `2Gi` -> 采集 | `scheduler.log` | 命中 `Memory limit changed/UPDATE_LIMIT` |
| FUNC-012 | 清理 -> 起 1 个 `w5`（`core=30`）-> Running 后改 `80` 再 `100` -> 采集 | `scheduler.log` | 命中 `Compute limit changed/UPDATE_CORE_LIMIT` |

## 17.3 Combination（COMBO）逐 Case 细节

| Case | 脚本实际执行动作（按顺序） | 重点采集数据 | PASS 判定 |
|---|---|---|---|
| COMBO-001 | 仅 C1：起 1 个 `w1`（`oversub=1`,`mem-ann=10Gi`）-> 等待结束 -> 采集 | `pods/*.log`、`scheduler.log` | 出现失败或 OOM/quota 关键字 |
| COMBO-002 | 起 2 个 `w2`（30/70，`oversub=1`）-> 等待结束 -> 采集 -> 若不同卡则 SKIP 断言 | `pods/*.log`、`gpu_mapping.txt` | 同卡时要求 `runtime_30 > runtime_70`；不同卡记 SKIP |
| COMBO-003 | 起 2 个 `w2`（`core=40/70`,`mem-ann=4Gi/8Gi`）-> 两 Pod Running 时抓 `metrics_mid.txt` -> 等待结束并采集 | `metrics_mid.txt`、`metrics.txt` | 2 Pod 成功；若 quota 指标缺失，当前实现记 PASS 但 summary 提示缺失 |
| COMBO-004 | 起 1 个 `w5`（`core=30`,`mem=2Gi`）-> 依次改内存/算力注解（4Gi->80->3Gi->50）-> 采集前后快照 | `metrics_start.txt`、`metrics_end.txt`、`scheduler.log` | scheduler 日志同时命中 memory/core 更新信号 |
| COMBO-005 | 仅 C1：起 1 个 `w5`（`oversub=1`,`mem=4Gi`）-> 运行中改 `8Gi->2Gi->6Gi` -> 采集 | `scheduler.log`、`metrics.env` | scheduler 存活且 memory 更新日志次数 >=2 |
| COMBO-006 | 起 1 个 `w5`（`oversub=1`,`core=30`）-> 改 `80->40->100` -> 采集 | `scheduler.log`、`pods/*.log` | compute 更新日志次数 >=2 且 Pod 日志有 `QUOTA_PROBE` |
| COMBO-007 | 起 4 个混合 Pod：`w2/w3/w2/w5`（不同 core + mem + oversub）-> 等待结束 -> 采集 | `metrics.txt`、`pods/*.log` | 成功数 >=3，且 memory/core quota 指标存在 |
| COMBO-008 | 起 8 个 `w5`（不同 core/mem/oversub）-> 运行中抓 `metrics_mid.txt` -> 等待结束 -> 采集 | `metrics_mid.txt` | `client_info` 中 `gpu_index` 去重数 >=2 |

## 17.4 Performance（PERF）逐 Case 细节

| Case | 脚本实际执行动作（按顺序） | 重点采集数据 | PASS 判定 |
|---|---|---|---|
| PERF-001 | 起 1 个 `w2` baseline -> 等待结束 -> 采集 | `metrics.env` (`baseline_runtime_sec`) | Pod 成功且 runtime 可解析 |
| PERF-002 | 先跑 `off` baseline；再跑 `on` 同 workload，同时后台高频抓 metrics -> 对比耗时 | `metrics_stress.txt`、`runtime_metrics_off/on` | 回退百分比 `metrics_overhead_pct <= 阈值`（默认 5%） |
| PERF-003 | 分别跑 `w2@25/50/75` -> 每轮采集并记录耗时 | `quota_runtime.txt` | 三点齐全且单调：`25>50>75` |
| PERF-004 | 并发跑 `w2@30` + `w2@60` -> 采集 -> 若不同卡则 SKIP | `runtime_ratio_30_over_60`、`gpu_mapping.txt` | 同卡时 `ratio >= XP_PERF_MIX_RATIO_MIN` |
| PERF-005 | 仅 C1：`w1` 比较 `oversub off` 与 `on` | `oversub_*` kv、`pods/*.log` | `off=Failed 且 on=Succeeded`，或两者均成功并记录时长 |
| PERF-006 | 仅 C2：`w1` 比较 `oversub off/on` | `a800_oversub_*` kv | 要求 `on` 场景 `Succeeded` |
| PERF-007 | 起 `w5@25` -> 运行中改 `core=75` -> 轮询 metrics 直到看到更新 -> 计算延迟 | `metrics_probe.txt`、`dynamic_compute_metric_latency_sec` | 60s 内观察到更新，且延迟 <= `XP_DYNAMIC_UPDATE_EXPECT_SEC` |
| PERF-008 | 按 `2/4/8/16` 阶梯并发跑 `w2@50` -> 每阶统计总耗时与成功数 | `scale_results.txt` | 每个阶梯至少有 1 个成功，且完成整组阶梯 |

## 17.5 Metrics（MET）逐 Case 细节

| Case | 脚本实际执行动作（按顺序） | 重点采集数据 | PASS 判定 |
|---|---|---|---|
| MET-001 | 直接抓 `/healthz` 与 `/metrics`（优先节点 SSH curl，失败回退 port-forward） | `metrics_health.txt`、`metrics.txt` | `HTTP_CODE=200` 且 metrics 含 `^nvshare_` |
| MET-002 | 抓一份 `metrics.txt`，遍历必需指标清单做存在性检查 | `missing_metrics.txt`、`missing_metric_count` | 缺失数为 0 |
| MET-003 | 跑 1 个 `w2`，Running 后抓 `metrics_mid`，计算 3 个内存总和，再等结束采集 | `metrics_mid.txt`、sum kv | `client_nvml_used / need_estimated / gpu_used` 三者均 > 0 |
| MET-004 | 跑 1 个 `w5`（`core=35`,`mem=4/8Gi`），Running 后抓中间快照读取 pod 维度 quota 值 | `metric_memory_quota_bytes`、`metric_core_quota_percent` | 两值存在，且 `mem>0`、`core>=35` |
| MET-005 | 跑 1 个 `w5`（`core=30`,`mem=2Gi`），运行中改 `mem=4Gi + core=80`，轮询直到指标更新 | `metrics_before.txt`、`metrics_probe.txt`、延迟 kv | 60s 内观察到变化，且延迟 <= 阈值 |
| MET-006 | 跑 1 个 `w2`，30s 采样 `gpu_utilization_ratio` | `metrics_series.txt`、`max_gpu_util_ratio` | 最大 util >= `XP_METRIC_UTIL_MIN_RATIO` |
| MET-007 | 不跑业务负载，直接高频抓 metrics 压力测试 | `metrics_stress.txt`、`metrics_health_after_stress.txt` | 样本数 >=5 且健康检查仍 200 |
| MET-008 | 跑 1 个 `w1`（`oversub=1`），40s 采样并计算 `used/total` 峰值 | `metrics_alert_probe.txt`、`peak_gpu_memory_used_ratio` | 峰值 >= `XP_METRIC_HIGH_MEM_ALERT_RATIO` |

## 17.6 Stability / Leak / Fail 逐 Case 细节

| Case | 脚本实际执行动作（按顺序） | 重点采集数据 | PASS 判定 |
|---|---|---|---|
| STAB-001 | 仅 C1：6h（默认）循环跑 `4x w2@50`，每轮记 scheduler RSS/FD | `scheduler_series.txt`、`iterations` | 循环期间 scheduler 始终存活 |
| STAB-002 | 仅 C2：24h（默认）循环跑 `16/32` 个 `w2` 交替负载 | `scheduler_series.txt`、`iterations` | 长时循环稳定，无 scheduler 掉线 |
| STAB-003 | 4 个 `w5@30` 长跑，按间隔循环改 core `30/60/90` | `update_timeline.txt`、`metrics_stab3_*`、`scheduler.log` | 日志可见 compute 动态更新信号 |
| STAB-004 | 4 个 `w5` 长跑，按间隔循环改 mem `base/2Gi/6Gi` | `update_timeline.txt`、`metrics_stab4_*`、`scheduler.log` | 日志可见 memory 动态更新信号 |
| LEAK-001 | 连续 `XP_LEAK_ROUNDS` 轮：每轮跑 `2x w4`，记录 scheduler RSS | `rss_series.txt`、`rss_growth_kb` | `rss_growth_kb <= XP_LEAK_RSS_GROWTH_MAX_KB` |
| LEAK-002 | 连续 `XP_LEAK_ROUNDS` 轮：每轮跑 `2x w4`，记录 scheduler FD | `fd_series.txt`、`fd_growth` | `fd_growth <= XP_LEAK_FD_GROWTH_MAX` |
| LEAK-003 | 记录空闲 GPU used -> 跑 `4x w2` -> 清理后再记录 used | `metrics_before/after.txt`、`gpu_used_*` | `after <= before + 容差` |
| LEAK-004 | 连续 churn：反复创建/删除 `2x w2`，最后检查 `client_info` 残留 | `metrics_after.txt`、`client_info_series_after_churn` | 残留 <= `XP_LEAK_GHOST_CLIENT_MAX` |
| LEAK-005 | 记录 series 基线 -> 多轮 churn `2x w4` -> 对比 series 增长 | `series_before/after/growth` | `growth <= XP_LEAK_SERIES_GROWTH_MAX` |
| FAIL-001 | 破坏性：负载中 `rollout restart ds/nvshare-scheduler` | `scheduler.log`、`pods/*.log` | 重启后 scheduler 存活且任务可终态 |
| FAIL-002 | 破坏性：负载中 `rollout restart ds/nvshare-device-plugin` | `device-plugin.log`、`pods/*.log` | 重启后 scheduler 存活且任务可终态 |
| FAIL-003 | 仅 C1 且需 `XP_C1_DRAIN_NODE`：负载中执行 `kubectl drain` 再 `uncordon` | `cluster_snapshot.txt`、`pods/*.log` | 无永久 Pending，流程可收敛 |
| FAIL-004 | 仅 C2 且需 `XP_C2_STRESS_NODE`：固定单节点起 8 个 Pod 压力 | `success_count`、`scheduler.log`、`metrics.txt` | 至少 1 个成功，恢复链路可观测 |

## 17.7 如何让“他人一眼看懂该 case 在做什么”

建议在测试报告中按以下固定结构落地（每个 case 一段）：

1. `操作`：写明创建了哪些 Pod、用了哪个 workload、改了哪些 annotation。
2. `采样`：写明看了哪些文件（例如 `metrics_mid.txt`、`scheduler.log`）。
3. `判定`：写明具体表达式（例如 `runtime_30 > runtime_60`，`HTTP_CODE=200`）。
4. `结论`：PASS/FAIL + 1 句根因摘要。

---

该方案可直接覆盖你提出的“组合功能 + 性能 + 稳定性 + 泄漏 + metrics + 双集群异构验证”需求，并能与现有 `tests/remote-test-*.sh` 体系平滑衔接。
