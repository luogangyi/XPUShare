# CANN 驱动分析：NPU 虚拟化可行性与 XPUShare 适配方案

> 基于 `/Users/luogangyi/Code/cann/driver` 源码分析

## 1. 核心结论

| 特性 | NVIDIA CUDA (GPU) | CANN (NPU) | 可行性 |
|:---|:---|:---|:---|
| **Unified Memory / SVM** | ✅ `cudaMallocManaged` | ✅ `halMemAlloc(BUFF_SP_SVM)` + Page Fault | **可行** |
| **内存显/隐式迁移** | ✅ Page Fault + Prefetch | ✅ `drvMemPrefetchToDevice` + SVM Fault Handler | **可行** |
| **API 劫持 (LD_PRELOAD)** | ✅ CUDA Driver API (libcuda.so) | ⚠️ ACL Runtime (libascendcl.so) | **需分层劫持** |
| **Kernel Launch 拦截** | ✅ `cuLaunchKernel` | ⚠️ `aclrtLaunchKernel` 或 Queue 提交 | **可行但机制不同** |
| **内存查询虚拟化** | ✅ `cuMemGetInfo` | ✅ `halMemGetInfo` / DSMI | **可行** |
| **利用率监控** | ✅ NVML | ✅ DSMI (`dsmi_get_device_info`) | **可行** |
| **设备虚拟化** | ✅ MIG / MPS | ✅ vascend (vNPU / SR-IOV) | **已有硬件能力** |

**结论：CANN 的 SVM 机制与 NVIDIA 的 Unified Memory 在架构上高度对应，XPUShare 的核心思路（SVM + 调度器时间片）在 NPU 上技术可行。**

---

## 2. CANN 驱动架构

根据 `driver/README.md`，CANN 驱动分三层：

```
┌─────────────────────────────────────────────────────┐
│  CANN Runtime (libascendcl.so)                      │  ← 用户态 API 层（不在此仓库）
│  aclrtMalloc / aclrtLaunchKernel / aclrtMemcpy      │
├─────────────────────────────────────────────────────┤
│  DCMI  (dsmi_common_interface.h)                    │  ← 设备管理接口
│  dsmi_get_device_info / dsmi_set_device_info        │
├─────────────────────────────────────────────────────┤
│  HAL   (ascend_hal_base.h)                          │  ← 硬件抽象层（本仓代码）
│  halMemAlloc / halMemFree / halMemAdvise            │
│  halMemcpy / halMemGetInfo / halMemAgentOpen        │
│  halMemAddressReserve / halMemMap / halMemCreate     │
├─────────────────────────────────────────────────────┤
│  SDK-Driver  (内核模块)                             │  ← 内核驱动
│  svm/ trs/ esched/ queue/ vascend/ vmng/            │
└─────────────────────────────────────────────────────┘
```

### 关键子系统

| 子系统 | 路径 | 功能 |
|:---|:---|:---|
| **SVM** | `src/ascend_hal/svm/` | 共享虚拟内存，Page Fault 处理，内存统计 |
| **TRS** | `src/ascend_hal/trs/` | 任务资源调度 (Task Resource Schedule) |
| **esched** | `src/ascend_hal/esched/` | 事件调度 (Event Schedule) |
| **queue** | `src/ascend_hal/queue/` | 消息队列管理 |
| **vascend** | `src/sdk_driver/vascend/` | NPU 算力切分 (SR-IOV / vNPU) |
| **vmng** | `src/sdk_driver/vmng/` | 设备虚拟化管理 |
| **DSMI** | `src/ascend_hal/dmc/dsmi/` | 设备系统管理接口（类似 NVML）|

---

## 3. SVM 与 UVM 的对应关系

CANN 的 **SVM (Shared Virtual Memory)** 是 NVIDIA **UVM (Unified Virtual Memory)** 的对等实现。

### 3.1 内存分配

**NVIDIA CUDA：**
```c
// 分配统一内存，Host 和 Device 使用同一虚拟地址
cuMemAllocManaged(&ptr, size, CU_MEM_ATTACH_GLOBAL);
```

