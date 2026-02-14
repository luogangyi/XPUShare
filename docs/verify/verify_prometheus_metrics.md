# Verify Prometheus Metrics

## Objective
验证 Prometheus metrics 端点正常工作，能通过 curl 命令获取 GPU、客户端、调度器指标。

## Prerequisites
1. nvshare 组件已部署（Scheduler、Device Plugin）
2. Scheduler DaemonSet 配置中已设置 `NVSHARE_METRICS_ENABLE=1`
3. 确认 `scheduler.yaml` 中包含 `containerPort: 9402`

## 获取 Metrics 访问地址

```bash
# 方法一：通过 port-forward（推荐，测试用）
export KUBECONFIG=~/Code/configs/kubeconfig-fuyao-gpu
SCHED_POD=$(kubectl get pod -n nvshare-system -l name=nvshare-scheduler -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n nvshare-system $SCHED_POD 9402:9402 &

# 方法二：直接进入节点后通过 Pod IP 访问
SCHED_IP=$(kubectl get pod -n nvshare-system -l name=nvshare-scheduler -o jsonpath='{.items[0].status.podIP}')
# 在节点上: curl http://$SCHED_IP:9402/metrics
```

---

## 测试步骤

### 1. Health Check

```bash
curl -s http://localhost:9402/healthz
```

**预期输出：**
```
OK
```

---

### 2. 空闲状态指标检查（无负载）

```bash
curl -s http://localhost:9402/metrics
```

**预期输出包含以下内容：**

```bash
# 检查 NVML 是否可用
curl -s http://localhost:9402/metrics | grep nvshare_nvml_up
# 预期: nvshare_nvml_up 1

# 检查 GPU 信息（应显示 GPU 型号）
curl -s http://localhost:9402/metrics | grep nvshare_gpu_info
# 预期: nvshare_gpu_info{gpu_uuid="GPU-xxx",gpu_index="0",gpu_name="NVIDIA ..."} 1

# 检查 GPU 显存总量
curl -s http://localhost:9402/metrics | grep nvshare_gpu_memory_total_bytes
# 预期: nvshare_gpu_memory_total_bytes{gpu_uuid="GPU-xxx",gpu_index="0"} 17179869184  (示例16GB)

# 检查 GPU 利用率（空闲时应接近 0）
curl -s http://localhost:9402/metrics | grep nvshare_gpu_utilization_ratio
# 预期: nvshare_gpu_utilization_ratio{gpu_uuid="GPU-xxx",gpu_index="0"} 0.0000

# 空闲状态应无 client 指标
curl -s http://localhost:9402/metrics | grep nvshare_client_info
# 预期: 无输出（没有注册的客户端）

# 调度器队列应为空
curl -s http://localhost:9402/metrics | grep nvshare_scheduler_running_clients
# 预期: nvshare_scheduler_running_clients{...} 0
```

---

### 3. 有负载状态指标检查

启动一个测试 Pod：

```bash
kubectl apply -f tests/manifests/nvshare-pytorch-small-pod-1.yaml
# 等待 Pod 进入 Running 状态
kubectl wait --for=condition=Ready pod/nvshare-pytorch-small-pod-1 -n default --timeout=120s
```

然后检查：

```bash
# 客户端信息（应出现注册的客户端）
curl -s http://localhost:9402/metrics | grep nvshare_client_info
# 预期: nvshare_client_info{namespace="default",pod="nvshare-pytorch-small-pod-1",client_id="...",gpu_uuid="...",gpu_index="...",host_pid="..."} 1

# 管理分配内存（应为非零）
curl -s http://localhost:9402/metrics | grep nvshare_client_managed_allocated_bytes
# 预期: nvshare_client_managed_allocated_bytes{...} <非零值>

# NVML 进程显存（需 host_pid 映射成功）
curl -s http://localhost:9402/metrics | grep nvshare_client_nvml_used_bytes
# 预期: nvshare_client_nvml_used_bytes{...,host_pid="<PID>"} <非零值>

# GPU 利用率应升高
curl -s http://localhost:9402/metrics | grep nvshare_gpu_utilization_ratio
# 预期: > 0.0

# 调度器运行中客户端数
curl -s http://localhost:9402/metrics | grep nvshare_scheduler_running_clients
# 预期: nvshare_scheduler_running_clients{...} 1

# 运行中内存
curl -s http://localhost:9402/metrics | grep nvshare_scheduler_running_memory_bytes
# 预期: > 0

# 消息计数器（REGISTER 应 >= 1）
curl -s http://localhost:9402/metrics | grep 'nvshare_scheduler_messages_total{type="REGISTER"}'
# 预期: nvshare_scheduler_messages_total{type="REGISTER"} >= 1
```

---

### 4. 多任务状态检查

再启动一个 Pod 以触发调度器队列/限流行为：

