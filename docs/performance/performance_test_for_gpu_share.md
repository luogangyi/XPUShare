# 环境说明
Nvidia GPU T4 * 2 (16G 显存 * 2)

# 测试0，基准测试
修改为原生nvidia的device-plugin，对pytorch-add.py、pytorch-add-small.py、pytorch-add-idle-small.py进行测试。

./remote-base-test.sh

测试结果：
```
pytorch-add-baseline           | PASS     | 163s
pytorch-small-baseline         | PASS     | 392s
pytorch-idle-small-baseline    | PASS     | 445s
```

# 测试1，单个任务占满显存，独占GPU

试用tests/pytorch-add.py 负载满负荷测试GPU，每个任务GPU显存占用约12GB，算力占用100%

remote-test.sh --skip-setup 2

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-g8lhv
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | febebf756a61f686   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | f2a9071d95ed7ff5   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 164s         | 25.83 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 164s         | 25.80 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 2, Pass: 2, Fail: 0
  Duration: Min=164s, Max=164s, Avg=164.0s
  Speed   : Min=25.80, Max=25.83, Avg=25.81 (it/s)


==========================================
✅ 测试通过：跨 GPU 负载分布成功
==========================================
```

# 测试2，多个任务串行，共享独占GPU

## 配置为串行模式

试用tests/pytorch-add.py 负载满负荷测试GPU，每个任务GPU显存占用约12GB，算力占用100%

remote-test.sh --serial--skip-setup 4 

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-g79d6
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | c6c3068df341e374   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | edbbd0a17e2b8350   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-3            | 622900c037f9ea29   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-4            | d3ce8c7d1b51ded2   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 309s         | 22.24 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 310s         | 22.21 it/s   | 1024
nvshare-cross-gpu-3            | PASS     | 346s         | 23.62 it/s   | 1024
nvshare-cross-gpu-4            | PASS     | 342s         | 23.65 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=309s, Max=346s, Avg=326.8s
  Speed   : Min=22.21, Max=23.65, Avg=22.93 (it/s)


==========================================
✅ 测试通过：跨 GPU 负载分布成功
==========================================
```

## 配置为auto模式

```
Analyzing scheduler pod: nvshare-scheduler-vcmhq
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-cross-gpu-1            | 590f7404f4a2ee15   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-cross-gpu-2            | 907c730df22d942d   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-3            | b03d1525817c98be   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-cross-gpu-4            | 7acd81ec86234e36   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-cross-gpu-1            | PASS     | 282s         | 24.47 it/s   | 1024
nvshare-cross-gpu-2            | PASS     | 347s         | 21.18 it/s   | 1024
nvshare-cross-gpu-3            | PASS     | 345s         | 6.48 it/s    | 1024
nvshare-cross-gpu-4            | PASS     | 341s         | 25.38 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=282s, Max=347s, Avg=328.8s
  Speed   : Min=6.48, Max=25.38, Avg=19.38 (it/s)


==========================================
✅ 测试通过：跨 GPU 负载分布成功
==========================================
```

# 测试3，单个任务占1/4显存，独占GPU

试用tests/pytorch-add-small.py 负载满负荷测试GPU，每个任务GPU显存占用约4GB，算力占用100%

./remote-test-small.sh --skip-setup 2

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-8hww8
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-small-1                | 7168850a95d8871a   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-2                | ecd31afb7530d21e   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-small-1                | PASS     | 392s         | 103.61 it/s  | 2048
nvshare-small-2                | PASS     | 393s         | 103.40 it/s  | 2048
==========================================================================================

📊 统计分析:
  Total: 2, Pass: 2, Fail: 0
  Duration: Min=392s, Max=393s, Avg=392.5s
  Speed   : Min=103.40, Max=103.61, Avg=103.50 (it/s)


==========================================
✅ 测试通过：Small Workload 全部成功
==========================================
```

# 测试4，单个任务占1/4显存，共享使用GPU

试用tests/pytorch-add-small.py 负载满负荷测试GPU，每个任务GPU显存占用约4GB，算力占用100%（由于共享GPU，实际占用约1/2)

./remote-test-small.sh --skip-setup 

测试结果

```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-b66f8
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-small-1                | a12c4b64b99e09dc   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-small-3                | 3ddc0cbb29e864ce   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-2                | 8a1187551fc907a3   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-small-4                | dc896c93bd23d55f   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-small-1                | PASS     | 866s         | 46.43 it/s   | 1024
nvshare-small-2                | PASS     | 869s         | 47.38 it/s   | 1024
nvshare-small-3                | PASS     | 868s         | 46.42 it/s   | 1024
nvshare-small-4                | PASS     | 867s         | 77.21 it/s   | 1024
==========================================================================================

📊 统计分析:
  Total: 4, Pass: 4, Fail: 0
  Duration: Min=866s, Max=869s, Avg=867.5s
  Speed   : Min=46.42, Max=77.21, Avg=54.36 (it/s)


