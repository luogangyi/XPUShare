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

---

## 附录A：Review结果（2026-02-17）

> 本附录为对上文初步分析的复核结论与补充实现建议；不改动正文原有论述，仅新增评审内容。

### A.1 评审结论总览

1. 方向总体正确：CANN 确实具备与 UVM 同类的 SVM 基础能力，可支撑“显存超分/迁移”的技术路线。  
2. 需要修正的关键点：
   - `hdcdrv_core.c` 中的 fault 回调不能作为 SVM fault 正向证据；该处日志明确是 `hdc mmap not supported page fault`。  
   - `aclrt*` 接口不在当前开源 `driver` 仓中，`aclrtMalloc -> 强制 SVM` 目前属于待验证假设。  
   - 当前开源仓里 SVM 的 cgroup wrapper 是 stub/no-op，不应直接假设可用。  
3. 推荐落地方式：先做“可交付”的配额/动态配额/metrics，再推进透明 SVM 与 token 硬配额。

### A.2 已证实能力（代码证据）

1. SVM 标志与分配能力
- `BUFF_SP_SVM`：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_external.h:86`
- `halMemAlloc(void **pp, size, flag)`：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2459`

2. SVM 迁移与策略接口
- `drvMemPrefetchToDevice`（注释明确 SVM 场景）：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2165`
- `halMemAdvise`：`/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2482`

3. 真正 SVM fault 路径
- `devmm_svm_vm_fault_host` / `devmm_svm_vmf_fault_host`：
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_vma_ops.c:192`
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_vma_ops.c:218`
- fault 处理中包含 host<->device 同步与 remap：
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_vma_ops.c:130`
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/pmaster/svm_master_pm_proc_mng.c:248`

4. 设备信息/内存信息/虚拟化接口
- `halMemGetInfo` + `MemPhyInfo(total/free/huge/giant)`：
  - `/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2821`
  - `/Users/luogangyi/Code/cann/driver/pkg_inc/ascend_hal_base.h:2900`
  - `/Users/luogangyi/Code/cann/driver/src/ascend_hal/svm/v2/devmm/devmm_svm.c:2282`
- DSMI/DCMI 主命令包含 `QOS/SVM`：
  - `/Users/luogangyi/Code/cann/driver/pkg_inc/dsmi_common_interface.h:1124`
  - `/Users/luogangyi/Code/cann/driver/src/custom/include/dcmi_interface_api.h:356`
- vDevice 创建/销毁：
  - `/Users/luogangyi/Code/cann/driver/pkg_inc/dsmi_common_interface.h:3328`
  - `/Users/luogangyi/Code/cann/driver/pkg_inc/dsmi_common_interface.h:3342`

5. cgroup 统计查询能力
- `dsmi_get_device_cgroup_info`：`/Users/luogangyi/Code/cann/driver/pkg_inc/dsmi_common_interface.h:3227`
- `tag_cgroup_info(limit/max_usage/usage)`：`/Users/luogangyi/Code/cann/driver/pkg_inc/dsmi_common_interface.h:360`

### A.3 需修正/待验证项

1. 需修正
- `hdc mmap` fault 分支不是 SVM fault 能力证据：
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/hdc/pcie/common/hdcdrv_core.c:6396`

2. 待验证（关键）
- ACL Runtime 可否稳定拦截、可否透传 SVM flag。  
- EX_COMPUTING token 的“设置”路径在目标环境是否可用（开源仓仅确认查询与通道定义）。

