# 测试目录分析报告

本文档详细分析 `tests` 目录下的测试代码结构、作用和使用方法。

## 目录结构概览

```
tests/
├── Makefile                    # 测试镜像构建脚本
├── dockerfiles/                # 测试镜像 Dockerfile
│   ├── Dockerfile.pytorch
│   ├── Dockerfile.pytorch.small
│   ├── Dockerfile.tsf
│   └── Dockerfile.tsf.small
├── kubernetes/manifests/       # Kubernetes 测试 Pod 清单
│   ├── nvshare-pytorch-pod-1.yaml
│   ├── nvshare-pytorch-pod-2.yaml
│   ├── nvshare-pytorch-small-pod-1.yaml
│   ├── nvshare-pytorch-small-pod-2.yaml
│   ├── nvshare-tf-pod-1.yaml
│   ├── nvshare-tf-pod-2.yaml
│   ├── nvshare-tf-small-pod-1.yaml
│   └── nvshare-tf-small-pod-2.yaml
├── pytorch-add.py              # PyTorch 张量加法测试（大矩阵）
├── pytorch-add-small.py        # PyTorch 张量加法测试（小矩阵）
├── tf-matmul.py                # TensorFlow 矩阵乘法测试（大矩阵）
└── tf-matmul-small.py          # TensorFlow 矩阵乘法测试（小矩阵）
```

---

## 1. Python 测试脚本

测试脚本用于验证 nvshare GPU 时分复用功能，通过执行 GPU 密集型计算来测试多进程共享 GPU 的效果。

### 1.1 PyTorch 测试脚本

#### `pytorch-add.py` - 大矩阵张量加法

| 参数 | 值 |
|------|-----|
| 矩阵大小 | 28000 × 28000 |
| 迭代次数 | 4000 |
| 显存需求 | 约 6GB |

**核心逻辑**：

```python
n = 28000
x = torch.ones([n, n], dtype=torch.float32).to(device)
y = torch.ones([n, n], dtype=torch.float32).to(device)
for i in range(4000):
    z = torch.add(x, y)
```

#### `pytorch-add-small.py` - 小矩阵张量加法

| 参数 | 值 |
|------|-----|
| 矩阵大小 | 14000 × 14000 |
| 迭代次数 | 40000 |
| 显存需求 | 约 1.5GB |

适用于显存较小的 GPU 或快速验证场景。

---

### 1.2 TensorFlow 测试脚本

#### `tf-matmul.py` - 大矩阵乘法

| 参数 | 值 |
|------|-----|
| 矩阵大小 | 35000 × 35000 |
| 迭代次数 | 10 |
| 显存需求 | 约 10GB |

**核心逻辑**：

```python
n = 35000
with tf.device("/gpu:0"):
    matrix1 = tf.Variable(tf.ones((n, n), dtype=tf.float32))
    matrix2 = tf.Variable(tf.ones((n, n), dtype=tf.float32))
    product = tf.matmul(matrix1, matrix2)
```

#### `tf-matmul-small.py` - 小矩阵乘法

| 参数 | 值 |
|------|-----|
| 矩阵大小 | 10000 × 10000 |
| 迭代次数 | 1000 |
| 显存需求 | 约 800MB |

---

## 2. Dockerfiles

每个 Dockerfile 将对应的 Python 脚本打包成容器镜像。

| Dockerfile | 基础镜像 | 测试脚本 |
|------------|----------|----------|
| `Dockerfile.pytorch` | `pytorch/pytorch:1.9.1-cuda11.1-cudnn8-runtime` | `pytorch-add.py` |
| `Dockerfile.pytorch.small` | `pytorch/pytorch:1.9.1-cuda11.1-cudnn8-runtime` | `pytorch-add-small.py` |
| `Dockerfile.tsf` | `tensorflow/tensorflow:2.7.0-gpu` | `tf-matmul.py` |
| `Dockerfile.tsf.small` | `tensorflow/tensorflow:2.7.0-gpu` | `tf-matmul-small.py` |

---

## 3. Makefile

### 构建目标

