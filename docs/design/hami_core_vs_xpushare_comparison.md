# HAMi-core vs XPUShare：GPU 算力配额控制的架构对比分析

## 1. 背景

HAMi-core 和 XPUShare (原 nvshare) 都通过 `LD_PRELOAD` 劫持 CUDA Driver API 来实现 GPU 共享，但二者在 API 劫持范围上有本质差异：

| 维度 | HAMi-core | XPUShare |
|:---|:---|:---|
| 劫持 API 数量 | **150+ 个** | **~16 个** |
| 核心机制 | 虚拟化设备内存 + 时间片限流 | Unified Memory + 时间片调度 |
| 内存隔离 | 软件层面精确记账 | 硬件层面 (UVM Page Fault) |
| 调度器 | 进程内自治（文件锁协调） | 独立守护进程 (Unix Socket) |

---

## 2. 为什么 HAMi-core 需要劫持这么多 API

### 2.1 根本原因：它不使用 Unified Memory

HAMi-core **不修改**应用程序的内存分配方式。`cudaMalloc` 仍然是 `cudaMalloc`，分配的是常规的 *Device Memory*。因此，HAMi-core 必须在软件层面"虚拟化"整个 GPU 显存视图：

```
应用程序 → cudaMalloc(1GB) → HAMi-core 拦截 → 检查是否超限 → 调用真正的 cudaMalloc
```

这意味着：

1. **每一种分配 API 都必须劫持**  
   GPU 内存不仅通过 `cuMemAlloc` 分配，还有：
   - `cuMemAllocManaged`, `cuMemAllocPitch`, `cuMemAllocHost`
   - `cuMemAllocAsync`, `cuMemAllocFromPoolAsync` (CUDA 11.2+)
   - `cuArrayCreate`, `cuArray3DCreate`, `cuMipmappedArrayCreate`
   - `cuMemAddressReserve`, `cuMemCreate`, `cuMemMap` (Virtual Memory Management API)
   - `cuIpcOpenMemHandle` (跨进程共享显存)
   - `cuImportExternalMemory` (外部资源互操作)
   
   遗漏**任何一个**分配路径，都会导致显存记账不准确，限制形同虚设。

2. **每一种释放 API 也必须劫持**  
   对应的 `cuMemFree`, `cuArrayDestroy`, `cuMipmappedArrayDestroy`, `cuMemRelease`, `cuIpcCloseMemHandle` 等。

3. **查询 API 必须返回虚拟值**  
   - `cuDeviceTotalMem` → 返回配额值而非物理值
   - `cuMemGetInfo` → 返回虚拟化后的 free/total
   - `cuDeviceGetAttribute` → 可能篡改显存相关属性

### 2.2 Context/Device API：多设备虚拟化

HAMi-core 支持将物理 GPU 的子集暴露给容器。例如，物理节点有 8 张 GPU，但容器只能看到 2 张：

```c
// HAMi-core 劫持这些 API 来实现 GPU 设备虚拟化
cuDeviceGetCount()     → 返回虚拟设备数
cuDeviceGet()          → 映射虚拟 ID → 物理 ID
cuDeviceGetByPCIBusId() → 过滤
cuDeviceGetUuid()       → 映射
cuCtxCreate()           → 绑定到正确的物理设备
cuDevicePrimaryCtxRetain() → 设备映射
```

XPUShare 不做设备虚拟化，容器可以看到所有 GPU。调度器按 GPU UUID 独立管理每张卡。

### 2.3 Stream/Event API：资源生命周期追踪

```c
cuStreamCreate()   → 记录 Stream 对象用于利用率追踪
cuStreamDestroy()  → 清理追踪
cuEventCreate()    → 记录 Event 对象
cuEventDestroy()   → 清理
```

HAMi-core 需要追踪 Stream 和 Event 的生命周期，因为它的利用率监控依赖于 `cuStreamSynchronize` 来测量实际 GPU 使用时间。

### 2.4 Module/Linker API：代码加载追踪

