# NVShare Prometheus Metrics 设计方案

## 1. 目标

本方案目标是让 Prometheus 能稳定采集以下信息：

1. GPU 设备级信息：显存、GPU 利用率、显存利用率等。
2. 进程/Pod 级显存信息：
   - `managed allocation`（调度器可见、可用于调度）
   - `NVML 进程显存`（最接近“驻留显存”的观测值）
   - “容量需求估算值”（用于容量规划）
3. 客户配置配额：
   - 显存 quota（`gpu-memory-limit` 或其他来源）
   - 算力 quota（`gpu-core-limit`）
4. 调度器状态：
   - running/wait 队列、内存压力、throttle 状态等。

## 2. 设计原则

1. 区分语义，不混淆：
   - `allocated`、`resident-like`、`estimated` 必须分开上报。
2. 以 scheduler 为单一采集出口：
   - Prometheus 只抓一个 `/metrics`，避免多端点 join 复杂度。
3. 指标可解释：
   - 每个指标对应明确来源（scheduler state / NVML / 估算公式）。
4. 控制标签基数：
   - 默认以 `namespace/pod/gpu_uuid` 作为主标签；`client_id/host_pid` 仅用于排障。

## 3. 整体架构

```text
libnvshare(client) --MEM_UPDATE--> scheduler state
                                  |
                                  +-- NVML sampler thread (GPU + per-process)
                                  |
                                  +-- metrics snapshot
                                  |
                                  +-- /metrics (Prometheus text format)
```

## 4. 关键改造点

## 4.1 协议与状态字段

为实现“NVML 进程显存”按 Pod 对齐，需要在 REGISTER 后保存进程标识：

1. `host_pid`（推荐）  
2. `pid_ns`（容器内 PID，辅助排障）  
3. `process_start_time`（防止 PID 复用误匹配，可选）

建议在 `struct message` 中新增字段，并引入 `protocol_version` 做兼容。

## 4.2 scheduler 内新增模块

1. NVML 采样线程（默认 1s）：
   - GPU 级：`memory used/total`，`gpu util`，`memory util`
   - 进程级：`usedGpuMemory`（按 `gpu + pid`）
2. PID 到 client 映射：
   - key: `(gpu_uuid, host_pid)`
   - value: `namespace/pod/client_id`
3. metrics exporter：
   - HTTP `/metrics`，默认 `:9402`
   - 只读快照，避免长时间持锁

## 5. 指标清单

## 5.1 GPU 设备级指标

| 指标名 | 类型 | 标签 | 含义 | 来源 |
|---|---|---|---|---|
| `nvshare_gpu_info` | gauge | `gpu_uuid,gpu_index,gpu_name` | 固定信息，值为 1 | NVML |
| `nvshare_gpu_memory_total_bytes` | gauge | `gpu_uuid,gpu_index` | 总显存 | NVML |
| `nvshare_gpu_memory_used_bytes` | gauge | `gpu_uuid,gpu_index` | 已用显存 | NVML |
| `nvshare_gpu_memory_free_bytes` | gauge | `gpu_uuid,gpu_index` | 剩余显存 | NVML |
| `nvshare_gpu_utilization_ratio` | gauge | `gpu_uuid,gpu_index` | GPU 利用率（0~1） | NVML |
| `nvshare_gpu_memory_utilization_ratio` | gauge | `gpu_uuid,gpu_index` | 显存控制器利用率（0~1） | NVML |
| `nvshare_gpu_process_count` | gauge | `gpu_uuid,gpu_index` | 当前 NVML 看到的进程数 | NVML |

## 5.2 Pod/进程显存指标

