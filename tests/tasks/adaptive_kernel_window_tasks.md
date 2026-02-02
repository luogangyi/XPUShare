# Adaptive Kernel Window 实现任务

## 概述
基于 `docs/adaptive_kernel_window_design.md` 设计方案和 `docs/adaptive_kernel_window_review.md` 评审意见，实现改进的动态流控窗口机制。

## 任务清单

### Phase 1: 基础设施
- [x] 1.1 在 `hook.c` 添加配置常量和变量
  - `KERN_WINDOW_MIN_FLOOR = 4`
  - `KERN_WARMUP_PERIOD_SEC = 30`
  - `KERN_MILD_THRESHOLD = 1`
  - `consecutive_timeout_count`
  - `lock_acquire_time`
- [x] 1.2 在 `client.c` 中记录 `LOCK_OK` 时间戳并导出

### Phase 2: 核心逻辑修改
- [x] 2.1 修改 `cuLaunchKernel` 中的窗口调整逻辑
  - 实现预热豁免期检查
  - 实现 AIMD 算法（乘性减 + 底限保护）
  - 实现连续超时计数器
- [x] 2.2 添加诊断日志
  - 窗口缩小时打印 WARN 日志
  - 窗口恢复时打印 INFO 日志

### Phase 3: 参数化配置
- [x] 3.1 支持环境变量覆盖
  - `NVSHARE_KERN_WINDOW_MIN`
  - `NVSHARE_KERN_WARMUP_SEC`
  - `NVSHARE_KERN_CRITICAL_TIMEOUT`

### Phase 4: 验证
- [x] 4.1 Docker 编译验证
- [x] 4.2 更新文档

## 代码修改清单

| 文件 | 修改内容 |
|------|----------|
| `src/hook.c` | 添加常量、变量、改进流控逻辑 |
| `src/client.c` | 记录并导出 `lock_acquire_time` |
| `src/client.h` | 声明 `get_lock_acquire_time()` |
