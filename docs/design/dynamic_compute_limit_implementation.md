# GPU 算力动态调整设计方案 (Dynamic Compute Limit)

## 0. 背景 & 目标

继 "动态显存配额" 功能后，用户希望能够动态调整 "GPU 算力"。在 `nvshare` 的分时复用（Time-Slicing）架构中，我们需要将 GPU 算力抽象为 **百分比份额**。

默认将每个 GPU 的算力划分为 **100 份** (100%)。用户可以通过 Pod Annotation 申请特定的算力比例。

**目标**:
1.  **基于百分比的限制**: 用户设置 `nvshare.com/gpu-core-limit=40`，表示该 Pod 最多使用 40% 的 GPU 时间。
2.  **动态调整**: 支持通过 `kubectl annotate` 在运行时动态修改该比例。
3.  **完全并行支持**: 方案必须支持 `SCHED_MODE_CONCURRENT`，允许多个 Client 并发占有 GPU，并对各自的配额进行独立统计和限制。

---

## 1. 核心设计

### 1.1 接口 (Annotation)

定义新的 Kubernetes Annotation:

*   **Key**: `nvshare.com/gpu-core-limit`
*   **Value**: `1` 到 `100` 的整数。
    *   `100` (默认): 无限制，尽力而为。
    *   `40`: 限制在该时间窗口内，该 Pod 累计运行时间不超过窗口总时长的 40%。

### 1.2 调度模型：基于窗口的并行限流

为了支持并发模式，我们采用 **Shared Window, Independent Accounting (共享窗口，独立计费)** 模型。

*   **调度周期 (Window Size)**: 全局周期 $W$ (e.g., 10秒)。
*   **计费策略 (Full Accounting)**:
    *   如果 Client A 和 Client B 同时运行了 1秒 (墙钟时间)。
    *   Client A 的使用量增加 1秒。
    *   Client B 的使用量增加 1秒。
    *   *解释*: 这种计费方式虽然“虚高”（总和可能超过 100%），但在 GPU 场景下是合理的。因为当两者并发时，它们确实都占用了 GPU 资源（SM, Memory Bandwidth 等），且相互干扰导致性能下降。如果用户希望限制干扰，这种计费能准确反映“该 Pod 在 GPU 上驻留了多久”。
*   **限流 (Targeted Throttling)**:
    *   当 Client A 的累计运行时间超过限额时，Scheduler 仅向 Client A 发送 `DROP_LOCK`。
    *   Client B 继续运行，不受影响。
    *   Client A 进入 `THROTTLED` 状态，直到窗口重置。

---

## 2. 详细实现方案

### 2.1 Scheduler 数据结构

修改 `src/scheduler.c`:

1.  **GPU 上下文**: 窗口状态
```c
struct gpu_context {
    // ...
    /* Compute Limit */
    time_t window_start_time;
};
```

2.  **Client 结构**: 配额与统计
```c
struct nvshare_client {
    // ...
    int core_limit;             /* 1-100 */
    long run_time_in_window_ms; /* 当前窗口已用时间 (毫秒精度) */
    int is_throttled;           /* 是否正在关禁闭 */
};
```

### 2.2 核心调度流程

#### 2.2.1 窗口重置逻辑 (`check_and_reset_window`)

> **改进**: 在 `try_schedule` 和 `timer_thr_fn` 两个入口都进行检查，防止 GPU 空闲导致窗口过期。

```c
#define COMPUTE_WINDOW_SIZE_MS 10000 

static void check_and_reset_window(struct gpu_context* ctx) {
    time_t now = time(NULL);
    // 判断是否超过窗口结束时间 (注意: window_start_time 存储秒级戳)
    if (now >= ctx->window_start_time + COMPUTE_WINDOW_SIZE_MS / 1000) {
        ctx->window_start_time = now;
        
        // 重置所有 Client 的统计
        // 注意: 即使 Annotation 更新了配额，也不会重置已运行时间，防止作弊
        struct nvshare_client* client;
        LL_FOREACH(clients, client) {
            if (client->context == ctx) {
                client->run_time_in_window_ms = 0;
                client->is_throttled = 0;
            }
        }
        
        // 唤醒 try_schedule 重新尝试调度被解禁的任务
        // (如果是 timer 线程调用的，这一步很重要)
        pthread_cond_signal(&ctx->sched_cv); 
    }
}
```

