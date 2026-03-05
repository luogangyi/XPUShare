# NVShare 性能测试报告（CUDA + CANN）

## 1. 测试目标

本报告覆盖四类问题：

1. 基线性能：NVShare 在单任务下是否接近原生性能。
2. 并发扩展：多任务并发时，耗时是否符合预期线性关系。
3. 调度正确性：任务是否按预期分布到多张 GPU/NPU，而不是挤在同一张卡。
4. 稳定性：高并发下是否存在异常（如 crash、大量 Pending、吞吐塌陷）。

---

## 2. 测试环境

## 2.1 CUDA 环境

- 集群：`kubeconfig-fuyao-gpu`
- 节点资源：2 x T4（16GB）
- 用例负载：`tests/pytorch-add.py`、`tests/pytorch-add-small.py`、`tests/pytorch-add-idle-small.py`

## 2.2 CANN 环境

- 集群：`kubeconfig-kcs-npu`
- 节点资源：910B 节点
- 本轮并发对比配置：**device-plugin 使用 2 张 Ascend910 物理卡**
  - 运行时确认：`huawei.com/Ascend910` limit = `2`
  - 节点 allocatable：`nvshare.com/gpu = 20`（10 vNPU/卡，2 卡）
- 用例负载：`tests/remote-test-smoke.sh --perf-only`

## 2.3 指标说明

- `wall`：端到端墙钟时间（含调度等待/排队/执行）。
- `bench`：容器内 workload 自报计算时间（更接近纯计算开销）。

---

## 3. 测试用例

## 3.1 CUDA 历史功能与性能回归（保留历史数据）

| 用例 | 场景 | 结果摘要 |
|---|---|---|
| Test0 | 原生 baseline | `add=163s`, `small=392s`, `idle-small=445s` |
| Test1 | 满显存任务，2任务/2卡独占 | `164s/164s`，接近 baseline |
| Test2-serial | 满显存任务，4任务串行共享 | 平均 `326.8s` |
| Test2-auto | 满显存任务，4任务自动调度 | 平均 `328.8s` |
| Test3 | small 任务，2任务/2卡独占 | 平均 `392.5s` |
| Test4 | small 任务，4任务共享 | 平均 `867.5s` |
| Test5 | idle-small，单任务 | `444s` |
| Test6 | idle-small，6任务共享 | 平均 `481.8s` |

结论（历史）：

1. 单任务虚拟化开销很低（接近 0~1%）。
2. 高算力并发时耗时按竞争关系放大；低算力 idle 负载可显著提升部署密度。
3. 自动调度能避免显存不足导致的不稳定。

## 3.2 CUDA 并发对比（2卡，1/2/4 任务）

执行方式：

```bash
XP_KUBECONFIG_CUDA=~/Code/configs/kubeconfig-fuyao-gpu \
  bash tests/remote-test-smoke.sh --skip-setup --clusters cuda --perf-only --perf-concurrent <N>
```

结果（取 nvshare）：

| 并发任务数 | avg_wall_ms | avg_bench_ms | 相对 1任务 wall 倍数 | 相对 1任务 bench 倍数 |
|---:|---:|---:|---:|---:|
| 1 | 404712 | 391449.49 | 1.0000x | 1.0000x |
| 2 | 403750 | 391548.42 | 0.9976x | 1.0003x |
| 4 | 877064 | 863208.85 | 2.1671x | 2.2052x |

结论：

1. 2任务几乎不变，说明两任务基本分散到两张卡。
2. 4任务约 2.2x，符合“两卡上每卡约2任务”的预期。

## 3.3 CANN 并发对比（2卡，1/2/4/8/16 任务）

执行方式：

```bash
XP_KUBECONFIG_CANN=~/Code/configs/kubeconfig-kcs-npu \
  bash tests/remote-test-smoke.sh --skip-setup --clusters cann --perf-only --perf-concurrent <N>
```

### 3.3.1 1/2/4/8 并发稳定结果

| 并发任务数 | avg_wall_ms | avg_bench_ms | 相对 1任务 wall 倍数 | 相对 1任务 bench 倍数 |
|---:|---:|---:|---:|---:|
| 1 | 113049 | 82632.35 | 1.0000x | 1.0000x |
| 2 | 112075 | 83240.67 | 0.9914x | 1.0074x |
| 4 | 201513 | 169530.70 | 1.7824x | 2.0517x |
| 8 | 376866 | 336361.38 | 3.3335x | 4.0707x |

分布确认（避免“同卡挤压”误判）：

- 2任务：`ASCEND_VISIBLE_DEVICES=4/5` 各1个。
- 4任务：`ASCEND_VISIBLE_DEVICES=4/5` 各2个。
- 8任务：`ASCEND_VISIBLE_DEVICES=4/5` 各4个。

结论：

1. CANN 在 2 卡配置下，2/4/8 并发的 `bench` 扩展符合预期（约 1x/2x/4x）。
2. 相比此前单卡结果，当前数据已明显修正，确认不再是“全挤同一张 NPU”。

### 3.3.2 16 并发结果与异常

16 并发在 2 卡环境下做了两次重测，均失败（`nvshare` 统计为 `NA`），主要现象：

1. 多个 Pod 在运行中出现 `Segmentation fault (core dumped)`。
2. 失败日志都出现相同前置信号：
   - `NPU DROP_LOCK short sync timeout=1 ret=507046`
3. 失败 Pod 分布在两张卡（4/5）上都出现，不是单卡热点问题。

结论：

- 16 并发当前是**稳定性瓶颈**，不是调度只用单卡的问题。
- 此档位暂不纳入“线性扩展”结论，应单列为高并发稳定性缺陷。

---

## 4. 配额阶段历史结果（保留）

## 4.1 CUDA 动态算力配额优化阶段（历史）

基准：`pytorch-add-small` 单任务约 `391s`

| 场景 | 实测 |
|---|---|
| 4任务2GPU，30%+60% | `60%=672s`，`30%=1316s` |
| 4任务2GPU，50%+50% | `864s/864s/864s/864s` |
| 4任务2GPU，75%+75% | `866/867/866/867s` |
| 单任务 25% | `1458s` |
| 单任务 50% | `739s` |
| 单任务 75% | `506s` |

结论：

1. 并发异配额（30/60）场景已接近线性目标。
2. 单任务低配额仍存在“略快于理论值”的残余偏差。

## 4.2 CANN 配额回归（历史）

该阶段已验证通过：

- `concurrent-bootstrap` PASS
- `mem-static` PASS
- `mem-dynamic` PASS
- `core-static` PASS
- `core-dynamic` PASS

---

## 5. 综合结论

1. **CUDA**：单任务损耗低；2/4 并发扩展符合两卡预期。
2. **CANN（2卡）**：1/2/4/8 并发扩展已恢复到可解释区间。
3. **CANN 16并发**：当前受高并发稳定性问题限制（DROP_LOCK 短同步超时后 segfault），需专项修复后再给正式性能结论。

## 6. 后续建议

1. 将 CANN 性能结论拆成两层：
   - 线性区（1/2/4/8）：可作为当前有效性能口径。
   - 超载区（16+）：作为稳定性回归口径，不直接用于性能承诺。
2. 针对 16 并发异常，优先排查并修复：
   - `DROP_LOCK` 后 `aclrtSynchronizeDevice`/短同步路径；
   - 多进程并发下的异常恢复与重入保护。
3. 修复后再重跑 16 并发，并补充 `P95 完成时延` 与 `失败率` 指标。
