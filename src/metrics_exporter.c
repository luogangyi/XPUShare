/*
 * Prometheus metrics HTTP exporter for nvshare-scheduler.
 *
 * Provides a minimal HTTP server that serves Prometheus text format
 * metrics on /metrics and a health check on /healthz.
 *
 * Thread-safety: snapshots scheduler state under global_mutex,
 * then formats the response outside the lock.
 */

#include "metrics_exporter.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "comm.h"
#include "common.h"
#include "nvml_sampler.h"

/* ---- External scheduler state (defined in scheduler.c) ---- */

/* We need to access these from scheduler.c */
extern pthread_mutex_t global_mutex;

/* Forward declarations of types from scheduler.c.
 * We include them here via extern pointers; the actual struct definitions
 * live in scheduler.c. To avoid exposing internal structs, we use a
 * snapshot approach: scheduler.c provides a function to fill the snapshot.
 */

/* ---- Event counter storage ---- */

unsigned long g_metrics_msg_count[NVSHARE_MSG_TYPE_COUNT] = {0};
unsigned long g_metrics_drop_lock_count = 0;
unsigned long g_metrics_client_disconnect_count = 0;
unsigned long g_metrics_wait_for_mem_count = 0;
unsigned long g_metrics_mem_available_count = 0;

/* ---- Metrics config ---- */

struct metrics_config g_metrics_config = {
    .enabled = 0,
    .bind_addr = "0.0.0.0",
    .port = NVSHARE_DEFAULT_METRICS_PORT,
    .debug_labels = 0,
    .stale_ttl_sec = 300,
};

void metrics_exporter_init_config(void) {
  char* val;

  val = getenv("NVSHARE_METRICS_ENABLE");
  if (val && (strcmp(val, "1") == 0 || strcmp(val, "true") == 0)) {
    g_metrics_config.enabled = 1;
  }

  val = getenv("NVSHARE_METRICS_ADDR");
  if (val) {
    /* Parse "host:port" or just "port" */
    char* colon = strrchr(val, ':');
    if (colon) {
      size_t host_len = (size_t)(colon - val);
      if (host_len > 0 && host_len < sizeof(g_metrics_config.bind_addr)) {
        memcpy(g_metrics_config.bind_addr, val, host_len);
        g_metrics_config.bind_addr[host_len] = '\0';
      }
      g_metrics_config.port = atoi(colon + 1);
    } else {
      g_metrics_config.port = atoi(val);
    }
  }

  val = getenv("NVSHARE_METRICS_DEBUG_LABELS");
  if (val && strcmp(val, "1") == 0) {
    g_metrics_config.debug_labels = 1;
  }

  val = getenv("NVSHARE_METRICS_STALE_TTL_SEC");
  if (val) {
    g_metrics_config.stale_ttl_sec = atoi(val);
  }

  if (g_metrics_config.enabled) {
    log_info("Metrics exporter enabled on %s:%d (debug_labels=%d)",
             g_metrics_config.bind_addr, g_metrics_config.port,
             g_metrics_config.debug_labels);
  }
}

/*
 * This function is implemented in scheduler.c to fill the snapshot
 * while holding global_mutex. It avoids exposing internal data structures.
 */
extern void metrics_fill_scheduler_snapshot(struct scheduler_snapshot* snap);

/* ---- Buffer helper ---- */

struct metrics_buf {
  char* data;
  size_t len;
  size_t cap;
};

static void buf_init(struct metrics_buf* b, size_t cap) {
  b->data = malloc(cap);
  b->len = 0;
  b->cap = cap;
  if (b->data) b->data[0] = '\0';
}

static void buf_append(struct metrics_buf* b, const char* fmt, ...)
    __attribute__((format(printf, 2, 3)));
static void buf_append(struct metrics_buf* b, const char* fmt, ...) {
  if (!b->data || b->len >= b->cap - 1) return;
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap);
  va_end(ap);
  if (n > 0) {
    b->len += (size_t)n;
    if (b->len >= b->cap) b->len = b->cap - 1;
  }
}

static void buf_free(struct metrics_buf* b) {
  free(b->data);
  b->data = NULL;
  b->len = b->cap = 0;
}

/* ---- Prometheus text formatting ---- */

