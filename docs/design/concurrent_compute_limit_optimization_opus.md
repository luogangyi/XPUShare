# 并发计算限制优化设计方案

## 问题描述

当多个任务共享同一GPU且设置了计算限制（如50%和60%）时，由于独立节流机制导致GPU实际利用率远低于预期。

### 问题现象
- 任务A设置50%限制，任务B设置60%限制
- 预期：GPU总利用率接近100%（交错使用）
- 实际：GPU总利用率仅约60-70%

### 根本原因

```
当前调度模式（并发运行 + 独立节流）：
时间轴 (2000ms窗口):
任务A(50%): [====同时运行1000ms====][====空闲1000ms====]
任务B(60%): [====同时运行1200ms====][===空闲800ms===]
GPU状态:    [=====并发（仅算1个GPU）=====][====空闲====]
实际利用率: ~60% (取决于重叠程度)
```

问题在于：
1. 两个任务**同时运行**，共享GPU计算资源
2. 达到配额后**同时被节流**
3. 窗口剩余时间GPU**完全空闲**

---

## 方案一：协调串行调度（Coordinated Serial Scheduling）

### 核心思想
当多个任务的配额总和超过100%时，切换到**协调串行模式**，按配额比例分配时间片，交错运行以最大化GPU利用率。

### 调度逻辑

```
期望调度模式（协调串行）：
时间轴 (2000ms窗口):
任务A(50%): [运行909ms][等待][运行91ms][等待]...
任务B(60%): [等待][运行1091ms][等待]...
GPU状态:    [===A===][=====B=====][A]...
实际利用率: ~100%
```

### 实现细节

#### 1. 配额总和检测
```c
/* 计算GPU上所有活跃任务的配额总和 */
static int calculate_total_quota(struct gpu_context* ctx) {
    int total = 0;
    struct nvshare_client* c;
    LL_FOREACH(clients, c) {
        if (c->context == ctx && (c->is_running || is_in_wait_queue(ctx, c))) {
            total += c->core_limit;
        }
    }
    return total;
}

/* 判断是否需要协调串行模式 */
static int needs_coordinated_serial(struct gpu_context* ctx) {
    return calculate_total_quota(ctx) > 100;
}
```

#### 2. 时间片计算
```c
/* 计算客户端在当前窗口的分配时间 */
static long calculate_allocated_time_ms(struct gpu_context* ctx, 
                                         struct nvshare_client* client) {
    if (!needs_coordinated_serial(ctx)) {
        /* 普通模式：按原始配额 */
        return (long)COMPUTE_WINDOW_SIZE_MS * client->core_limit / 100;
    }
    
    /* 协调串行模式：按比例缩放 */
    int total_quota = calculate_total_quota(ctx);
    /* 按比例分配，确保总和不超过窗口大小 */
    return (long)COMPUTE_WINDOW_SIZE_MS * client->core_limit / total_quota;
}
```

#### 3. 调度器修改

在 `can_run()` 中添加协调串行逻辑：
```c
static int can_run(struct gpu_context* ctx, struct nvshare_client* client) {
    check_and_reset_window(ctx);
    
    if (client->core_limit < 100) {
        if (client->is_throttled) return 0;
        
        /* 使用动态计算的时间片 */
        long limit_ms = calculate_allocated_time_ms(ctx, client);
        if (client->run_time_in_window_ms >= limit_ms) return 0;
        
        /* 协调串行模式下，如果有其他任务在运行，则等待 */
        if (needs_coordinated_serial(ctx) && ctx->lock_held) {
            return 0;
        }
    }
    
    return can_run_with_memory(ctx, client);
}
```

### 优点
- 最大化GPU利用率（理论可达100%）
- 公平分配：每个任务获得按比例调整的时间
- 向后兼容：配额总和≤100%时行为不变

### 缺点
- 实现复杂，需要全局协调
- 任务切换开销增加（更频繁的上下文切换）
- 可能影响单个任务的响应延迟

---

## 方案二：动态并发策略（Dynamic Concurrency Strategy）

### 核心思想
根据配额情况**动态选择**并发或串行模式：
- 配额总和 ≤ 100%：允许并发运行
- 配额总和 > 100%：强制串行运行

### 实现细节

