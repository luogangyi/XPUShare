# 显存感知调度方案分析

## 1. 用户方案概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       用户提出的显存感知调度方案                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. 进程 A 先申请到全部显存，开始运行                                        │
│  2. 进程 B 申请显存，发现不够 → 留在系统内存，不调度执行                     │
│  3. A 运行超过时间阈值 T → 强制切换：A 暂停，B 开始运行                      │
│  4. B 运行超过时间阈值 T → 强制切换：B 暂停，A 恢复运行                      │
│  5. 循环往复，保证所有进程都能得到运行                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

**核心思想**：
- 避免多进程同时占用显存导致的页面抖动
- 通过时间片强制切换保证公平性
- 等待进程只占用系统内存，不参与 GPU 调度

---

## 2. 与现有方案对比

| 特性 | 当前 nvshare | 用户方案 | 差异 |
|------|--------------|----------|------|
| 内存分配 | 多进程同时分配 Managed Memory | 当前运行进程独占显存 | ✓ 避免抖动 |
| 调度策略 | FCFS + TQ 时间片 | 显存感知 + 强制切换 | ✓ 更智能 |
| 等待进程 | 在 GPU 上等待页面迁移 | 在系统内存中等待 | ✓ 减少开销 |
| 切换触发 | TQ 到期 + `DROP_LOCK` | TQ 到期 + 显存不足 | ≈ 类似 |

---

## 3. 方案分析

### 3.1 优点

#### ✅ 消除显存抖动
```
当前方案：
  Pod A (12GB) + Pod B (12GB) + Pod C (12GB) = 36GB 同时在 GPU
  → 物理显存 16GB 不够 → 频繁页面迁移 → 性能暴跌

用户方案：
  时刻 1：Pod A (12GB) 独占 GPU，B/C 在系统内存等待
  时刻 2：Pod B (12GB) 独占 GPU，A/C 在系统内存等待
  → 无抖动，性能稳定
```

#### ✅ 保证公平性
- 强制时间切换确保所有进程都能获得 GPU 时间
- 避免"饥饿"问题

#### ✅ 简化实现
- 可以在现有 scheduler 基础上扩展
- 主要修改：显存感知 + 等待队列管理

### 3.2 缺点与挑战

#### ⚠️ 挑战 1：显存使用量获取

**问题**：如何知道每个进程需要多少显存？

**方案**：采用 **libnvshare 自报告** 机制

| 方案 | 优点 | 缺点 |
|------|------|------|
| **进程自报告（采用）** | 精确、实时更新 | 需修改 libnvshare |
| ~~预声明（Pod annotation）~~ | ~~简单~~ | ~~不灵活、不准确~~ |
| ~~NVML 查询~~ | ~~无需改客户端~~ | ~~Unified Memory 统计不准~~ |

**实现方式**：libnvshare 在每次 `cuMemAlloc` 和 `cuMemFree` 后向 scheduler 报告当前显存使用量

```c
// libnvshare hook.c: 在内存分配/释放后报告
CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
  // ... 分配逻辑 ...
  
  if (result == CUDA_SUCCESS) {
    insert_cuda_allocation(*dptr, bytesize);
    
    // 新增：通知 scheduler 显存变化
    report_memory_usage_to_scheduler(sum_allocated);
  }
  return result;
}

CUresult cuMemFree(CUdeviceptr dptr) {
  // ... 释放逻辑 ...
  
  if (result == CUDA_SUCCESS) {
    remove_cuda_allocation(dptr);
    
    // 新增：通知 scheduler 显存变化
    report_memory_usage_to_scheduler(sum_allocated);
  }
  return result;
}
```

**优势**：
1. **精确**：基于实际 CUDA 内存分配，而非估算
2. **实时**：每次分配/释放都更新，scheduler 掌握最新状态
3. **无预设**：不需要用户在 Pod 中预声明显存需求

#### ⚠️ 挑战 2：切换时机的确定

**问题**：什么时候强制切换？