static void format_gpu_metrics(struct metrics_buf* b) {
  pthread_rwlock_rdlock(&g_nvml_snapshot.lock);

  if (!g_nvml_snapshot.sampler_available) {
    buf_append(b,
               "# HELP nvshare_gpu_sampler_up Whether GPU sampler backend is "
               "available (1=yes, 0=no)\n"
               "# TYPE nvshare_gpu_sampler_up gauge\n"
               "nvshare_gpu_sampler_up 0\n");
    buf_append(b,
               "# HELP nvshare_nvml_up Whether NVML is available (1=yes, "
               "0=no)\n"
               "# TYPE nvshare_nvml_up gauge\n"
               "nvshare_nvml_up 0\n");
    pthread_rwlock_unlock(&g_nvml_snapshot.lock);
    return;
  }

  const char* backend = "unknown";
  if (g_nvml_snapshot.backend_kind == GPU_SAMPLER_BACKEND_NVML) {
    backend = "nvml";
  } else if (g_nvml_snapshot.backend_kind == GPU_SAMPLER_BACKEND_DCMI) {
    backend = "dcmi";
  } else if (g_nvml_snapshot.backend_kind == GPU_SAMPLER_BACKEND_ACL) {
    backend = "acl";
  }

  buf_append(
      b,
      "# HELP nvshare_gpu_sampler_up Whether GPU sampler backend is available "
      "(1=yes, 0=no)\n"
      "# TYPE nvshare_gpu_sampler_up gauge\n"
      "nvshare_gpu_sampler_up 1\n");
  buf_append(b,
             "# HELP nvshare_gpu_sampler_backend_info Active sampler backend\n"
             "# TYPE nvshare_gpu_sampler_backend_info gauge\n"
             "nvshare_gpu_sampler_backend_info{backend=\"%s\"} 1\n",
             backend);

  buf_append(b,
             "# HELP nvshare_nvml_up Whether NVML is available (1=yes, 0=no)\n"
             "# TYPE nvshare_nvml_up gauge\n"
             "nvshare_nvml_up %d\n",
             g_nvml_snapshot.nvml_available ? 1 : 0);

  buf_append(b,
             "# HELP nvshare_gpu_info GPU device information\n"
             "# TYPE nvshare_gpu_info gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(b,
               "nvshare_gpu_info{gpu_uuid=\"%s\",gpu_index=\"%d\",gpu_name=\"%"
               "s\"} 1\n",
               g->uuid, g->gpu_index, g->gpu_name);
  }

  buf_append(b,
             "# HELP nvshare_gpu_memory_total_bytes Total GPU memory in bytes\n"
             "# TYPE nvshare_gpu_memory_total_bytes gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(
        b,
        "nvshare_gpu_memory_total_bytes{gpu_uuid=\"%s\",gpu_index=\"%d\"} "
        "%zu\n",
        g->uuid, g->gpu_index, g->memory_total);
  }

  buf_append(b,
             "# HELP nvshare_gpu_memory_used_bytes Used GPU memory in bytes\n"
             "# TYPE nvshare_gpu_memory_used_bytes gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(
        b,
        "nvshare_gpu_memory_used_bytes{gpu_uuid=\"%s\",gpu_index=\"%d\"} "
        "%zu\n",
        g->uuid, g->gpu_index, g->memory_used);
  }

  buf_append(b,
             "# HELP nvshare_gpu_memory_free_bytes Free GPU memory in bytes\n"
             "# TYPE nvshare_gpu_memory_free_bytes gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(
        b,
        "nvshare_gpu_memory_free_bytes{gpu_uuid=\"%s\",gpu_index=\"%d\"} "
        "%zu\n",
        g->uuid, g->gpu_index, g->memory_free);
  }

  buf_append(b,
             "# HELP nvshare_gpu_utilization_ratio GPU utilization (0~1)\n"
             "# TYPE nvshare_gpu_utilization_ratio gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(
        b,
        "nvshare_gpu_utilization_ratio{gpu_uuid=\"%s\",gpu_index=\"%d\"} "
        "%.4f\n",
        g->uuid, g->gpu_index, g->gpu_util);
  }

  buf_append(b,
             "# HELP nvshare_gpu_memory_utilization_ratio Memory controller "
             "utilization (0~1)\n"
             "# TYPE nvshare_gpu_memory_utilization_ratio gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(b,
               "nvshare_gpu_memory_utilization_ratio{gpu_uuid=\"%s\",gpu_index="
               "\"%d\"} %.4f\n",
               g->uuid, g->gpu_index, g->mem_util);
  }

  buf_append(
      b,
      "# HELP nvshare_gpu_process_count Number of compute processes on GPU\n"
      "# TYPE nvshare_gpu_process_count gauge\n");
  for (int i = 0; i < g_nvml_snapshot.gpu_count; i++) {
    struct nvml_gpu_snapshot* g = &g_nvml_snapshot.gpus[i];
    if (!g->valid) continue;
    buf_append(
        b, "nvshare_gpu_process_count{gpu_uuid=\"%s\",gpu_index=\"%d\"} %d\n",
        g->uuid, g->gpu_index, g->process_count);
  }

  pthread_rwlock_unlock(&g_nvml_snapshot.lock);
}

