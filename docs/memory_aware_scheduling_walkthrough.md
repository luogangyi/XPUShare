# 显存感知调度实现总结

我们已经成功完成了 **显存感知调度 (Memory-Aware Scheduling)** 的核心功能开发。该功能解决了当多个大显存任务竞争 GPU 时可能发生的 OOM 崩溃问题，并引入了更智能的动态时间片调度。

## 主要变更

### 1. 显存追踪 (Memory Tracking)
- **协议扩展**: 在通信协议中添加了 `MEM_UPDATE` 消息类型，允许客户端实时向调度器报告显存使用量。
- **Client/Hook**: 修改了 `libnvshare` (`hook.c`, `client.c`)，在 CUDA 内存分配 (`cuMemAlloc`) 和释放 (`cuMemFree`) 时自动拦截并向调度器发送更新。
- **Scheduler**: 调度器现在维护每个 GPU 上下文的 `total_memory` 和 `running_memory_usage`。

### 2. 准入控制 (Admission Control)
- **等待队列**: 在调度器中实现了 `wait_queue`。当新的任务请求 GPU 锁时，系统会检查当前剩余显存是否足以支持该任务。
- **调度逻辑**: 
  - 如果显存充足 -> 允许执行 (LOCK_OK)。
  - 如果显存不足 -> 放入等待队列，并发送 `WAIT_FOR_MEM` 消息。
- **资源回收**: 当正在运行的任务释放锁或显存时，系统会自动检查等待队列，将满足条件的高优先级任务提升到执行队列 (`requests` list head)。

### 3. 智能抢占与动态时间片 (Smart Preemption)
- **动态时间片**: 实现了 `calculate_switch_time` 函数。
  - **Auto 模式**: 根据显存使用量动态调整时间片长度 (默认为 `显存(GB) * 5` 秒)，范围 10s - 300s。高显存任务获得更长的时间片，减少切换开销。
  - **Fixed 模式**: 可通过环境变量配置固定时间片。
- **智能切换**: 修改了 `timer_thr_fn` 线程。只有在**确实有其他任务在等待** (在 `requests` 队列或 `wait_queue` 中) 时，才会触发抢占 (`DROP_LOCK`)。如果系统空闲，当前任务可以继续运行，避免无谓的性能损耗。

## 配置指南

新的调度器行为可以通过以下环境变量进行配置：

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `NVSHARE_SWITCH_TIME_MODE` | `auto` | 切换模式: `auto` 或 `fixed` |
| `NVSHARE_SWITCH_TIME_FIXED` | `60` | Fixed 模式下的切换时间 (秒) |
| `NVSHARE_SWITCH_TIME_MULTIPLIER` | `5` | Auto 模式下的时间倍数 (GB * N) |
| `NVSHARE_MEMORY_RESERVE_PERCENT` | `10` | 预留显存缓冲区的百分比 (防止边缘 OOM) |
| `NVSHARE_DEFAULT_GPU_MEMORY_GB` | `16` | 默认 GPU 显存大小 (如果无法自动检测) |

## 验证与测试

由于开发环境限制 (macOS)，我们在 Docker 中进行了编译验证。

### 构建命令
```bash
# 构建调度器
docker build -f Dockerfile.scheduler -t nvshare-scheduler .

# 构建客户端库
docker build -f Dockerfile.libnvshare -t libnvshare .
```

### 推荐测试场景
1. **显存边界测试**: 启动 2 个 Pod，每个申请 60% GPU 显存。
   - **预期结果**: 一个运行，另一个处于 `WAIT_FOR_MEM` 等待状态，直到第一个释放资源或超时切换（如果启用了非常激进的内存预留）。注意：如果是纯粹的显存不足，应该顺序执行而不是并行或频繁切换导致 OOM。
   
2. **混合负载测试**: 一个大显存任务 (80% MEM) 和一个小任务 (10% MEM)。
   - **预期结果**: 两者可以交替运行。大任务的时间片可能更长。

## 下一步建议
- **多任务并行 (Phase 4)**: 目前实现保证了显存安全，但在显存充足时仍采用互斥调度 (Time Slicing)。未来可以优化 `try_schedule` 逻辑，在显存允许的情况下支持多个任务同时并发运行 (`lock_held` 逻辑改为计数器)。
