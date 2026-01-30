# nvshare 多任务性能问题深度复盘报告

## 1. 核心问题回顾

### 1.1 观察到的现象

| 场景 | 运行时间 | 相对性能 |
|------|----------|----------|
| Native (nvidia device plugin) | 155 秒 | 100% |
| nvshare 单任务 | 159 秒 | 97.5% |
| nvshare 多任务并发 | 估算 > 5000 秒 | **< 3%** |

**核心矛盾**：单任务几乎无性能损失，但多任务性能却下降到原来的 3%。

### 1.2 关键问题

> 之前的分析思路是否没有找到真正的问题？

**结论：之前的分析方向是正确的，但提出的解决方案并未实现。**

---

## 2. 问题根因分析

### 2.1 为什么单任务没有性能损失？

单任务场景下，虽然 nvshare 使用 `cuMemAllocManaged` (Unified Memory) 替代 `cuMemAlloc`，但由于：

1. **无竞争环境**：只有一个任务使用 GPU，所有显存页面可以安全驻留在 VRAM
2. **无切换开销**：不需要与其他任务轮转，没有 Page Eviction/Migration
3. **CUDA 驱动优化**：驱动可以主动预取连续访问模式的页面

因此，实际计算速度与原生方式持平（159秒 vs 155秒）。

### 2.2 为什么多任务性能暴跌？

多任务并发时，nvshare 引入了 **时间片轮转调度**。当任务 B 获得 GPU 锁时：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         数据恢复的两种路径                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  当前实现: 按需分页 (Demand Paging)                                          │
│  ──────────────────────────────────────                                     │
│                                                                             │
│    获得锁 → 执行 Kernel → GPU 访问内存 → 触发 Page Fault → CPU 处理中断     │
│              ↑                                ↓                             │
│              └──────── 等待 (GPU 空闲) ────────┘                            │
│                                                                             │
│    耗时: 3,145,728 页 × 15µs/页 ≈ 47.2 秒 (12GB 数据)                       │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  理想方案: 批量预取 (Bulk Prefetch) [未实现]                                  │
│  ────────────────────────────────────────────                               │
│                                                                             │
│    获得锁 → cuMemPrefetchAsync → DMA 引擎批量搬运 → 执行 Kernel             │
│                    ↓                                                        │
│              GPU Copy Engine 全速传输                                        │
│                                                                             │
│    耗时: 12GB / 16GB/s ≈ 0.75 秒                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 3% 性能的数学解释

假设配置：
- 时间片 (TQ) = 30 秒
- 12GB 数据恢复时间（按需分页）≈ 47 秒
- 时间片 < 数据恢复时间

```
有效计算时间 = max(0, TQ - 数据恢复时间)
             = max(0, 30 - 47)
             = 0 秒

→ 任务在每个时间片内的计算量 = 0
→ 进度完全依赖少量"热页"的偶然命中
→ 实际进度 ≈ 0% ~ 3%
```

**这是一个典型的 Thrashing (颠簸) 现象：系统将全部时间用于内存迁移，几乎不做有效计算。**

---

## 3. 之前尝试的优化及为何失效

### 3.1 尝试 1: 修改 Kernel Window 增长速度

**目标**：让任务更快进入"全速状态"

**问题**：Kernel Window 控制的是 kernel 提交批次大小，与数据恢复时间无关。无论窗口是 4 还是 512，在首次同步时都要等待 47 秒的页面迁移。

### 3.2 尝试 2: 修改切换策略

**目标**：减少切换频率

**问题**：即使延长时间片到 60 秒甚至 120 秒，也只是将问题推迟。如下表所示：

| 时间片 | 恢复时间 | 有效计算时间 | 效率 |
|--------|----------|--------------|------|
| 30 秒  | ~47 秒   | 0 秒         | 0%   |
| 60 秒  | ~47 秒   | 13 秒        | ~22% |
| 120 秒 | ~47 秒   | 73 秒        | ~61% |
| 180 秒 | ~47 秒   | 133 秒       | ~74% |

**权衡**：时间片过长会导致其他任务饥饿。这只是治标不治本。

### 3.3 尝试 3: 显存分配/抢占策略

**目标**：优化内存配额管理

**问题**：这些策略解决的是"谁先分到显存"的问题，而不是"如何快速恢复已分配显存"的问题。

---

## 4. 根本解决方案：实现显存预取

### 4.1 方案概述

在获得 GPU 锁的瞬间，主动调用 `cuMemPrefetchAsync` 将所有已分配的内存块预取到 GPU VRAM。

```c
// hook.c 或 client.c 中在 LOCK_OK 处理逻辑新增
void on_lock_acquired() {
    CUstream stream;
    cuStreamCreate(&stream, CU_STREAM_NON_BLOCKING);
    
    // 遍历所有分配的内存块
    struct cuda_mem_allocation* alloc;
    LL_FOREACH(cuda_allocation_list, alloc) {
        cuMemPrefetchAsync(alloc->ptr, alloc->size, current_device, stream);
    }
    
    // 等待预取完成
    cuStreamSynchronize(stream);
    cuStreamDestroy(stream);
    
    // 此时数据已就绪，计算可以全速进行
}
```

### 4.2 预期效果

| 指标 | 按需分页 (当前) | 批量预取 (改进后) | 提升 |
|------|----------------|-------------------|------|
| 12GB 恢复时间 | ~47 秒 | ~1-2 秒 | **≈40x** |
| 30 秒时间片效率 | 0% | ~93% | **∞** |
| 多任务总完成时间 | ≥15 小时 | ~4×3 分钟 = 12 分钟 | **≈75x** |

### 4.3 为什么这个方案没有被实现？

通过代码审查确认：