static void format_client_metrics(struct metrics_buf* b,
                                  struct scheduler_snapshot* snap) {
  /* Client info */
  buf_append(b,
             "# HELP nvshare_client_info Client metadata (value=1)\n"
             "# TYPE nvshare_client_info gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_info{namespace=\"%s\",pod=\"%s\",client_id="
               "\"%016lx\",gpu_uuid=\"%s\",gpu_index=\"%d\",host_pid=\"%d\"} "
               "1\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->gpu_index, (int)c->host_pid);
  }

  /* Managed allocation */
  buf_append(b,
             "# HELP nvshare_client_managed_allocated_bytes Current managed "
             "allocation\n"
             "# TYPE nvshare_client_managed_allocated_bytes gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_managed_allocated_bytes{namespace=\"%s\",pod="
               "\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %zu\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->memory_allocated);
  }

  /* Peak managed allocation */
  buf_append(b,
             "# HELP nvshare_client_managed_allocated_peak_bytes Lifetime peak "
             "managed allocation\n"
             "# TYPE nvshare_client_managed_allocated_peak_bytes gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_managed_allocated_peak_bytes{namespace=\"%s\","
               "pod=\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %zu\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->peak_allocated);
  }

  /* NVML used bytes (per-process, matched by host_pid) */
  buf_append(
      b,
      "# HELP nvshare_client_nvml_used_bytes NVML per-process GPU memory\n"
      "# TYPE nvshare_client_nvml_used_bytes gauge\n");
  pthread_rwlock_rdlock(&g_nvml_snapshot.lock);
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    if (c->host_pid <= 0) continue;
    /* Find matching NVML process entry */
    size_t nvml_used = 0;
    for (int g = 0; g < g_nvml_snapshot.gpu_count; g++) {
      struct nvml_gpu_snapshot* gs = &g_nvml_snapshot.gpus[g];
      if (!gs->valid) continue;
      /* Match by GPU UUID prefix */
      if (strncmp(gs->uuid, c->gpu_uuid, strlen(c->gpu_uuid)) != 0 &&
          strncmp(c->gpu_uuid, gs->uuid, strlen(gs->uuid)) != 0)
        continue;
      for (int p = 0; p < gs->process_count; p++) {
        if (gs->processes[p].pid == c->host_pid) {
          nvml_used = gs->processes[p].used_memory;
          break;
        }
      }
    }
    buf_append(b,
               "nvshare_client_nvml_used_bytes{namespace=\"%s\",pod=\"%s\","
               "client_id=\"%016lx\",gpu_uuid=\"%s\",host_pid=\"%d\"} %zu\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               (int)c->host_pid, nvml_used);
  }
  pthread_rwlock_unlock(&g_nvml_snapshot.lock);

  /* Memory quota */
  buf_append(b,
             "# HELP nvshare_client_memory_quota_bytes Configured memory quota "
             "(0=unlimited)\n"
             "# TYPE nvshare_client_memory_quota_bytes gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_memory_quota_bytes{namespace=\"%s\",pod=\"%s\","
               "client_id=\"%016lx\",gpu_uuid=\"%s\"} %zu\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->memory_limit);
  }

  /* Memory quota exceeded */
  buf_append(
      b,
      "# HELP nvshare_client_memory_quota_exceeded Whether allocation exceeds "
      "quota (0/1)\n"
      "# TYPE nvshare_client_memory_quota_exceeded gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    int exceeded =
        (c->memory_limit > 0 && c->memory_allocated > c->memory_limit) ? 1 : 0;
    buf_append(b,
               "nvshare_client_memory_quota_exceeded{namespace=\"%s\",pod="
               "\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %d\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               exceeded);
  }
}

static void format_compute_metrics(struct metrics_buf* b,
                                   struct scheduler_snapshot* snap) {
  buf_append(
      b,
      "# HELP nvshare_client_core_quota_config_percent Configured compute "
      "quota (1-100)\n"
      "# TYPE nvshare_client_core_quota_config_percent gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_core_quota_config_percent{namespace=\"%s\",pod="
               "\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %d\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->core_limit);
  }

  buf_append(
      b,
      "# HELP nvshare_client_core_quota_effective_percent Effective compute "
      "quota after scaling\n"
      "# TYPE nvshare_client_core_quota_effective_percent gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    /* Compute effective percentage from effective_quota_ms and window_limit_ms
     */
    int effective_pct = 100;
    if (c->window_limit_ms > 0) {
      effective_pct = (int)(c->effective_quota_ms * 100 / c->window_limit_ms);
    }
    buf_append(b,
               "nvshare_client_core_quota_effective_percent{namespace=\"%s\","
               "pod=\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %d\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               effective_pct);
  }

  buf_append(
      b,
      "# HELP nvshare_client_core_window_usage_ms Runtime in current window "
      "(ms)\n"
      "# TYPE nvshare_client_core_window_usage_ms gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_core_window_usage_ms{namespace=\"%s\",pod="
               "\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %ld\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->run_time_in_window_ms);
  }

  buf_append(b,
             "# HELP nvshare_client_core_window_limit_ms Window limit (ms)\n"
             "# TYPE nvshare_client_core_window_limit_ms gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_core_window_limit_ms{namespace=\"%s\",pod="
               "\"%s\",client_id=\"%016lx\",gpu_uuid=\"%s\"} %ld\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->effective_quota_ms);
  }

  buf_append(b,
             "# HELP nvshare_client_core_usage_ratio usage_ms / limit_ms\n"
             "# TYPE nvshare_client_core_usage_ratio gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    float ratio = 0.0f;
    if (c->effective_quota_ms > 0)
      ratio = (float)c->run_time_in_window_ms / (float)c->effective_quota_ms;
    buf_append(b,
               "nvshare_client_core_usage_ratio{namespace=\"%s\",pod=\"%s\","
               "client_id=\"%016lx\",gpu_uuid=\"%s\"} %.4f\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               ratio);
  }

  buf_append(b,
             "# HELP nvshare_client_throttled Whether client is throttled "
             "(0/1)\n"
             "# TYPE nvshare_client_throttled gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_throttled{namespace=\"%s\",pod=\"%s\",client_id="
               "\"%016lx\",gpu_uuid=\"%s\"} %d\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->is_throttled);
  }

  buf_append(
      b,
      "# HELP nvshare_client_pending_drop Whether DROP sent awaiting release "
      "(0/1)\n"
      "# TYPE nvshare_client_pending_drop gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_pending_drop{namespace=\"%s\",pod=\"%s\","
               "client_id=\"%016lx\",gpu_uuid=\"%s\"} %d\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->pending_drop);
  }

  buf_append(b,
             "# HELP nvshare_client_quota_debt_ms Carryover debt (ms)\n"
             "# TYPE nvshare_client_quota_debt_ms gauge\n");
  for (int i = 0; i < snap->client_count; i++) {
    struct client_snapshot* c = &snap->clients[i];
    buf_append(b,
               "nvshare_client_quota_debt_ms{namespace=\"%s\",pod=\"%s\","
               "client_id=\"%016lx\",gpu_uuid=\"%s\"} %ld\n",
               c->pod_namespace, c->pod_name, (unsigned long)c->id, c->gpu_uuid,
               c->quota_debt_ms);
  }
}

static void format_scheduler_metrics(struct metrics_buf* b,
                                     struct scheduler_snapshot* snap) {
  buf_append(b,
             "# HELP nvshare_scheduler_running_clients Running list length\n"
             "# TYPE nvshare_scheduler_running_clients gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_running_clients{gpu_uuid=\"%s\",gpu_index="
               "\"%d\"} %d\n",
               ctx->uuid, ctx->gpu_index, ctx->running_count);
  }

  buf_append(
      b,
      "# HELP nvshare_scheduler_request_queue_clients Request queue length\n"
      "# TYPE nvshare_scheduler_request_queue_clients gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_request_queue_clients{gpu_uuid=\"%s\",gpu_"
               "index=\"%d\"} %d\n",
               ctx->uuid, ctx->gpu_index, ctx->request_count);
  }

  buf_append(b,
             "# HELP nvshare_scheduler_wait_queue_clients Wait queue length\n"
             "# TYPE nvshare_scheduler_wait_queue_clients gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_wait_queue_clients{gpu_uuid=\"%s\",gpu_index="
               "\"%d\"} %d\n",
               ctx->uuid, ctx->gpu_index, ctx->wait_count);
  }

  buf_append(
      b,
      "# HELP nvshare_scheduler_running_memory_bytes Total running managed "
      "memory\n"
      "# TYPE nvshare_scheduler_running_memory_bytes gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_running_memory_bytes{gpu_uuid=\"%s\",gpu_"
               "index=\"%d\"} %zu\n",
               ctx->uuid, ctx->gpu_index, ctx->running_memory);
  }

  buf_append(b,
             "# HELP nvshare_scheduler_peak_running_memory_bytes Peak running "
             "memory\n"
             "# TYPE nvshare_scheduler_peak_running_memory_bytes gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_peak_running_memory_bytes{gpu_uuid=\"%s\","
               "gpu_index=\"%d\"} %zu\n",
               ctx->uuid, ctx->gpu_index, ctx->peak_memory);
  }

  buf_append(
      b,
      "# HELP nvshare_scheduler_memory_safe_limit_bytes Safe memory limit "
      "(total*(1-reserve))\n"
      "# TYPE nvshare_scheduler_memory_safe_limit_bytes gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    size_t safe_limit =
        ctx->total_memory * (100 - ctx->memory_reserve_percent) / 100;
    buf_append(b,
               "nvshare_scheduler_memory_safe_limit_bytes{gpu_uuid=\"%s\",gpu_"
               "index=\"%d\"} %zu\n",
               ctx->uuid, ctx->gpu_index, safe_limit);
  }

  buf_append(b,
             "# HELP nvshare_scheduler_memory_overloaded Memory overload state "
             "(0/1)\n"
             "# TYPE nvshare_scheduler_memory_overloaded gauge\n");
  for (int i = 0; i < snap->context_count; i++) {
    struct context_snapshot* ctx = &snap->contexts[i];
    buf_append(b,
               "nvshare_scheduler_memory_overloaded{gpu_uuid=\"%s\",gpu_index="
               "\"%d\"} %d\n",
               ctx->uuid, ctx->gpu_index, ctx->memory_overloaded);
  }
}