```bash
kubectl apply -f tests/manifests/nvshare-pytorch-small-pod-2.yaml
sleep 30
```

```bash
# 检查有多个客户端
curl -s http://localhost:9402/metrics | grep nvshare_client_info | wc -l
# 预期: 2

# 检查算力 quota 指标
curl -s http://localhost:9402/metrics | grep nvshare_client_core_quota_config_percent
# 预期: 每个客户端一行，值为配置的 core_limit（默认100）

# 检查 GPU 进程数
curl -s http://localhost:9402/metrics | grep nvshare_gpu_process_count
# 预期: nvshare_gpu_process_count{...} 2

# 检查 DROP_LOCK 计数（如果发生了时间片轮转）
curl -s http://localhost:9402/metrics | grep nvshare_scheduler_drop_lock_total
# 预期: > 0 （如果是并发模式且触发了 quota 限流）
```

---

### 5. Prometheus 格式合规性检查

```bash
# 验证所有指标行都有 HELP 和 TYPE 注释
curl -s http://localhost:9402/metrics | grep -c "^# HELP"
# 预期: >= 25 (至少25个指标定义)

curl -s http://localhost:9402/metrics | grep -c "^# TYPE"
# 预期: >= 25

# 验证没有空行或格式错误（每一行要么是注释要么是 metric）
curl -s http://localhost:9402/metrics | grep -v "^#" | grep -v "^nvshare_" | grep -v "^$"
# 预期: 无输出（所有非注释行都以 nvshare_ 开头）

# 验证 counter 类型的指标有正确的 TYPE 声明
curl -s http://localhost:9402/metrics | grep "^# TYPE.*counter"
# 预期: 包含 messages_total, drop_lock_total, client_disconnect_total 等
```

---

### 6. 404 和错误处理

```bash
# 访问不存在的路径
curl -s -o /dev/null -w "%{http_code}" http://localhost:9402/notexist
# 预期: 404

# healthz 返回 200
curl -s -o /dev/null -w "%{http_code}" http://localhost:9402/healthz
# 预期: 200

# metrics 返回 200 和正确的 Content-Type
curl -sI http://localhost:9402/metrics | grep Content-Type
# 预期: Content-Type: text/plain; version=0.0.4; charset=utf-8
```

---

### 7. 一键快速验证脚本

以下脚本可以一次性执行所有基础检查：

```bash
#!/bin/bash
METRICS_URL=${1:-http://localhost:9402}

echo "=== 1. Health Check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $METRICS_URL/healthz)
[ "$HTTP_CODE" = "200" ] && echo "PASS: healthz returns 200" || echo "FAIL: healthz returns $HTTP_CODE"

echo ""
echo "=== 2. Metrics Endpoint ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $METRICS_URL/metrics)
[ "$HTTP_CODE" = "200" ] && echo "PASS: metrics returns 200" || echo "FAIL: metrics returns $HTTP_CODE"

echo ""
echo "=== 3. NVML Status ==="
curl -s $METRICS_URL/metrics | grep "nvshare_nvml_up"

echo ""
echo "=== 4. GPU Info ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_info"

echo ""
echo "=== 5. GPU Memory ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_memory_total_bytes"
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_memory_used_bytes"

echo ""
echo "=== 6. GPU Utilization ==="
curl -s $METRICS_URL/metrics | grep "nvshare_gpu_utilization_ratio"

echo ""
echo "=== 7. Client Info ==="
CLIENT_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^nvshare_client_info")
echo "Active clients: $CLIENT_COUNT"

echo ""
echo "=== 8. Scheduler Queues ==="
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_running_clients"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_request_queue_clients"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_wait_queue_clients"

echo ""
echo "=== 9. Event Counters ==="
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_messages_total"
curl -s $METRICS_URL/metrics | grep "nvshare_scheduler_drop_lock_total"

echo ""
echo "=== 10. Format Check ==="
HELP_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^# HELP")
TYPE_COUNT=$(curl -s $METRICS_URL/metrics | grep -c "^# TYPE")
echo "HELP lines: $HELP_COUNT, TYPE lines: $TYPE_COUNT"
BAD_LINES=$(curl -s $METRICS_URL/metrics | grep -v "^#" | grep -v "^nvshare_" | grep -v "^$" | wc -l)
[ "$BAD_LINES" = "0" ] && echo "PASS: No malformed lines" || echo "FAIL: $BAD_LINES malformed lines"

echo ""
echo "=== 11. 404 Check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $METRICS_URL/notexist)
[ "$HTTP_CODE" = "404" ] && echo "PASS: 404 for unknown path" || echo "FAIL: returns $HTTP_CODE"
```

## Cleanup

```bash
kubectl delete -f tests/manifests/nvshare-pytorch-small-pod-1.yaml
kubectl delete -f tests/manifests/nvshare-pytorch-small-pod-2.yaml
# 停止 port-forward
kill %1
```

