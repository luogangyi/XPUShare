# 多 GPU 支持与显存超分测试验证方案

本文档详细描述了如何验证 `nvshare` 在多 GPU 环境下的功能正确性，以及显存超额订阅 (Oversubscription) 能力的测试方法。

## 1. 测试环境准备

### 1.1 前置条件
*   Kubernetes 集群已就绪。
*   节点至少拥有 2 张 NVIDIA GPU。
*   已安装 NVIDIA Driver 和 Kubernetes Device Plugin (NVIDIA 官方插件需禁用或与 nvshare 共存配置正确)。
*   `nvshare` 组件 (Scheduler, Device Plugin) 已成功部署。

### 1.2 部署检查
确保 `nvshare` 节点已上报虚拟资源：
```bash
kubectl describe node <gpu-node> | grep nvshare.com/gpu
# 预期输出：nvshare.com/gpu: 20 (假设 2 张卡，每张虚拟化 10 个)
```

---

## 2. 多 GPU 调度验证

### 2.1 目标
验证 K8s 能将 Pod 调度到不同的物理 GPU 上，且 Pod 内环境变量正确指向单一物理 GPU UUID。

### 2.2 测试步骤

1.  **创建测试 Pod 定义 (test-pods.yaml)**
    创建两个 Pod，申请 `nvshare.com/gpu: 1`。

    ```yaml
    apiVersion: v1
    kind: Pod
    metadata:
      name: gpu-pod-1
    spec:
      containers:
      - name: cuda-container
        image: nvidia/cuda:11.8.0-base-ubuntu22.04
        command: ["sleep", "infinity"]
        resources:
          limits:
            nvshare.com/gpu: 1
    ---
    apiVersion: v1
    kind: Pod
    metadata:
      name: gpu-pod-2
    spec:
      containers:
      - name: cuda-container
        image: nvidia/cuda:11.8.0-base-ubuntu22.04
        command: ["sleep", "infinity"]
        resources:
          limits:
            nvshare.com/gpu: 1
    ```

2.  **部署并验证**
    ```bash
    kubectl apply -f test-pods.yaml
    ```

3.  **检查环境变量**
    分别进入两个 Pod 检查分配的 UUID：
    ```bash
    UUID1=$(kubectl exec gpu-pod-1 -- env | grep NVIDIA_VISIBLE_DEVICES)
    UUID2=$(kubectl exec gpu-pod-2 -- env | grep NVIDIA_VISIBLE_DEVICES)
    
    echo "Pod 1: $UUID1"
    echo "Pod 2: $UUID2"
    ```

### 2.3 预期结果
*   如果实现了负载均衡 (GetPreferredAllocation)，`UUID1` 和 `UUID2` 应不同（假设之前节点空闲）。
*   即使是顺序分配，两个 UUID 也应是有效的物理 GPU UUID。
*   Pod 内运行 `nvidia-smi` (如果镜像内有) 应该只能看到被分配的那一张卡。

---

## 3. 并行隔离性测试

### 3.1 目标
验证两个通过 `nvshare` 共享不同 GPU 的 Pod，其调度是独立的，互不阻塞。

### 3.2 测试方法
1.  在 `gpu-pod-1` (绑定 GPU A) 运行持续计算任务。
2.  在 `gpu-pod-2` (绑定 GPU B) 运行持续计算任务。
3.  观察宿主机的 `nvidia-smi` 或 `nvshare-scheduler` 日志。

### 3.3 预期结果
*   宿主机上看到两张 GPU 的利用率都上升。
*   `nvshare-scheduler` 日志显示两个不同的 Context 都在进行 `LOCK_OK` / `DROP_LOCK` 的循环（如果开启了时间片抢占），或者长期持有锁。
*   **关键点**: GPU A 的任务不应导致 GPU B 的任务卡顿。

---

## 4. 显存超额订阅 (Oversubscription) 测试

### 4.1 目标
验证 Unified Memory 机制是否生效，允许申请超过物理显存大小的内存。

### 4.2 准备测试代码 (mem_eater.cu)
编写一个简单的 CUDA 程序，申请指定大小的显存并写入数据。

```cpp
#include <stdio.h>
#include <cuda_runtime.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    size_t free, total;
    cudaMemGetInfo(&free, &total);
    printf("Initial: Free: %zu MB, Total: %zu MB\n", free/1024/1024, total/1024/1024);

    // 申请比 Total 还大的内存，例如 Total * 1.5
    // 或者通过参数传入申请大小 (MB)
    size_t alloc_size_mb = 0;
    if (argc > 1) alloc_size_mb = atoi(argv[1]);
    
    if (alloc_size_mb == 0) alloc_size_mb = (total / 1024 / 1024) + 2048; // Default: Total + 2GB

    size_t alloc_bytes = alloc_size_mb * 1024 * 1024;
    printf("Attempting to allocate %zu MB...\n", alloc_size_mb);

    char *d_ptr;
    // 注意：这里代码写 cudaMalloc，但运行时会被 libnvshare 劫持为 cudaMallocManaged
    cudaError_t err = cudaMalloc((void**)&d_ptr, alloc_bytes);
    
    if (err != cudaSuccess) {
        printf("ALLOC FAILED: %s\n", cudaGetErrorString(err));
        return 1;
    }
    
    printf("Allocation successful! Touching memory...\n");
    // 触发 Page Fault
    cudaMemset(d_ptr, 0, alloc_bytes);
    cudaDeviceSynchronize();
    
    printf("Memory touched successfully. Sleeping 10s...\n");
    sleep(10);
    
    cudaFree(d_ptr);
    printf("Done.\n");
    return 0;
}
```
*编译*: `nvcc mem_eater.cu -o mem_eater` 并打入镜像。

### 4.3 测试场景 A: 未开启超分 (预期失败)

1.  部署 Pod，**不设置** `NVSHARE_ENABLE_SINGLE_OVERSUB`。
2.  运行 `mem_eater`，请求 Total + 1GB 内存。
3.  **预期结果**: 程序输出 `ALLOC FAILED: out of memory`。
    *   原因: `hook.c` 中检测到 `sum_allocated > allocatable` 且开关未开，主动拦截并返回错误。

### 4.4 测试场景 B: 开启超分 (预期成功)

1.  修改 Pod 配置，添加环境变量：
    ```yaml
    env:
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
    ```
2.  运行 `mem_eater`，请求 Total + 1GB 内存。
3.  **预期结果**:
    *   程序输出 `Allocation successful!`。
    *   `cudaMemset` 执行可能较慢（涉及 CPU-GPU 页交换）。
    *   宿主机 `nvidia-smi` 显示该进程显存占用接近物理上限，但不会 OOM。

---

## 5. 多租户高密度与公平性测试

### 5.1 目标
验证在单张 GPU 上运行超过物理承载能力的并发任务数（例如 10 个），验证调度器是否公平轮转。

### 5.2 方法
1.  部署 5 个 Pod 到同一节点，确保它们落在同一物理 GPU（可通过手动修改代码强制或利用当前调度器的 Bin-packing 特性）。
2.  每个 Pod 运行死循环计算任务 (`while(1) { kernel<<<...>>>(); synchronize(); }`)。
3.  查看 `nvshare-scheduler` 日志。

### 5.3 预期结果
*   日志显示 `LOCK_OK` 依次发送给 Client 1 -> 2 -> 3 -> 4 -> 5 -> 1...
*   每个 Client 持有锁的时间大约等于配置的 `NVSHARE_DEFAULT_TQ` (默认 30ms-50ms)。
*   所有 Pod 都在缓慢推进，没有 Pod 被饿死。
