# 简单预取 (Simple Prefetch) 失效深度分析

## 1. 现象复盘
在 300% 显存超卖场景下（4 Pods x 12GB @ 16GB GPU），我们尝试通过 `cuMemPrefetchAsync` 提前将显存搬运至 GPU，以消除时间片切换初期的"缺页风暴"（Page Fault Storm）。

然而，实测结果显示：
1.  **预取操作耗时 0.000 秒**: `[NVSHARE][INFO]: Prefetch: Done. DMA migration took 0.000 seconds`.
2.  **性能无改善**: 任务依然卡顿 50s+ (`Warmup: Ignored critical timeout (26 s)`, `Grace Period: timeout (50 s)`).
3.  **显存未驻留**: `nvidia-smi` 显示所有进程似乎占满了显存（14911MiB Used），但实际上当前激活的进程并未能独占 GPU 显存，导致持续缺页。

## 2. 核心矛盾：为什么预取是 No-Op (0秒)？

代码中已经添加了强制同步 (`cuCtxSynchronize`)，理论上如果驱动执行了搬运，必然会产生耗时（搬运 9GB 数据至少需要 ~1秒）。0.000秒 说明驱动 **直接忽略了** 该请求，或者认为 **无需搬运**。

### 原因一：虚拟内存 vs 物理内存 (First Touch 问题)
这是最根本的技术原因。
*   **分配机制**: `cuMemAllocManaged` (Unified Memory) 在分配时，只会在页表中保留 **虚拟地址 (VA)** 范围，而 **不会分配物理内存**。物理内存是在 **第一次访问 (First Touch)** 时才分配的。
*   **PyTorch 行为**: 
    1.  调用 `cudaMalloc` (被我们拦截为 `cuMemAllocManaged`) -> 获得 VA。
    2.  此时物理上这些页面是 "空的"（Non-resident）。
    3.  我们的 `hook.c` 在此时触发 `cuMemPrefetchAsync`。
    4.  **驱动行为**: 驱动看到这些 VA 根本没有对应的物理页（无论是在 CPU 还是 GPU），也没有数据需要迁移。因此，`cuMemPrefetchAsync` 直接返回成功（Did nothing）。
    5.  **后续灾难**: 接着 PyTorch 启动 Kernel 开始初始化权重（写操作）。此时触发真实的 **缺页中断 (Page Fault)**。驱动不得不逐页分配物理内存，导致了观测到的 26s/50s 卡顿。

**结论**: 对"空页面"进行预取是无效的。

### 原因二：驱动的预取策略 (Driver Policy under Pressure)
**最新验证**: 通过 SSH `nvidia-smi` 验证，当 Pod 停止时显存占用为 0。测试中显示的 `14911MiB Used` 实际上是 4 个 PyTorch 进程抢占显存的结果 (平均每人驻留 ~3.75GB)。
此时 GPU **物理全满**。
*   **Hint 被忽略**: `cuMemPrefetchAsync` 只是一个建议。当目标设备没有空闲页时，驱动选择忽略该建议，而不是主动触发昂贵的全局驱逐。
*   **同步无用**: 因此 `cuCtxSynchronize` 立即返回 (0.000s)，因为根本没有任务被提交到 Copy Engine。

## 3. 为什么后续 Slice 依然慢？
即使物理页已分配，从 Host 到 Device 的换入依然受制于驱动的"按需"策略及 Page Fault 处理速度。

## 解决方案展望：手动交换 (Manual Swap)
既然驱动不可靠，我们需要接管显存并在用户态实现强制交换。

### 方案 8: Manual Host Swap (Shadow Buffer)
**原理**: 不依赖 UVM 的自动管理，而是由 `libnvshare` 维护一份 Host 端的"影子内存"。
1.  **Alloc**: 当 App 申请 GPU 显存时，同时申请一块等大的 Host Pinned Memory。
2.  **Release Lock**: 将 GPU 数据强制 `cudaMemcpy` 备份到 Host Shadow Buffer。
3.  **Acquire Lock**: 将 Host Shadow Buffer 强制 `cudaMemcpy` 恢复到 GPU。
    *   此时使用的是计算/复制引擎 (CE/Kernel)，而非缺页中断。
    *   **预期性能**: PCIe 3.0 x16 带宽 ~12GB/s。恢复 12GB 数据约需 **1秒**。
    *   相比 50s 的缺页风暴，这是巨大的提升。

**代价**:
*   Host 内存消耗翻倍 (48GB RAM)。
*   代码复杂度增加（需保证数据一致性，dirty bit 追踪困难，可能需要全量 Copy）。

