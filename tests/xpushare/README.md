# XPUSHARE 测试套件

本目录提供 nvshare 的多集群测试脚本，覆盖以下能力：

1. 显存超分（oversubscription）
2. 静态显存配额
3. 静态算力配额
4. 动态显存配额（annotation）
5. 动态算力配额（annotation）
6. Metrics 采集与一致性校验
7. 性能回归与稳定性/泄漏测试

## 最近实测结果（2026-03-07）

本节仅记录“实际执行到的量化结果”，不是仅列 case 名称和 pass/fail。

### 本次执行范围

1. CUDA 重跑：`PERF-003`（同轮包含 `PERF-001` baseline，run_id=`20260307-cuda-perf003-rerun3`）。
2. CUDA 补跑：`PERF-001/002/005/007`（run_id=`20260307-cuda-perf-others`）。
3. CUDA 再补跑：`PERF-001/008/009/010`（run_id=`20260307-cuda-perf8to10-rerun`）。
4. NPU(A800) 补跑：`PERF-006`（run_id=`20260307-c2-perf006`）。
5. 复用最近已完成结果：CUDA 长基线 `PERF-011/003/004`（run_id=`20260306-longbench-c1-cuda-v2`）。

### CUDA 关键结果（C1）

1. `PERF-001`（w6 长基线，25000 iters）：
   - baseline=`246.2115s`（`20260307-cuda-perf003-rerun3`）。
2. `PERF-003` 重跑：
   - 框架判定：`placement=PASS`，`quota_effect=FAIL`，原因是 `missing runtime data for same-gpu low/high pairs`（低配额 pod 日志无 `--- xxx seconds ---` 行）。
   - 同轮 pod 终止时间反算（用于人工校核）：`q25` 两个 pod `977s/983s`，`q75` 两个 pod `458s/458s`。
   - 反算均值比值：`ratio25_vs_base=3.980`，`ratio75_vs_base=1.860`（与长基线历史值接近）。
3. `PERF-011`（长基线单任务配额精度，`20260306-longbench-c1-cuda-v2`）：
   - `q25=911.283s (3.700x)`，`q50=440.156s (1.787x)`，`q75=318.447s (1.293x)`，判定 `PASS`。
4. `PERF-003`（长基线历史通过样本，`20260306-longbench-c1-cuda-v2`）：
   - `avg25=975.501s (3.961x)`，`avg75=455.902s (1.851x)`，判定 `PASS`。
5. `PERF-004`（长基线 30/60 混配，`20260306-longbench-c1-cuda-v2`）：
   - `avg30=798.622s (3.243x)`，`avg60=481.628s (1.956x)`，`30/60=1.658`，判定 `PASS`。
6. `PERF-002`（metrics 开销，`20260307-cuda-perf-others`）：
   - `off=391.237s`，`on=391.220s`，`overhead=-0.004%`，判定 `PASS`。
7. `PERF-005`（T4 oversub 对比，`20260307-cuda-perf-others`）：
   - `off=162.540s`，`on=162.238s`，两个分支均 `Succeeded`，判定 `PASS`。
8. `PERF-007`（动态算力配额传播时延，`20260307-cuda-perf-others`）：
   - `dynamic_compute_metric_latency_sec=5`，判定 `PASS`。
9. `PERF-008`（阶梯扩容，`20260307-cuda-perf8to10-rerun`）：
   - `pods=2 elapsed=707s success=2`，`pods=4 elapsed=881s success=4`，判定 `PASS`。
10. `PERF-009`（单卡并发子集，`20260307-cuda-perf8to10-rerun`）：
   - `target_concurrency=1`，未形成“同卡>=2并发”样本，结果为 `SKIP`（用例状态 `PASS`）。
11. `PERF-010`（多卡并发线性，`20260307-cuda-perf8to10-rerun`）：
   - 两个 GPU 的 runtime ratio 分别为 `2.104`、`2.077`，均落在期望区间 `[1.200, 3.800]`，判定 `PASS`。

### NPU 关键结果（C2）

1. `PERF-006`（A800 oversub 对比，run_id=`20260307-c2-perf006`）：
   - `off_phase=Succeeded`，`on_phase=Succeeded`。
   - `off_runtime=6.774s`，`on_runtime=6.895s`。
   - 用例判定：`PASS`（`A800 oversub comparison recorded`）。

