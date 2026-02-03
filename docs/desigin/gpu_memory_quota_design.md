# GPU 显存配额管理设计方案

## 1. 需求概述

### 核心需求
1. **Pod 级显存配额**：创建 Pod 时可指定显存上限（可选，默认使用全部显存）
2. **显存使用限制**：当 Pod 使用超过配置的显存时，拒绝分配
3. **超分配置**：Device-Plugin 可配置每个物理 GPU 可虚拟的总显存量

### 使用场景
```yaml
# 示例：Pod 申请 4GB 显存
resources:
  limits:
    nvshare.com/gpu: 1
    nvshare.com/gpumem: "4Gi"  # 新增：显存配额（单位：Mi/Gi）
```

## 2. 架构设计

```
┌─────────────────────────────────────────────────────────────────┐
│                      Kubernetes API                              │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Device Plugin                                 │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ • 注册 nvshare.com/gpu-memory 资源类型                      │ │
│  │ • 配置 NVSHARE_GPU_MEMORY_OVERSUB_RATIO (默认 1.0)         │ │
│  │ • 追踪每个 GPU 的已分配显存                                  │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼ 环境变量: NVSHARE_GPU_MEMORY_LIMIT
┌─────────────────────────────────────────────────────────────────┐
│                        Client (libnvshare)                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ • 读取 NVSHARE_GPU_MEMORY_LIMIT 环境变量                   │ │
│  │ • 在 cuMemAlloc 时检查累计分配是否超限                      │ │
│  │ • 超限时返回 CUDA_ERROR_OUT_OF_MEMORY                      │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## 3. 详细设计

### 3.1 Device Plugin 修改

#### 新增资源类型
```go
const (
    resourceGPU       = "nvshare.com/gpu"
    resourceGPUMemory = "nvshare.com/gpu-memory"  // 新增
)
```

#### 配置项
| 环境变量 | 说明 | 默认值 |
|---------|------|--------|
| `NVSHARE_GPU_MEMORY_OVERSUB_RATIO` | 显存超分比例 | 1.0 |
| `NVSHARE_GPU_PHYSICAL_MEMORY_MB` | 物理 GPU 显存 (MB) | 自动检测 |

#### 显存分配逻辑
```go
// GetPreferredAllocation 中
type gpuLoad struct {
    uuid            string
    allocatedMemory int64  // 已分配显存 (MB)
    allocatedCount  int    // 已分配任务数
}

// 选择显存最充足的 GPU
sort.Slice(gpuLoads, func(i, j int) bool {
    return gpuLoads[i].allocatedMemory < gpuLoads[j].allocatedMemory
})
```

#### Allocate 响应
```go
// Allocate 时注入环境变量
envs := map[string]string{
    "NVIDIA_VISIBLE_DEVICES": gpuUUID,
    "NVSHARE_GPU_MEMORY_LIMIT": fmt.Sprintf("%dMi", requestedMemory),
}
```

### 3.2 Client (libnvshare) 修改

#### 环境变量读取
```c
// client.c
static size_t memory_limit = SIZE_MAX;  // 默认无限制

void init_memory_limit() {
    char* limit_str = getenv("NVSHARE_GPU_MEMORY_LIMIT");
    if (limit_str) {
        memory_limit = parse_memory_size(limit_str);  // 支持 Mi/Gi 后缀
        log_info("GPU memory limit: %zu MB", memory_limit / (1024*1024));
    }
}
```

#### cuMemAlloc 拦截增强
```c
// hook.c
CUresult cuMemAlloc_v2(CUdeviceptr *dptr, size_t bytesize) {
    // 检查配额
    if (current_allocated + bytesize > memory_limit) {
        log_warn("Memory allocation rejected: %zu + %zu > %zu limit",
                 current_allocated, bytesize, memory_limit);
        return CUDA_ERROR_OUT_OF_MEMORY;
    }
    
    // 调用原始函数
    CUresult ret = orig_cuMemAlloc_v2(dptr, bytesize);
    if (ret == CUDA_SUCCESS) {
        current_allocated += bytesize;
        // 通知 scheduler 更新
        send_memory_update(current_allocated);
    }
    return ret;
}
```

### 3.3 Scheduler 修改 (可选增强)

```c
// 在 MEM_UPDATE 处理中检查配额
case MEM_UPDATE:
    if (client->memory_allocated > client->memory_limit) {
        log_warn("Client %016" PRIx64 " exceeded memory limit: %zu > %zu",
                 client->id, client->memory_allocated, client->memory_limit);
        // 可选：发送警告或强制释放
    }
```

## 4. Pod Manifest 示例

### 指定显存配额（通过环境变量方式）
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-workload
spec:
  containers:
  - name: worker
    image: my-cuda-app
    env:
    - name: NVSHARE_GPU_MEMORY_LIMIT
      value: "4Gi"  # 限制 GPU 显存为 4GiB
    resources:
      limits:
        nvshare.com/gpu: 1
```

### 使用默认配额 (全部显存)
```yaml
resources:
  limits:
    nvshare.com/gpu: 1
    # 不指定 NVSHARE_GPU_MEMORY_LIMIT，默认可使用全部
```

## 5. 实现步骤

### Phase 1: Device Plugin 资源注册
- [ ] 注册 `nvshare.com/gpu-memory` 扩展资源
- [ ] 读取 `NVSHARE_GPU_MEMORY_OVERSUB_RATIO` 配置
- [ ] 修改 Allocate 注入 `NVSHARE_GPU_MEMORY_LIMIT` 环境变量

### Phase 2: Client 显存限制
- [ ] 读取 `NVSHARE_GPU_MEMORY_LIMIT` 环境变量
- [ ] 在 `cuMemAlloc` 中检查配额并拒绝超限分配
- [ ] 更新 MEM_UPDATE 消息包含配额信息

### Phase 3: Scheduler 增强 (可选)
- [ ] 记录每个客户端的显存配额
- [ ] 在调度决策中考虑显存配额

## 6. 兼容性考虑

1. **向后兼容**：不指定 `gpu-memory` 时行为与现有相同
2. **渐进式采用**：可以只在特定 Pod 上启用配额
3. **安全限制**：Client 端强制执行，即使恶意程序也无法绕过

## 7. 风险与限制

| 风险 | 影响 | 缓解措施 |
|-----|------|---------|
| CUDA 库绕过 libnvshare 直接分配 | 配额失效 | 文档说明限制 |
| 显存碎片化导致分配失败 | 实际可用 < 配额 | 记录日志供排查 |
| 超分过高导致频繁换页 | 性能下降 | 默认超分比=1.0 |