| 指标名 | 类型 | 标签 | 含义 | 来源 |
|---|---|---|---|---|
| `nvshare_client_info` | gauge | `namespace,pod,client_id,gpu_uuid,gpu_index,host_pid` | client 元信息，值为 1 | scheduler |
| `nvshare_client_managed_allocated_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | 当前 managed 分配量（D） | MEM_UPDATE |
| `nvshare_client_managed_allocated_peak_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | 生命周期峰值 managed 分配 | scheduler |
| `nvshare_client_nvml_used_bytes` | gauge | `namespace,pod,client_id,gpu_uuid,host_pid` | NVML 进程显存（N） | NVML |
| `nvshare_client_memory_overhead_baseline_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | 进程固定开销基线（O_base） | 估算 |
| `nvshare_client_memory_need_estimated_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | `D + O_base`，容量规划推荐值 | 估算 |
| `nvshare_client_memory_need_upper_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | `D + N`，保守上界 | 估算 |
| `nvshare_client_memory_quota_bytes` | gauge | `namespace,pod,client_id,gpu_uuid` | 配置显存 quota（0=unlimited） | annotation/env |
| `nvshare_client_memory_quota_source_info` | gauge | `namespace,pod,client_id,source` | quota 来源（annotation/env/default/none），命中为 1 | scheduler |
| `nvshare_client_memory_quota_exceeded` | gauge | `namespace,pod,client_id,gpu_uuid` | 当前是否超 quota（0/1） | scheduler |

说明：

1. `nvshare_client_nvml_used_bytes` 是“最接近驻留显存”的观测，不等于严格真值（UVM 下可能低估）。
2. `nvshare_client_memory_need_estimated_bytes` 用于容量规划；`upper` 用于保守阈值告警。

## 5.3 算力 quota 与利用率指标

| 指标名 | 类型 | 标签 | 含义 | 来源 |
|---|---|---|---|---|
| `nvshare_client_core_quota_config_percent` | gauge | `namespace,pod,client_id,gpu_uuid` | 配置算力 quota（1~100） | annotation/default |
| `nvshare_client_core_quota_effective_percent` | gauge | `namespace,pod,client_id,gpu_uuid` | 等比例缩放后的有效 quota | scheduler |
| `nvshare_client_core_window_usage_ms` | gauge | `namespace,pod,client_id,gpu_uuid` | 当前窗口已计费 ms | scheduler |
| `nvshare_client_core_window_limit_ms` | gauge | `namespace,pod,client_id,gpu_uuid` | 当前窗口可用 ms | scheduler |
| `nvshare_client_core_usage_ratio` | gauge | `namespace,pod,client_id,gpu_uuid` | `usage_ms / limit_ms` | 计算 |
| `nvshare_client_throttled` | gauge | `namespace,pod,client_id,gpu_uuid` | 是否被 throttle（0/1） | scheduler |
| `nvshare_client_pending_drop` | gauge | `namespace,pod,client_id,gpu_uuid` | 是否已发 DROP 等待释放（0/1） | scheduler |
| `nvshare_client_quota_debt_ms` | gauge | `namespace,pod,client_id,gpu_uuid` | 跨窗口 carryover 债务 | scheduler |

## 5.4 scheduler/gpu context 指标

| 指标名 | 类型 | 标签 | 含义 | 来源 |
|---|---|---|---|---|
| `nvshare_scheduler_running_clients` | gauge | `gpu_uuid,gpu_index` | running_list 长度 | scheduler |
| `nvshare_scheduler_request_queue_clients` | gauge | `gpu_uuid,gpu_index` | requests 队列长度 | scheduler |
| `nvshare_scheduler_wait_queue_clients` | gauge | `gpu_uuid,gpu_index` | wait_queue 长度 | scheduler |
| `nvshare_scheduler_running_memory_bytes` | gauge | `gpu_uuid,gpu_index` | 运行中总 managed 内存 | scheduler |
| `nvshare_scheduler_peak_running_memory_bytes` | gauge | `gpu_uuid,gpu_index` | 峰值 running memory | scheduler |
| `nvshare_scheduler_memory_safe_limit_bytes` | gauge | `gpu_uuid,gpu_index` | `total * (1-reserve)` 安全水位 | scheduler |
| `nvshare_scheduler_memory_overloaded` | gauge | `gpu_uuid,gpu_index` | overload 状态（0/1） | scheduler |

## 5.5 事件计数指标

| 指标名 | 类型 | 标签 | 含义 |
|---|---|---|---|
| `nvshare_scheduler_messages_total` | counter | `type` | 各类消息累计数（MEM_UPDATE/LOCK_OK/...) |
| `nvshare_scheduler_drop_lock_total` | counter | `gpu_uuid,reason` | DROP_LOCK 总数 |
| `nvshare_scheduler_client_disconnect_total` | counter | `reason` | 客户端断开累计 |
| `nvshare_scheduler_wait_for_mem_total` | counter | `gpu_uuid` | WAIT_FOR_MEM 累计 |
| `nvshare_scheduler_mem_available_total` | counter | `gpu_uuid` | MEM_AVAILABLE 累计 |

## 6. 计算定义（重点）

设：

- `D = nvshare_client_managed_allocated_bytes`
- `N = nvshare_client_nvml_used_bytes`
- `O_base = nvshare_client_memory_overhead_baseline_bytes`

定义：

1. 容量规划推荐值：`need_estimated = D + O_base`
2. 保守上界：`need_upper = D + N`

`O_base` 更新策略：

1. 仅在 client 低负载且 `D < 256MiB` 时采样 `N`。
2. 使用 EWMA 更新：`O_base = alpha * N + (1-alpha) * O_base`（默认 `alpha=0.2`）。
3. 限幅：`256MiB <= O_base <= 4GiB`。

## 7. 标签规范与基数控制

默认标签：

1. `namespace`
2. `pod`
3. `gpu_uuid`
4. `gpu_index`

排障标签（可开关）：

1. `client_id`
2. `host_pid`

控制策略：

1. `NVSHARE_METRICS_DEBUG_LABELS=0/1`（默认 0）。
2. 对离线 client 保留 5 分钟后回收 series。
3. 不在高频 counter 上携带 `pod` + `client_id` + `pid` 三重标签组合。

## 8. 暴露接口与配置

建议新增环境变量：

1. `NVSHARE_METRICS_ENABLE=1`
2. `NVSHARE_METRICS_ADDR=0.0.0.0:9402`
3. `NVSHARE_METRICS_NVML_INTERVAL_MS=1000`
4. `NVSHARE_METRICS_DEBUG_LABELS=0`
5. `NVSHARE_METRICS_STALE_TTL_SEC=300`

接口：

1. `GET /metrics`：Prometheus 文本格式。
2. `GET /healthz`：健康检查。

## 9. Prometheus 抓取示例

```yaml
scrape_configs:
  - job_name: nvshare-scheduler
    scrape_interval: 2s
    metrics_path: /metrics
    static_configs:
      - targets:
          - nvshare-scheduler.nvshare-system.svc:9402