#### 修改 `can_run_with_memory()`
```c
static int can_run_with_memory(struct gpu_context* ctx,
                               struct nvshare_client* client) {
    /* ... 现有内存检查逻辑 ... */
    
    /* 新增：配额感知的并发控制 */
    if (config.scheduling_mode == SCHED_MODE_AUTO) {
        int total_quota = calculate_total_quota(ctx);
        
        /* 如果加上当前任务会超过100%，切换到串行 */
        if (total_quota > 100 && ctx->lock_held) {
            log_debug("Quota-aware: total %d%% > 100%%, using serial mode", 
                      total_quota);
            return 0;
        }
    }
    
    return 1;
}
```

### 调度行为

```
配额感知调度：
场景1: 任务A(30%) + 任务B(40%) = 70% ≤ 100%
  → 允许并发，两者同时运行

场景2: 任务A(50%) + 任务B(60%) = 110% > 100%
  → 强制串行，A运行1000ms后切换到B运行1200ms
  
时间轴 (2000ms窗口):
任务A(50%): [====运行1000ms====][=========空闲==========]
任务B(60%): [======空闲======][======运行1200ms======]
GPU状态:    [=======A=======][=========B==========]
实际利用率: (1000+1200)/2000 = 110% → 实际100%（串行最大化）
```

### 优点
- 实现简单，改动小
- 自动选择最优模式
- 保留并发优势（当配额允许时）

### 缺点
- 串行模式下切换粒度较粗（整个配额用完才切换）
- 可能导致一个任务等待较长时间

---

## 方案三：窗口内公平轮转（Fair Round-Robin within Window）

### 核心思想
在每个计算窗口内，将时间分成多个**小时间片**，按配额比例轮转调度，实现细粒度的公平共享。

### 实现细节

#### 新增配置
```c
#define MINI_SLICE_MS 100  /* 最小时间片100ms */

struct nvshare_client {
    /* ... 现有字段 ... */
    long allocated_slices;     /* 本窗口分配的时间片数 */
    long used_slices;          /* 本窗口已使用的时间片数 */
};
```

#### 时间片分配算法
```c
/* 每个窗口开始时重新计算时间片分配 */
static void allocate_slices(struct gpu_context* ctx) {
    int total_quota = calculate_total_quota(ctx);
    int total_slices = COMPUTE_WINDOW_SIZE_MS / MINI_SLICE_MS;  /* 20个片 */
    
    struct nvshare_client* c;
    LL_FOREACH(clients, c) {
        if (c->context == ctx) {
            if (total_quota <= 100) {
                /* 不超载：按原始配额分配 */
                c->allocated_slices = total_slices * c->core_limit / 100;
            } else {
                /* 超载：按比例缩放 */
                c->allocated_slices = total_slices * c->core_limit / total_quota;
            }
            c->used_slices = 0;
        }
    }
}
```

#### 轮转调度逻辑
```c
/* 选择下一个应该运行的客户端 */
static struct nvshare_client* select_next_client(struct gpu_context* ctx) {
    struct nvshare_client* best = NULL;
    float best_ratio = 2.0;  /* 已用/分配比例，越小优先级越高 */
    
    struct nvshare_client* c;
    LL_FOREACH(clients, c) {
        if (c->context != ctx) continue;
        if (c->used_slices >= c->allocated_slices) continue;  /* 配额用完 */
        
        float ratio = (float)c->used_slices / c->allocated_slices;
        if (ratio < best_ratio) {
            best_ratio = ratio;
            best = c;
        }
    }
    return best;
}
```

### 调度行为

```
公平轮转调度（MINI_SLICE_MS=100ms）：
时间轴 (2000ms窗口，20个时间片):
任务A(50%): 分配9片 (50/110*20)
任务B(60%): 分配11片 (60/110*20)

实际调度:
[A][B][A][B][B][A][B][A][B][B][A][B][A][B][B][A][B][A][B][B]
 1  1  2  2  3  3  4  4  5  6  5  7  6  8  9  7  10 8 11  9
     
GPU状态: 持续100%利用率
```

### 优点
- 最细粒度的公平调度
- 所有任务获得接近实时的响应
- 利用率最接近理论最优

### 缺点
- 实现最复杂
- 频繁切换可能增加GPU上下文切换开销
- 对于GPU-heavy任务，频繁中断可能影响性能

---

## 方案对比