3. 当前开源仓现实约束
- `svm_master_cgroup.c` 中 `devmm_enable_cgroup/devmm_disable_cgroup` 为空实现：
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_cgroup.c:20`
  - `/Users/luogangyi/Code/cann/driver/src/sdk_driver/svm/v2/master/comm/svm_master_cgroup.c:25`

### A.4 对本项目（XPUShare）的补充实现建议

1. 第一阶段（优先可交付）
- 先实现 NPU 版：
  - 显存配额（静态/动态）
  - 算力配额（软件时间片）
  - metrics（设备层 + client层 + scheduler层）
- 不把透明 SVM 作为第一阶段阻塞项。

2. 第二阶段（SVM 超分）
- 增加模式开关：
  - `native`
  - `svm_coop`（协作模式）
  - `svm_transparent`（透明模式，需额外验证）
- 先在 `svm_coop` 灰度，观察 fault 频率与吞吐退化。

3. 第三阶段（硬件 token）
- 在 capability probe 证实可 `set/get` token 后再开启。  
- 与软件时间片并行：token 做硬上限，时间片做公平性调节。

### A.5 建议新增的 capability probe（落地前必须完成）

建议输出 `cann_capability_matrix.json`，至少包括：
- `svm_alloc_enforceable`
- `token_set_available`
- `dynamic_update_latency_ms`
- `resident_metric_available`

最小探测动作：
1. HAL 层 SVM alloc + prefetch + advise 调用回归。  
2. DCMI/DSMI `EX_COMPUTING_SUB_CMD_TOKEN` 的 set/get 回环（若 set 不可用，明确降级策略）。  
3. 大工作集压测，记录 fault 频率、吞吐退化、P99 延迟。  
4. 指标口径校验：`allocated` vs `resident_estimated` vs `quota`。

### A.6 建议的指标口径（避免“真实驻留”争议）

1. 设备层
- `xpushare_npu_device_memory_total_bytes`
- `xpushare_npu_device_memory_free_bytes`
- `xpushare_npu_device_utilization_ratio`

2. 进程层
- `xpushare_npu_client_memory_allocated_bytes`（分配追踪）
- `xpushare_npu_client_memory_quota_bytes`
- `xpushare_npu_client_memory_resident_estimated_bytes`（估算口径，需标注）
- `xpushare_npu_client_core_quota_percent`

3. 调度层
- `xpushare_npu_scheduler_running_clients`
- `xpushare_npu_scheduler_wait_queue_clients`
- `xpushare_npu_scheduler_update_latency_ms`

## 附录B：基于 runtime 源码的补充复核（2026-02-17）

> 本附录在附录A基础上，结合你新增的 `runtime` 源码做进一步修正。仍然只追加，不改正文与附录A内容。

### B.1 结论修正（相对附录A）

1. **“ACL runtime 不在开源仓”这一点需要修正**  
现在可在 `/Users/luogangyi/Code/cann/runtime` 直接看到 ACL runtime 实现：
- `aclrtMalloc*`：`/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:252`
- `aclrtGetMemInfo`：`/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:786`
- `aclrtLaunchKernel*`：`/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/kernel.cpp:114`

2. **ACL 劫持路径现在可直接落源码级证据**  
`aclrt*` 接口在 `acl_rt_wrapper.h` 中有完整映射：  
`/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/acl_rt_wrapper.h:71`

3. **UVM 类能力不是“纯推测”，但仍需性能侧实测**  
SVM/managed memory、prefetch、advise、page-fault 计数链路都能在 runtime+driver 代码中对上（见 B.2）。

### B.2 基于 runtime 的关键证据

1. **设备内存分配调用链（ACL -> RT -> Driver）**
- `aclrtMallocImpl` -> `aclMallocMemInner` -> `rtMalloc`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:252`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:172`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:210`
- `aclrtMallocWithCfgImpl` -> `aclrtMallocInnerWithCfg` -> `rtsMalloc`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:301`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:219`  
  `/Users/luogangyi/Code/cann/runtime/src/acl/aclrt_impl/memory.cpp:241`

2. **SVM/managed memory 与迁移相关能力**
- managed 分配落到 `MEM_SVM_HUGE/MEM_SVM_NORMAL`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:800`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:805`
- `rtMemPrefetchToDevice` 全链路存在  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c.cc:1025`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:3198`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:658`
- `rtMemAdvise` 全链路存在（标准 SoC 路径）  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c_standard_soc.cc:891`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:2649`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:715`
- 指针属性可区分 managed 与“真实位置(host/device)”  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:1994`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:2037`