1. `cuMemPrefetchAsync` 函数符号 **未被加载**
2. `on_lock_acquired` 中 **没有预取逻辑**
3. 之前的分析文档明确提出了这个方案（见 `deep_analysis_performance_bottleneck.md` 和 `memory_and_schedule_analysis.md`），但实际代码中并未实现

---

## 5. 补充发现：潜在的额外问题

### 5.1 Warm-up 逻辑时序问题

```c
// hook.c 当前逻辑
result = real_cuCtxSynchronize();  // ← 可能耗时 47 秒
// ...
time_t now = time(NULL);
if ((now - lock_acquire_time) < kern_warmup_period_sec) {  // 30 秒
    // 判断为预热期
}
```

**问题**：如果同步本身就耗时 47 秒，则 `now - lock_acquire_time` 已 > 30 秒，预热判断失效。

**解决**：应在同步 **之前** 判断是否处于预热期。

### 5.2 cuda_sync_context 中重置窗口过于激进

```c
static void cuda_sync_context(void) {
    pending_kernel_window = 1;  // ← 直接重置为 1
    // ...
}
```

**问题**：每次释放锁时都将 kernel window 重置为 1，导致下次获得锁后需要重新爬坡。

**建议**：保留一定的窗口大小，避免从 1 重新开始。

---

## 6. 改进实施计划

### 阶段 1: 实现 cuMemPrefetchAsync 预取 [核心]

**优先级**: 🔴 最高

**预计耗时**: 3-5 天

**实施步骤**:

1. **加载 cuMemPrefetchAsync 符号** - 修改 `bootstrap_cuda()`
2. **实现 prefetch_all_allocations 函数** - 遍历 `cuda_allocation_list` 执行预取
3. **在 LOCK_OK 处理中调用预取** - 修改 `client_fn()` 或新增钩子

```c
// 新增函数
static void prefetch_all_allocations(int device) {
    CUstream stream;
    cuStreamCreate(&stream, CU_STREAM_NON_BLOCKING);
    
    struct cuda_mem_allocation* alloc;
    LL_FOREACH(cuda_allocation_list, alloc) {
        cuMemPrefetchAsync(alloc->ptr, alloc->size, device, stream);
    }
    
    cuStreamSynchronize(stream);
    cuStreamDestroy(stream);
    log_info("Prefetched %zu MB in preparation for compute", 
             sum_allocated / (1024 * 1024));
}
```

### 阶段 2: 修复 Warm-up 逻辑

**优先级**: 🟡 中

**预计耗时**: 1 天

**修改**:
```c
// 修改后的逻辑
int in_warmup = (time(NULL) - lock_acquire_time) < kern_warmup_period_sec;
result = real_cuCtxSynchronize();
// 使用之前记录的 in_warmup，而不是重新计算
```

### 阶段 3: 优化 Kernel Window 管理

**优先级**: 🟢 低

**预计耗时**: 0.5 天

**修改**: 在 `cuda_sync_context()` 中保留部分窗口大小

---

## 7. 验证方法

### 7.1 单元测试

创建测试脚本验证预取功能：

```bash
# tests/test_prefetch_performance.sh
#!/bin/bash

# 启动 2 个并发任务
( LD_PRELOAD=/path/to/libnvshare.so python tests/pytorch-add.py ) &
( LD_PRELOAD=/path/to/libnvshare.so python tests/pytorch-add.py ) &

wait
```

### 7.2 性能指标

| 指标 | 修改前预期 | 修改后预期 | 验证方法 |
|------|------------|------------|----------|
| 单任务时间 | ~159 秒 | ~159 秒 | 时间对比 |
| 双任务总时间 | > 10000 秒 | < 400 秒 | 时间对比 |
| 切换后首次同步耗时 | ~47 秒 | < 3 秒 | 日志时间戳 |

### 7.3 日志验证

实现后应能看到类似日志：
```
[NVSHARE][INFO]: Received LOCK_OK
[NVSHARE][INFO]: Prefetched 12288 MB in preparation for compute
[NVSHARE][INFO]: Prefetch completed in 1.23 seconds
```

---

## 8. 结论

### 8.1 问题诊断结论

之前的分析方向 **完全正确**：

1. ✅ 正确识别了 UVM Demand Paging 是性能瓶颈
2. ✅ 正确计算了 47 秒的恢复延迟
3. ✅ 正确提出了 `cuMemPrefetchAsync` 预取方案

**但关键的解决方案未被实施**，这是性能未改善的根本原因。

### 8.2 为什么调整其他参数无效

| 尝试的优化 | 目标 | 为何无效 |
|------------|------|----------|
| 增大 Kernel Window | 提高并发 | 数据不在 GPU，窗口再大也无 kernel 可执行 |
| 延长时间片 | 延长有效时间 | 治标不治本，仍有 47 秒不可逾越的恢复开销 |
| 显存配额管理 | 控制分配 | 解决的是"分配给谁"，不是"如何快速恢复" |

### 8.3 下一步行动

**立即执行**：实现 `cuMemPrefetchAsync` 预取功能

这是解决多任务性能问题的 **唯一有效方案**。其他所有优化都只是锦上添花，没有预取，就没有根本性能提升。

---

## 附录：相关代码位置

| 文件 | 待修改函数/区域 | 修改内容 |
|------|-----------------|----------|
| `src/hook.c` | `bootstrap_cuda()` | 加载 `cuMemPrefetchAsync` 符号 |
| `src/hook.c` | 新增 `prefetch_all_allocations()` | 实现批量预取 |
| `src/client.c` | `case LOCK_OK:` | 调用预取函数 |
| `src/hook.c` | `cuLaunchKernel()` 中的 warmup 判断 | 修复时序问题 |
