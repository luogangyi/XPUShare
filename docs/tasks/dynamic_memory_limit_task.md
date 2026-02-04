# Task: 动态显存配额调整 (Annotations)

## Phase 1: 协议扩展
- [ ] 在 `comm.h` 中添加 `UPDATE_LIMIT` 消息类型
- [ ] 在 `message` 结构体中添加 `memory_limit` 字段

## Phase 2: Client 处理
- [ ] 在 `client.c` 中添加 `UPDATE_LIMIT` 消息处理
- [ ] 在 `hook.c` 中添加线程安全的 `update_memory_limit()` 函数

## Phase 3: Scheduler 监控
- [ ] 添加 annotation 监控功能
- [ ] 实现 `send_update_limit()` 函数
- [ ] 添加 K8s API 访问 (或简化方案)

## Phase 4: 测试验证
- [ ] 创建测试脚本
- [ ] 验证动态修改生效
