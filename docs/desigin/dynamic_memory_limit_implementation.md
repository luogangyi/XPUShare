# 动态显存配额调整实现方案 (Annotations)

## 目标

实现通过 `kubectl annotate` 动态调整 Pod 显存限制，无需重启 Pod。

```bash
# 动态调整示例
kubectl annotate pod my-pod nvshare.com/gpu-memory-limit=8Gi --overwrite
```

---

## 架构概览

```
kubectl annotate pod xxx ...
        │
        ▼
   Scheduler Node
   ┌────────────────────────────────────────┐
   │  DaemonSet Pod (nvshare-scheduler)     │
   │  • 周期性读取 Pod annotations           │
   │  • 检测变化时发送 UPDATE_LIMIT 消息     │
   └────────────────────────────────────────┘
        │ Unix Socket
        ▼
   Container (libnvshare.so)
   ┌────────────────────────────────────────┐
   │  client.c: 处理 UPDATE_LIMIT 消息      │
   │  hook.c: 使用新的 memory_limit         │
   └────────────────────────────────────────┘
```

---

## 实现步骤

### Phase 1: 协议扩展

#### [MODIFY] [comm.h](file:///Users/luogangyi/Code/nvshare/src/comm.h)

添加新消息类型：
```c
enum message_type {
  // ... 现有类型 ...
  UPDATE_LIMIT = 13,    /* Scheduler -> Client: 更新显存限制 */
};
```

扩展 message 结构体：
```c
struct message {
  // ... 现有字段 ...
  size_t memory_limit;  /* 新增: 显存限制 (bytes), 0 = 无限制 */
};
```

---

### Phase 2: Scheduler 修改

#### [MODIFY] [scheduler.c](file:///Users/luogangyi/Code/nvshare/src/scheduler.c)

1. **新增 client 字段**: 存储 pod annotation 中的显存限制
```c
struct nvshare_client {
  // ... 现有字段 ...
  size_t memory_limit;         /* 从 annotation 读取的限制 */
  time_t last_annotation_check; /* 上次检查时间 */
};
```

2. **新增 annotation 监控线程**:
```c
void* annotation_watcher_fn(void* arg);
```

3. **实现 Kubernetes API 调用**:
   - 使用 Downward API 文件或 libcurl 调用 API Server
   - 读取 `nvshare.com/gpu-memory-limit` annotation

4. **发送 UPDATE_LIMIT 消息**:
```c
void send_update_limit(struct nvshare_client* client, size_t new_limit);
```

---

### Phase 3: Client 修改

#### [MODIFY] [client.c](file:///Users/luogangyi/Code/nvshare/src/client.c)

处理 UPDATE_LIMIT 消息：
```c
case UPDATE_LIMIT:
  log_info("Received UPDATE_LIMIT: %zu bytes", in_msg.memory_limit);
  update_memory_limit(in_msg.memory_limit);
  break;
```

#### [MODIFY] [hook.c](file:///Users/luogangyi/Code/nvshare/src/hook.c)

1. 添加线程安全的限制更新：
```c
extern pthread_mutex_t limit_mutex;
extern void update_memory_limit(size_t new_limit);
```

2. 修改 `cuMemAlloc` 使用互斥锁保护 `memory_limit` 读取

---

### Phase 4: Scheduler 部署修改

#### [MODIFY] DaemonSet ServiceAccount

需要添加 RBAC 权限读取 Pod annotations：
```yaml
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

---

## 简化方案 (Phase 1 MVP)

考虑到 Scheduler 访问 K8s API 的复杂度，可以先实现简化版本：

### 方案 A: 通过 Downward API 投射 Annotation

Pod 挂载 annotation 为文件，Client 直接读取：
```yaml
volumes:
- name: podinfo
  downwardAPI:
    items:
    - path: "memory-limit"
      fieldRef:
        fieldPath: metadata.annotations['nvshare.com/gpu-memory-limit']
```

Client 周期性读取 `/etc/podinfo/memory-limit` 文件。

> [!WARNING]
> Downward API 无法直接投射 annotation 到文件（只支持 labels）

### 方案 B: Client 直接轮询文件 (推荐 MVP)

1. Pod 挂载 ConfigMap 作为配置文件
2. 运维人员修改 ConfigMap 
3. Client 用 inotify 监听文件变化

---

## 验证计划

### 手动测试
```bash
# 1. 创建带 annotation 的 Pod
kubectl apply -f tests/kubernetes/manifests/nvshare-memlimit-test.yaml

# 2. 验证初始限制生效
kubectl logs <pod>

# 3. 动态修改 annotation
kubectl annotate pod <pod> nvshare.com/gpu-memory-limit=8Gi --overwrite

# 4. 观察 scheduler 日志确认检测到变化
kubectl logs -n nvshare-system <scheduler-pod>

# 5. 在 Pod 中分配内存验证新限制
kubectl exec <pod> -- python -c "import torch; ..."
```

---

## 风险与限制

| 风险 | 影响 | 缓解措施 |
|-----|------|---------|
| Scheduler 需要 K8s API 访问权限 | 增加部署复杂度 | RBAC 配置文档 |
| API Server 轮询延迟 | 限制更新不是实时 | 记录日志供排查 |
| 已分配内存不会回收 | 降低限制不会立即生效 | 文档说明 |
