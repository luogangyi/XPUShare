# Libnvshare Unified Memory 架构与实现分析

## 1. 概述

`libnvshare` 不仅实现了 GPU 时间片的共享，还通过利用 NVIDIA 的 **Unified Memory (UM, 统一内存)** 技术，实现了显存的 **超额订阅 (Oversubscription)**。这一机制允许应用申请超过物理 GPU 显存容量的内存，或者允许多个应用的总显存需求超过物理显存上限，从而极大提升了多租户环境下的部署密度。

## 2. 核心实现机制

### 2.1 强制显存托管 (Forced Managed Memory)

`libnvshare` 对 Unified Memory 的利用是非常激进且透明的。它并不是等待应用主动调用 `cuMemAllocManaged`，而是**劫持了标准的显存分配函数 `cuMemAlloc`，并将其底层实现替换为 `cuMemAllocManaged`**。

代码位置: `src/hook.c`:

```c
CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
  // ...
  // 关键点：将普通的 cuMemAlloc 请求重定向为 Managed 内存分配
  result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
  // ...
}
```

这意味着：
*   **应用无感知**: 普通的 CUDA 应用完全不知道自己使用的是 Unified Memory。
*   **零修改**: 不需要修改应用代码将 `cudaMalloc` 改为 `cudaMallocManaged`。
*   **自动迁移**: 分配得到的内存页可以由 CUDA Driver 根据访问情况，在 Host RAM 和 Device RAM 之间自动按需迁移 (Page Faulting)。

### 2.2 显存超额订阅 (Oversubscription)

通过上述替换，应用获得的显存本质上变成了主机虚拟内存的一部分（由 GPU 驱动管理）。这为显存超额订阅提供了基础。

系统通过环境变量 `NVSHARE_ENABLE_SINGLE_OVERSUB` 控制超额订阅行为：

1.  **限制模式 (默认)**:
    *   `enable_single_oversub == 0`
    *   `libnvshare` 会维护一个全局的已分配内存计数 `sum_allocated`。
    *   当 `sum_allocated + bytesize` 超过物理显存限制 (`nvshare_size_mem_allocatable`) 时，直接返回 `CUDA_ERROR_OUT_OF_MEMORY`。
    *   这模拟了标准 GPU 的行为，防止单一应用意外耗尽显存导致严重的 Thrashing。

2.  **超额模式**:
    *   `enable_single_oversub == 1`
    *   即使分配量超过物理显存，依然允许分配 (`cuMemAllocManaged` 成功即可)。
    *   这完全依赖 NVIDIA Driver 的分页机制 (Unified Memory Paging) 来处理显存压力。当显存不足时，旧的页会被驱逐 (Evict) 到系统内存；当 GPU 再次访问时，触发缺页中断并迁移回显存。

### 2.3 物理显存预留

为了防止驱动程序、上下文切换以及 `libnvshare` 自身占用显存导致应用可用显存不足（从而引发抖动），代码中硬编码了一个预留值：

```c
#define MEMINFO_RESERVE_MIB 1536 /* MiB */
```

在拦截 `cuMemGetInfo` 时，`libnvshare` 会向应用报告：
`Free Memory = Total Memory - Used - MEMINFO_RESERVE_MIB`

这“欺骗”应用认为可用显存比实际少 1.5GB，从而为系统开销预留缓冲空间。

## 3. 架构优势与权衡

### 优势
*   **提高混部密度**: 允许多个显存需求较大的任务即使在显存吃紧时也能启动运行（利用时间片轮转，在未被调度时，其显存页可能被换出）。
*   **简化开发**: 用户无需关心显存管理细节，无需手动处理 Host/Device 数据搬运。

### 权衡与代价
*   **性能隐患**:
    *   **Thrashing (抖动)**: 如果超额严重，GPU 会频繁触发缺页中断 (Page Fault) 和数据迁移 (HtoD / DtoH)。PCIe 带宽将成为瓶颈，计算性能可能呈指数级下降。
    *   **调度开销**: `libnvshare` 的锁机制 (`LOCK_OK` / `DROP_LOCK`) 配合 UM 可能加剧抖动。当一个进程获得锁开始计算时，它可能通过缺页将之前被换出的数据大量换入，导致其他进程的数据被换出。
*   **不支持 IPC**: 目前实现仅针对单进程上下文。Unified Memory 在多进程间共享（IPC）需要特殊的句柄处理，目前的 `cuMemAlloc` 劫持并不自动支持跨进程指针共享。

## 4. 总结

`libnvshare` 的 Unified Memory 实现是一种**透明代理模式**。它通过 Hook 技术，在应用毫不知情的情况下，将其显存模型从 "Explicit Management" 转换为 "Unified Memory / Demand Paging"。这一设计极大地增强了系统处理突发显存需求和多任务并行的能力，但也对系统 PCIe 带宽和调度策略提出了更高的要求。
