# 测试与验证指南

本文档介绍了如何使用 NVShare 项目提供的测试脚本进行功能验证和性能测试。测试脚本分为 **远程自动化测试脚本** 和 **手动测试脚本** 两类。

## 1. 远程自动化测试脚本 (Remote Test Scripts)

位于 `tests/` 目录下，这些脚本设计用于在本地机器上发起对远程 GPU 服务器的全流程测试。它们会自动执行以下步骤：
1.  **代码同步**：将本地代码同步到远程服务器。
2.  **构建与部署**：在远程服务器上构建项目，更新镜像，并重新部署 Scheduler 和 Device Plugin。
3.  **运行测试**：执行具体的测试用例。

### 支持的脚本

*   **Standard / Cross-GPU Test** (`tests/remote-test.sh`)
    *   **描述**: 标准测试，验证跨 GPU 的负载分布和基本调度功能。
    *   **默认配置**: 启动 3-4 个标准 PyTorch Pod。
    *   **代码**: `tests/scripts/test-cross-gpu.sh`

*   **Small Workload Test** (`tests/remote-test-small.sh`)
    *   **描述**: 小负载测试，用于验证高并发下的调度能力（如 1:10 虚拟化）。适合测试显存占用较小的任务。
    *   **默认配置**: 启动 10+ 个小显存占用 Pod。
    *   **代码**: `tests/scripts/test-small.sh`

*   **Idle Small Workload Test** (`tests/remote-test-idle-small.sh`)
    *   **描述**: 空闲/低负载测试，验证在任务算力占用极低（Idle）情况下的并行调度和稳定性。
    *   **默认配置**: 启动 10+ 个低算力 Pod。
    *   **代码**: `tests/scripts/test-idle-small.sh`
*   **GPU Memory Limit Test** (`tests/remote-test-memlimit.sh`)
    *   **描述**: 验证 GPU 显存配额功能，测试 `NVSHARE_GPU_MEMORY_LIMIT` 环境变量是否正确限制显存分配。
    *   **测试用例**:
        | 测试 | 显存限制 | 预期结果 | 说明 |
        |------|---------|---------|------|
        | Test 1 | 1Gi | ❌ FAIL | pytorch-add-small 需要 ~1.5GB，1Gi 限制应触发 OOM |
        | Test 2 | 4Gi | ✅ PASS | 4Gi 足够 1.5GB 分配 |
        | Test 3 | 无限制 | ✅ PASS | 默认行为，使用全部可用显存 |
    *   **使用**:
        ```bash
        ./tests/remote-test-memlimit.sh         # 完整测试（含构建部署）
        ./tests/remote-test-memlimit.sh -s      # 跳过构建部署
        ```
    *   **验证日志**: 成功时 Pod 日志应显示：
        ```
        cuMemGetInfo (with limit): free=276.00 MiB, total=1024.00 MiB
        RuntimeError: CUDA out of memory...
        ```

### 常用参数

所有 `remote-test-*.sh` 脚本均支持以下参数：

*   **`--skip-setup` / `-s`**
    *   **作用**: 跳过代码同步、构建、集群清理和部署步骤，直接运行测试用例。
    *   **场景**: 当你已经部署了最新代码，只想反复运行测试脚本查看结果时使用。
    *   **示例**:
        ```bash
        ./tests/remote-test.sh --skip-setup
        ```

*   **`--serial`**
    *   **作用**: 强制以 **串行模式 (Serial Mode)** 部署 Scheduler。
    *   **原理**: 注入环境变量 `NVSHARE_SCHEDULING_MODE=serial` 到 Scheduler Pod。在此模式下，每个 GPU 同一时间只允许一个任务运行，禁止并发。
    *   **场景**: 用于对比并发 vs 串行性能，或调试并发相关的问题。
    *   **注意**: 必须配合完整流程使用（即**不能**与 `--skip-setup` 同时使用，否则无法重新部署 Scheduler）。
    *   **示例**:
        ```bash
        ./tests/remote-test.sh --serial
        ```