| 目标 | 说明 |
|------|------|
| `build` | 构建所有测试镜像 |
| `build-tf` | 构建 TensorFlow 大矩阵测试镜像 |
| `build-tf-small` | 构建 TensorFlow 小矩阵测试镜像 |
| `build-pytorch` | 构建 PyTorch 大矩阵测试镜像 |
| `build-pytorch-small` | 构建 PyTorch 小矩阵测试镜像 |
| `push` | 推送所有镜像到仓库 |

### 镜像标签格式

- `nvshare:tf-matmul-<commit>`
- `nvshare:tf-matmul-small-<commit>`
- `nvshare:pytorch-add-<commit>`
- `nvshare:pytorch-add-small-<commit>`

### 使用方法

```bash
cd tests

# 构建所有测试镜像
make build

# 仅构建 PyTorch 测试镜像
make build-pytorch

# 推送到镜像仓库
make push
```

---

## 4. Kubernetes 测试清单

每种测试提供 2 个 Pod 清单（pod-1 和 pod-2），用于同时运行两个测试 Pod 验证 GPU 共享功能。

### Pod 配置特点

- **资源请求**：`nvshare.com/gpu: 1`（请求 1 个 nvshare 虚拟 GPU）
- **环境变量**：`NVSHARE_DEBUG=1`（启用调试日志）
- **重启策略**：`OnFailure`

### 清单列表

| 清单文件 | 测试类型 | 说明 |
|----------|----------|------|
| `nvshare-pytorch-pod-1.yaml` | PyTorch 大矩阵 | 第一个测试 Pod |
| `nvshare-pytorch-pod-2.yaml` | PyTorch 大矩阵 | 第二个测试 Pod |
| `nvshare-pytorch-small-pod-1.yaml` | PyTorch 小矩阵 | 第一个测试 Pod |
| `nvshare-pytorch-small-pod-2.yaml` | PyTorch 小矩阵 | 第二个测试 Pod |
| `nvshare-tf-pod-1.yaml` | TensorFlow 大矩阵 | 第一个测试 Pod |
| `nvshare-tf-pod-2.yaml` | TensorFlow 大矩阵 | 第二个测试 Pod |
| `nvshare-tf-small-pod-1.yaml` | TensorFlow 小矩阵 | 第一个测试 Pod |
| `nvshare-tf-small-pod-2.yaml` | TensorFlow 小矩阵 | 第二个测试 Pod |

---

## 5. 完整测试流程

### 5.1 准备工作

确保已部署 nvshare 组件：

```bash
kubectl get pods -n nvshare-system
# 确认 nvshare-scheduler 和 nvshare-device-plugin 正常运行
```

### 5.2 构建测试镜像

```bash
cd tests
make build
make push  # 需要配置镜像仓库权限
```

### 5.3 运行 GPU 共享测试

同时启动两个 Pod 验证 GPU 时分复用：

```bash
# 同时运行两个 PyTorch 测试 Pod
kubectl apply -f kubernetes/manifests/nvshare-pytorch-pod-1.yaml
kubectl apply -f kubernetes/manifests/nvshare-pytorch-pod-2.yaml

# 查看 Pod 状态
kubectl get pods -w

# 查看日志
kubectl logs nvshare-pytorch-add-1
kubectl logs nvshare-pytorch-add-2
```

### 5.4 验证结果

两个 Pod 应该能够同时运行在同一个 GPU 上，日志中输出 `PASS` 表示测试成功。

### 5.5 清理

```bash
kubectl delete -f kubernetes/manifests/
```

---

## 6. 测试场景说明

| 测试场景 | 推荐清单 | 显存需求 | 执行时间 |
|----------|----------|----------|----------|
| 快速验证 | `*-small-pod-*.yaml` | ~2GB | 较短 |
| 完整测试 | `*-pod-*.yaml` | ~12GB | 较长 |
| PyTorch 验证 | `nvshare-pytorch-*.yaml` | - | - |
| TensorFlow 验证 | `nvshare-tf-*.yaml` | - | - |

> [!TIP]
> 推荐使用 `*-small-*` 系列进行快速验证，使用标准版本进行压力测试。