#### 2.2.2 准入控制 (`try_schedule`)

```c
static int can_run(struct nvshare_client* c) {
    if (c->core_limit >= 100) return can_run_with_memory(c);

    // 1. 检查窗口是否过期 (作为新任务调度的入口，必须先检查)
    check_and_reset_window(c->context);

    // 2. 检查是否被限流
    if (c->is_throttled) return 0;
    
    // 3. 检查配额是否耗尽
    long limit_ms = COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;
    if (c->run_time_in_window_ms >= limit_ms) return 0;

    return can_run_with_memory(c);
}
```

#### 2.2.3 并发计费与 Timer 逻辑 (`timer_thr_fn`)

**改进**:
- 使用 `MIN` 宏。
- 采用 `pthread_cond_timedwait` 实现可中断睡眠。
- 精确毫秒计费。

```c
#define MIN(a,b) ((a)<(b)?(a):(b))
#define DEFAULT_TQ_MS (DEFAULT_TQ * 1000)

void* timer_thr_fn(void* arg) {
    while (1) {
        long now_ms = current_time_ms();
        
        // 1. 窗口重置检查
        check_and_reset_window(ctx);

        // 2. 计算下一次唤醒时间 (Next Event)
        long min_sleep_ms = DEFAULT_TQ_MS;
        struct nvshare_client *victim = NULL;
        
        LL_FOREACH(ctx->running_list, req) {
            struct nvshare_client* c = req->client;
            if (c->core_limit < 100) {
                 long limit_ms = COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;
                 long remaining = limit_ms - c->run_time_in_window_ms;
                 if (remaining <= 0) {
                     min_sleep_ms = 0; // 立即处理
                     break;
                 }
                 if (remaining < min_sleep_ms) min_sleep_ms = remaining;
            }
        }
        
        // 3. 执行睡眠
        if (min_sleep_ms > 0) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            // ts += min_sleep_ms
            
            pthread_mutex_lock(&ctx->mutex);
            pthread_cond_timedwait(&ctx->timer_cv, &ctx->mutex, &ts);
            pthread_mutex_unlock(&ctx->mutex);
            
            // 计算实际经过时间 (可能被 signal 提前唤醒)
            long actual_elapsed = current_time_ms() - now_ms;
             
            // 更新所有运行任务的使用时间 (Full Accounting)
            LL_FOREACH(ctx->running_list, req) {
                req->client->run_time_in_window_ms += actual_elapsed;
            }
        }

        // 4. 处理超额任务 (Targeted Preemption)
        LL_FOREACH_SAFE(ctx->running_list, req, tmp) {
            struct nvshare_client* c = req->client;
            if (c->core_limit < 100) {
                long limit_ms = COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;
                if (c->run_time_in_window_ms >= limit_ms) {
                    log_info("Throttling client %016" PRIx64 " (Used: %ld/%ld ms)", 
                             c->id, c->run_time_in_window_ms, limit_ms);
                    c->is_throttled = 1;
                    send_message(c, &drop_msg); 
                    // 不直接从 list 移除，等待 client 回复 LOCK_RELEASED
                }
            }
        }
    }
}
```

### 2.3 Annotation 动态更新

当用户通过 `kubectl annotate` 更新 `gpu-core-limit` 时：

1.  Scheduler 更新 `client->core_limit`。
2.  **不重置** `client->run_time_in_window_ms`。
    - *例子*: Pod A (limit=10%) 已运行 0.9s (90% quota)。
    - 用户更新 limit=90% (8.1s available)。
    - 下一次 Timer 检查时，剩余配额 = 9s - 0.9s = 8.1s。Pod A 可以继续运行。
    - 这样设计防止了用户通过反复更新配额来清空已用时间。

---

## 3. 验证计划

### 3.1 验证场景