static void format_event_metrics(struct metrics_buf* b,
                                 struct scheduler_snapshot* snap) {
  buf_append(b,
             "# HELP nvshare_scheduler_messages_total Message counts by type\n"
             "# TYPE nvshare_scheduler_messages_total counter\n");
  const char* msg_names[] = {NULL,
                             "REGISTER",
                             "SCHED_ON",
                             "SCHED_OFF",
                             "REQ_LOCK",
                             "LOCK_OK",
                             "DROP_LOCK",
                             "LOCK_RELEASED",
                             "SET_TQ",
                             "MEM_UPDATE",
                             "WAIT_FOR_MEM",
                             "MEM_AVAILABLE",
                             "PREPARE_SWAP_OUT",
                             "UPDATE_LIMIT",
                             "UPDATE_CORE_LIMIT"};
  for (int i = 1; i < NVSHARE_MSG_TYPE_COUNT && i < 15; i++) {
    if (msg_names[i]) {
      buf_append(b, "nvshare_scheduler_messages_total{type=\"%s\"} %lu\n",
                 msg_names[i], snap->msg_counts[i]);
    }
  }

  buf_append(b,
             "# HELP nvshare_scheduler_drop_lock_total DROP_LOCK events sent\n"
             "# TYPE nvshare_scheduler_drop_lock_total counter\n"
             "nvshare_scheduler_drop_lock_total %lu\n",
             snap->drop_lock_count);

  buf_append(
      b,
      "# HELP nvshare_scheduler_client_disconnect_total Client disconnects\n"
      "# TYPE nvshare_scheduler_client_disconnect_total counter\n"
      "nvshare_scheduler_client_disconnect_total %lu\n",
      snap->client_disconnect_count);

  buf_append(
      b,
      "# HELP nvshare_scheduler_wait_for_mem_total WAIT_FOR_MEM events sent\n"
      "# TYPE nvshare_scheduler_wait_for_mem_total counter\n"
      "nvshare_scheduler_wait_for_mem_total %lu\n",
      snap->wait_for_mem_count);

  buf_append(
      b,
      "# HELP nvshare_scheduler_mem_available_total MEM_AVAILABLE events "
      "sent\n"
      "# TYPE nvshare_scheduler_mem_available_total counter\n"
      "nvshare_scheduler_mem_available_total %lu\n",
      snap->mem_available_count);
}

