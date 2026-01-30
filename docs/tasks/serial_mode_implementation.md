# 实现计划：Per-GPU 串行/智能执行模式 + GPU 负载均衡

## 目标

1. **智能调度模式**：显存充足时并发执行，超卖时自动切换为串行
2. **最大运行时长**：任务最长运行 5 分钟（可配置），到期后强制切换
3. **强制 Swap-Out**：切换时主动驱逐上一个任务的显存，减少新任务的 Page Fault
4. **Device-Plugin 负载均衡**：任务尽可能分配到不同 GPU

---

## Proposed Changes

### Component 1: Scheduler 智能调度

#### [MODIFY] [scheduler.c](file:///Users/luogangyi/Code/nvshare/src/scheduler.c)

**1. 新增配置项**

```c
struct scheduler_config {
  // 现有字段...
  int serial_mode;              // 0=auto(智能), 1=serial(强制串行), 2=concurrent(强制并发)
  int max_runtime_sec;          // 最大运行时长（秒），默认 300
};
```

**环境变量**：
- `NVSHARE_SCHEDULING_MODE`: `auto` (默认) | `serial` | `concurrent`
- `NVSHARE_MAX_RUNTIME_SEC`: 默认 300 秒

**2. 智能模式逻辑**

```c
// 判断是否可以并发运行
static int should_allow_concurrent(struct gpu_context* ctx, struct nvshare_client* client) {
  // 如果强制串行模式
  if (config.serial_mode == 1) return 0;
  // 如果强制并发模式
  if (config.serial_mode == 2) return 1;
  
  // 智能模式: 检查显存是否足够
  size_t safe_limit = ctx->total_memory * (100 - config.memory_reserve_percent) / 100;
  size_t needed = ctx->running_memory_usage + client->memory_allocated;
  
  return (needed <= safe_limit);
}
```

**3. 最大运行时长**

修改 `timer_thr_fn()`：
- 使用 `max_runtime_sec` 替代原有的 TQ
- 到期后仍然发送 `DROP_LOCK`，但在智能模式下如果无人等待则延长

**4. 强制 Swap-Out（新增消息类型）**

```c
// comm.h 新增
enum message_type {
  // ...
  PREPARE_SWAP_OUT,  // Scheduler -> Client: 准备将数据 swap 出去
};
```

在 `client.c` 处理：调用 `cuMemAdvise(..., CU_MEM_ADVISE_SET_PREFERRED_LOCATION, cudaCpuDeviceId)` 提示驱动将数据移到 Host。

---

### Component 2: Client Swap-Out 支持

#### [MODIFY] [client.c](file:///Users/luogangyi/Code/nvshare/src/client.c)

**新增消息处理**

```c
case PREPARE_SWAP_OUT:
  log_info("Received PREPARE_SWAP_OUT, hinting driver to evict memory");
  // 遍历所有分配的内存，提示移到 Host
  struct cuda_mem_allocation* alloc;
  LL_FOREACH(cuda_allocation_list, alloc) {
    cuMemAdvise(alloc->ptr, alloc->size, 
                CU_MEM_ADVISE_SET_PREFERRED_LOCATION, 
                cudaCpuDeviceId);
  }
  // 同步确保生效
  real_cuCtxSynchronize();
  break;
```

#### [MODIFY] [hook.c](file:///Users/luogangyi/Code/nvshare/src/hook.c)

- 添加 `cuMemAdvise` 函数符号加载

---

### Component 3: Device-Plugin GPU 负载均衡

#### [MODIFY] [server.go](file:///Users/luogangyi/Code/nvshare/kubernetes/device-plugin/server.go)

- 启用 `GetPreferredAllocationAvailable: true`
- 实现 `GetPreferredAllocation()`: 追踪每 GPU 分配数，优先选择最少的

---

## Verification Plan

### 测试 1: 智能模式

```bash
# 启用智能模式（默认）
kubectl set env daemonset/nvshare-scheduler -n nvshare NVSHARE_SCHEDULING_MODE=auto

# 场景 A: 显存充足（如 2 个小任务各 4GB，GPU 16GB）
# 预期: 并发执行

# 场景 B: 显存超卖（如 2 个大任务各 12GB，GPU 16GB）
# 预期: 串行执行
```

### 测试 2: 最大运行时长

```bash
kubectl set env daemonset/nvshare-scheduler -n nvshare NVSHARE_MAX_RUNTIME_SEC=60

# 启动一个长任务和一个短任务
# 预期: 长任务运行 60 秒后被切换
```

### 测试 3: 多 GPU 负载均衡

```bash
# 在多 GPU 节点上创建多个任务
# 预期: 任务分布在不同 GPU 上
```
