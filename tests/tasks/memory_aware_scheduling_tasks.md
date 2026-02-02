# 显存感知调度开发任务

基于 [memory_aware_scheduling_analysis.md](../memory_aware_scheduling_analysis.md) 的设计方案，制定以下开发任务。

---

## 阶段 1：显存追踪功能

### 任务 1.1：扩展消息协议

**文件**: `src/comm.h`

**目标**: 添加显存相关的消息类型

**详细步骤**:
1. 在 `enum message_type` 中添加新消息类型：
   - `MEM_UPDATE = 9` - Client 向 Scheduler 报告显存使用变化
   - `WAIT_FOR_MEM = 10` - Scheduler 告知 Client 显存不足，需等待
   - `MEM_AVAILABLE = 11` - Scheduler 告知 Client 显存可用，可以继续

2. 在 `struct message` 中添加显存字段：
   - `size_t memory_usage` - 当前显存使用量（字节）

**预计工时**: 0.5 小时

---

### 任务 1.2：扩展 Scheduler 数据结构

**文件**: `src/scheduler.c`

**目标**: 添加显存管理相关的数据结构

**详细步骤**:
1. 扩展 `struct nvshare_client`：
   ```c
   struct nvshare_client {
     // ... existing fields ...
     size_t memory_allocated;     // 当前分配的显存量
     int is_running;              // 是否在 GPU 上运行
     time_t last_scheduled_time;  // 上次被调度的时间
   };
   ```

2. 扩展 `struct gpu_context`：
   ```c
   struct gpu_context {
     // ... existing fields ...
     size_t total_memory;          // GPU 总显存
     size_t available_memory;      // 可用显存
     size_t running_memory_usage;  // 当前运行进程的显存使用
     struct nvshare_request* wait_queue;  // 等待显存的进程队列
   };
   ```

3. 添加调度器配置结构：
   ```c
   enum switch_time_mode {
     SWITCH_TIME_AUTO,   // 自动计算切换时间
     SWITCH_TIME_FIXED   // 固定切换时间
   };
   
   struct scheduler_config {
     enum switch_time_mode mode;
     int fixed_switch_time;    // 固定切换时间（秒）
     int time_multiplier;      // auto 模式的时间倍数（默认 5）
     int memory_reserve_percent; // 预留显存百分比
   };
   ```

**预计工时**: 1 小时

---

### 任务 1.3：修改 libnvshare 报告显存

**文件**: `src/hook.c`

**目标**: 在内存分配/释放时向 Scheduler 报告显存使用量

**详细步骤**:
1. 添加显存报告函数：
   ```c
   static void report_memory_usage_to_scheduler(size_t allocated) {
     struct message mem_msg = {0};
     mem_msg.type = MEM_UPDATE;
     mem_msg.memory_usage = allocated;
     // 发送至 scheduler
     nvshare_send_noblock(scheduler_fd, &mem_msg, sizeof(mem_msg));
   }
   ```

2. 修改 `cuMemAlloc` 函数，在分配成功后调用 `report_memory_usage_to_scheduler(sum_allocated)`

3. 修改 `cuMemFree` 函数，在释放成功后调用 `report_memory_usage_to_scheduler(sum_allocated)`

**预计工时**: 1 小时

---

### 任务 1.4：Scheduler 处理显存更新消息

**文件**: `src/scheduler.c`

**目标**: 处理客户端发送的 MEM_UPDATE 消息

**详细步骤**:
1. 在 `process_msg` 函数中添加 `MEM_UPDATE` case：
   ```c
   case MEM_UPDATE:
     client->memory_allocated = in_msg->memory_usage;
     ctx->running_memory_usage = calculate_total_running_memory(ctx);
     log_msg("Client %016" PRIx64 " memory update: %zu MB",
             client->id, client->memory_allocated / (1024*1024));
     break;
   ```

2. 添加辅助函数 `calculate_total_running_memory()`

**预计工时**: 1 小时

---

## 阶段 2：等待队列实现

### 任务 2.1：实现等待队列数据结构

**文件**: `src/scheduler.c`

**目标**: 实现等待队列的基本操作

**详细步骤**:
1. 添加等待队列操作函数：
   - `move_to_wait_queue(ctx, req)` - 将请求移到等待队列
   - `remove_from_wait_queue(ctx, req)` - 从等待队列移除
   - `get_next_waiting_request(ctx)` - 获取等待队列中的下一个请求

2. 使用 `utlist.h` 提供的链表宏实现队列操作

**预计工时**: 1 小时

---

### 任务 2.2：实现显存感知调度逻辑

**文件**: `src/scheduler.c`

**目标**: 修改调度逻辑以支持显存感知

**详细步骤**:
1. 添加显存检查函数：
   ```c
   static int can_colocate(struct gpu_context* ctx, struct nvshare_client* client) {
     size_t new_mem = client->memory_allocated;
     size_t current_usage = ctx->running_memory_usage;
     size_t safe_limit = ctx->total_memory * (100 - config.memory_reserve_percent) / 100;
     return (current_usage + new_mem) <= safe_limit;
   }
   ```

2. 重构 `try_schedule` 函数为 `try_schedule_with_memory`：
   - 检查显存是否充足
   - 显存充足时允许多任务并行
   - 显存不足时将请求移入等待队列

