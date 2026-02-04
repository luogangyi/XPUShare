# 内存过载自动回退串行模式

## 问题背景
当前调度器使用任务报告的初始内存（如 2992 MB）来决定是否允许并发，但任务实际运行时可能使用更多内存（如 12 GB）。这导致：
- 调度器错误地允许多个任务并发运行
- 实际内存远超 GPU 容量，导致严重的 page faulting
- 性能下降 150 倍（25 it/s → 0.17 it/s）

## 设计方案

### 核心思路
1. 在 `gpu_context` 中添加 `memory_overloaded` 标志
2. 当 `MEM_UPDATE` 消息显示实际内存超过安全限制时，设置此标志
3. 一旦检测到过载，立即向所有运行中的任务发送 `DROP_LOCK`，强制回退到串行模式
4. 后续调度使用串行逻辑，直到所有任务完成

### 实现步骤

#### 1. 修改 `gpu_context` 结构体
```c
struct gpu_context {
  // ... existing fields ...
  int memory_overloaded;       /* Set to 1 when memory overload detected */
  size_t peak_memory_usage;    /* Track peak memory for diagnostics */
};
```

#### 2. 修改 `MEM_UPDATE` 处理
当收到内存更新时，检查总内存是否超过安全限制：
```c
case MEM_UPDATE:
  // ... update memory ...
  if (ctx->running_memory_usage > safe_limit && !ctx->memory_overloaded) {
    ctx->memory_overloaded = 1;
    log_warn("Memory overload detected on GPU %s: %zu MB > %zu MB limit",
             ctx->uuid, ctx->running_memory_usage / MB, safe_limit / MB);
    // Trigger preemption to fall back to serial mode
    force_preemption(ctx);
  }
```

#### 3. 添加 `force_preemption()` 函数
向所有运行中的任务发送 `DROP_LOCK`，强制释放锁：
```c
static void force_preemption(struct gpu_context* ctx) {
  struct nvshare_request *r, *tmp;
  struct message msg = { .type = DROP_LOCK };
  
  LL_FOREACH_SAFE(ctx->running_list, r, tmp) {
    send_message(r->client, &msg);
  }
  log_info("Forced preemption on GPU %s due to memory overload", ctx->uuid);
}
```

#### 4. 修改 `can_run_with_memory()` 
当检测到过载时，使用串行逻辑：
```c
static int can_run_with_memory(struct gpu_context* ctx, struct nvshare_client* client) {
  // If memory overload was detected, use serial mode
  if (ctx->memory_overloaded) {
    if (ctx->lock_held) {
      log_debug("Overload fallback: GPU %s in serial mode", ctx->uuid);
      return 0;
    }
    return 1;
  }
  // ... rest of original logic ...
}
```

## 验证计划
1. 使用 `remote-test.sh 4`（不加 --serial）测试
2. 预期：检测到过载后自动回退串行，性能恢复
3. 检查日志确认过载检测和回退逻辑被触发