```c
cuModuleLoad()         → 追踪 Module 加载开销
cuModuleLoadData()     → 同上
cuModuleLoadFatBinary() → 同上
cuModuleGetFunction()  → 追踪 Kernel 函数
cuModuleUnload()       → 清理
cuLinkCreate/AddData/Complete/Destroy → JIT 编译追踪
```

这些 API 加载 GPU 代码（PTX/CUBIN），会消耗显存用于 JIT 编译缓存。HAMi-core 必须追踪这些隐性内存消耗。

### 2.5 Memcpy/Memset API：完整数据面拦截

HAMi-core 劫持了 **所有** memcpy 和 memset 变体（~30个）：

```c
cuMemcpy, cuMemcpyAsync, cuMemcpyPeer, cuMemcpyPeerAsync,
cuMemcpyAtoD, cuMemcpyDtoA, cuMemcpyDtoD, cuMemcpyDtoH, cuMemcpyHtoD,
cuMemcpy2D, cuMemcpy3D, cuMemcpy3DPeer, cuMemPrefetchAsync,
cuMemsetD8/16/32, cuMemsetD2D8/16/32, (及其 Async 变体)
```

原因：
- 这些操作在执行前需要确保**当前进程有 GPU 访问权**（未被限流）
- 需要追踪数据传输量用于利用率计算
- `cuMemPrefetchAsync` 会影响显存 Residency，需要记账

### 2.6 Graph API：CUDA Graph 支持

CUDA Graph 将一系列操作（kernel launch、memcpy、memset 等）打包为一个可重放的图。如果不劫持 Graph API，应用程序可以通过 Graph 绕过所有限制：

```c
cuGraphCreate, cuGraphAddKernelNode, cuGraphAddMemcpyNode,
cuGraphAddMemsetNode, cuGraphAddHostNode, cuGraphClone, ...
```

### 2.7 Memory Pool API (CUDA 11.2+)

```c
cuMemPoolCreate, cuMemPoolDestroy, cuMemPoolTrimTo,
cuMemPoolSetAttribute, cuMemPoolGetAttribute, cuMemPoolSetAccess,
cuMemAllocFromPoolAsync, cuMemPoolExportPointer, cuMemPoolImportPointer
```

现代 CUDA 应用越来越多使用 Memory Pool 来提升分配性能。不劫持这些 API，显存记账就会不准确。

---

## 3. 为什么 XPUShare 只需劫持 ~16 个 API

### 3.1 核心设计差异：Unified Memory 一招解千忧

XPUShare 的核心策略是将 `cuMemAlloc` 替换为 `cuMemAllocManaged`：

```c
// hook.c 中的 cuMemAlloc 实现
CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
    // ...
    result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
    insert_cuda_allocation(*dptr, bytesize);
    return result;
}
```

这一改动使得：

1. **无需虚拟化显存大小**  
   Unified Memory 允许分配超过物理显存的内存，利用系统 RAM 通过 Page Fault 自动换页。因此不需要拦截 `cuArrayCreate`、`cuMipmappedArrayCreate`、`cuMemAllocPitch` 等——它们分配的是特定布局的"物理"显存，在 UVM 模式下不需要特殊处理。

2. **无需追踪所有分配路径**  
   只需要劫持 `cuMemAlloc`（最常用的分配入口）和 `cuMemFree`。其他分配方式（Array、Mipmap、Host pinned memory 等）影响较小，可以放过。

3. **`cuMemGetInfo` 只需简单调整**  
   返回减去保留量的值即可，不需要像 HAMi-core 那样完全虚拟化。

### 3.2 XPUShare 劫持的 API 清单及原因

| API | 原因 |
|:---|:---|
| `cuInit` | 用作 Bootstrap 信号，触发 nvshare 初始化 |
| `cuMemAlloc` | **核心**：替换为 `cuMemAllocManaged` |
| `cuMemFree` | 追踪内存释放，更新已分配量 |
| `cuMemGetInfo` | 返回调整后的 free/total |
| `cuLaunchKernel` | **核心**：在此做 Lock 检查 + Kernel Window 流控 |
| `cuMemcpy` 系列 (8个) | 阻止未持锁时的数据传输（会触发 Page Fault） |
| `cuGetProcAddress` (v1 & v2) | 入口劫持：CUDA ≥11.3 通过此 API 获取函数指针 |
| `dlsym` (v2.2.5 & v2.34) | 入口劫持：CUDA <11.3 通过 dlsym 获取函数指针 |