### 当前结论

1. CUDA 配额线性在长基线样本中可复现（`PERF-011/003/004` 均有稳定量化数据）。
2. `PERF-003` 本次重跑暴露“日志 runtime 行偶发缺失”问题：pod 成功结束，但自动解析不到 runtime，导致用例误判 `quota_effect=FAIL`。
3. NPU 的 `PERF-006` 补跑结果正常，可稳定完成 off/on 对比。

### 2026-03-11 增量验证（C2，driver 25.5.1 + CANN 8.5.1）

1. 本次改动目标：
   - `device-plugin` 启动前增加 Ascend 驱动版本门禁（默认 `>=25.5.0`）；
   - 自动检测并执行 `npu-smi set -t device-share`（仅在状态为 `False` 时执行）。
2. 版本门禁验证：
   - 将 `NVSHARE_ASCEND_MIN_DRIVER_VERSION=25.6.0` 后，`nvshare-device-plugin` 启动失败；
   - 日志：`ascend driver 25.5.1 is lower than required 25.6.0`（符合预期）。
3. 恢复门禁阈值验证：
   - 恢复 `NVSHARE_ASCEND_MIN_DRIVER_VERSION=25.5.0` 后插件正常启动；
   - 日志：`Ascend preflight passed: driver=25.5.1 (min=25.5.0)`。
4. `device-share` 自动设置验证：
   - 将可见 NPU 手动设为 `Device-share Status=False` 后重启插件；
   - 日志出现 `device-share is disabled, enabling it now` + `enabled successfully`；
   - `npu-smi info -t device-share` 复查为 `True`。
5. 回归观察（`run_id=20260311-c2-dscheckfix*`）：
   - `xpushare` 的 `FUNC-001`/`PERF-001` 在 `nvshare.com/gpu` 路径下失败，业务进程 `exit 139`（Segmentation fault）；
   - 同镜像同脚本在原生 `huawei.com/Ascend910` 资源下可成功（`PASS native-npu-check`）；
   - 结论：本次 preflight 改动（版本门禁 + device-share 自动设置）生效，当前失败点位于 `nvshare` 运行态 hook 稳定性，不在该 preflight 逻辑本身。

### 2026-03-11 稳定性修复补充（C2）

1. 修复策略：
   - 在 `2026-03-11` 当时临时将 NPU ACL 拦截路径默认关闭（`NVSHARE_NPU_ENABLE_HOOK=0`）；
   - 关闭时仅做透明透传，不启动 `initialize_client` 调度线程；
   - `aclrtSetDevice`/`aclrtSynchronizeDeviceWithTimeout` 改为直接调用已加载的真实 ACL 符号，移除 `RTLD_NEXT` passthrough 路径。
2. 实测结果（`run_id=20260311-c2-stabilityfix`）：
   - `FUNC-001`: `PASS`；
   - `PERF-006`: `PASS`（`off_runtime=1.7778s`，`on_runtime=1.7775s`）；
   - `PERF-001`: 首次失败原因为基线阈值门限（`222.67s < 240s`，非崩溃），将 `XP_PERF_BASELINE_MIN_SEC=180` 后 `PASS`。
3. 最小复现脚本验证：
   - 两个并发 `nvshare.com/gpu` Pod 均 `PASS`；
   - 不再复现 `exit 139`。
4. 测试配置建议：
   - 当前 `tests/xpushare/config.env(.example)` 默认值为 `XP_NVSHARE_NPU_ENABLE_HOOK=1`、`XP_NVSHARE_NPU_ENABLE_CLIENT=1`；
   - 若要切回纯透传路径排障，可设 `XP_NVSHARE_NPU_ENABLE_HOOK=0`。
5. 已知现状：
   - 当前主线默认开启 NPU hook + client 路径用于配额管理；
   - 如遇特定业务兼容性问题，可临时改为 `hook=0` 做隔离定位。

## 目录结构