| 特性 | 方案一（协调串行） | 方案二（动态并发） | 方案三（公平轮转） |
|------|-------------------|-------------------|-------------------|
| 实现复杂度 | 中 | 低 | 高 |
| GPU利用率 | 高 (~100%) | 高 (~100%) | 最高 (~100%) |
| 任务响应延迟 | 中（等待时间片结束） | 高（等待整个配额） | 低（100ms级别） |
| 切换开销 | 中 | 低 | 高 |
| 代码改动量 | 中 (~100行) | 小 (~30行) | 大 (~200行) |
| 向后兼容性 | 好 | 最好 | 好 |

---

## 推荐方案

**推荐采用方案二（动态并发策略）作为第一阶段实现**，原因：
1. 实现简单，风险低
2. 能解决核心问题（GPU空闲）
3. 改动集中，易于测试和回滚

后续如有更高精度需求，可升级到方案一或方案三。

---

## 实现计划（方案二）

### 阶段1：核心逻辑
1. 添加 `calculate_total_quota()` 函数
2. 修改 `can_run_with_memory()` 添加配额检查
3. 确保窗口重置时正确处理串行切换

### 阶段2：测试验证
1. 单任务配额测试（确保不影响现有功能）
2. 双任务配额测试（50%+60%场景）
3. 多任务配额测试（30%+30%+30%）
4. 边界情况测试（100%+任意配额）

### 阶段3：监控增强
1. 添加日志记录配额模式切换
2. 可选：添加指标导出（Prometheus）

---

## 最终采纳方案：加权计费 + 等比例缩放

经过讨论，最终采纳结合 Gemini 的"加权计费"方案和用户提出的"等比例缩放"优化。

### 核心思想

1. **加权计费**：并发运行时，计费按并发数分摊
   - `计费时长 = 挂钟时长 / 当前并发数`
2. **等比例缩放**：超配时，按比例缩小各任务配额，确保总和=100%
   - `有效配额 = 原始配额 × (100 / 总配额)`

### 场景验证

#### 场景：A(80%) + B(80%) = 160%

```
缩放因子 = 100 / 160 = 0.625
A 有效配额 = 80% × 0.625 = 50% → 1000ms
B 有效配额 = 80% × 0.625 = 50% → 1000ms

执行（加权计费）：
T=0~2000ms: A和B同时运行
- A 计费: 2000 / 2 = 1000ms ✓ 恰好用完配额
- B 计费: 2000 / 2 = 1000ms ✓ 恰好用完配额

GPU利用率: 100% ✓
比例公平: A:B = 50:50 = 80:80 ✓
```

### 实现代码

```c
/* 计算GPU上所有活跃客户端的配额总和 */
static int calculate_total_quota(struct gpu_context* ctx) {
    int total = 0;
    struct nvshare_client* c;
    LL_FOREACH(clients, c) {
        if (c->context == ctx && c->core_limit < 100) {
            total += c->core_limit;
        }
    }
    /* 如果有无限制的客户端，或没有客户端，返回100 */
    return total > 0 ? total : 100;
}

/* 统计当前正在运行的客户端数量 */
static int count_running_clients(struct gpu_context* ctx) {
    int count = 0;
    struct nvshare_request* req;
    LL_FOREACH(ctx->running_list, req) count++;
    return count > 0 ? count : 1;
}

/* 计算有效配额（含等比例缩放） */
static long get_effective_quota_ms(struct gpu_context* ctx, 
                                    struct nvshare_client* c) {
    int total_quota = calculate_total_quota(ctx);
    long base_quota_ms = (long)COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;
    
    if (total_quota <= 100) {
        return base_quota_ms;  /* 不超配，原样返回 */
    }
    
    /* 超配：等比例缩放 */
    return base_quota_ms * 100 / total_quota;
}

/* 计算加权计费时长 */
static long calculate_weighted_usage(struct gpu_context* ctx, long wall_time) {
    int n = count_running_clients(ctx);
    return wall_time / n;
}
```

### 修改点

1. **`timer_thr_fn`**：使用 `get_effective_quota_ms()` 和 `calculate_weighted_usage()` 计算配额使用
2. **`remove_req`**：结算时使用加权计费
3. **`can_run`**：使用 `get_effective_quota_ms()` 检查配额

### 优势

| 方面 | 分析 |
|------|------|
| 简洁性 | ✓ 只需几个辅助函数，无需切换调度模式 |
| 公平性 | ✓ 保持原始配额比例（80:80 = 50:50） |
| 利用率 | ✓ 配额正好等于100%，GPU满载 |
| 向后兼容 | ✓ 不超配时行为不变 |