**CANN HAL：**
```c
// 分配 SVM 内存，通过 flag 指定 SVM 模式
// flag 中包含 BUFF_SP_SVM (1 << 3) 标志
halMemAlloc(&ptr, size, flag);  // flag 包含设备 ID、内存类型、SVM 标志
```

在 `ascend_hal_external.h:89`：
```c
#define BUFF_SP_SVM (1 << 3)   // SVM 共享虚拟内存标志
```

在 `drv_buff_memzone.c:1081`：
```c
if ((flag & BUFF_SP_SVM) == BUFF_SP_SVM) {
    // SVM 模式分配路径
    info->flag = (uint64)(info->flag & (uint64)(~BUFF_SP_SVM));
}
```

### 3.2 Page Fault 处理

**NVIDIA：** GPU MMU 产生缺页中断 → UVM 驱动处理 → 迁移页面到 GPU/CPU

**CANN：** NPU 访问未映射的 SVM 地址 → 驱动 Page Fault Handler 处理 → 迁移页面

在 `hdcdrv_core.c`：
```c
STATIC ka_vm_fault_t hdcdrv_svm_vmf_fault_host(ka_vm_fault_struct_t *vmf)
// SVM 缺页异常处理函数

STATIC void hdcdrv_svm_mmap_init_vm_struct(ka_vm_operations_struct_t *ops_managed)
// 注册 SVM mmap 操作，包括 fault 处理
```

### 3.3 数据预取

**NVIDIA：** `cuMemPrefetchAsync(ptr, size, device)`