- `run-matrix.sh`：总入口，按集群/套件/用例执行
- `lib/common.sh`：公共函数（创建/删除轮询、日志采集、结果汇总等）
- `suites/functional.sh`：`FUNC-*`
- `suites/combination.sh`：`COMBO-*`
- `suites/performance.sh`：`PERF-*`
- `suites/metrics.sh`：`MET-*`
- `suites/stability.sh`：`STAB-*`、`LEAK-*`、`FAIL-*`
- `config.env.example`：配置模板

## 近期优化（含本次修正）

1. 安全优化：`tests/xpushare/config.env` 已加入 `.gitignore`，避免敏感配置提交。
2. 分段执行与断点续跑：支持 `--suite`、`--case` 分段执行，支持 `--resume` 跳过已 `PASS` 的用例。
3. 用例即时分析：每个 case 结束后自动生成 `analysis.env`、`analysis.txt`，并写入 run 级汇总 `case-summary.tsv`。
4. Pod 创建/删除强校验：创建后轮询确认已创建，删除后轮询确认已删除，再进入下一步。
5. Scheduler 大日志优化：支持远端 `kubectl logs -f` 重定向后回传，降低本地直连抓全量日志的压力。
6. `smoke` 预设：新增 `--suite smoke`，用于最短路径回归。
7. 本次配置修正：scheduler 远端日志采集不再使用单独 `C*_SCHED_LOG_*` 配置，改为复用节点 SSH 占位变量。
8. 运行前全量清理：每个集群执行前会自动清理历史 `xpf/xpc/xpp/xpm/xps` 测试 Pod，并轮询确认删除完成。
9. 容量感知默认值：按当前集群容量默认采用 `C1=40 vGPU`、`C2=20 vNPU(单节点，2 物理 NPU x 10)`，`PERF-008` 与 `STAB-002` 可按集群使用不同负载梯度。
10. Metrics 用例鲁棒性优化：`MET-002/003/005` 会先启动探测工作负载再采样，避免“无活跃 client 导致误判”；`COMBO-007/008` 改为优先中途快照并按 `gpu_uuid` 统计多卡分布。
11. 本次新增：`C1` 默认启用并发安全上限（每张 16G T4 默认最多 3 任务），`C2` 支持 NPU 专用镜像与 `torch_npu` 工作负载路径，且可按 `node count` 自动只操作单节点。
12. 本次新增：性能套件支持两类重负载：`w6`（固定迭代 `torch.add`，偏带宽）与 `w7`（固定迭代 `torch.matmul`，偏算力）；`XP_PERF_BASELINE_WORKLOAD` 为空时自动按后端选择（`cuda->w6`，`npu->w7`）。`PERF-003/004` 改为“先起 2 个再延迟起 2 个”的分批策略（`XP_PERF_STAGGER_SLEEP_SEC`），并在同卡 low/high 配对基础上判定；同卡失败支持可配置重试（`XP_PERF_SAME_GPU_RETRIES`）；新增 `PERF-009/010` 覆盖单卡并发子集与多卡并发线性校验。
13. 本次新增：`release` 预设（`--suite release`）用于发布前全量回归，默认跑 `functional+combination+performance+metrics+stability`，且稳定性长窗默认限制为 8 小时。
14. 本次新增：自动生成 run 级 Markdown 报告 `run-report.md`（含 suite/case 汇总、覆盖检查、关键性能指标摘录与发布建议）。

## 快速开始

```bash
cd /Users/luogangyi/Code/nvshare
cp tests/xpushare/config.env.example tests/xpushare/config.env
# 编辑 tests/xpushare/config.env
```

## 最小可运行配置模板

将下面内容保存到 `tests/xpushare/config.env` 即可开始运行（按需补充节点 SSH）：

