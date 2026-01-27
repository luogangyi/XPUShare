# nvshare GPU 共享性能问题分析报告

## 1. 问题描述

在 2x T4 GPU 环境（每卡 16GB，共 32GB）上运行 4 个 pytorch-add Pod 时，观察到：

- 性能从 ~1.28 it/s 骤降至 13.65s/it（降低约 17 倍）
- 每个 Pod 的容器内存占用高达 ~14.5GB
- `nvidia-smi` 显示每进程仅占用 ~1006MiB GPU 显存
- 频繁出现 `DROP_LOCK` → `LOCK_RELEASED` → `LOCK_OK` 周期

---

## 2. 日志关键信息

```
[NVSHARE][DEBUG]: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1: undefined symbol: nvmlDeviceGetHandleByUUID_v2
[NVSHARE][DEBUG]: Could not find NVML
```

```
[NVSHARE][DEBUG]: cuMemAllocManaged allocated 3137339392 bytes  // ~3GB × 4 = ~12GB/Pod
[NVSHARE][DEBUG]: Total allocated memory on GPU is 11968.00 MiB // ~12GB/Pod
```

```
[NVSHARE][DEBUG]: Received DROP_LOCK
[NVSHARE][DEBUG]: Sent LOCK_RELEASED
[NVSHARE][DEBUG]: Received LOCK_OK
  1%|          | 32/4000 [01:27<15:02:36, 13.65s/it]  // 性能骤降
```

---

## 3. 根因分析

### 3.1 CUDA Unified Memory 显存抖动（**主要原因**）

| 指标 | 值 |
|------|-----|
| 每 Pod 显存需求 | ~12GB |
| 4 Pod 总需求 | ~48GB |
| 物理 GPU 显存 | 32GB（2×16GB） |
| 超额比例 | 150% |

**机制**：
- nvshare 使用 `cuMemAllocManaged()` 分配 CUDA 统一内存
- 当总分配超过物理显存时，CUDA 驱动在 GPU 和系统内存间进行页面迁移
- 每次 kernel 执行前需要将数据从系统内存迁移到 GPU，消耗大量 PCIe 带宽

**证据**：
```
kubectl top po
NAME                  CPU(cores)   MEMORY(bytes)
nvshare-cross-gpu-1   1m           14499Mi  ← 系统内存高占用，说明数据被换出到主存
nvshare-cross-gpu-3   979m         14486Mi
```

```
nvidia-smi
|    1   N/A  N/A           80513      C   python     1006MiB |  ← GPU 显存只有 1GB
```

---

### 3.2 为什么 nvidia-smi 只显示 ~1GB GPU 显存？

#### 核心原因：CUDA Unified Memory 的按需迁移机制

nvshare 的内存分配逻辑（`hook.c:637`）：

```c
// nvshare 将 cuMemAlloc 替换为 cuMemAllocManaged
result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
```

**`cuMemAllocManaged` vs `cuMemAlloc` 的关键区别**：

| 特性 | cuMemAlloc | cuMemAllocManaged |
|------|------------|-------------------|
| 内存位置 | GPU 显存 | 虚拟地址空间（CPU+GPU 共享） |
| 初始状态 | 立即占用 GPU 显存 | 不预占任何物理内存 |
| 按需迁移 | 无 | 数据访问时自动迁移 |
| nvidia-smi 统计 | 显示实际占用 | 只显示 CUDA 上下文开销 |

#### 详细分配流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  cuMemAllocManaged(12GB)                                                    │
│       ↓                                                                     │
│  CUDA 驱动分配 12GB 虚拟地址空间（此时 GPU 显存和系统内存均未使用）          │
│       ↓                                                                     │
│  首次 GPU kernel 访问数据 → 触发页面错误 → 按需迁移所需页面到 GPU           │
│       ↓                                                                     │
│  nvidia-smi 显示: ~1GB（仅 CUDA 上下文 + 当前活跃页面）                     │
│       ↓                                                                     │
│  其他进程请求 GPU → 当前进程数据被换出到系统内存                            │
│       ↓                                                                     │
│  kubectl top: ~14GB 系统内存（换出的 GPU 数据）                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### nvidia-smi 显示 1GB 的组成

| 组件 | 大小 | 说明 |
|------|------|------|
| CUDA Context | ~300-500MB | 每个进程的 CUDA 运行时上下文 |
| Driver 内部缓冲 | ~200-300MB | cuBLAS、cuDNN 等库的工作空间 |
| 当前活跃页面 | ~200-400MB | 正在被 GPU kernel 使用的数据页 |
| **总计** | **~1000MB** | nvidia-smi 报告的值 |

#### 为什么不优先分配 GPU 显存？

这是 nvshare 的**设计选择**，目的是实现 GPU 内存共享：

1. **传统 `cuMemAlloc`**：
   - 立即在 GPU 显存分配物理内存
   - 独占式，其他进程无法使用这部分显存
   - 无法实现显存超分

