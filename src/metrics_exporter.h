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
#define NVSHARE_MSG_TYPE_COUNT 16

/* ---- Snapshot structures for lock-free formatting ---- */

struct client_snapshot {
  uint64_t id;
  char pod_name[POD_NAME_LEN_MAX];
  char pod_namespace[POD_NAMESPACE_LEN_MAX];
  char gpu_uuid[NVSHARE_GPU_UUID_LEN];
  int gpu_index;
  pid_t host_pid;
  size_t memory_allocated;
  size_t peak_allocated;
  size_t memory_limit;
  int core_limit;
  int is_running;
  int is_throttled;
  int pending_drop;
  long run_time_in_window_ms;
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
  size_t running_memory;
  size_t peak_memory;
  size_t total_memory;
  int memory_reserve_percent;
  int memory_overloaded;
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

#endif /* _NVSHARE_METRICS_EXPORTER_H_ */