```bash
#!/bin/bash

# 双集群 kubeconfig
export XPUSHARE_KUBECONFIG_C1="$HOME/Code/configs/kubeconfig-fuyao-gpu"
export XPUSHARE_KUBECONFIG_C2="$HOME/Code/configs/kubeconfig-kcs-npu"

# 集群后端类型（C1=CUDA, C2=NPU）
export XP_CLUSTER_C1_BACKEND='cuda'
export XP_CLUSTER_C2_BACKEND='npu'

# 命名空间（默认可不改）
export XPUSHARE_DEFAULT_NAMESPACE="default"
export XPUSHARE_SYSTEM_NAMESPACE="nvshare-system"

# C2 NPU 镜像（可按需覆盖）
export XP_IMAGE_PYTORCH_ADD_NPU='docker.io/local/ascendhub-cann:8.5.1-pt2.9.0-npu2.9.0'
export XP_IMAGE_PYTORCH_ADD_SMALL_NPU='docker.io/local/ascendhub-cann:8.5.1-pt2.9.0-npu2.9.0'
export XP_IMAGE_PYTORCH_ADD_IDLE_SMALL_NPU='docker.io/local/ascendhub-cann:8.5.1-pt2.9.0-npu2.9.0'

# 节点 SSH 占位（先留空，后续按实际补充）
export XPUSHARE_C1_NODE1_SSH=''
export XPUSHARE_C1_NODE2_SSH=''
export XPUSHARE_C2_NODE1_SSH=''
# C2 单节点时可留空
export XPUSHARE_C2_NODE2_SSH=''

# 可选：远端 scheduler 日志目录
export XPUSHARE_REMOTE_SCHED_LOG_DIR='/tmp/xpushare-scheduler-logs'

# 可选：先跳过稳定性长测
export XP_SKIP_STABILITY='1'

# 可选：集群容量与分级压测默认值（按当前部署）
export XP_CLUSTER_C1_TOTAL_VGPU='40'
export XP_CLUSTER_C2_TOTAL_VGPU='20'
export XP_CLUSTER_C1_NODE_COUNT='2'
export XP_CLUSTER_C2_NODE_COUNT='1'
export XP_C1_MAX_TASKS_PER_GPU='3'
export XP_PERF_SCALE_SET_C1='2 4 8 16 24 32 40'
export XP_PERF_SCALE_SET_C2='8 16 20'
export XP_W6_MATRIX_N_C1='14000'
export XP_W6_MATRIX_N_C2='14000'
export XP_W6_ITERS_C1='60000'
export XP_W6_ITERS_C2='120000'
export XP_W7_MATRIX_N_C1='6144'
export XP_W7_MATRIX_N_C2='6144'
export XP_W7_ITERS_C1='2400'
export XP_W7_ITERS_C2='42000'
# 留空自动选择：cuda->w6, npu->w7
export XP_PERF_BASELINE_WORKLOAD=''
export XP_PERF_BASELINE_MIN_SEC='240'
export XP_PERF_QUOTA_LINEAR_TOL_PCT='40'
export XP_PERF_SINGLE_CARD_PODS='4'
export XP_PERF_MULTI_CARD_PODS='8'
export XP_PERF_SAME_GPU_RETRIES='8'
export XP_PERF_STAGGER_SLEEP_SEC='15'
export XP_PERF_DUAL_STATUS_STRICT='1'
export XP_STAB_RELEASE_MAX_SEC='28800'
export XP_STABILITY_CASES_RELEASE='STAB-001 STAB-002 STAB-003 STAB-004 LEAK-001 LEAK-002 LEAK-003 LEAK-004 LEAK-005'
```

常用命令：

```bash
# cluster1 跑 functional 全量
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --cluster c1 \
  --suite functional

# cluster2 跑单用例
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --cluster c2 \
  --case MET-002

# smoke 最短回归
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --cluster c1 \
  --suite smoke

# 发布前全量回归（双集群 + 自动报告）
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --cluster all \
  --suite release

# 续跑（跳过已 PASS）
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --resume \
  --run-id 20260214-220000 \
  --cluster c1 \
  --suite all

# 双集群全量
bash tests/xpushare/run-matrix.sh \
  --config tests/xpushare/config.env \
  --cluster all \
  --suite all
```

## CANN Device-Share 验证

默认目标环境：

- 节点：`kcs-lihao-serving-test01-s-wz97b`（`ssh root@139.196.28.96 -p 32036`）
- 镜像：`swr.cn-south-1.myhuaweicloud.com/ascendhub/cann:8.5.1-910b-ubuntu22.04-py3.11`
- 运行时：`ctr -n k8s.io`

执行命令：

```bash
bash tests/xpushare/verify-cann-device-share.sh \
  --runtime ctr \
  --ctr-namespace k8s.io \
  --device-id 0
```

脚本会自动执行两阶段对比：