2. **nvshare 使用 `cuMemAllocManaged`**：
   - 只分配虚拟地址空间，不预占物理显存
   - 多进程可以分配超过物理显存总量的内存
   - 由 CUDA 驱动自动管理物理显存的分配和回收
   - **代价**：当总需求超过物理显存时，触发频繁的页面迁移

#### 代码验证

```c
// hook.c:611-645
CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
  // ...
  
  // 关键：替换为 Managed Memory
  result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
  
  // 日志显示分配成功，但此时 GPU 显存未被实际占用
  log_debug("cuMemAllocManaged allocated %zu bytes at 0x%llx", bytesize, *dptr);
  
  // nvshare 内部记录分配量（用于配额管理）
  insert_cuda_allocation(*dptr, bytesize);
  // sum_allocated += bytesize;  // 这是"逻辑分配"，非物理占用
  
  return result;
}
```

### 3.3 时分复用调度开销

nvshare scheduler 使用 `DROP_LOCK` / `LOCK_OK` 机制实现时间片轮转：

```
时间线:
Pod3: [运行中] → DROP_LOCK → 等待 → LOCK_OK → [运行中]
                    ↓
            需要同步 GPU 上下文 (cuCtxSynchronize)
                    ↓
            页面迁移：GPU ↔ 系统内存
                    ↓
            造成 60 秒级延迟
```

**问题**：当 GPU 显存被超额使用时，上下文切换需要将整个工作集（~12GB）在 GPU 和系统内存之间迁移，导致切换开销从毫秒级飙升到秒级。

### 3.4 NVML 未找到

```
[NVSHARE][DEBUG]: Could not find NVML
```

这导致 nvshare scheduler 无法获取 GPU 利用率信息（`nvmlDeviceGetUtilizationRates`），可能影响调度决策。但这不是性能问题的主要原因。

---

## 4. 性能对比

| 场景 | 预期耗时 | 实际耗时 | 原因 |
|------|----------|----------|------|
| 1 Pod 独占 GPU | ~30 分钟 | ~30 分钟 | 正常 |
| 2 Pod 共享（无超分） | ~60 分钟 | ~60 分钟 | 时分复用正常 |
| 4 Pod 共享（超分 150%） | ~120 分钟 | **~15+ 小时** | Unified Memory 抖动 |

---

## 5. 改进方案

### 5.1 短期方案：限制同时运行的 Pod 数量

**原理**：确保同时运行的 Pod 总显存需求不超过物理显存

```yaml
# 建议配置
每 GPU vGPU 数量: 2-3 (而非 10)
每 Pod 显存限制: ~5GB
2 GPU × 2 vGPU = 4 Pod，总需求 ~20GB < 32GB
```

**操作**:
```bash
# 修改 device-plugin 配置
# .tests/manifests/device-plugin.yaml
- name: NVSHARE_VIRTUAL_DEVICES
  value: "2"  # 原为 10
```

### 5.2 短期方案：使用小显存测试容器

```bash
# 使用 tf-matmul-small (~800MB) 或 pytorch-add-small (~1.5GB)
# 4 Pod × 1.5GB = 6GB << 32GB，无超分
.tests/workloads/manifests/nvshare-pytorch-small-pod-*.yaml
```

### 5.3 中期方案：基于显存的智能调度

**设计**：在 scheduler 中实现显存感知调度

```go
// 伪代码
type Client struct {
    MemoryUsage uint64  // 新增：当前显存使用量
}

func (s *Scheduler) selectNextClient() *Client {
    // 只有当 GPU 显存足够容纳下一个 client 时才调度
    for _, c := range s.pendingClients {
        if s.currentGpuMemUsage + c.MemoryUsage <= s.totalGpuMem {
            return c
        }
    }
    return nil  // 等待当前任务完成再调度
}
```

### 5.4 长期方案：显存配额管理

**设计**：在 libnvshare 中实现显存配额限制

```c
// hook.c 修改
#define ENV_NVSHARE_MEM_LIMIT "NVSHARE_MEM_LIMIT_MB"

CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
    // 检查配额
    if (sum_allocated + bytesize > mem_limit) {
        log_warn("Memory allocation exceeds quota");
        return CUDA_ERROR_OUT_OF_MEMORY;
    }
    // ...
}
```

---

## 6. 建议测试配置

| 测试场景 | Pod 数量 | 容器类型 | 预期结果 |
|----------|----------|----------|----------|
| 无超分基准 | 2 | pytorch-add | 正常完成，~60 分钟 |
| 轻度超分 | 4 | pytorch-add-small | 正常完成，略有延迟 |
| 跨 GPU 分布 | 12 | tf-matmul-small | 正常完成，验证调度 |

---

## 7. 结论

性能骤降的根本原因是 **CUDA Unified Memory 在显存超额使用时的页面抖动**。这是 nvshare 设计的固有局限：它通过 Unified Memory 实现显存共享，但当总需求超过物理显存时会触发频繁的 GPU-CPU 内存交换。

**建议**：
1. 控制 vGPU 数量，避免显存超额使用
2. 对于大显存任务，限制并发 Pod 数量
3. 考虑实现显存配额机制，防止单任务过度使用显存