**CANN：** `drvMemPrefetchToDevice(dev_ptr, len, device)` ([ascend_hal_base.h:2182](file:///Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h#L2165-L2182))

文档说明：
> "First apply for svm memory, then fill the data, and then prefetch to the target device side."

### 3.4 内存 Advise（提示/策略）

**NVIDIA：** `cuMemAdvise(ptr, count, advice, device)`

**CANN：** `halMemAdvise(ptr, count, type, device)` ([ascend_hal_base.h:2482](file:///Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h#L2471-L2482))

### 3.5 API 对应表

| NVIDIA CUDA | CANN HAL | 说明 |
|:---|:---|:---|
| `cuMemAllocManaged` | `halMemAlloc(flag\|BUFF_SP_SVM)` | SVM 内存分配 |
| `cuMemFree` | `halMemFree` | 内存释放 |
| `cuMemAdvise` | `halMemAdvise` | 内存使用提示 |
| `cuMemPrefetchAsync` | `drvMemPrefetchToDevice` | 数据预取到设备 |
| `cuMemGetInfo` | `halMemGetInfo` | 内存使用查询 |
| `cuMemcpy*` | `halMemcpy` / `halSdmaCopy` | 数据拷贝 |
| `cuMemAddressReserve` | `halMemAddressReserve` | 虚拟地址预留 |
| `cuMemCreate` | `halMemCreate` | 物理内存分配 |
| `cuMemMap` | `halMemMap` | 虚拟地址映射 |
| `cuMemRelease` | `halMemRelease` | 物理内存释放 |
| `cuMemSetAccess` | `halMemSetAccess` | 跨设备访问权限 |
| `cuIpcGetMemHandle` | `halShmemCreateHandle` | 进程间共享 |
| `cuIpcOpenMemHandle` | `halShmemOpenHandle` | 打开共享内存 |
| `cuMemGetAddressRange` | `halMemGetAddressRange` | 查询地址范围 |
| `cuMemAgentOpen` | `halMemAgentOpen` | 内存管理初始化 |

---

## 4. XPUShare 各功能模块的 NPU 适配方案

### 4.1 内存管理 → SVM 替代 UVM

**XPUShare CUDA 实现：**
```c
// hook.c: 劫持 cuMemAlloc → cuMemAllocManaged
CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
    result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
    insert_cuda_allocation(*dptr, bytesize);
    return result;
}
```

**NPU 适配方案：**

CANN 的用户态入口是 **ACL Runtime** (`libascendcl.so`)，而非 HAL 层。需要劫持的是：

```c
// 劫持 aclrtMalloc → 强制使用 SVM 模式分配
aclError aclrtMalloc(void **devPtr, size_t size, aclrtMemMallocPolicy policy) {
    // 原始调用: 分配设备专用 HBM 内存
    // 替换为: 分配 SVM 共享内存（类似 cudaMallocManaged）
    aclError ret = real_aclrtMalloc_with_svm_flag(devPtr, size, policy);
    insert_npu_allocation(*devPtr, size);
    return ret;
}
```

> [!IMPORTANT]
> CANN ACL Runtime 的 `aclrtMalloc` 底层调用 `halMemAlloc`。需要验证是否可以通过设置环境变量或 `halMemAlloc` 的 `flag` 参数强制走 SVM 路径，而不需要修改 ACL Runtime 层。

### 4.2 Kernel Launch 拦截 → Queue 任务提交拦截

**XPUShare CUDA 实现：**
```c
// hook.c: 在 cuLaunchKernel 中做调度检查
CUresult cuLaunchKernel(...) {
    continue_with_lock(lock);  // 等待调度器授权
    result = REAL(cuLaunchKernel)(...);
    maybe_sync(lock);          // AIMD 窗口控制
    return result;
}
```

**NPU 差异：** CANN 的计算模型与 CUDA 不同。CUDA 使用 `cuLaunchKernel` 直接提交 Grid/Block 的 Kernel；CANN 使用 **Queue-based Task Submission**：

```
CUDA:  cuLaunchKernel(function, gridDim, blockDim, args, ...)
CANN:  aclrtLaunchKernel(opType, ...) 或 Queue 提交 Task
       → 底层通过 HAL Queue API → TS (Task Scheduler) → NPU Cluster
```

**NPU 适配方案：**

```c
// 劫持 aclrtLaunchKernel 或任务提交入口
aclError aclrtLaunchKernel(...) {
    continue_with_lock(lock);      // 等待调度器授权
    aclError ret = real_aclrtLaunchKernel(...);
    maybe_sync(lock);              // 窗口控制
    return ret;
}
```

> [!NOTE]
> CANN 的任务提交可能有多个入口（单算子模式、Graph 模式、aclrtLaunchKernel），需要识别并劫持所有关键入口。

### 4.3 内存查询 → halMemGetInfo / DSMI

**XPUShare CUDA 实现：**
```c
CUresult cuMemGetInfo(size_t *free, size_t *total) {
    *total = gpu_mem_total - reserved;
    *free = *total - currently_allocated;
}
```

**NPU 适配方案：**

```c
// 劫持 aclrtGetMemInfo
aclError aclrtGetMemInfo(aclrtMemAttr attr, size_t *free, size_t *total) {
    // 返回配额化后的值
    real_aclrtGetMemInfo(attr, free, total);
    *total = min(*total, memory_quota);
    *free = *total - currently_allocated;
}
```

底层可使用：
- `halMemGetInfo(device, type, &info)` → 获取 `MemPhyInfo` 结构体（`total`, `free`, `huge_total`, `huge_free`）
- `dsmi_get_device_info(devid, DSMI_MAIN_CMD_MEMORY, sub_cmd, ...)` → DSMI 监控接口

### 4.4 利用率监控 → DSMI 替代 NVML

**XPUShare CUDA 实现：**
```c
// scheduler.c: 使用 NVML 读取利用率
nvmlDeviceGetUtilizationRates(device, &utilization);
```

**NPU 适配方案：**

DSMI 提供了与 NVML 对等的监控能力：

```c
// DSMI 监控接口
dsmi_get_device_info(device_id, DSMI_MAIN_CMD_MEMORY, sub_cmd, buf, &buf_size);
dsmi_get_device_info(device_id, DSMI_MAIN_CMD_QOS, sub_cmd, buf, &buf_size);

// DSMI_AICPU_INFO 结构体包含：
// - utilRate[TAISHAN_CORE_NUM]: AI Core 利用率数组
// - curFreq: 当前频率
// - aicpuNum: AI CPU 数量
```

> [!NOTE]
> DSMI 包含 `DSMI_MAIN_CMD_SVM`（SVM 子命令）和 `DSMI_MAIN_CMD_QOS`（QoS 子命令），可用于精确的算力和内存监控。

### 4.5 计算配额控制 → Computing Token / vNPU

CANN 驱动已有**原生**的算力配额机制：

1. **Computing Token** (`ascend_hal_base.h`):
   ```c
   struct computing_token {
       float value;          // Token 值（算力配额）
       unsigned char type;   // Token 类型
   };
   #define COMPUTING_POWER_MAX_VALUE 65535
   #define COMPUTING_POWER_MIN_VALUE 0
   ```

2. **vascend (vNPU)**: 基于 SR-IOV 的硬件级 NPU 虚拟化
   - `vdavinci.c`: VF (Virtual Function) 分配和管理
   - 支持按 `aicore_num`, `mem_size`, `aicpu_num` 切分 NPU 资源
   ```c
   struct vdavinci_type {
       aicore_num;   // AI Core 数量
       mem_size;     // 内存大小
       aicpu_num;    // AI CPU 数量
       vpc_num;      // VPC 数量
   };
   ```

3. **TRS (Task Resource Schedule)**: 任务资源调度
   - 在驱动层实现了任务级别的资源调度

**XPUShare 可以选择两种策略：**

| 策略 | 描述 | 优劣 |
|:---|:---|:---|
| **策略 A：软件时间片** | 复用 XPUShare 现有的 Scheduler + Lock + AIMD 机制 | 灵活，但依赖 ACL API 劫持 |
| **策略 B：原生 Token** | 利用 CANN 的 Computing Token 直接设置算力上限 | 简单，但可能不够灵活 |

建议 **A + B 结合**：用 Computing Token 设置硬上限，用 Scheduler 做软调度。

---

## 5. API 劫持层的差异

### 5.1 CUDA 的劫持路径

```
应用程序 → libcuda.so (CUDA Driver API) → 内核驱动
        ↑
    LD_PRELOAD libnvshare.so 劫持
```

XPUShare 劫持的是 **CUDA Driver API** (`libcuda.so`)，这是一个**稳定且单一**的劫持层。

### 5.2 CANN 的劫持路径

```
应用程序 → libascendcl.so (ACL Runtime) → HAL (ascend_hal.so) → 内核驱动
        ↑                                ↑
    方案 A: 劫持 ACL           方案 B: 劫持 HAL
```

| 方案 | 劫持目标 | 优势 | 风险 |
|:---|:---|:---|:---|
| **方案 A** | `libascendcl.so` (ACL Runtime) | 层级高、API 稳定、文档完善 | 可能有 PyTorch/Mindspore 通过其他路径绕过 |
| **方案 B** | `ascend_hal.so` (HAL 层) | 接近底层、覆盖全面 | API 可能随驱动版本变化 |

> [!IMPORTANT]
> **建议选择方案 A**（劫持 ACL Runtime），原因：
> 1. 华为官方公开文档覆盖 ACL API，稳定性有保证
> 2. 所有上层框架（PyTorch Ascend、MindSpore）都通过 ACL 调用 NPU
> 3. 与 XPUShare 劫持 CUDA Driver API 的设计保持一致

### 5.3 CANN ACL 需要劫持的 API

参考 XPUShare 在 CUDA 中劫持的 API，对应 CANN ACL：

| XPUShare (CUDA) | 对应 CANN ACL API | 作用 |
|:---|:---|:---|
| `cuInit` | `aclInit` | 初始化，触发 XPUShare 启动 |
| `cuMemAlloc` | `aclrtMalloc` | **核心**：替换为 SVM 分配 |
| `cuMemFree` | `aclrtFree` | 追踪内存释放 |
| `cuMemGetInfo` | `aclrtGetMemInfo` | 返回配额化数值 |
| `cuLaunchKernel` | `aclrtLaunchKernel` / `aclopExecuteV2` | **核心**：调度检查 |
| `cuMemcpy*` | `aclrtMemcpy` / `aclrtMemcpyAsync` | 数据传输控制 |
| `cuGetProcAddress` | (ACL 不使用此模式) | 不需要 |
| `dlsym` | `dlsym` | 入口劫持（同 CUDA 方案）|

**总计约 ~10 个 API**，与 XPUShare 当前的 ~16 个相当。

---

## 6. 实现路线图

### Phase 1: 验证 SVM 可行性
- [ ] 在 Ascend 910B 上验证 `halMemAlloc(BUFF_SP_SVM)` 的行为
- [ ] 测试 SVM 内存超过 HBM 物理容量时的 Page Fault 行为
- [ ] 测量 SVM vs 原生 HBM 的性能差异

### Phase 2: ACL API 劫持原型
- [ ] 实现 `libxpushare_npu.so`，劫持 `aclrtMalloc` → SVM 模式
- [ ] 劫持 `aclrtLaunchKernel` / `aclopExecuteV2` 做调度检查
- [ ] 验证 PyTorch Ascend 训练任务是否正常工作

### Phase 3: 调度器适配
- [ ] Scheduler 添加 NPU 设备支持（DSMI 替代 NVML）
- [ ] 适配 Queue-based 任务模型的 AIMD 窗口控制
- [ ] 实现 Computing Token 硬限制 + 软调度结合

### Phase 4: Kubernetes 集成
- [ ] NPU Device Plugin（`xpushare.com/npu`）
- [ ] DaemonSet 部署 scheduler + `libxpushare_npu.so`
- [ ] 与现有 GPU 共享功能共存

---

## 7. 风险与挑战

### 7.1 SVM Page Fault 性能

> [!WARNING]
> CANN 的 SVM Page Fault 行为可能与 NVIDIA UVM 不同。NVIDIA UVM 经过多年优化（Pascal/Volta/Ampere），支持 ATS (Address Translation Services)、HMM 集成等。CANN 的 SVM 实现成熟度需要实测验证。

具体风险：
- NPU 的 Page Fault 延迟可能高于 GPU
- SVM 在跨 HCCS（NPU 间互联）场景下的行为未知
- HBM → DDR 的页面迁移可能与 NVIDIA 的 GPU_mem → System_RAM 机制不对等

### 7.2 ACL API 稳定性

- CANN 版本迭代较快（当前 8.x），API 可能变化
- 部分 API 可能不支持 `LD_PRELOAD` 劫持（如静态链接场景）
- MindSpore 可能有直接调用 HAL 的路径

### 7.3 多框架兼容

- PyTorch Ascend (torch_npu) 通过 ACL 调用
- MindSpore 可能有混合调用路径
- ONNX Runtime Ascend EP 需要验证

### 7.4 vNPU 与软件虚拟化的冲突

- 如果用户已使用 vascend (vNPU) 切分，XPUShare 的 SVM 策略可能与硬件虚拟化冲突
- 需要检测是否运行在 vNPU 环境中并适配

---

## 8. 总结

CANN 驱动提供了实现 XPUShare NPU 版本所需的**全部底层能力**：

| XPUShare 核心机制 | CANN 对等能力 | 成熟度 |
|:---|:---|:---|
| Unified Memory (显存超卖) | SVM + Page Fault | ✅ 完整实现 |
| Kernel Launch 拦截 | ACL Runtime API 劫持 | ⚠️ 需验证 |
| 利用率监控 | DSMI | ✅ 完整 |
| 计算配额 | Computing Token + Scheduler | ✅ 原生支持 |
| 设备虚拟化 | vascend (SR-IOV) | ✅ 硬件支持 |

**最关键的技术验证点**是 SVM 在内存超卖场景下的 Page Fault 性能。如果 CANN 的 SVM 能提供与 NVIDIA UVM 相近的性能，则 XPUShare 的核心架构可以几乎原样迁移到 NPU 平台。
