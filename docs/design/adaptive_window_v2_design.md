# Adaptive Kernel Window V2 改进设计

## 1. 背景
根据 [Failure Analysis](adaptive_window_failure_analysis.md) 的结论，V1 版本的自适应窗口机制存在逻辑缺陷，导致在严重内存颠簸（Thrashing）场景下，Warm-up 保护机制失效。

**问题根因**:
- Warm-up 检查是在耗时的 `cuCtxSynchronize` **之后** 进行的。
- 当发生严重缺页时，`cuCtxSynchronize` 可能耗时 >20s。
- 这导致检查时 System Time 已经超过了 `lock_acquire_time + warmup_period`，保护期意外过期。

## 2. 改进方案

### 2.1 修复 Warm-up 检查时机关
**核心变更**: 将 Warm-up 状态的判定提前到 `cuCtxSynchronize` 之前，或者在计算时扣除本次 Sync 的耗时。

**伪代码 V2**:
```c
// 1. 获取锁获得时间
time_t lock_time = client->lock_acquire_time;
time_t now = time(NULL);

// 2. 提前判定是否处于预热期 (Pre-check)
// 只要开始同步时还在预热期内，本次同步就应被豁免
int is_warming_up = (now - lock_time) < config.warmup_period;

// 3. 执行同步 (可能耗时很久)
clock_gettime(CLOCK_MONOTONIC, &start);
real_cuCtxSynchronize();
clock_gettime(CLOCK_MONOTONIC, &end);

// 4. 计算耗时
double duration = timespec_diff(end, start);

// 5. 应用流控策略
if (duration > CRITICAL_THRESHOLD) {
    if (is_warming_up) {
        // 因开始时处于预热期，豁免本次超时
        log_info("Warmup active (snapshot): Ignoring critical timeout (%f s)", duration);
        increase_window(); 
    } else {
        // 确实过载，降级
        decrease_window();
    }
}
```

### 2.2 增强配置建议
修改默认配置或在该任务中强调：
- `NVSHARE_KERN_WARMUP_PERIOD_SEC`: 推荐值提升至 **60s** (原 30s)，以覆盖 12GB+ 显存的换入时间 (约 26s)。

## 3. 实现步骤
1.  修改 `src/hook.c` 中的 `cuda_sync_context` 函数。
2.  在调用 `real.cuCtxSynchronize` 之前快照 `now` 时间或直接计算 `in_warmup` 状态。
3.  重新编译 `libnvshare.so`。
4.  在测试脚本中应用新的环境变量 (`WARMUP=60`)。

## 4. 验证计划
-   运行 `test-cross-gpu.sh` (4 Pods)。
-   观察日志：
    -   即使发生 `26s` 的同步耗时，是否仍打印 `Warmup: Ignored critical timeout`。
    -   窗口是否保持增长而非骤降。
