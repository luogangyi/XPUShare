# 自适应流控窗口 (Adaptive Pending Kernel Window) 优化设计方案

## 背景与问题
在 `nvshare` 的显存超卖场景下，当通过 Unified Memory 运行大显存任务时，我们观察到性能从 1.5s/it 骤降至 35s/it（下降 95%）。
**根因分析**表明：
1. 任务在刚获得 GPU 锁或进行 Context Switch 后，面临大量的缺页异常（Page Faults）和数据换入。
2. 这导致早期的 `cuCtxSynchronize` 操作耗时极长（可能超过 10 秒）。
3. 现有的流控机制过于敏感，一旦检测到单次耗时 >10s，立即将并发窗口 (`pending_kernel_window`) 重置为 1。
4. 窗口为 1 导致 CPU-GPU 流水线断裂，系统退化为完全同步模式，进一步放大了所有延迟，陷入“性能陷阱”。

## 设计目标
设计一套更鲁棒的流控机制，能够在**保护 GPU 响应性**（防止恶意占用）和**维持流水线效率**（高吞吐）之间取得平衡，特别是要避免因瞬时系统抖动导致的性能雪崩。

## 优化方案核心逻辑

### 1. 引入“预热豁免期” (Warm-up Grace Period)
在此期间忽略由于换页导致的超时惩罚。

*   **机制**: 记录最近一次获得 LOCK_OK 的时间戳 `last_acquire_time`。
*   **逻辑**: 
    ```c
    time_since_lock = now - last_acquire_time;
    if (time_since_lock < WARMUP_THRESHOLD_SEC) {
        // 处于预热期 (比如前 30秒)
        // 即使 sync 耗时很长，也不减小窗口大小
        // 允许窗口继续增长，尽快建立流水线掩盖延迟
        increase_window();
    } else {
        // 正常流控逻辑
        check_timeout_and_adjust();
    }
    ```
*   **收益**: 任务有足够的时间将工作集（Working Set）换入显存，填充 Pipeline，而不是在最需要并发掩盖延迟的时候被“断腿”。

### 2. 采用 AIMD 算法代替“断崖式重置”
现有的逻辑是：超时 >10s -> `Window = 1`。这过于激进。
建议采用 TCP 拥塞控制类似的 **加性增、乘性减 (AIMD)** 策略。

*   **增长 (无超时)**: `Window = min(Window + 1, MAX_WINDOW)` (线性增长，防止激增) 或者保持倍增（快速恢复）。建议保持倍增以便快速从抖动恢复。
*   **惩罚 (超时)**: 
    *   **轻微超时 (1s - 10s)**: `Window = max(1, Window * 0.8)`。
    *   **严重超时 (> 10s)**: `Window = max(4, Window / 2)`。
*   **底线保护**: 设定 `MIN_WINDOW_FLOOR = 4`。
    *   即使发生严重阻塞，也至少保留 4 个 Kernel 的缓冲能力，防止流水线彻底枯竭。

### 3. 滑动平均去噪 (EMA Filter)
单次 `Synchronization` 的时间可能受到偶然因素（如 OS 调度、GC）影响。使用指数移动平均值来判定是否拥塞。

*   `avg_duration = alpha * current_duration + (1 - alpha) * avg_duration`
*   仅当 `avg_duration > THRESHOLD` 时触发窗口缩减。

## 伪代码实现预览

```c
// Hook.c 中的逻辑改进建议

static void adjust_window(double sync_duration) {
    // 1. 检查预热期
    if (get_time() - client->lock_acquire_time < CONFIG_WARMUP_SEC) {
        // 预热期内，无条件增长，加速流水线建立
        pending_kernel_window = min(pending_kernel_window * 2, MAX_WINDOW);
        return;
    }

    // 2. 正常调节
    if (sync_duration > CRITICAL_THRESHOLD) { // > 10s
        // 严重拥堵：乘性减，但保留底限
        pending_kernel_window = max(4, pending_kernel_window / 2);
    } 
    else if (sync_duration > MILD_THRESHOLD) { // > 1s
        // 轻微拥堵：轻微收缩
        pending_kernel_window = max(1, pending_kernel_window - 1);
    } 
    else {
        // 顺畅：倍增恢复
        pending_kernel_window = min(pending_kernel_window * 2, MAX_WINDOW);
    }
}
```

## 预期效果
1. **消除启动抖动**: 任务在切换回来后，虽然前几秒会有卡顿（换页），但窗口保持较大，后续计算能迅速利用流水线跑满带宽。
2. **平滑降级**: 即使网络/显存极其卡顿，保留的窗口底限 (4) 也能维持基本的 API 异步性，避免性能下降 95%。
