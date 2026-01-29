# nvshare GPU 共享测试方案

## 1. 测试环境

| 配置项 | 规格 |
|--------|------|
| GPU 型号 | NVIDIA Tesla T4 × 2 |
| 单卡显存 | 16GB |
| 虚拟 GPU 数量 | 每卡 10 个，共 20 个 vGPU |
| nvshare 组件 | scheduler + device-plugin |

---

## 2. 测试容器规格

| 容器类型 | 显存需求 | 迭代次数 | 运行时长 | 适用场景 |
|----------|----------|----------|----------|----------|
| `pytorch-add-small` | ~1.5GB | 40000 | 中等 | GPU 共享测试 |
| `tf-matmul-small` | ~800MB | 1000 | 较短 | 快速验证 |
| `pytorch-add` | ~6GB | 4000 | 较长 | 显存压力测试 |
| `tf-matmul` | ~10GB | 10 | 较短 | 大显存测试 |

> [!TIP]
> T4 有 16GB 显存，推荐使用 `*-small` 系列进行多任务共享测试，使用标准版进行显存边界测试。

---

## 3. 测试场景

### 场景 1：基础 GPU 共享验证

**目的**：验证 2 个 Pod 能否共享同一 GPU

| 参数 | 值 |
|------|-----|
| Pod 数量 | 2 |
| 容器类型 | `pytorch-add-small` |
| 预期结果 | 两个 Pod 同时运行，均输出 PASS |

```bash
.tests/scripts/test-basic-sharing.sh
```

---

### 场景 2：多 Pod GPU 共享（同 GPU）

**目的**：验证多个 Pod（4个）在单 GPU 上的时分复用

| 参数 | 值 |
|------|-----|
| Pod 数量 | 4 |
| 容器类型 | `tf-matmul-small` |
| 预期结果 | 4 个 Pod 共享 GPU，均输出 PASS |

```bash
.tests/scripts/test-multi-pod-sharing.sh
```

---

### 场景 3：跨 GPU 负载分布

**目的**：验证多 Pod 是否能分布到不同 GPU

> [!IMPORTANT]
> 配置为 1:10 虚拟化比（每 GPU 10 个 vGPU），需要 >10 个 Pod 才能验证跨 GPU 调度

| 参数 | 值 |
|------|-----|
| Pod 数量 | 12（超过单 GPU 的 10 vGPU） |
| 容器类型 | `tf-matmul-small` |
| 预期结果 | Pod 分布在 2 个 GPU 上 |

```bash
.tests/scripts/test-cross-gpu.sh
```

---

### 场景 4：显存边界测试（启用超分）

**目的**：验证大显存任务的 GPU 共享稳定性

> [!IMPORTANT]
> 需设置 `NVSHARE_ENABLE_SINGLE_OVERSUB=1` 启用单进程显存超分

| 参数 | 值 |
|------|-----|
| Pod 数量 | 2 |
| 容器类型 | `pytorch-add`（~6GB × 2 = ~12GB） |
| 环境变量 | `NVSHARE_ENABLE_SINGLE_OVERSUB=1` |
| 预期结果 | 两个 Pod 共享 GPU（总显存 ~12GB < 16GB），无 OOM |

```bash
.tests/scripts/test-memory-boundary.sh
```

---

### 场景 5：混合框架测试

**目的**：验证 PyTorch 和 TensorFlow 任务混合共享

| 参数 | 值 |
|------|-----|
| Pod 数量 | 4（2 PyTorch + 2 TensorFlow） |
| 容器类型 | `pytorch-add-small` + `tf-matmul-small` |
| 预期结果 | 不同框架任务能正常时分复用 |

```bash
.tests/scripts/test-mixed-frameworks.sh
```

---

### 场景 6：高并发压力测试

**目的**：验证大量 Pod 同时请求 vGPU 的调度稳定性

| 参数 | 值 |
|------|-----|
| Pod 数量 | 10 |
| 容器类型 | `tf-matmul-small` |
| 预期结果 | 所有 Pod 均能完成，输出 PASS |

```bash
.tests/scripts/test-high-concurrency.sh
```

---

## 4. 测试脚本使用

### 4.1 前置条件

```bash
# 1. 确保 nvshare 组件已部署
kubectl get pods -n nvshare-system

# 2. 更新测试清单中的镜像 URL
.tests/workloads/update-manifests.sh
.tests/update-manifests.sh
```

### 4.2 运行测试

```bash
# 运行单个测试场景
.tests/scripts/test-basic-sharing.sh

# 运行所有测试
.tests/scripts/run-all-tests.sh
```

### 4.3 查看结果

```bash
# 查看 Pod 日志
kubectl logs <pod-name>

# 监控 GPU 使用
nvidia-smi -l 1
```

---

## 5. 验收标准

| 测试场景 | 通过标准 |
|----------|----------|
| 基础 GPU 共享 | 2 个 Pod 均输出 PASS |
| 多 Pod 共享 | 4 个 Pod 均输出 PASS |
| 跨 GPU 分布 | Pod 分布在多个 GPU 上 |
| 显存边界 | 无 OOM 错误，均输出 PASS |
| 混合框架 | PyTorch/TensorFlow 混合运行正常 |
| 高并发 | 10 个 Pod 全部完成 |

---

## 6. 故障排查

### Pod 无法调度

```bash
kubectl describe pod <pod-name>
kubectl get events --sort-by=.metadata.creationTimestamp
```

### GPU 资源不足

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.'nvshare\.com/gpu'
```

### 查看 scheduler 日志

```bash
kubectl logs -n nvshare-system -l name=nvshare-scheduler
```