```

## 10. 常用查询示例

1. 每 GPU 显存压力：

```promql
nvshare_gpu_memory_used_bytes / nvshare_gpu_memory_total_bytes
```

2. 每 Pod 容量规划建议（近 5 分钟峰值）：

```promql
max_over_time(nvshare_client_memory_need_estimated_bytes[5m])
```

3. 每 Pod 保守上界（近 5 分钟峰值）：

```promql
max_over_time(nvshare_client_memory_need_upper_bytes[5m])
```

4. 配额使用率：

```promql
nvshare_client_core_window_usage_ms / nvshare_client_core_window_limit_ms
```

5. GPU 利用率与总配额对比：

```promql
sum by (gpu_uuid) (nvshare_client_core_quota_effective_percent) / 100
```

对照：

```promql
nvshare_gpu_utilization_ratio
```

## 11. 告警建议

1. 显存压力高：
   - 条件：`nvshare_gpu_memory_used_bytes / nvshare_gpu_memory_total_bytes > 0.9` 持续 3 分钟。
2. Pod 超 quota：
   - 条件：`nvshare_client_memory_quota_exceeded == 1` 持续 1 分钟。
3. 长时间 throttle：
   - 条件：`avg_over_time(nvshare_client_throttled[5m]) > 0.8`。
4. 调度拥塞：
   - 条件：`nvshare_scheduler_wait_queue_clients > 0` 且 `nvshare_gpu_utilization_ratio < 0.4`。

## 12. 分阶段落地计划

### 阶段 A（最小可用，1~2 天）

1. 暴露 scheduler 现有内存/队列/quota 指标。
2. 增加 GPU 级 NVML 指标（不做进程映射）。

验收：

1. Prometheus 可抓到 GPU 利用率、GPU 显存、running/wait 队列、client quota。

### 阶段 B（进程显存增强，2~3 天）

1. 协议新增 `host_pid` 并完成 `(gpu_uuid,pid)->client` 映射。
2. 暴露 `nvshare_client_nvml_used_bytes` 与估算指标。

验收：

1. 在 `tests/pytorch-add-small.py` 场景下，可同时看到 `managed`、`nvml`、`estimated/upper` 三种口径。

### 阶段 C（稳定性与可观测性，1~2 天）

1. 增加事件 counter 与健康指标。
2. 完成告警规则与 dashboard 模板。

## 13. 风险与边界

1. UVM 场景下“严格真实驻留显存”不可直接获得；`nvml_used` 是最接近观测值，不是绝对真值。
2. PID 映射依赖 `host_pid` 传递，需处理 PID 复用（建议加 `process_start_time`）。
3. 高基数风险：
   - debug 标签默认关闭。
4. NVML 调用失败时：
   - 保留 scheduler 指标，NVML 指标打 `up=0`（或对应指标缺失并记录错误计数）。

## 14. 与当前代码语义对齐说明

1. `managed allocation` 来自 client 侧 `MEM_UPDATE`，对应当前 `sum_allocated` 语义。
2. `running_memory_usage` / `peak_memory_usage` 对应 scheduler 现有字段。
3. `memory quota` 与 `core quota` 分别对应动态 annotation 机制。

该方案可以覆盖你当前关注的全部监控诉求：  
`进程显存观测 + 容量估算 + GPU利用率 + 显存/算力quota + 调度状态`，并保持语义清晰、可解释、可落地。
