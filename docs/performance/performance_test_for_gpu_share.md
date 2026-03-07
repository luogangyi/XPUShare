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

### 3.3.1 1/2/4/8/16 并发对比结果

| 并发任务数 | avg_wall_ms | avg_bench_ms | 相对 1任务 wall 倍数 | 相对 1任务 bench 倍数 |
|---:|---:|---:|---:|---:|
| 1 | 113049 | 82632.35 | 1.0000x | 1.0000x |
| 2 | 112075 | 83240.67 | 0.9914x | 1.0074x |
| 4 | 201513 | 169530.70 | 1.7824x | 2.0517x |
| 8 | 376866 | 336361.38 | 3.3335x | 4.0707x |
| 16 | 731531 | 676295.52 | 6.8121x | 8.1824x |

分布确认（避免“同卡挤压”误判）：

- 2任务：`ASCEND_VISIBLE_DEVICES=4/5` 各1个。
- 4任务：`ASCEND_VISIBLE_DEVICES=4/5` 各2个。
- 8任务：`ASCEND_VISIBLE_DEVICES=4/5` 各4个。

结论：

1. CANN 在 2 卡配置下，`bench` 随并发数呈稳定上升趋势，16 并发可稳定完成。
2. 相比此前单卡结果，当前数据已明显修正，确认不再是“全挤同一张 NPU”。

### 3.3.2 16 并发专项观察（2卡，20 vNPU）

本轮使用配置：

1. `huawei.com/Ascend910=2`（device-plugin）
2. `nvshare.com/gpu allocatable=20`（10 vNPU/卡）
3. 命令：`--skip-setup --clusters cann --perf-only --perf-concurrent 16 --perf-rounds 1`
4. 脚本保护：`--perf-concurrent >= 16` 时，自动要求至少 2 张物理 NPU（即使单卡 vNPU 容量足够也不放行）

结果A（run_id=`20260306-003111`）：

| 指标 | 数值 |
|---|---:|
| native avg_wall_ms | 107387.00 |
| native avg_bench_ms | 82652.29 |
| nvshare(16并发) avg_wall_ms | 731531.00 |
| nvshare(16并发) avg_bench_ms | 676295.52 |
| wall_ratio(nvshare/native) | 6.8121x |
| bench_ratio(nvshare/native) | 8.1824x |

结果B（run_id=`20260306-085655`，`XP_CANN_NPU_DROP_SYNC_TIMEOUT=1`）：

| 指标 | 数值 |
|---|---:|
| native avg_wall_ms | 112993.00 |
| native avg_bench_ms | 82767.67 |
| nvshare(16并发) avg_wall_ms | 740116.00 |
| nvshare(16并发) avg_bench_ms | 676622.84 |
| wall_ratio(nvshare/native) | 6.5501x |
| bench_ratio(nvshare/native) | 8.1750x |

稳定性观察：

1. 16/16 Pod 全部 `Succeeded`。
2. 日志未出现 `Segmentation fault`、`NPU DROP_LOCK short sync timeout`、`ret=507046`。
3. 绑定分布在两张卡（`ASCEND_VISIBLE_DEVICES=4/5`），不是单卡挤压。

补充回归（误配置防护）：

1. 在 `XP_CANN_NPU_DROP_SYNC_TIMEOUT=1` 下重跑 16 并发（结果B），16/16 pod 全部 `Succeeded`。
2. 日志统一出现：`NVSHARE_NPU_DROP_SYNC_TIMEOUT=1 is ignored on NPU DROP_LOCK path; skip unsafe cross-thread sync`。
3. 未复现 `Segmentation fault`、`ret=507046`、`ret=507000`。

结论：

- 在“2卡+20 vNPU”前提下，16 并发已可稳定完成。
- 16 并发性能数据可纳入 CANN 并发对比结果。

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
3. **CANN 16并发**：在 2 卡 20 vNPU 配置下已稳定通过；当前瓶颈转为正常资源竞争带来的吞吐下降，而非 crash。

## 6. 后续建议

1. 将 CANN 性能结论拆成两层：
   - 线性区（1/2/4/8）：可作为当前有效性能口径。
   - 超载区（16+）：作为稳定性回归口径，不直接用于性能承诺。
2. 继续补充 16 并发场景的时延分布（`P50/P95/P99`）和长稳（多轮）失败率。
3. 保持“并发数 <= allocatable vNPU”作为回归前置校验，避免调度容量不足导致的失真结果。

---

## 7. 2026-03 长基线配额精度补测（bench口径）

说明：

1. 本节仅使用 `bench`（workload 脚本输出的 `--- X seconds ---`）进行比对，不使用 pod wall 时间。
2. 用例与口径：`PERF-001/011/003/004`，重点验证配额线性关系。
3. 长基线参数：统一使用 `w6` 工作负载。

### 7.1 CANN（cluster2）补测结果