1.  **单 Pod 限流测试**
    *   启动 Pod A, 设置 `gpu-core-limit=50`.
    *   执行持续计算任务。
    *   **验证命令**:
        ```bash
        # 采集 GPU 利用率 (sm: SM 利用率, mem: 显存带宽利用率)
        nvidia-smi dmon -s u -d 1
        # 预期: sm 应该在 50% 左右波动 (例如 1秒 100%, 1秒 0%)
        ```

2.  **并发限流 (Concurrent Throttling)**
    *   Pod A (`limit=50`), Pod B (`limit=100`, 无限制).
    *   **预期**:
        *   Pod B 持续运行 (sm ~100%).
        *   Pod A 断续运行 (sm 贡献 50% 的负载).
        *   日志显示 A 周期性收到 `DROP_LOCK`.

### 3.2 与显存限制的交互

`gpu-core-limit` 与 `gpu-memory-limit` 是 **完全独立** 的：
- 显存配额在 `register_client` 和 `try_schedule` (can_run_with_memory) 时检查。
- 算力配额在 `timer_thr_fn` 运行时动态检查。
- 两者互不干扰，可以同时生效。

---

## 4. 任务列表

| Phase | Task |
|-------|------|
| 1     | scheduler: 引入毫秒级时间函数 `current_time_ms` |
| 2     | scheduler: 实现 `check_and_reset_window` 并在 `try_schedule` 调用 |
| 3     | scheduler: 重构 `timer_thr_fn` 实现并行计费与定向抢占 |
| 4     | verify: 更新测试脚本，使用 `nvidia-smi dmon` 验证 |

---

保存路径: `docs/design/dynamic_compute_limit_implementation.md`

---

## 5. 阶段性实现总结（从 `6c8ec4e27400` 到当前）

本阶段围绕并发场景下的算力配额准确性进行了持续优化，核心改动如下：

1. **并发计费口径统一为“真实运行态”**
   - 对运行中的 client 按当前 `running_list` 的并发数进行加权计费（`wall / concurrent`）。
   - 在 `LOCK_RELEASED` 时补齐精确账单，减少窗口边界和切换瞬间的计费抖动。

2. **配额窗口机制增强**
   - 引入/稳定化可配置窗口与采样参数：`NVSHARE_COMPUTE_WINDOW_MS`、`NVSHARE_QUOTA_SAMPLE_INTERVAL_MS`。
   - 增加跨窗口结转参数 `NVSHARE_QUOTA_CARRYOVER_PERCENT`，用于控制超额尾账是否结转到下一窗口。

3. **DROP 尾段计费优化（Phase B，保留）**
   - 新增 `NVSHARE_DROP_TAIL_BILLING_PERCENT`，对 `DROP_LOCK -> LOCK_RELEASED` 的尾段计费按比例折算，降低因释放延迟带来的系统性低估/高估。
   - 默认建议值：`70`。

4. **提前触发 DROP（Phase C，已回退）**
   - 曾引入 `NVSHARE_DROP_LEAD_MS` 以提前触发限流。
   - 实测在 `50%+50%` 场景造成整体吞吐下降，已按测试结论回退，仅保留 Phase B。

5. **调试与验证链路改进**
   - 增强关键路径日志（限流、窗口重置、并发计费）。
   - 测试脚本与日志分析流程支持快速定位“分布不符合预期”和“计费口径偏移”问题。

---

## 6. 当前遗留问题（后续优化点）

1. **低配额单任务仍有偏差**
   - 单任务 `25%/50%/75%` 与理论值仍有约 3%~7% 偏差，说明窗口粒度、内核批次行为与计费模型仍有耦合误差。

2. **不同 workload 的稳定性差异**
   - 计算密集型任务收敛较好；kernel 粒度更细或 burst 型 workload 下，配额波动仍偏大。

3. **日志噪声仍偏高**
   - 高频路径日志（窗口重置/配额统计）在压测时体量较大，影响定位效率，需继续分级与抽样。

4. **自动参数整定缺失**
   - 目前采样周期、窗口大小、尾段折算比例依赖人工调参，后续可考虑按实际 `drop_to_release` 延迟做自适应。

5. **测试矩阵仍需扩展**
   - 缺少长稳态（>1h）与多租户混部（不同模型/不同 batch）回归，尚不能完全覆盖生产波动。