3. **page fault 观测链路**
- 驱动侧页错误计数读取：`STATUS_SVM_PAGE_FALUT_ERR_CNT`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver.cc:1446`
- runtime 里有周期检测和阈值告警（100次/2s）  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/runtime.cc:71`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/runtime.cc:5926`

4. **VMM（VA 保留 + 物理句柄 + 映射）链路**
- ACL 对外接口：`aclrtReserveMemAddress/aclrtMallocPhysical/aclrtMapMem`  
  `/Users/luogangyi/Code/cann/runtime/include/external/acl/acl_rt.h:2114`  
  `/Users/luogangyi/Code/cann/runtime/include/external/acl/acl_rt.h:2149`  
  `/Users/luogangyi/Code/cann/runtime/include/external/acl/acl_rt.h:2183`
- runtime 实现直接走 `halMemAddressReserve/halMemCreate/halMemMap`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:281`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:317`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:370`

### B.3 对现有方案的新增约束与风险

1. **`rtMallocConfig` 的 `VA_FLAG` 在设备内存路径中并未生效**
- `ApiImpl::ParseMallocCfg` 只接受 `MODULE_ID/DEVICE_ID`，不接受 `VA_FLAG`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:7965`
- `vaFlag` 当前只在 `HostMallocWithCfg` 路径被处理  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:2422`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:738`

2. **`rtGetMemUsageInfo` 是“模块维度”，不是“进程真实驻留维度”**
- 注释明确：仅统计 `halMemAlloc/halMemCreate` 申请的内存  
  `/Users/luogangyi/Code/cann/runtime/include/driver/ascend_hal_base.h:2939`

3. **`rtMemGetInfoEx` 存在信息映射行为，HBM/DDR口径需谨慎**
- `memInfoMapType` 会触发类型映射（如 HBM -> DDR）  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:1624`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/drv/npu_driver_mem.cc:1897`

4. **部分构建形态下 `rtMemAdvise` 可能是 no-op**
- tiny stub 版本直接返回成功  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api/api_c_tiny_stub.cc:56`

### B.4 对 XPUShare-NPU 落地方案的进一步补强

1. **显存超分路线**
- 主路径：`aclrtMallocWithCfg/aclrtMalloc` 拦截 + managed/SVM 分配追踪。  
- 观测补强：增加 page-fault 指标采集（驱动计数）用于判定“超分是否引发抖动”。

2. **显存配额路线**
- 继续采用 scheduler 级配额为主（因为 runtime/driver 无通用“进程驻留字节”接口）。  
- 运行态指标至少拆成：
  - `allocated_bytes`（拦截分配累加）
  - `driver_module_usage_bytes`（`rtGetMemUsageInfo`）
  - `quota_bytes`
  - `svm_page_fault_count`

3. **算力配额路线**
- ACL/RT 已有 `Device/Stream ResLimit`（cube/vector core）：  
  `/Users/luogangyi/Code/cann/runtime/include/external/acl/acl_rt.h:3447`
- 但其执行时机/生效粒度更偏运行时资源配置，建议仍保留你现有 scheduler 软件时间片作为主控，`ResLimit` 作为可选硬上限能力。

4. **动态调整**
- `SetDeviceResLimit/SetStreamResLimit` 支持运行时更新：  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:7554`  
  `/Users/luogangyi/Code/cann/runtime/src/runtime/feature/src/api_impl/api_impl.cc:7629`
- 建议新增回归用例验证“更新后新任务与长任务”的差异行为。

5. **建议补充的 capability probe（新增）**
- `support_managed_svm`
- `support_mem_prefetch_to_device`
- `support_mem_advise_effective`
- `support_host_uva_flag`
- `support_vmm_reserve_map`
- `support_page_fault_counter`
- `support_device_stream_res_limit`

### B.5 仍需你补充的代码（才能把 review 再收敛一轮）

1. **框架接入层代码**
- `torch_npu`/MindSpore 里实际调用 ACL 的入口（确认是否有绕过 `aclrt*` 的路径）。

2. **你当前项目里的 NPU 适配实现**
- 计划拦截库（或适配层）代码路径：包含 `dlsym`/hook 初始化、分配追踪、quota 判定逻辑。

3. **部署注入链路**
- K8s 注入方式（`LD_PRELOAD`、sidecar、容器启动脚本）与实际生效日志。

4. **你提到的 token 配额实现代码**
- 若已经有 `EX_COMPUTING` 相关 set/get 封装，请给出路径，便于确认“查询可用但设置不可用”的问题是否已解决。
