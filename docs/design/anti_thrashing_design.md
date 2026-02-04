# Anti-Thrashing Scheduler Optimization

## 问题分析
用户指出：在 3x 超卖场景下，任务执行时间呈现“无限长”（>60分钟 vs 预期5分钟），远超正常线性损耗。
代码分析确认了 **Time Quantum (TQ) 计算逻辑的局限性**：
1.  **TQ 基于当前运行内存**: `switch_time = active_mem_gb * 5`。
    -   对于 12GB 任务，TQ ≈ 60s。
2.  **忽略了换页开销**: 物理换页可能耗时 27s。
    -   有效计算时间 = 60s - 27s = 33s。
    -   开销占比 = 27/60 = 45%。效率尚可。
3.  **忽略了初始状态**: 
    -   如果任务刚启动尚未汇报内存，TQ 可能被 Clamp 到最小 10s。
    -   此时 **10s < 27s (Swap time)** -> **Live Lock**。任务在换页完成前就被强制剥夺。
4.  **无视争抢程度**:
    -   当有 3 个胖任务排队时，频繁切换会导致每个任务都需要 Swap-in。
    -   此时应采取 **"更少切换，更长运行"** 的策略。

## 改进方案 design

### 1. 引入 "Contention Factor" (争抢因子)
在计算 TQ 时，考虑正在排队的任务数量。排队越多，说明争抢越激烈，应延长 TQ 以分摊切换开销。

`calculate_switch_time` 修改逻辑：
```c
int num_waiting = count_waiting_clients(ctx);
if (num_waiting > 0) {
    // 存在争抢，且可能发生 Thrashing
    // 策略：每多一个等待任务，增加 20% 时间，或者直接由 Multiplier 翻倍
    switch_time *= (1 + 0.5 * num_waiting); 
}
```

### 2. 保证最小 TQ > Swap Latency
硬性规定在有内存压力的场景下，最小 TQ 不得低于 **45s** 或 **60s**，确保即使是最慢的 PCIe 换页也能完成并留出计算窗口。

```c
// 检测潜在的内存颠簸 (Total Requested > Total Physical)
size_t total_requested = sum_all_requests(ctx);
if (total_requested > ctx->total_memory) {
    // 严重超卖模式
    min_switch_time = 60; // 强制至少 60s
}
```

### 3. 实现步骤 (Plan)
1.  修改 `src/scheduler.c`:
    -   实现 `get_total_requested_memory(ctx)` 辅助函数。
    -   修改 `calculate_switch_time`：
        -   如果是超卖状态 (`total_req > physical`)，`multiplier` 翻倍 (5 -> 10)。
        -   设定 `min_tq = 60s` (原 10s)。
2.  验证：
    -   重新编译 scheduler。
    -   运行 3 Pods 同 GPU 测试，观察 TQ 是否变为 60s+ 且吞吐恢复。

## 预期收益
- 就算发生 Thrashing，每个 Pod 也能获得至少 60s - 27s = 33s 的**净计算时间**。
- 300% 超卖下的完成时间应回归到线性增长（约 3x-4x 单任务时间），而非指数级爆炸。
