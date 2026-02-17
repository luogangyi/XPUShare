# XPUSHARE 测试套件

本目录提供 nvshare 的多集群测试脚本，覆盖以下能力：

1. 显存超分（oversubscription）
2. 静态显存配额
3. 静态算力配额
4. 动态显存配额（annotation）
5. 动态算力配额（annotation）
6. Metrics 采集与一致性校验
7. 性能回归与稳定性/泄漏测试

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
9. 容量感知默认值：按当前集群容量默认采用 `C1=40 vGPU`、`C2=160 vGPU`，`PERF-008` 与 `STAB-002` 可按集群使用不同负载梯度。
10. Metrics 用例鲁棒性优化：`MET-002/003/005` 会先启动探测工作负载再采样，避免“无活跃 client 导致误判”；`COMBO-007/008` 改为优先中途快照并按 `gpu_uuid` 统计多卡分布。

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
export XPUSHARE_KUBECONFIG_C2="$HOME/Code/configs/kubeconfig-kcs-gpu"

# 命名空间（默认可不改）
export XPUSHARE_DEFAULT_NAMESPACE="default"
export XPUSHARE_SYSTEM_NAMESPACE="nvshare-system"

# 节点 SSH 占位（先留空，后续按实际补充）
export XPUSHARE_C1_NODE1_SSH=''
export XPUSHARE_C1_NODE2_SSH=''
export XPUSHARE_C2_NODE1_SSH=''
export XPUSHARE_C2_NODE2_SSH=''

# 可选：远端 scheduler 日志目录
export XPUSHARE_REMOTE_SCHED_LOG_DIR='/tmp/xpushare-scheduler-logs'

# 可选：先跳过稳定性长测
export XP_SKIP_STABILITY='1'

# 可选：集群容量与分级压测默认值（按当前部署）
export XP_CLUSTER_C1_TOTAL_VGPU='40'
export XP_CLUSTER_C2_TOTAL_VGPU='160'
export XP_PERF_SCALE_SET_C1='2 4 8 16 24 32 40'
export XP_PERF_SCALE_SET_C2='8 16 32 64 96 128 160'
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

## 执行参数

- `--cluster c1|c2|all`
- `--suite functional|combination|performance|metrics|stability|smoke|all`
- `--case <CASE_ID>`（如 `FUNC-003`）
- `--resume`（续跑模式）
- `--run-id <id>`（指定 run id，配合续跑常用）
- `--config <file>`

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
- Cluster2：`~/Code/configs/kubeconfig-kcs-gpu`

## 节点 SSH 占位变量

以下变量用于节点级采样（`nvidia-smi` / `dmon`）以及 scheduler 远端日志优化：

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

1. 每个 case 启动时，会按 `node1 -> node2` 尝试可用节点。
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
- `remote_*_nvidia_smi.txt`、`remote_*_dmon.txt`（配置 SSH 时）

run 级汇总：

- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/run-summary.tsv`
- `/Users/luogangyi/Code/nvshare/.tmplog/<run-id>/xpushare/case-summary.tsv`
