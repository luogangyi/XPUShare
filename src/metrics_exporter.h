/*
 * Prometheus metrics HTTP exporter for nvshare-scheduler.
 */

#ifndef _NVSHARE_METRICS_EXPORTER_H_
#define _NVSHARE_METRICS_EXPORTER_H_

#include <pthread.h>
#include <sys/types.h>

#include "comm.h"

/* Default metrics port */
#define NVSHARE_DEFAULT_METRICS_PORT 9402
#define NVSHARE_METRICS_BUFFER_SIZE (256 * 1024) /* 256 KB output buffer */
#define MAX_SNAPSHOT_CLIENTS 256
#define MAX_SNAPSHOT_CONTEXTS 16
#define NVSHARE_MSG_TYPE_COUNT 21
#define NVSHARE_INIT_FAIL_REASON_MAX 16

/* ---- Snapshot structures for lock-free formatting ---- */

struct client_snapshot {
  uint64_t id;
  char pod_name[POD_NAME_LEN_MAX];
  char pod_namespace[POD_NAMESPACE_LEN_MAX];
  char gpu_uuid[NVSHARE_GPU_UUID_LEN];
  int gpu_index;
  pid_t host_pid;
  size_t memory_allocated;
  size_t memory_managed;
  size_t memory_native;
  size_t peak_allocated;
  size_t peak_managed;
  size_t peak_native;
  unsigned long fallback_symbol_unavailable;
  unsigned long fallback_align_overflow;
  unsigned long fallback_alloc_failed;
  unsigned long fallback_cfg_nonnull;
  unsigned long prefetch_ok_total;
  unsigned long prefetch_fail_total;
  size_t memory_limit;
  uint32_t capability_flags;
  int uses_active_meter;
  int core_limit;
  int is_running;
  int is_throttled;
  int pending_drop;
  long core_usage_in_window_ms;
  long run_time_in_window_ms;
  long active_time_in_window_ms;
  uint64_t active_time_total_ms;
  uint64_t active_time_report_count;
  long quota_debt_ms;
  long effective_quota_ms;
  long window_limit_ms;
};

struct context_snapshot {
  char uuid[NVSHARE_GPU_UUID_LEN];
  int gpu_index;
  int running_count;
  int request_count;
  int wait_count;
  int init_wait_count;
  int init_owner_active;
  size_t running_memory;
  size_t peak_memory;
  size_t total_memory;
  int memory_reserve_percent;
  int memory_overloaded;
};

struct init_fail_reason_snapshot {
  int acl_error;
  unsigned long count;
};

struct scheduler_snapshot {
  int client_count;
  struct client_snapshot clients[MAX_SNAPSHOT_CLIENTS];
  int context_count;
  struct context_snapshot contexts[MAX_SNAPSHOT_CONTEXTS];
  unsigned long msg_counts[NVSHARE_MSG_TYPE_COUNT];
  unsigned long drop_lock_count;
  unsigned long client_disconnect_count;
  unsigned long wait_for_mem_count;
  unsigned long mem_available_count;
  unsigned long init_wait_count;
  unsigned long init_wait_sum_ms;
  unsigned long init_wait_max_ms;
  unsigned long init_preempt_count;
  int init_fail_reason_count;
  struct init_fail_reason_snapshot
      init_fail_reasons[NVSHARE_INIT_FAIL_REASON_MAX];
};

/* Metrics configuration */
struct metrics_config {
  int enabled;
  char bind_addr[64];
  int port;
  int debug_labels; /* 0=minimal labels, 1=include client_id/host_pid */
  int stale_ttl_sec;
};

extern struct metrics_config g_metrics_config;

/*
 * Initialize the metrics exporter configuration from env vars.
 * Call before starting the metrics server thread.
 */
void metrics_exporter_init_config(void);

/*
 * Metrics HTTP server thread function.
 * Binds, listens, and serves /metrics and /healthz.
 */
void* metrics_exporter_thread_fn(void* arg);

/* ---- Event counters (incremented from scheduler.c) ---- */

/* Message type counters */
extern unsigned long g_metrics_msg_count[NVSHARE_MSG_TYPE_COUNT];

/* Specific event counters */
extern unsigned long g_metrics_drop_lock_count;
extern unsigned long g_metrics_client_disconnect_count;
extern unsigned long g_metrics_wait_for_mem_count;
extern unsigned long g_metrics_mem_available_count;
extern unsigned long g_metrics_init_wait_count;
extern unsigned long g_metrics_init_wait_sum_ms;
extern unsigned long g_metrics_init_wait_max_ms;
extern unsigned long g_metrics_init_preempt_count;
extern int g_metrics_init_fail_reason_count;
extern struct init_fail_reason_snapshot
    g_metrics_init_fail_reasons[NVSHARE_INIT_FAIL_REASON_MAX];

/* Increment helpers (not atomic, but always called under global_mutex) */
static inline void metrics_inc_msg(int type) {
  if (type >= 0 && type < NVSHARE_MSG_TYPE_COUNT) {
    g_metrics_msg_count[type]++;
  }
}

static inline void metrics_inc_drop_lock(void) { g_metrics_drop_lock_count++; }

static inline void metrics_inc_client_disconnect(void) {
  g_metrics_client_disconnect_count++;
}

static inline void metrics_inc_wait_for_mem(void) {
  g_metrics_wait_for_mem_count++;
}

static inline void metrics_inc_mem_available(void) {
  g_metrics_mem_available_count++;
}

void metrics_record_init_wait(long wait_ms);
void metrics_record_init_preempt(void);
void metrics_record_init_fail_reason(int acl_error);

#endif /* _NVSHARE_METRICS_EXPORTER_H_ */