### 3.3 不需要劫持的 API 及原因

| API 类别 | 为什么不需要 |
|:---|:---|
| **Device/Context** | 不做设备虚拟化，容器可看到所有 GPU |
| **Stream/Event** | 不追踪 Stream 生命周期；调度基于 Lock 不基于 Stream |
| **Module/Linker** | JIT 编译开销在 UVM 下自动管理 |
| **Memset** | 不需要记账，在 UVM 下安全 |
| **Graph** | 目前不支持，但 Graph 内的 Kernel Launch 仍会触发 `cuLaunchKernel` |
| **Memory Pool** | UVM 模式下不太需要 Pool；如需支持可按需添加 |
| **IPC** | 不支持跨进程显存共享场景 |
| **Virtual Memory** | UVM 不使用 Virtual Address Management API |
| **External Resource** | 不支持 Vulkan/OpenGL 互操作 |

---

## 4. 算力配额控制的具体对比

### 4.1 HAMi-core 的算力限制

HAMi-core 使用 **利用率监控 + 主动限流** 的方式：

```
utilization_watcher 线程:
  1. 每 N ms 读取 NVML (nvmlDeviceGetUtilizationRates)
  2. 如果利用率 > SM_LIMIT → 在 cuLaunchKernel 前 sleep 等待
  3. 通过文件锁 (/tmp/vgpulock/) 进行进程间协调
```

**缺点**：
- 依赖 NVML 采样，有滞后性
- sleep-based 限流会导致 GPU 空闲浪费
- 文件锁协调粗粒度

### 4.2 XPUShare 的算力限制

XPUShare 使用 **Scheduler 集中调度 + Adaptive Kernel Window** 的方式：

```
Scheduler 守护进程:
  1. 中心化管理所有客户端的时间片
  2. 基于显存压力动态选择并行/串行模式
  3. 客户端在 cuLaunchKernel 中执行 Lock 检查

客户端 hook.c:
  1. cuLaunchKernel → continue_with_lock() 等待调度器授权
  2. AIMD 算法动态调整 pending_kernel_window
  3. 周期性 cuCtxSynchronize 刷新 pipeline
```

**优点**：
- 中心化调度消除锁竞争
- AIMD 自适应窗口避免过量提交
- Kernel-level 粒度控制

---

## 5. 设计权衡总结

```
                     HAMi-core                XPUShare
                    ┌─────────┐             ┌─────────┐
 API Surface        │  巨大    │             │  极小    │
                    └────┬────┘             └────┬────┘
                         │                       │
 兼容性              更广（不依赖 UVM）       需 Pascal+ GPU
 维护成本            高（需跟进所有 CUDA 新 API）  低
 显存隔离精度        精确到字节               依赖 UVM 页面粒度
 CUDA 版本兼容性     需要持续更新 hook 列表     稳定
 性能开销            每个 API 调用都有额外开销   仅关键路径有开销
 显存超卖能力        不能超卖物理显存          天然支持（UVM）
 特殊 API 支持       Graph、Pool、IPC 均支持    不支持
```

### 核心结论

> **HAMi-core 劫持 150+ API 是因为它选择了"软件虚拟化显存"的路径**——不修改内存分配语义，必须在每一个可能分配、释放、查询显存的入口做拦截和记账。
>
> **XPUShare 只劫持 ~16 个 API 是因为它选择了"Unified Memory"的路径**——通过硬件级的 Page Fault + 自动换页机制，将显存管理卸载给了 NVIDIA 驱动和硬件，因此只需在关键控制点（Kernel Launch、Memory Alloc/Free）做拦截。

这是一个经典的 **完备性 vs 简洁性** 的架构权衡：
- HAMi-core 追求的是"任何 CUDA 应用都能正确限制"的**完备性**
- XPUShare 追求的是"用最少的侵入实现最核心的共享"的**简洁性**