/* ---- HTTP handling ---- */

static void handle_metrics(int client_fd) {
  struct metrics_buf b;
  buf_init(&b, NVSHARE_METRICS_BUFFER_SIZE);

  /* Take scheduler snapshot under lock */
  struct scheduler_snapshot snap;
  memset(&snap, 0, sizeof(snap));

  pthread_mutex_lock(&global_mutex);
  metrics_fill_scheduler_snapshot(&snap);
  pthread_mutex_unlock(&global_mutex);

  /* Format all metrics (outside the lock) */
  format_gpu_metrics(&b);
  format_client_metrics(&b, &snap);
  format_compute_metrics(&b, &snap);
  format_scheduler_metrics(&b, &snap);
  format_event_metrics(&b, &snap);

  /* Send HTTP response */
  char header[256];
  int hlen = snprintf(header, sizeof(header),
                      "HTTP/1.1 200 OK\r\n"
                      "Content-Type: text/plain; version=0.0.4; "
                      "charset=utf-8\r\n"
                      "Content-Length: %zu\r\n"
                      "Connection: close\r\n"
                      "\r\n",
                      b.len);
  write(client_fd, header, (size_t)hlen);
  if (b.data && b.len > 0) {
    write(client_fd, b.data, b.len);
  }

  buf_free(&b);
}