==========================================
✅ 测试通过：Small Workload 全部成功
==========================================
```

# 测试5，每个任务占1/4 GPU，独占GPU
试用tests/pytorch-add-idle-small.py 间歇性测试GPU，每个任务GPU显存占用约4GB，算力占用约50%%

remote-test-idle-small.sh --skip-setup 1

测试结果
```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-vcmhq
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-idle-small-1           | 6b8926a17f393395   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1

==========================================================================================
nvshare-idle-small-1           | PASS     | 444s         | 9.12 it/s    | 2048
==========================================================================================

📊 统计分析:
  Total: 1, Pass: 1, Fail: 0
  Duration: Min=444s, Max=444s, Avg=444.0s
  Speed   : Min=9.12, Max=9.12, Avg=9.12 (it/s)


==========================================
✅ 测试通过：Idle Small Workload
==========================================
```

# 测试6，每个任务占1/4 GPU，共享GPU
试用tests/pytorch-add-idle-small.py 间歇性测试GPU，每个任务GPU显存占用约4GB，算力占用约10%%，共享GPU，由于本身任务就不需要跑满GPU算力，理论上并行不会影响任务完成时间。

remote-test-idle-small.sh --skip-setup 6

测试结果
```
Scheduler Log Analysis (GPU Distribution):
Analyzing scheduler pod: nvshare-scheduler-8ss4f
Pod Name                       | Client ID          | GPU UUID
--------------------------------------------------------------------------------------------
nvshare-idle-small-3           | d5bd144e36db3ac1   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-idle-small-2           | 5303e558781a9411   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-4           | 4c35e94d799441ab   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-5           | 78d1a1c85ea5f193   | GPU-dc895bd6-43d7-a984-b1ee-870332194bd1
nvshare-idle-small-1           | a5fdcec1c148ce27   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e
nvshare-idle-small-6           | 478c496370dd9c3f   | GPU-1f4246ce-cc92-8c8d-9f31-83660be04a1e

==========================================================================================
nvshare-idle-small-1           | PASS     | 481s         | 8.32 it/s    | 2048
nvshare-idle-small-2           | PASS     | 483s         | 8.42 it/s    | 2048
nvshare-idle-small-3           | PASS     | 481s         | 8.51 it/s    | 2048
nvshare-idle-small-4           | PASS     | 482s         | 9.05 it/s    | 2048
nvshare-idle-small-5           | PASS     | 483s         | 8.19 it/s    | 2048
nvshare-idle-small-6           | PASS     | 481s         | 9.07 it/s    | 2048
==========================================================================================

📊 统计分析:
  Total: 6, Pass: 6, Fail: 0
  Duration: Min=481s, Max=483s, Avg=481.8s
  Speed   : Min=8.19, Max=9.07, Avg=8.59 (it/s)


