# Prometheus Metrics Implementation for NVShare Scheduler

This implements **Phase A** (最小可用) from [prometheus_metrics_design.md](file:///Users/luogangyi/Code/nvshare/docs/design/prometheus_metrics_design.md): exposing scheduler state, GPU-level NVML metrics, per-client metrics, and event counters via a Prometheus-compatible HTTP endpoint.

## User Review Required

> [!IMPORTANT]
> **Phase A scope**: We implement all metrics from §5.1-§5.5 in a single pass, but defer `O_base` EWMA overhead estimation (§6, `nvshare_client_memory_overhead_baseline_bytes`) and stale-series TTL garbage collection to Phase B. The `nvml_used_bytes` per-process metric requires `host_pid` mapping which is included.

> [!WARNING]
> **NVML dependency**: The scheduler currently does NOT link against NVML. The Dockerfile base image (`ubuntu:18.04`) does not have NVML headers. Since the scheduler runs inside a container with NVIDIA drivers mounted, we'll use runtime `dlopen("libnvidia-ml.so.1")` to load NVML symbols dynamically—just like `client.c`/`hook.c` already does for the client side. This avoids build-time NVML dependency entirely.

> [!IMPORTANT]
> **HTTP server**: Since this is a C codebase with no external HTTP library, we implement a minimal, custom TCP-based HTTP responder. It only needs to handle `GET /metrics` and `GET /healthz`—no general-purpose HTTP parsing needed.

---

## Proposed Changes

### Protocol Layer

#### [MODIFY] [comm.h](file:///Users/luogangyi/Code/nvshare/src/comm.h)

Add two new fields to `struct message`:
- `uint16_t protocol_version` — set to `2` by new clients, `0` by old clients (backwards compatible)
- `pid_t host_pid` — the host-namespace PID of the client process

```diff
 struct message {
   enum message_type type;
+  uint16_t protocol_version;
   char pod_name[POD_NAME_LEN_MAX];
   char pod_namespace[POD_NAMESPACE_LEN_MAX];
   char gpu_uuid[NVSHARE_GPU_UUID_LEN];
   uint64_t id;
   char data[MSG_DATA_LEN];
   size_t memory_usage;
   size_t memory_limit;
   int core_limit;
+  pid_t host_pid;
 } __attribute__((__packed__));
```

---

#### [MODIFY] [client.c](file:///Users/luogangyi/Code/nvshare/src/client.c)

Set `host_pid = getpid()` and `protocol_version = 2` in the REGISTER message before sending to the scheduler.

---

### Scheduler Core Changes

#### [MODIFY] [scheduler.c](file:///Users/luogangyi/Code/nvshare/src/scheduler.c)

1. **`nvshare_client` struct**: Add `host_pid` (from REGISTER), `peak_allocated` (track lifetime peak managed allocation).

2. **`register_client()`**: Save `in_msg->host_pid` into client struct.

3. **`process_msg(MEM_UPDATE)`**: Track `peak_allocated = max(peak_allocated, memory_allocated)`.

4. **Event counters**: Add global atomic counters:
   - `messages_total[type]` — increment in `process_msg` per message type
   - `drop_lock_total` — incremented when DROP_LOCK is sent
   - `client_disconnect_total` — incremented in `delete_client`
   - `wait_for_mem_total`, `mem_available_total` — incremented when sending WAIT_FOR_MEM / MEM_AVAILABLE

5. **`main()`**: Start NVML sampler thread and metrics HTTP server thread after config init.

---

### New Files

#### [NEW] [nvml_sampler.h](file:///Users/luogangyi/Code/nvshare/src/nvml_sampler.h)

Header for NVML sampler thread and data structures.

#### [NEW] [nvml_sampler.c](file:///Users/luogangyi/Code/nvshare/src/nvml_sampler.c)

NVML sampler thread that periodically (default 1s) collects:

1. **GPU-level**: For each GPU context, get device handle by UUID, then:
   - `nvmlDeviceGetMemoryInfo` → total/used/free
   - `nvmlDeviceGetUtilizationRates` → gpu_util, mem_util
   - `nvmlDeviceGetName` → gpu_name (cached, once)

2. **Process-level**: `nvmlDeviceGetComputeRunningProcesses` → per-PID `usedGpuMemory`

3. **Data storage**: Protected snapshot struct with `pthread_rwlock`:
   ```c
   struct nvml_gpu_snapshot {
     char uuid[96];
     int gpu_index;
     char gpu_name[96];
     size_t memory_total, memory_used, memory_free;
     float gpu_util, mem_util;
     int process_count;
     struct { pid_t pid; size_t used_mem; } processes[64];
   };
   ```

4. **Symbol loading**: Use `dlopen("libnvidia-ml.so.1")` + `dlsym` to resolve NVML functions at runtime, similar to how `cuda_defs.h` works in the client. If NVML is unavailable, sampler thread logs a warning and fills GPU metrics with zeros.

---

#### [NEW] [metrics_exporter.h](file:///Users/luogangyi/Code/nvshare/src/metrics_exporter.h)

Header for HTTP metrics exporter.

#### [NEW] [metrics_exporter.c](file:///Users/luogangyi/Code/nvshare/src/metrics_exporter.c)

Minimal HTTP server exposing Prometheus metrics:

1. **Server thread**: Binds to `NVSHARE_METRICS_ADDR` (default `0.0.0.0:9402`), accepts connections, handles `GET /metrics` and `GET /healthz`.

2. **`/metrics` handler**:
   - Acquires `global_mutex` briefly to snapshot scheduler state (clients, gpu_contexts, event counters)
   - Acquires NVML rwlock to snapshot GPU/process data
   - Releases all locks
   - Formats Prometheus text exposition format into buffer
   - Sends HTTP 200 response

3. **`/healthz` handler**: Returns `HTTP 200 OK`

4. **Metrics output** (all from §5.1-§5.5):

   | Section | Metrics |
   |---------|---------|
   | §5.1 GPU | `nvshare_gpu_info`, `gpu_memory_total/used/free_bytes`, `gpu_utilization_ratio`, `gpu_memory_utilization_ratio`, `gpu_process_count` |
   | §5.2 Client Memory | `nvshare_client_info`, `client_managed_allocated_bytes`, `client_managed_allocated_peak_bytes`, `client_nvml_used_bytes`, `client_memory_quota_bytes`, `client_memory_quota_exceeded` |
   | §5.3 Compute | `client_core_quota_config_percent`, `client_core_quota_effective_percent`, `client_core_window_usage_ms`, `client_core_window_limit_ms`, `client_core_usage_ratio`, `client_throttled`, `client_pending_drop`, `client_quota_debt_ms` |
   | §5.4 Scheduler | `scheduler_running_clients`, `scheduler_request_queue_clients`, `scheduler_wait_queue_clients`, `scheduler_running_memory_bytes`, `scheduler_peak_running_memory_bytes`, `scheduler_memory_safe_limit_bytes`, `scheduler_memory_overloaded` |
   | §5.5 Events | `scheduler_messages_total`, `scheduler_drop_lock_total`, `scheduler_client_disconnect_total`, `scheduler_wait_for_mem_total`, `scheduler_mem_available_total` |

   Deferred to Phase B:
   - `nvshare_client_memory_overhead_baseline_bytes` (needs EWMA with O_base)
   - `nvshare_client_memory_need_estimated_bytes` (needs O_base)
   - `nvshare_client_memory_need_upper_bytes` (straightforward once nvml_used is available, but semantically tied to O_base estimation)
   - `nvshare_client_memory_quota_source_info` (needs source tracking)
   - Debug label toggle (`NVSHARE_METRICS_DEBUG_LABELS`)
   - Stale series TTL cleanup

---

### Build & Docker

#### [MODIFY] [Makefile](file:///Users/luogangyi/Code/nvshare/src/Makefile)

- Add `nvml_sampler.o` and `metrics_exporter.o` to the `nvshare-scheduler` target
- Add `-ldl` to `SCHEDULER_LDLIBS` (for `dlopen`/`dlsym` of NVML)

```diff
-nvshare-scheduler: scheduler.o common.o comm.o k8s_api.o
-	$(CC) $(CFLAGS) $(GENERAL_LDFLAGS) $^ -o $@ $(SCHEDULER_LDLIBS)
+SCHEDULER_LDLIBS = -lpthread -lcurl -ldl
+nvshare-scheduler: scheduler.o common.o comm.o k8s_api.o nvml_sampler.o metrics_exporter.o
+	$(CC) $(CFLAGS) $(GENERAL_LDFLAGS) $^ -o $@ $(SCHEDULER_LDLIBS)
```

#### [MODIFY] [Dockerfile.scheduler](file:///Users/luogangyi/Code/nvshare/Dockerfile.scheduler)

- Add `EXPOSE 9402` to document the metrics port

---

## Verification Plan

### Build Verification

Since the project uses Docker-based builds targeting Linux/NVIDIA, building locally on macOS won't work. Verification requires building the Docker image.

```bash
cd /Users/luogangyi/Code/nvshare
docker build -f Dockerfile.scheduler -t nvshare:test-scheduler .
```

> [!IMPORTANT]
> If the Docker build is not feasible in the current environment (no Docker / no GPU), we at minimum verify:
> 1. All new `.c` files have correct `#include` references
> 2. No syntax errors via a dry-run compile check (on platforms with gcc)

### Functional Verification (Manual, on GPU node)

Since this is a C system-level component running on GPU nodes, automated unit testing is impractical. The verification relies on deploying and testing on a real Kubernetes cluster with GPUs.

1. **Deploy updated scheduler** to the test cluster
2. **Verify metrics endpoint**:
   ```bash
   # Port-forward or curl from within the cluster
   curl http://nvshare-scheduler-pod:9402/healthz
   # Expected: HTTP 200, body "OK"

   curl http://nvshare-scheduler-pod:9402/metrics
   # Expected: Prometheus text format with all metrics
   ```
3. **Verify with a running workload** (e.g., `tests/pytorch-add-small.py`):
   - Start a test pod
   - Curl `/metrics` and verify:
     - `nvshare_gpu_memory_total_bytes` shows correct GPU memory
     - `nvshare_gpu_utilization_ratio` > 0 during workload
     - `nvshare_client_managed_allocated_bytes` shows non-zero allocation
     - `nvshare_scheduler_running_clients` shows 1

4. **Verify Prometheus scrape**: Add the scheduler as a scrape target and confirm metrics appear in Prometheus UI.

### Code Review (Static)

After implementation, review the following:
- Thread safety: all shared state accessed under `global_mutex` or NVML rwlock
- No memory leaks in HTTP handler (buffer allocation)
- Prometheus text format compliance (metric name, label escaping, HELP/TYPE lines)