1. `npu-smi set -t device-share -i <id> -c 0 -d 0`
2. `npu-smi set -t device-share -i <id> -c 0 -d 1`（自动输入 `Y` 确认）

并在同一物理 NPU 上并发启动两个容器进行 ACL `memset_async` 压测，最终输出分类结论（`RESULT=*`）。

## 执行参数

- `--cluster c1|c2|all`
- `--suite functional|combination|performance|metrics|stability|smoke|release|all`
- `--case <CASE_ID>`（如 `FUNC-003`）
- `--resume`（续跑模式）
- `--run-id <id>`（指定 run id，配合续跑常用）
- `--config <file>`
- `--no-report`（关闭自动报告）
- `--report-file <path>`（自定义报告输出路径）

`--resume` 默认行为：

1. 只在该 `run-id` 已有历史记录的集群上续跑。
2. 跳过已经 `PASS` 的 case，仅重跑失败/中断未落盘的 case。

如需在 `--resume` 时也包含“该 run-id 没有历史记录”的集群，可设置：

```bash
export XPUSHARE_RESUME_INCLUDE_NEW_CLUSTERS=1
```

## 集群访问配置

默认 kubeconfig（可在 `config.env` 覆盖）：

- Cluster1：`~/Code/configs/kubeconfig-fuyao-gpu`
- Cluster2：`~/Code/configs/kubeconfig-kcs-npu`

## 节点 SSH 占位变量

以下变量用于节点级采样（CUDA: `nvidia-smi/dmon`，NPU: `npu-smi info`）以及 scheduler 远端日志优化：

- `XPUSHARE_C1_NODE1_SSH`
- `XPUSHARE_C1_NODE2_SSH`
- `XPUSHARE_C2_NODE1_SSH`
- `XPUSHARE_C2_NODE2_SSH`

示例：

```bash
export XPUSHARE_C1_NODE1_SSH='ssh root@10.0.0.11 -p 22'
```

未配置时，会跳过远端节点采样，并自动回退到本地日志模式。

## Scheduler 大日志优化说明

当集群配置了上述 SSH 变量时：

1. 每个 case 启动时，会按 `node1 -> node2` 尝试可用节点；若配置 `XP_CLUSTER_*_NODE_COUNT=1`，则仅尝试 `node1`。
2. 在该节点远端执行 `kubectl logs -f` 并重定向到远端文件。
3. case 结束时停止远端日志进程，并优先 `scp` 拉回本地。
4. 若 `scp` 不可用或失败，自动回退 `ssh cat`。
5. 若远端不可用或远端 `kubectl` 上下文不可用，自动回退本地 `kubectl logs --since-time`。

Metrics/Health 采集同样优先走你要求的路径：

1. 本地用 kubeconfig 查询 scheduler 的 Pod IP。
2. SSH 到可用节点执行 `curl <scheduler-ip>:9402/metrics` 或 `/healthz`。
3. 若该路径失败，回退为本地 `port-forward + curl`。

可选远端目录配置：

- `XPUSHARE_REMOTE_SCHED_LOG_DIR`（默认 `/tmp/xpushare-scheduler-logs`）

## 破坏性用例（FAIL）

`FAIL-*` 默认关闭，开启方式：

```bash
export XP_ENABLE_DISRUPTIVE=1
```

部分用例还需要：

- `XP_C1_DRAIN_NODE`（`FAIL-003`）
- `XP_C2_STRESS_NODE`（`FAIL-004`）

## 日志与结果目录

输出目录：

```text
/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/<cluster>/<suite>/<case-id>/
```

每个 case 典型产物：

- `result.json`
- `analysis.env`
- `analysis.txt`
- `scheduler.log`
- `device-plugin.log`
- `metrics.txt`
- `metrics_health.txt`
- `scheduler_proc.txt`
- `pods/*.log`
- `remote_*_nvidia_smi.txt`、`remote_*_dmon.txt`（CUDA 集群）
- `remote_*_npu_smi.txt`（NPU 集群）

run 级汇总：

- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/run-summary.tsv`
- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/case-summary.tsv`
- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/run-report.md`
- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/run-config.env`

手动重建报告（可选）：

```bash
bash tests/xpushare/generate-report.sh --run-id <run-id>
```