==========================================
✅ 测试通过：Idle Small Workload
==========================================
```

# 7. 测试总结与分析

本轮测试覆盖了基准性能、独占模式、串行共享、高负载并发及低负载并发等多种场景，以下是对 NVShare GPU 共享方案的核心指标分析：

## 1. 虚拟化开销 (Virtualization Overhead)
**结论：极低 (< 1%)**
通过对比 **Test 0 (基准)** 与 **Test 1/3/5 (NVShare独占状态)** 的数据可以看到：
*   Standard (Compute Heavy): 163s (Base) vs 164s (NVShare)
*   Small (Memory Bound): 392s (Base) vs 392.5s (NVShare)
*   Idle (Latency Sensitive): 445s (Base) vs 444s (NVShare)
NVShare 的拦截与调度机制在单任务场景下几乎不产生额外的时间开销，证明了其轻量级设计的优势。

## 2. 调度策略正确性与内存安全性 (Correctness & Safety)
**结论：符合预期，有效防止 OOM**
*   在 **Test 2 (Standard)** 中，单任务显存占用 12GB，显存 (16GB) 无法同时容纳两个任务。
    *   **Serial 模式**: 平均耗时 ~327s (约为基准 163s 的 2 倍)，符合串行执行的理论值。
    *   **Auto 模式**: 平均耗时 ~329s，与 Serial 模式极其接近。
    *   **分析**: 这表明 NVShare 准确识别了显存压力，自动触发了串行调度或高效的 Time-Slicing 机制，避免了并发运行导致的 OOM 崩溃或严重的 Swap 抖动。

## 3. 并发效率与算力共享 (Concurrency Efficiency)
**结论：计算密集型线性扩展，空闲/IO密集型显著提升密度**
*   **Test 4 (Small, 高算力并发)**:
    *   场景: 2 任务/GPU，显存充足，但算力需求均为 100%。
    *   结果: 耗时 ~867s，约是基准 (392s) 的 2.2 倍。
    *   **分析**: 此时瓶颈在于 GPU CUDA Core 算力。两任务竞争算力导致时间翻倍，额外 ~10% 的开销来自上下文切换 (Context Switch)。这是时分复用 (Time-Slicing) 的正常表现。
*   **Test 6 (Idle, 低算力并发)**:
    *   场景: 3 任务/GPU，显存充足，算力需求低 (~10%)。
    *   结果: 耗时 ~482s，仅比基准 (445s) 增加约 8%。
    *   **分析**: 这是 GPU 共享的最佳场景。NVShare 成功实现了 3 倍的任务部署密度，同时仅牺牲了 <10% 的运行时间。这证明了在推理服务或开发环境中，NVShare 能显著提升 GPU 利用率。

## 4. 总体评价
NVShare 在保证**零侵入性**（无需修改代码）和**低开销**的前提下，展示了优秀的调度能力：
1.  **安全性**: 内存不足时自动串行，保证任务成功率。
2.  **高利用率**: 在显存和算力允许时（如 Test 6），能大幅提升部署密度而几乎不影响性能。
3.  **公平性**: 从跨 GPU 测试日志看，任务被均匀分配到了不同 GPU 上，未出现负载倾斜。

---

# 8. 动态算力配额优化阶段最新结果（2026-02-11 ~ 2026-02-14）

> 基准：`tests/pytorch-add-small.py` 单任务无配额时约 `391s`。

## 8.1 关键场景结果

| 场景 | 实测耗时 | 备注 |
|---|---:|---|
| 4任务2GPU，`30%+60%`（每GPU各1个30+1个60） | `60%: 672s`，`30%: 1316s` | 已接近目标比例 |
| 4任务2GPU，`50%+50%` | `864s/864s/864s/864s` | 对称性稳定 |
| 4任务2GPU，`75%+75%` | `866s/867s/866s/867s` | 与 50+50 场景接近，说明主要受双任务共享上限影响 |
| 单任务1GPU，`25%` | `1458s` | 相对理论值偏快 |
| 单任务1GPU，`50%` | `739s` | 相对理论值偏快 |
| 单任务1GPU，`75%` | `506s` | 相对理论值偏快 |

## 8.2 偏差分析

- `30%+60%` 场景中：
  - 理论值（按 `391s / quota`）约：`60% -> 652s`，`30% -> 1303s`
  - 实测：`672s` / `1316s`，误差约 `+3.1%` / `+1.0%`
  - 结论：并发异配额场景已明显改善，可用于下一阶段小步优化。

- 单任务低配额场景（25/50/75）普遍快于理论值，说明当前模型在该类场景下会略“多给算力”：
  - `25%`: 理论 `1564s`，实测 `1458s`（约 `-6.8%`）
  - `50%`: 理论 `782s`，实测 `739s`（约 `-5.5%`）
  - `75%`: 理论 `521s`，实测 `506s`（约 `-2.9%`）

## 8.3 本阶段结论

1. `Phase B`（DROP 尾段折算计费）保留，收益稳定且无明显副作用。  
2. `Phase C`（提前触发 DROP）已回退，原因是会在 `50%+50%` 场景引入可见吞吐下降。  
3. 当前版本在“并发异配额公平性”上已接近目标；后续优先优化“单任务低配额偏快”的残留偏差。

---

# 9. CANN 配额能力回归结果（2026-03-05）

本节补充最新一轮 CANN quota 能力回归数据，结果来自：

- `.tmplog/20260305-170436/remote-smoke/run-summary.tsv`（最终通过）
- `.tmplog/20260305-161231/remote-smoke/run-summary.tsv`（core-static 单项回归）

## 9.1 最终全量回归（run_id=20260305-170436）

| 用例 | 结果 | 关键数据 |
|---|---|---|
| `cann-quota-concurrent-bootstrap` | PASS | `both_pods_running`，`req_lock_delta=10`，`lock_ok_delta=10`，`iters_a=31700`，`iters_b=31600` |
| `cann-quota-mem-static` | PASS | `limit=1Gi`，`settle_sec=20`，观察到预期 OOM |
| `cann-quota-mem-dynamic` | PASS | `1Gi -> 2Gi`，`metric_before=1073741824`，`metric_after=2147483648` |
| `cann-quota-core-static` | PASS | `base=3.332572s`，`limited=8.084036s`，`ratio=2.4258`（阈值 `1.70`） |
| `cann-quota-core-dynamic` | PASS | 核心算力指标从 `20 -> 80`，`target=80` |
| `cann-quota`（汇总） | PASS | `all cann quota cases passed` |

## 9.2 关键结论

1. **内存配额生效**：静态限额可触发预期 OOM，动态调整可在 metrics 上观测到字节级变化。
2. **算力配额生效**：静态 50% 配额下耗时放大比约 `2.43x`，达到预期降速区间；动态配额指标能从 `20` 提升到 `80`。
3. **并发引导可用**：并发 bootstrap 场景下，两任务均可进入运行态，调度握手计数与运行迭代数均符合预期。