static void handle_healthz(int client_fd) {
  const char* response =
      "HTTP/1.1 200 OK\r\n"
      "Content-Type: text/plain\r\n"
      "Content-Length: 3\r\n"
      "Connection: close\r\n"
      "\r\n"
      "OK\n";
  write(client_fd, response, strlen(response));
}

static void handle_not_found(int client_fd) {
  const char* response =
      "HTTP/1.1 404 Not Found\r\n"
      "Content-Type: text/plain\r\n"
      "Content-Length: 10\r\n"
      "Connection: close\r\n"
      "\r\n"
      "Not Found\n";
  write(client_fd, response, strlen(response));
}

static void handle_connection(int client_fd) {
  char buf[1024];
  ssize_t n = read(client_fd, buf, sizeof(buf) - 1);
  if (n <= 0) {
    close(client_fd);
    return;
  }
  buf[n] = '\0';

  /* Simple HTTP request parsing */
  if (strncmp(buf, "GET /metrics", 12) == 0) {
    handle_metrics(client_fd);
  } else if (strncmp(buf, "GET /healthz", 12) == 0) {
    handle_healthz(client_fd);
  } else {
    handle_not_found(client_fd);
  }

  close(client_fd);
}

/* ---- Server thread ---- */

void* metrics_exporter_thread_fn(void* arg __attribute__((unused))) {
  int server_fd, client_fd;
  struct sockaddr_in addr;
  int opt = 1;

  server_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (server_fd < 0) {
    log_warn("Metrics server: socket() failed: %s", strerror(errno));
    return NULL;
  }

  setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)g_metrics_config.port);
  if (inet_pton(AF_INET, g_metrics_config.bind_addr, &addr.sin_addr) <= 0) {
    addr.sin_addr.s_addr = INADDR_ANY;
  }

  if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    log_warn("Metrics server: bind() failed on port %d: %s",
             g_metrics_config.port, strerror(errno));
    close(server_fd);
    return NULL;
  }

  if (listen(server_fd, 8) < 0) {
    log_warn("Metrics server: listen() failed: %s", strerror(errno));
    close(server_fd);
    return NULL;
  }

  log_info("Metrics server listening on %s:%d", g_metrics_config.bind_addr,
           g_metrics_config.port);

  while (1) {
    client_fd = accept(server_fd, NULL, NULL);
    if (client_fd < 0) {
      if (errno == EINTR) continue;
      log_warn("Metrics server: accept() failed: %s", strerror(errno));
      continue;
    }
    handle_connection(client_fd);
  }

  close(server_fd);
  return NULL;
}