```
情况 1：A 运行 30s，B 等待
  → A 到期，切换到 B ✓

情况 2：A 运行 5s 就完成了
  → 不需要等 30s，立即调度 B ✓

情况 3：A 运行中，B 申请更多显存
  → A 的剩余时间如何处理？
```

**建议**：引入"显存释放事件"触发调度

#### ⚠️ 挑战 3：多 GPU 调度

**问题**：如何在多 GPU 间分配任务？

```
GPU 0: Pod A (12GB) 运行中
GPU 1: 空闲

Pod B (12GB) 申请：
  → 应该去 GPU 1，而不是等 GPU 0
```

**建议**：优先分配到空闲 GPU，全忙时再排队

#### ⚠️ 挑战 4：进程上下文保存

**问题**：A 被暂停时，其 GPU 上的数据怎么办？

- CUDA Unified Memory 会自动将数据迁移到系统内存
- 但这个迁移过程也需要时间
- 如果 A 分配了 12GB，迁移需要 ~5-10 秒

**建议**：在切换时预留缓冲时间

---

## 4. 改进方案

### 4.1 架构设计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        改进后的调度器架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────┐      ┌─────────────────────────────────┐                 │
│   │ libnvshare  │◄────►│         Scheduler               │                 │
│   │  (client)   │      │  ┌───────────────────────────┐  │                 │
│   └─────────────┘      │  │     Memory Tracker        │  │                 │
│         │              │  │  - per-client mem usage   │  │                 │
│         │              │  │  - total GPU mem          │  │                 │
│         ▼              │  └───────────────────────────┘  │                 │
│   ┌─────────────┐      │  ┌───────────────────────────┐  │                 │
│   │    GPU      │      │  │    Ready Queue            │  │                 │
│   │  (物理)     │      │  │  [clients that fit]       │  │                 │
│   └─────────────┘      │  └───────────────────────────┘  │                 │
│                        │  ┌───────────────────────────┐  │                 │
│                        │  │    Wait Queue             │  │                 │
│                        │  │  [clients that don't fit] │  │                 │
│                        │  └───────────────────────────┘  │                 │
│                        └─────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 核心数据结构

```c
// scheduler.c 扩展

struct nvshare_client {
  // ... existing fields ...
  
  // 新增：显存使用信息
  size_t memory_allocated;     // 当前分配的显存量
  size_t memory_declared;      // 预声明的显存需求（可选）
  int is_running;              // 是否在 GPU 上运行
  time_t last_scheduled_time;  // 上次被调度的时间
};

struct gpu_context {
  // ... existing fields ...
  
  // 新增：显存管理
  size_t total_memory;          // GPU 总显存
  size_t available_memory;      // 可用显存
  size_t running_memory_usage;  // 当前运行进程的显存使用
  
  // 新增：等待队列
  struct nvshare_request* wait_queue;  // 等待显存的进程
};
```

### 4.3 调度算法

```c
// 改进的调度函数
static void try_schedule_with_memory(struct gpu_context* ctx) {
  struct nvshare_request* current = ctx->requests;
  struct nvshare_request* waiting = ctx->wait_queue;
  
  // 情况 1：无任何请求
  if (current == NULL && waiting == NULL) {
    return;
  }
  
  // 情况 2：当前有运行进程
  if (ctx->lock_held && current != NULL) {
    size_t running_mem = current->client->memory_allocated;
    
    // 检查是否超时
    time_t now = time(NULL);
    if (now - current->client->last_scheduled_time >= tq) {
      // 检查等待队列中是否有需要运行的进程
      if (waiting != NULL) {
        // 强制切换：暂停当前进程
        send_message(current->client, &drop_lock_msg);
        
        // 将当前进程移到等待队列
        move_to_wait_queue(ctx, current);
        
        // 从等待队列选择下一个进程
        schedule_from_wait_queue(ctx);
      }
    }
    return;
  }
  
  // 情况 3：无运行进程，尝试调度
  // 优先从等待队列中选择（保证公平性）
  if (waiting != NULL) {
    size_t needed_mem = waiting->client->memory_allocated;
    if (needed_mem <= ctx->available_memory) {
      schedule_client(ctx, waiting);
      return;
    }
  }
  
  // 从新请求中选择
  if (current != NULL) {
    size_t needed_mem = current->client->memory_allocated;
    if (needed_mem <= ctx->available_memory) {
      schedule_client(ctx, current);
    } else {
      // 显存不足，移到等待队列
      move_to_wait_queue(ctx, current);
    }
  }
}
```

### 4.4 消息协议扩展

```c
// comm.h 新增消息类型

enum message_type {
  // ... existing types ...
  
  MEM_UPDATE,      // Client -> Scheduler: 报告显存使用变化
  WAIT_FOR_MEM,    // Scheduler -> Client: 显存不足，等待
  MEM_AVAILABLE,   // Scheduler -> Client: 显存可用，可以继续
};

struct message {
  // ... existing fields ...
  size_t memory_usage;  // 新增：显存使用量
};
```

### 4.5 客户端修改

```c
// hook.c 修改

CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
  // ... existing logic ...
  
  if (result == CUDA_SUCCESS) {
    insert_cuda_allocation(*dptr, bytesize);
    
    // 新增：通知 scheduler 显存变化
    struct message mem_msg = {
      .type = MEM_UPDATE,
      .memory_usage = sum_allocated
    };
    nvshare_send(scheduler_fd, &mem_msg, sizeof(mem_msg));
  }
  
  return result;
}

// 新增：等待显存分配的逻辑
static int wait_for_memory(void) {
  struct message msg;
  
  // 告诉 scheduler 我需要多少显存
  msg.type = MEM_UPDATE;
  msg.memory_usage = sum_allocated;
  nvshare_send(scheduler_fd, &msg, sizeof(msg));
  
  // 等待 scheduler 的响应
  nvshare_receive(scheduler_fd, &msg, sizeof(msg));
  
  if (msg.type == WAIT_FOR_MEM) {
    // 进入等待状态，不执行 GPU 操作
    wait_for_mem_available();
    return 0;
  }
  
  return 0;
}
```

---

## 5. 实现步骤

### 阶段 1：显存追踪（1-2 周）

| 任务 | 优先级 | 复杂度 |
|------|--------|--------|
| 扩展 scheduler 数据结构 | 高 | 低 |
| 添加 MEM_UPDATE 消息处理 | 高 | 中 |
| 修改 libnvshare 报告显存 | 高 | 低 |

### 阶段 2：等待队列（1-2 周）

| 任务 | 优先级 | 复杂度 |
|------|--------|--------|
| 实现等待队列数据结构 | 高 | 低 |
| 修改 try_schedule 逻辑 | 高 | 中 |
| 添加 WAIT_FOR_MEM 消息 | 中 | 低 |

### 阶段 3：强制切换（1 周）

| 任务 | 优先级 | 复杂度 |
|------|--------|--------|
| 修改 timer_thr_fn 添加显存感知 | 高 | 中 |
| 实现进程暂停/恢复逻辑 | 高 | 中 |
| 添加切换缓冲时间 | 中 | 低 |

---

## 6. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 显存报告不准确 | 中 | 高 | 添加校验，使用 NVML 辅助 |
| 切换开销过大 | 中 | 中 | 增大时间片，减少切换频率 |
| 死锁 | 低 | 高 | 添加超时机制 |
| 饥饿（大任务阻塞小任务） | 中 | 中 | 优先级队列 + 最大等待时间 |

---

## 7. 性能预期

| 场景 | 当前方案 | 改进方案 | 提升 |
|------|----------|----------|------|
| 4 Pod × 12GB（超分） | ~15 小时 | ~4 × 1 小时 = 4 小时 | **~4x** |
| 2 Pod × 12GB（无超分） | ~2 小时 | ~2 小时 | 持平 |
| 10 Pod × 1GB（轻量） | ~30 分钟 | ~30 分钟 | 持平 |

---

## 8. 增强特性

### 8.1 可配置的强制切换时间

**需求**：强制切换时间应该做成参数，支持灵活配置

#### 配置方式

```yaml
# scheduler 配置（环境变量或配置文件）
NVSHARE_SWITCH_TIME_MODE: "auto"  # 可选: "auto" | "fixed"
NVSHARE_SWITCH_TIME_FIXED: 60     # 固定模式下的切换时间（秒）
NVSHARE_SWITCH_TIME_MULTIPLIER: 5 # auto 模式下的时间倍数
```

#### 实现

```c
// scheduler.c 新增配置

// 切换时间模式
enum switch_time_mode {
  SWITCH_TIME_AUTO,   // 自动计算
  SWITCH_TIME_FIXED   // 固定值
};

struct scheduler_config {
  enum switch_time_mode mode;
  int fixed_switch_time;    // 固定切换时间（秒）
  int time_multiplier;      // auto 模式的时间倍数（默认 5）
};

static struct scheduler_config config = {
  .mode = SWITCH_TIME_AUTO,
  .fixed_switch_time = 60,
  .time_multiplier = 5
};

// 初始化时读取配置
static void init_config(void) {
  char* mode = getenv("NVSHARE_SWITCH_TIME_MODE");
  if (mode && strcmp(mode, "fixed") == 0) {
    config.mode = SWITCH_TIME_FIXED;
  }
  
  char* fixed_time = getenv("NVSHARE_SWITCH_TIME_FIXED");
  if (fixed_time) {
    config.fixed_switch_time = atoi(fixed_time);
  }
  
  char* multiplier = getenv("NVSHARE_SWITCH_TIME_MULTIPLIER");
  if (multiplier) {
    config.time_multiplier = atoi(multiplier);
  }
}
```

---

### 8.2 Auto 模式：基于置换时间自动计算

**原理**：切换时间应该让任务有足够的有效运行时间，避免切换开销成为主要因素

#### 计算公式

```
切换时间 = 置换时间 × 时间倍数

其中：
  置换时间 = 需置换显存大小 / PCIe 带宽
  时间倍数 = 5（默认）
```

#### 示例

| 需置换显存 | 估算带宽 | 置换时间 | 切换时间（5x） |
|------------|----------|----------|----------------|
| 10 GB | ~10 GB/s (PCIe 3.0 x16) | ~1s | **5s** |
| 10 GB | ~1 GB/s (实际受限) | ~10s | **50s** |
| 12 GB | ~1 GB/s | ~12s | **60s** |

> [!NOTE]
> 实际置换带宽受多因素影响：PCIe 版本、负载、CUDA 驱动优化等。
> 建议使用保守估计（~1 GB/s）计算。

#### 实现

```c
// 计算切换时间
static int calculate_switch_time(struct gpu_context* ctx) {
  if (config.mode == SWITCH_TIME_FIXED) {
    return config.fixed_switch_time;
  }
  
  // Auto 模式：基于显存使用量计算
  // 估算置换时间 = 显存量(GB) / 估算带宽(1 GB/s)
  size_t mem_to_swap_gb = ctx->running_memory_usage / (1024 * 1024 * 1024);
  int swap_time_sec = (int)mem_to_swap_gb;  // 假设 1 GB/s 带宽
  
  // 最小置换时间保底 1 秒
  if (swap_time_sec < 1) swap_time_sec = 1;
  
  // 切换时间 = 置换时间 × 倍数
  int switch_time = swap_time_sec * config.time_multiplier;
  
  // 设置最小/最大边界
  if (switch_time < 10) switch_time = 10;   // 最小 10 秒
  if (switch_time > 300) switch_time = 300; // 最大 5 分钟
  
  log_debug("Auto switch time: %d sec (mem=%zu MB, swap=%d sec, multiplier=%d)",
            switch_time, ctx->running_memory_usage / (1024*1024), 
            swap_time_sec, config.time_multiplier);
  
  return switch_time;
}

// 修改 timer 线程
void* timer_thr_fn(void* arg) {
  struct gpu_context* ctx = (struct gpu_context*)arg;
  // ...
  
  while (1) {
    // 动态计算切换时间
    int switch_time = calculate_switch_time(ctx);
    timer_end_ts.tv_sec = now.tv_sec + switch_time;
    
    // ... 其余逻辑不变
  }
}
```

---

### 8.3 多任务显存优化：优先使用显存

**原理**：如果 GPU 显存能容纳多个任务，让它们同时在显存中运行，避免不必要的置换

#### 调度策略

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        多任务显存优化策略                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  情况 1：显存充足                                                            │
│    GPU 显存: 16 GB                                                          │
│    Pod A: 4 GB, Pod B: 4 GB, Pod C: 4 GB                                   │
│    总需求: 12 GB < 16 GB                                                    │
│    → 三个 Pod 同时在 GPU 显存中运行，无需切换                               │
│                                                                             │
│  情况 2：显存不足                                                            │
│    GPU 显存: 16 GB                                                          │
│    Pod A: 12 GB, Pod B: 12 GB                                               │
│    总需求: 24 GB > 16 GB                                                    │
│    → 只有一个 Pod 在显存中运行，另一个等待切换                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 实现

```c
// 判断是否可以并行运行多个任务
static int can_colocate(struct gpu_context* ctx, struct nvshare_client* new_client) {
  size_t new_mem = new_client->memory_allocated;
  size_t current_usage = ctx->running_memory_usage;
  
  // 预留 10% 显存给系统开销
  size_t safe_limit = ctx->total_memory * 90 / 100;
  
  return (current_usage + new_mem) <= safe_limit;
}

// 改进的调度函数
static void try_schedule_with_memory(struct gpu_context* ctx) {
  // ... 前面的逻辑 ...
  
  // 情况 4：当前有运行进程，尝试添加新进程（多任务并行）
  if (ctx->lock_held && ctx->requests != NULL) {
    struct nvshare_request* new_req = get_next_waiting_request(ctx);
    
    if (new_req && can_colocate(ctx, new_req->client)) {
      // 显存充足，允许新进程加入
      log_info("Collocating client %016" PRIx64 " (mem=%zu MB) with existing running tasks",
               new_req->client->id, new_req->client->memory_allocated / (1024*1024));
      
      schedule_client_parallel(ctx, new_req);
      
      // 更新显存使用
      ctx->running_memory_usage += new_req->client->memory_allocated;
      
      return;
    }
  }
  
  // ... 后续逻辑：如果无法并行，则进入等待队列
}

// 并行调度：不抢占现有任务，直接加入运行
static void schedule_client_parallel(struct gpu_context* ctx, 
                                     struct nvshare_request* req) {
  out_msg.type = LOCK_OK;
  send_message(req->client, &out_msg);
  
  req->client->is_running = 1;
  req->client->last_scheduled_time = time(NULL);
  
  // 从等待队列移除
  remove_from_wait_queue(ctx, req);
}
```

#### 调度流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           新任务调度流程                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                          新任务 B 请求调度
                                    │
                                    ▼
                      ┌──────────────────────────┐
                      │ 当前显存够放 A + B 吗？   │
                      └──────────────────────────┘
                          │              │
                         是             否
                          │              │
                          ▼              ▼
              ┌─────────────────┐  ┌─────────────────┐
              │ B 加入 GPU 运行 │  │ B 进入等待队列  │
              │ 无需切换        │  │ 等 A 超时或完成 │
              └─────────────────┘  └─────────────────┘
```

---

### 8.4 环境变量配置汇总

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `NVSHARE_SWITCH_TIME_MODE` | `auto` | 切换时间模式：`auto` 或 `fixed` |
| `NVSHARE_SWITCH_TIME_FIXED` | `60` | 固定模式下的切换时间（秒） |
| `NVSHARE_SWITCH_TIME_MULTIPLIER` | `5` | Auto 模式的时间倍数 |
| `NVSHARE_MEMORY_RESERVE_PERCENT` | `10` | 预留显存百分比（用于系统开销） |

---

## 9. 结论

用户提出的方案是一个**可行且有效**的改进方向。本文档在此基础上新增了三项增强特性：

| 特性 | 描述 | 收益 |
|------|------|------|
| **可配置切换时间** | 支持 `auto` 和 `fixed` 两种模式 | 灵活适配不同场景 |
| **Auto 模式智能计算** | 基于置换时间 × 5 倍估算 | 确保有效运行时间 |
| **多任务显存优化** | 显存充足时多任务并行 | 避免不必要的切换 |

**最终调度策略**：

1. 新任务到达 → 检查显存是否充足
2. **充足**：加入 GPU 并行运行（无切换）
3. **不足**：进入等待队列
4. 当前任务超时 → 强制切换（时间由 `auto` 或 `fixed` 决定）
5. 循环调度，保证公平性

建议按照上述实现步骤分阶段推进，先实现显存追踪和多任务并行，再实现可配置的强制切换时间。

---

## 10. 进一步审查与改进建议

基于 `docs/gpu_sharing_performance_analysis.md` 的根因分析（Unified Memory 抖动、NVML 缺失、上下文开销），对本方案进行深度审查并提出以下修正：

### 10.1 修正：显存安全阈值计算

**问题**：原方案建议预留 10% 显存（`safe_limit = total * 90%`）。
**分析**：性能报告指出每个 CUDA 进程即使不分配显存，仅 Context 就占用 ~300-500MB。如果有 10 个进程，光 Context 就可能占用 3-5GB。固定百分比预留可能在多进程场景下导致 OOM。

**改进**：动态计算安全阈值

```c
// 估算系统开销
size_t estimated_overhead = 0;
// 固定系统预留 (e.g. 500MB)
estimated_overhead += 500 * 1024 * 1024;
// 每个活跃进程预留 (e.g. 300MB)
estimated_overhead += ctx->active_process_count * 300 * 1024 * 1024;

size_t safe_limit = ctx->total_memory - estimated_overhead;
```

### 10.2 优化：使用 `cuMemPrefetchAsync` 减少被动抖动

**问题**：也就是方案中的"显存置换"。当前方案依赖 CUDA 驱动的"按需分页（Demand Paging）"。当进程切换时，新进程访问内存触发 Page Fault，驱动逐页迁移。
**风险**：这会导致切换初期 GPU 利用率波动，且置换时间难以精确预测。

**改进**：在切换时主动预取（可选的高级特性）

```c
// 在恢复进程运行前
if (enable_prefetch) {
   // 提示驱动将该进程的内存预取到 GPU
   // 注意：需要遍历 allocation list，可能增加复杂性
   cuMemPrefetchAsync(ptr, size, gpu_device, stream);
}
```

*注：鉴于实现复杂度，建议作为后期优化特性，初期仍依赖按需分页。*

### 10.3 确认：自报告机制的鲁棒性

**分析**：性能报告指出环境中缺少 `nvmlDeviceGetHandleByUUID_v2` 导致 NVML 不可用。
**评估**：本方案采用 `libnvshare` 拦截自报告显存使用量，**完全不依赖 NVML**。这是一个巨大的优势，确保了方案在当前缺陷环境下的可用性。

### 10.4 策略：应对 "Bad Case"

**场景**：如果用户代码申请了 16GB 显存（Virtual），但实际只用了 1GB（Physical）。
**当前方案**：调度器会认为它占用了 16GB，从而阻止其他进程运行。
**评价**：这是为了稳定性必须付出的代价（Conservative Policy）。在 Unified Memory 场景下，"逻辑申请量"是唯一安全的并发控制指标。如果按物理使用量调度，一旦进程突然真正使用这 16GB，将立即导致严重的 Thrashing。因此，**维持保守调度策略是正确的**。
