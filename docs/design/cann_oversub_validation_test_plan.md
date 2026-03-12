# CANN 显存超分生效验证测试用例设计

## 1. 目标

验证 CANN 场景下，xpushare 的“显存超分（类 UVM）”是否真实生效，并区分以下三类结果：

1. 功能生效：可在单卡上申请超过物理 HBM 的总量且任务可完成。
2. 兼容生效：`aclrtMallocWithCfg` 在默认/受控模式下行为符合预期。
3. 失败可解释：关闭 managed 或关闭 fallback 后，失败原因可定位、可复现。

## 2. 测试范围

- 后端：CANN（Ascend 910B）
- 关键开关：
  - `XPUSHARE_NPU_OVERSUB_ALLOC_MODE`（`managed` / `acl`）
  - `XPUSHARE_NPU_MANAGED_WITHCFG`（`0` / `1`）
  - `XPUSHARE_NPU_MANAGED_FALLBACK`（`0` / `1`）
- 核心 API 路径：
  - `aclrtMalloc`
  - `aclrtMallocWithCfg`

## 3. 前置条件

1. 组件版本
- `xpushare-scheduler` / `xpushare-device-plugin` / `libxpushare` 已部署到待测版本。
- 当前修复点要求：`libxpushare` 可从 `libruntime.so` 解析 `rtMemAllocManaged`。

2. 集群
- 使用 CANN 集群（`kubeconfig-kcs-npu`）。
- device-plugin 至少暴露 1 张物理 NPU（推荐 2 张，便于并发场景）。

3. 观测能力
- scheduler 指标可访问：`http://<scheduler-ip>:9402/metrics`
- 必采指标：
  - `xpushare_gpu_memory_total_bytes`
  - `xpushare_scheduler_running_memory_bytes`
  - `xpushare_scheduler_memory_overloaded`
  - `xpushare_client_managed_allocated_bytes`
  - `xpushare_client_managed_allocated_peak_bytes`
  - `xpushare_client_memory_quota_bytes`

## 4. 工作负载设计

建议准备两个探针程序（可内联到 Pod command）：

1. `alloc_api_probe`（API 级）
- 用 `ctypes` 直接调用 `aclInit/aclrtSetDevice/aclrtMalloc*`。
- 参数：`api={malloc,mallocWithCfg}`、`alloc_mb`、`cfg_null={0,1}`。
- 目的：精确验证 hook 分支命中。

2. `oversub_stress_probe`（超分场景）
- 按 chunk 循环申请显存（如每次 256MB），累计到 `target_gb`。
- 仅对一小部分工作集反复计算（避免纯“全量触碰”导致无意义抖动）。
- 打印：成功申请总量、耗时、失败点、释放结果。

## 5. 用例矩阵

| 用例ID | 场景 | 关键开关 | 预期结果 |
|---|---|---|---|
| OVS-001 | 基线（不超分） | `ALLOC_MODE=acl` | 小于物理显存申请成功，任务完成 |
| OVS-002 | 正向超分（malloc） | `ALLOC_MODE=managed` | 单进程申请总量 > 物理显存，任务成功 |
| OVS-003 | 反向对照（malloc） | `ALLOC_MODE=acl` | 同 OVS-002 申请量下失败（OOM/分配失败） |
| OVS-004 | WithCfg 默认兼容 | `ALLOC_MODE=managed, WITHCFG=0` | `aclrtMallocWithCfg` 成功（走原生路径） |
| OVS-005 | WithCfg managed 生效 | `ALLOC_MODE=managed, WITHCFG=1, FALLBACK=0, cfg=NULL` | `aclrtMallocWithCfg` 成功（走 managed） |
| OVS-006 | WithCfg 受控拒绝 | `ALLOC_MODE=managed, WITHCFG=1, FALLBACK=0, cfg!=NULL` | 分配失败且日志明确“cfg 非空回退/拒绝” |
| OVS-007 | 指标一致性 | 同 OVS-002 | `client_managed_allocated_peak_bytes` 高于物理显存阈值；任务完成 |
| OVS-008 | 并发超分稳定性 | OVS-002 配置，2~4 并发 | 无初始化死锁/异常退出；指标与日志完整 |

## 6. 通过标准（严格）

### 6.1 功能通过

满足全部条件：

1. OVS-002 成功，且申请峰值 `> 1.1 * xpushare_gpu_memory_total_bytes`。
2. OVS-003 失败（作为反向对照）。
3. OVS-005 成功，且日志出现 `NPU managed path enabled for aclrtMallocWithCfg`。
4. OVS-006 失败且可解释（受控拒绝，不是随机崩溃）。

### 6.2 可观测通过

1. `xpushare_client_managed_allocated_peak_bytes` 与任务日志中“成功申请峰值”误差 < 10%。
2. `xpushare_scheduler_running_memory_bytes` 与并发任务的分配总量趋势一致。
3. 失败场景有明确日志：
- symbol 缺失
- cfg 非空受控拒绝
- quota/physical limit 触发

## 7. 执行顺序建议

1. 先跑 OVS-004/005/006（API 路径验证，耗时短）。
2. 再跑 OVS-001/002/003（单任务功能对照）。
3. 最后跑 OVS-008（并发稳定性）。

## 8. 风险与规避

1. 风险：`oversub_stress_probe` 只分配不触发迁移，导致“看起来成功但业务无意义”。
- 规避：保留小工作集计算循环，至少验证 runtime 可持续执行。

2. 风险：指标采样延迟导致短任务抓不到峰值。
- 规避：每个用例保持 60~120s 运行，并保留结束前最后一次 metrics 抓取。

3. 风险：并发场景被调度到同一物理卡导致结果失真。
- 规避：分两阶段创建 Pod（先 2 个，后 2 个）并记录 `gpu_uuid`。

## 9. 建议产出物

每个用例固定输出以下文件：

1. `<case>/pod.yaml`
2. `<case>/pod.log`
3. `<case>/pod.describe.txt`
4. `<case>/metrics.before.prom`
5. `<case>/metrics.after.prom`
6. `<case>/result.json`（含 pass/fail、关键数值、失败原因）

## 10. 下一步自动化建议

将 OVS-001~008 合入 `tests/remote-test-smoke.sh` 新参数：

- `--oversub-check`
- `--oversub-only`
- `XP_OVERSUB_TARGET_GB`
- `XP_OVERSUB_CHUNK_MB`
- `XP_OVERSUB_CONCURRENCY`

并将结果追加到统一汇总（TSV + Markdown）。