3. 添加从等待队列调度的逻辑

**预计工时**: 2 小时

---

### 任务 2.3：实现 WAIT_FOR_MEM 消息流程

**文件**: `src/scheduler.c`, `src/hook.c`

**目标**: 实现显存不足时的等待逻辑

**详细步骤**:
1. Scheduler 端：
   - 当显存不足时，发送 `WAIT_FOR_MEM` 消息
   - 将客户端加入等待队列
   - 当显存释放时，向等待客户端发送 `MEM_AVAILABLE`

2. Client 端（hook.c）：
   - 处理 `WAIT_FOR_MEM` 消息，进入等待状态
   - 处理 `MEM_AVAILABLE` 消息，恢复执行

**预计工时**: 2 小时

---

## 阶段 3：强制切换实现

### 任务 3.1：实现可配置的切换时间

**文件**: `src/scheduler.c`

**目标**: 支持 auto 和 fixed 两种切换时间模式

**详细步骤**:
1. 添加配置初始化函数 `init_config()`，读取环境变量：
   - `NVSHARE_SWITCH_TIME_MODE`
   - `NVSHARE_SWITCH_TIME_FIXED`
   - `NVSHARE_SWITCH_TIME_MULTIPLIER`
   - `NVSHARE_MEMORY_RESERVE_PERCENT`

2. 添加切换时间计算函数：
   ```c
   static int calculate_switch_time(struct gpu_context* ctx) {
     if (config.mode == SWITCH_TIME_FIXED) {
       return config.fixed_switch_time;
     }
     // Auto 模式：基于显存使用量计算
     size_t mem_gb = ctx->running_memory_usage / (1024 * 1024 * 1024);
     int swap_time = (int)(mem_gb > 0 ? mem_gb : 1);
     int switch_time = swap_time * config.time_multiplier;
     return MAX(10, MIN(300, switch_time));
   }
   ```

**预计工时**: 1 小时

---

### 任务 3.2：修改定时器线程支持显存感知

**文件**: `src/scheduler.c`

**目标**: 修改 timer_thr_fn 支持动态切换时间

**详细步骤**:
1. 在 `timer_thr_fn` 中使用 `calculate_switch_time()` 替代固定 TQ

2. 添加显存感知的切换逻辑：
   - 当定时器到期时，检查等待队列是否有进程
   - 如有等待进程，发送 `DROP_LOCK` 给当前进程
   - 将当前进程移入等待队列
   - 从等待队列调度下一个进程

**预计工时**: 2 小时

---

### 任务 3.3：实现进程暂停/恢复

**文件**: `src/scheduler.c`, `src/hook.c`

**目标**: 实现进程的优雅暂停和恢复

**详细步骤**:
1. 暂停进程：
   - Scheduler 发送 DROP_LOCK
   - Client 同步 CUDA 操作后释放锁

2. 恢复进程：
   - Scheduler 从等待队列选择进程
   - 发送 LOCK_OK
   - Client 恢复执行

**预计工时**: 1 小时

---

## 阶段 4：多任务并行优化

### 任务 4.1：实现并行调度

**文件**: `src/scheduler.c`

**目标**: 显存充足时允许多任务并行运行

**详细步骤**:
1. 修改调度逻辑，当新任务可以与现有任务共存时直接调度
2. 更新 `running_memory_usage` 跟踪
3. 不触发定时器重置

**预计工时**: 1.5 小时

---

## 验证计划

### 单元测试
- 测试消息协议的序列化/反序列化
- 测试等待队列的增删改查操作
- 测试切换时间计算函数

### 集成测试
1. **单进程显存报告测试**：
   - 启动单个 CUDA 进程
   - 验证 Scheduler 正确接收显存使用量
   
2. **多进程显存感知测试**：
   - 启动多个 CUDA 进程（总显存需求 > 物理显存）
   - 验证进程被正确分配到运行队列和等待队列
   
3. **强制切换测试**：
   - 设置较短的切换时间
   - 验证进程能够按时切换

4. **多任务并行测试**：
   - 启动多个小显存需求的进程（总需求 < 物理显存）
   - 验证所有进程同时运行

### 手动验证
使用现有的测试脚本 `.tests/scripts/` 进行验证

---

## 进度跟踪

| 任务 | 状态 | 完成时间 |
|------|------|----------|
| 1.1 扩展消息协议 | [ ] 待开始 | - |
| 1.2 扩展 Scheduler 数据结构 | [ ] 待开始 | - |
| 1.3 修改 libnvshare 报告显存 | [ ] 待开始 | - |
| 1.4 处理显存更新消息 | [ ] 待开始 | - |
| 2.1 实现等待队列 | [ ] 待开始 | - |
| 2.2 显存感知调度逻辑 | [ ] 待开始 | - |
| 2.3 WAIT_FOR_MEM 消息流程 | [ ] 待开始 | - |
| 3.1 可配置切换时间 | [ ] 待开始 | - |
| 3.2 修改定时器线程 | [ ] 待开始 | - |
| 3.3 进程暂停/恢复 | [ ] 待开始 | - |
| 4.1 多任务并行优化 | [ ] 待开始 | - |

**预计总工时**: 14 小时