## Manual Checklist
- [ ] healthz 返回 200 OK
- [ ] metrics 返回 200 + Prometheus 格式
- [ ] `nvshare_nvml_up` = 1
- [ ] GPU 信息正确（UUID、名称、显存）
- [ ] 空闲时无 client 指标
- [ ] 有负载时 client 指标出现且值合理
- [ ] NVML per-process 显存映射成功
- [ ] 调度器队列指标正确
- [ ] 消息计数器递增
- [ ] 404 路径返回 404
- [ ] Content-Type 正确

## 测试结果与分析 (2026-02-14)

### 1. 测试环境
- **Cluster**: 139.196.28.96
- **Scheduler Pod**: `nvshare-scheduler-97zbk`
- **Workload**: 4 active pods (`complex-test-*`)

### 2. 验证结果

| 检查项 | 结果 | 说明 |
| :--- | :--- | :--- |
| **Healthz Check** | ✅ PASS | HTTP 200 OK |
| **Metrics Endpoint** | ✅ PASS | HTTP 200 OK, Content-Type 正确 |
| **System Info** | ⚠️ VARIES | `nvshare_nvml_up` = 0 (见底下分析) |
| **Client Discovery** | ✅ PASS | 4 个客户端全部被 metrics 捕获 |
| **Scheduler State** | ✅ PASS | 队列状态正确 (2 running/GPU), 无积压 |
| **Event Counters** | ✅ PASS | 消息计数器正常工作 (`REQ_LOCK`, `MEM_UPDATE`) |
| **Managed Memory** | ✅ PASS | 数值准确 (~2.92 GiB per client) |

### 3. 问题分析

#### A. NVML 不可用 (`nvshare_nvml_up 0`)
- **现象**: `nvshare_nvml_up` 为 0，导致 GPU 型号、显存总量、利用率等指标缺失。
- **原因**: Scheduler Pod 在 `scheduler.yaml` 中未申请 GPU 资源，导致 NVIDIA Container Runtime 未将驱动库 (`libnvidia-ml.so`) 挂载到容器内。
- **修复建议**: 在 `scheduler.yaml` 的容器 spec 中添加环境变量 `NVIDIA_VISIBLE_DEVICES=all` 和 `NVIDIA_DRIVER_CAPABILITIES=utility`，或申请资源 `nvidia.com/gpu: 1`。

#### B. Host PID 映射失效 (`host_pid=1`)
- **现象**: 所有 Client 的 `host_pid` 均为 1。
- **原因**: 客户端代码运行在容器内，`getpid()` 返回的是容器 PID namespace 下的 PID (通常为1)。Scheduler 无法获知宿主机上的真实 PID。
- **影响**: `nvshare_client_nvml_used_bytes` 指标无法关联到具体的 GPU 进程（因为 NVML 使用宿主机 PID），导致该指标始终为 0。
- **改进建议**: 需要在协议中增加机制，让 Scheduler 通过 cgroup 或 K8s API 反查宿主机 PID，或者利用 Device Plugin 提供的机制。

#### C. DROP_LOCK 计数较高
- **现象**: `nvshare_scheduler_drop_lock_total` 计数 (284) 与 `LOCK_RELEASED` 相当。
- **分析**: 这表明 Scheduler 频繁向客户端发送 `DROP_LOCK`。在使用 `calc_switch_time` 的时间片轮转机制下，如果客户端持有锁的时间超过了时间片，Scheduler 会发送 `DROP_LOCK`。这在多任务并行且竞争激烈的场景下是正常的调度行为，但也提示我们客户端可能持有锁时间较长。

## 修复后测试结果 (2026-02-14 Post-Fix)

针对上述问题修复后，进行了第二轮验证。

### 1. 验证项状态

| 检查项 | 结果 | 说明 |
| :--- | :--- | :--- |
| **System Info** | ✅ PASS | `nvshare_nvml_up` = 1, GPU 信息完整 |
| **Host PID Mapping** | ✅ PASS | `host_pid` 显示真实宿主机 PID (如 `2057141`)，不再是 1 |
| **Metrics Accuracy** | ✅ PASS | 核心指标准确，Host PID 映射机制已工作 |

### 2. 详细数据样本

**NVML Status:**
```
nvshare_nvml_up 1
nvshare_gpu_info{...} 1
```

**Client Host PID:**
```
nvshare_client_info{..., host_pid="2057141"} 1
nvshare_client_info{..., host_pid="2057240"} 1
```
*(注：Host PID 已成功从 Unix Socket 的 SO_PEERCRED 获取)*

### 3. 结论
修复措施有效。Metrics 系统现已完全就绪，可准确反映 GPU 硬件状态并关联到宿主机进程。
