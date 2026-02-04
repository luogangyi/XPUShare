# 深度性能瓶颈分析报告与优化方案 (Deep Analysis of Performance Bottleneck)

## 1. 现象描述 (Problem Statement)
在 300% 显存超卖（15GB 物理显存运行 4 个 12GB 任务）的场景下，用户观察到单次 Kernel Window (128个 kernels) 的执行耗时高达 **50秒**。
虽然 `nvidia-smi` 显示物理显存有大量剩余（因为其他非活跃进程的内存已被驱逐到 Host RAM），但任务执行依然极慢。

## 2. 核心原因：缺页中断风暴 (The Page Fault Storm)

### 为什么带宽并不是瓶颈？
GPU 的 PCIe 3.0 x16 带宽约为 16GB/s。
理论上，将 12GB 数据从 Host RAM 搬运到 GPU VRAM 只需要：
$$ \frac{12 \text{ GB}}{16 \text{ GB/s}} \approx 0.75 \text{ 秒} $$
但在实际日志中，我们看到了 ~50秒 的延迟。这说明**带宽并未跑满**。

### 真正的瓶颈：按需分页延迟 (Demand Paging Latency)
`nvshare` 使用 CUDA Unified Memory (UVM) 的 `cuMemAllocManaged` 进行显存分配。
当一个进程获得 GPU 锁并开始执行时，它的内存页大部分都位于 Host RAM（因为之前被驱逐了）。
由于没有显式的 "预取" (Prefetch) 操作，GPU 必须通过 **缺页中断 (Page Fault)** 来逐页加载数据：

1.  **页数量**: 假设页大小为 4KB (UVM 默认值)，12GB 数据意味着 **3,145,728 (314万)** 个内存页。
2.  **中断开销**: 每次处理缺页中断（CPU中断 -> 驱动处理 -> 数据迁移 -> 页表更新 -> GPU恢复）的物理延迟约为 15微秒 (15µs)。
3.  **总耗时**:
    $$ 3,145,728 \times 15\mu s \approx 47.2 \text{ 秒} $$

**结论**: `47.2秒` 的理论缺页处理可以完美解释日志中观测到的 `50秒` 耗时。目前的"慢"是由于 IO 操作过于**细碎**（300万次微小的 IO）而非总量过大导致的。

## 3. 优化方案：批量预取 (Simple Prefetch Strategy)

用户提出的 "基于剩余显存的批量加载" 是**完全可行且高效**的解决方案。

### 方案逻辑
在 `hook.c` 已经从 `client.c` 获得 "新时间片 (New Slice)" 信号（即 `LOCK_OK`）的时刻，我们可以执行以下逻辑：

1.  **检查余量**: 调用 `cuMemGetInfo` 获取当前物理显存剩余量 (例如 11GB)。
2.  **遍历分配**: 遍历 `nvshare` 维护的 `cuda_allocation_list` 链表（记录了该进程所有的 `cuMemAllocManaged` 指针和大小）。
3.  **批量预取**:
    -   如果 `Total_Allocation_Size < Free_Memory` (例如任务需 10GB，剩余 11GB)：
    -   调用 `cuMemPrefetchAsync(ptr, size, device, stream)`。
    -   这会指示 CUDA 驱动使用 **Copy Engine (DMA)** 进行大块数据传输。

### 预期收益
-   **传输模式**: 从 "300万次 4KB 传输" 变为 "几次 1GB+ 的 DMA 传输"。
-   **耗时**: 将由 ~50秒 (Latency Bound) 降低到 ~1-2秒 (Bandwidth Bound)。
-   **体验**: 消除长时间的 "假死/暂停" 现象，大幅提升吞吐量。

## 4. 实施计划 (Implementation Plan)

该方案需要修改 `src/hook.c`：
1.  **加载符号**: 加载 `cuMemPrefetchAsync` 函数符号（目前未加载）。
2.  **新增函数**: 实现 `prefetch_all_allocations()`，遍历链表并执行预取。
3.  **插入钩子**: 在 `hook.c` 检测到 `New Slice`（`lock_acquire_time` 变更）时，立即调用该预取函数。

这种"主动预取"策略将是解决超卖场景下性能问题的银弹。