*   **位置参数 (Positional Args)**
    *   **作用**: 传递给底层测试脚本的参数（通常是 Pod 数量）。
    *   **示例** (启动 20 个 Pod):
        ```bash
        ./tests/remote-test-small.sh 20
        ```

### 组合示例

1.  **完整部署并进行串行测试**:
    ```bash
    ./tests/remote-test.sh --serial 4
    ```

2.  **已部署好环境，快速重跑并发测试**:
    ```bash
    ./tests/remote-test.sh --skip-setup 4
    ```

3.  **测试 GPU 显存配额功能**:
    ```bash
    ./tests/remote-test-memlimit.sh -s
    ```

---

## 2. 手动测试脚本 (Manual Test Scripts)

位于 `tests/scripts/` 目录下。如果你已经配置好了 `kubectl` 连接到目标集群，且集群中已经部署了 NVShare 系统，可以直接运行这些脚本。

### 前置条件
*   本地环境已安装 `kubectl` 并配置好 `KUBECONFIG`。
*   集群中已安装 `nvshare-scheduler` 和 `nvshare-device-plugin`。

### 使用方法

直接执行脚本即可，可以跟一个数字参数指定 Pod 数量。

*   **跨 GPU 分布测试**:
    ```bash
    ./tests/scripts/test-cross-gpu.sh [POD_COUNT]
    ```

*   **小负载并发测试**:
    ```bash
    ./tests/scripts/test-small.sh [POD_COUNT]
    ```

*   **Idle 负载测试**:
    ```bash
    ./tests/scripts/test-idle-small.sh [POD_COUNT]
    ```

### 脚本功能
这些脚本会自动：
1.  清理旧的测试 Pod。
2.  应用对应的 Pod Manifests。
3.  等待 Pod 创建并监控运行进度（解析 logs 显示进度条）。
4.  **日志分析**: 自动抓取 Scheduler 日志，根据测试开始时间过滤，展示 Pod -> Client -> GPU UUID 的映射关系表格。
5.  **结果统计**: 统计 Pass/Fail 数量，计算平均运行时间 (Duration) 和处理速度 (Speed)。

---

## 3. GPU 显存配额使用说明

### 环境变量配置

在 Pod 的 manifest 中通过环境变量设置显存限制：

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
      value: "4Gi"  # 支持 Mi/Gi/Ki 单位
    resources:
      limits:
        nvshare.com/gpu: 1
```

### 支持的单位
- `Gi` / `GiB`: 1024^3 字节
- `Mi` / `MiB`: 1024^2 字节
- `Ki` / `KiB`: 1024 字节
- 纯数字: 字节

### 行为说明
1. 当设置 `NVSHARE_GPU_MEMORY_LIMIT` 后，`cuMemGetInfo()` 将返回配置的限制值作为 `total`
2. 当内存分配超过限制时，`cuMemAlloc()` 返回 `CUDA_ERROR_OUT_OF_MEMORY`
3. 不设置该环境变量时，默认使用物理 GPU 显存

## 4. 动态显存配额测试 (Dynamic Memory Limit)

本功能允许在 Pod 运行时通过 Kubernetes Annotations 动态调整显存限制，无需重启 Pod。

### 测试方法

1. **部署测试 Pod** (初始无限制)
   ```bash
   kubectl apply -f tests/kubernetes/manifests/nvshare-memlimit-test.yaml
   ```

2. **添加显存限制** (例如 4Gi)
   ```bash
   kubectl annotate pod <pod-name> nvshare.com/gpu-memory-limit=4Gi --overwrite
   ```

3. **验证生效**
   查看 Scheduler 日志，应包含 "Sending UPDATE_LIMIT" 消息：
   ```bash
   kubectl logs -n nvshare-system <scheduler-pod> | grep "UPDATE_LIMIT"
   ```

4. **移除限制** (恢复无限)
   ```bash
   kubectl annotate pod <pod-name> nvshare.com/gpu-memory-limit-
   ```

### 自动化验证脚本
使用 `tests/remote-test-dynamic-limit.sh` 可自动完成全流程验证：
```bash
./tests/remote-test-dynamic-limit.sh
```