| 指标 | 数值 |
|---|---:|
| baseline（PERF-001） | 254.351s |
| 单任务 25% vs baseline（PERF-011） | 1.967x |
| 单任务 50% vs baseline（PERF-011） | 1.485x |
| 单任务 75% vs baseline（PERF-011） | 1.192x |
| 并发 25/75：25% vs baseline（PERF-003） | 2.489x |
| 并发 25/75：75% vs baseline（PERF-003） | 1.850x |
| 并发 30/60：30% vs baseline（PERF-004） | 2.522x |
| 并发 30/60：60% vs baseline（PERF-004） | 2.177x |
| 并发 30/60 直接比值（30/60） | 1.158 |

用例判定：

1. `PERF-001`: PASS
2. `PERF-011`: FAIL
3. `PERF-003`: PASS
4. `PERF-004`: FAIL

结论（CANN）：

1. 在长基线下，并发 25/75 场景（PERF-003）可通过线性判定。
2. 单任务配额（PERF-011）仍存在明显偏差，未达到理想线性（25/50/75 理论应接近 4.0x/2.0x/1.333x）。
3. 30/60 并发场景（PERF-004）中 60% 档相对 baseline 仍偏高，导致整体未通过。
4. **结论：NPU 的配额控制准确度当前仍存在一定偏差。**

### 7.2 CUDA（cluster1）补测结果

| 指标 | 数值 |
|---|---:|
| baseline（PERF-001） | 246.267s |
| 单任务 25% vs baseline（PERF-011） | 3.700x |
| 单任务 50% vs baseline（PERF-011） | 1.787x |
| 单任务 75% vs baseline（PERF-011） | 1.293x |
| 并发 30/60：30% vs baseline（PERF-004） | 3.243x |
| 并发 30/60：60% vs baseline（PERF-004） | 1.956x |
| 并发 30/60 直接比值（30/60） | 1.658 |

用例判定：

1. `PERF-001`: PASS
2. `PERF-011`: PASS
3. `PERF-003`: FAIL（同卡配对后运行时样本采集不完整）
4. `PERF-004`: PASS

结论（CUDA）：

1. 单任务配额（25/50/75）在长基线下整体符合预期趋势，精度明显优于当前 CANN 结果。
2. 并发 30/60 场景通过，说明混合配额在 CUDA 上可稳定反映差异。
3. `PERF-003` 本次失败主要是样本采集缺失，不是明确的配额算法失效结论。

---

## 8. 2026-03 CANN 显存超分性能对比（冷访问/热访问）

测试目的：

1. 验证 CANN 超分在“申请很多但基本不访问”和“申请很多且持续访问”两类场景下的性能差异。
2. 对比超分与非超分的耗时比例。

测试命令（示例）：

```bash
XP_OVERSUB_PERF_BASE_FACTOR=0.75 \
XP_OVERSUB_PERF_OVERSUB_FACTOR=1.20 \
XP_OVERSUB_PERF_ACCESS_LOOPS=4 \
XP_OVERSUB_PERF_TOUCH_MB=64 \
XP_OVERSUB_PERF_HOLD_SEC=5 \
XP_OVERSUB_CHUNK_MB=512 \
XP_OVERSUB_MAX_ALLOC_GB=96 \
bash tests/remote-test-smoke.sh --skip-setup --clusters cann --oversub-perf-only
```

场景设计：

1. `cold-native`：非超分（`acl`，目标 0.75x 物理显存），分配后仅驻留（sleep）。
2. `cold-managed`：超分（`managed`，目标 1.20x 物理显存），分配后仅驻留（sleep）。
3. `hot-native`：非超分（`acl`，目标 0.75x 物理显存），分配后循环 `aclrtMemset + aclrtSynchronizeDevice`。
4. `hot-managed`：超分（`managed`，目标 1.20x 物理显存），分配后循环 `aclrtMemset + aclrtSynchronizeDevice`。

测试结果：

| 场景 | total_mem_bytes | allocated_bytes | total_ms | 结论 |
|---|---:|---:|---:|---|
| cold-native | 65,452,113,920 | 49,392,123,904 | 5,246 | 非超分冷访问基线 |
| cold-managed | 65,452,113,920 | 78,920,024,064 | 5,023 | 超分成功（allocated > total） |
| hot-native | 65,452,113,920 | 49,392,123,904 | 1,495 | 非超分热访问基线 |
| hot-managed | 65,452,113,920 | 78,920,024,064 | 4,923 | 超分成功（allocated > total） |

对比比值：

1. 冷访问：`cold-managed / cold-native = 0.9575x`
2. 热访问：`hot-managed / hot-native = 3.2930x`

结论（超分性能）：

1. 冷访问场景下，超分与非超分耗时接近（本轮接近 1x），主要由固定驻留等待时间主导。
2. 热访问场景下，超分耗时显著上升（本轮约 3.29x），符合“超分后持续访问会引入明显额外开销”的预期。
3. 显存超分是否“可用”，取决于业务访问模式：偏驻留型工作负载影响较小，偏持续大带宽访问型工作负载影响明显。
