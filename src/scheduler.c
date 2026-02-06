/*
 * Copyright (c) 2023 Georgios Alexopoulos
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 *
 * The nvshare scheduler.
 */

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "comm.h"
#include "common.h"
#include "k8s_api.h"
#include "utlist.h"

#define MEMORY_LIMIT_ANNOTATION "nvshare.com/gpu-memory-limit"
#define CORE_LIMIT_ANNOTATION "nvshare.com/gpu-core-limit"
#define COMPUTE_WINDOW_SIZE_MS 2000

#define NVSHARE_DEFAULT_TQ 30
#define NVSHARE_DEFAULT_GPU_MEMORY \
  (16ULL * 1024 * 1024 * 1024) /* 16GB default */
#define NVSHARE_DEFAULT_MEMORY_RESERVE_PERCENT 10
#define NVSHARE_DEFAULT_SWITCH_TIME_MULTIPLIER 5
#define NVSHARE_DEFAULT_FIXED_SWITCH_TIME 60
#define NVSHARE_DEFAULT_MAX_RUNTIME_SEC 300 /* 5 minutes */

/* Globals moved to gpu_context */
int scheduler_on;
int tq;

/* Memory-aware scheduling configuration */
enum switch_time_mode {
  SWITCH_TIME_AUTO, /* Auto-calculate based on memory usage */
  SWITCH_TIME_FIXED /* Fixed switch time in seconds */
};

/* Scheduling mode for multi-task scenarios */
enum scheduling_mode {
  SCHED_MODE_AUTO,      /* Smart: concurrent if memory fits, serial otherwise */
  SCHED_MODE_SERIAL,    /* Force serial: one task at a time per GPU */
  SCHED_MODE_CONCURRENT /* Force concurrent: original behavior */
};

struct scheduler_config {
  enum switch_time_mode mode;
  enum scheduling_mode scheduling_mode;
  int fixed_switch_time;      /* Fixed switch time in seconds */
  int time_multiplier;        /* Multiplier for auto mode */
  int memory_reserve_percent; /* Reserved memory percentage */
  int max_runtime_sec;        /* Max runtime before forced switch */
  size_t default_gpu_memory;  /* Default GPU memory if not detected */
};

static struct scheduler_config config = {
    .mode = SWITCH_TIME_AUTO,
    .scheduling_mode = SCHED_MODE_AUTO,
    .fixed_switch_time = NVSHARE_DEFAULT_FIXED_SWITCH_TIME,
    .time_multiplier = NVSHARE_DEFAULT_SWITCH_TIME_MULTIPLIER,
    .memory_reserve_percent = NVSHARE_DEFAULT_MEMORY_RESERVE_PERCENT,
    .max_runtime_sec = NVSHARE_DEFAULT_MAX_RUNTIME_SEC,
    .default_gpu_memory = NVSHARE_DEFAULT_GPU_MEMORY};

/* Initialize configuration from environment variables */
static void init_config(void) {
  char* val;

  val = getenv("NVSHARE_SWITCH_TIME_MODE");
  if (val && strcmp(val, "fixed") == 0) {
    config.mode = SWITCH_TIME_FIXED;
    log_info("Switch time mode: FIXED");
  } else {
    log_info("Switch time mode: AUTO");
  }

  val = getenv("NVSHARE_SWITCH_TIME_FIXED");
  if (val) {
    config.fixed_switch_time = atoi(val);
    log_info("Fixed switch time: %d seconds", config.fixed_switch_time);
  }

  val = getenv("NVSHARE_SWITCH_TIME_MULTIPLIER");
  if (val) {
    config.time_multiplier = atoi(val);
    log_info("Switch time multiplier: %d", config.time_multiplier);
  }

  val = getenv("NVSHARE_MEMORY_RESERVE_PERCENT");
  if (val) {
    config.memory_reserve_percent = atoi(val);
    log_info("Memory reserve percent: %d%%", config.memory_reserve_percent);
  }

  val = getenv("NVSHARE_DEFAULT_GPU_MEMORY_GB");
  if (val) {
    config.default_gpu_memory = (size_t)atoi(val) * 1024 * 1024 * 1024;
    log_info("Default GPU memory: %zu GB",
             config.default_gpu_memory / (1024 * 1024 * 1024));
  }

  /* Scheduling mode: auto (smart), serial, or concurrent */
  val = getenv("NVSHARE_SCHEDULING_MODE");
  if (val) {
    if (strcmp(val, "serial") == 0) {
      config.scheduling_mode = SCHED_MODE_SERIAL;
      log_info("Scheduling mode: SERIAL (one task at a time per GPU)");
    } else if (strcmp(val, "concurrent") == 0) {
      config.scheduling_mode = SCHED_MODE_CONCURRENT;
      log_info("Scheduling mode: CONCURRENT (original behavior)");
    } else {
      config.scheduling_mode = SCHED_MODE_AUTO;
      log_info("Scheduling mode: AUTO (smart - concurrent if memory fits)");
    }
  } else {
    log_info("Scheduling mode: AUTO (default)");
  }

  /* Maximum runtime before forced switch */
  val = getenv("NVSHARE_MAX_RUNTIME_SEC");
  if (val) {
    config.max_runtime_sec = atoi(val);
    if (config.max_runtime_sec < 10) {
      config.max_runtime_sec = 10; /* Minimum 10 seconds */
    }
    log_info("Max runtime per task: %d seconds", config.max_runtime_sec);
  } else {
    log_info("Max runtime per task: %d seconds (default)",
             config.max_runtime_sec);
  }
}
/*
 * Making scheduling_round global is problematic if used for uniqueness checks
 * per GPU. Moving to gpu_context.
 */

struct message out_msg = {0};

char nvscheduler_socket_path[NVSHARE_SOCK_PATH_MAX];

pthread_mutex_t global_mutex;

/* File descriptor for epoll */
int epoll_fd;

/* Manages state for a single physical GPU */
struct gpu_context {
  char uuid[NVSHARE_GPU_UUID_LEN];
  struct nvshare_request* requests;     /* Pending requests waiting to run */
  struct nvshare_request* running_list; /* Currently running tasks */
  int lock_held;
  int must_reset_timer;
  unsigned int scheduling_round;
  pthread_cond_t timer_cv;
  pthread_cond_t sched_cv; /* Wakes up scheduler (try_schedule) */
  pthread_t timer_tid;
  struct gpu_context* next;
  /* Memory-aware scheduling fields */
  size_t total_memory;         /* Total GPU memory in bytes */
  size_t available_memory;     /* Available memory in bytes */
  size_t running_memory_usage; /* Memory used by running processes */
  size_t peak_memory_usage;    /* Peak memory usage for diagnostics */
  int memory_overloaded;       /* Set to 1 when memory overload detected */
  struct nvshare_request* wait_queue; /* Processes waiting for memory */
  /* Compute limit fields */
  time_t window_start_time; /* Start time of current compute window (sec) */
};

/* Necessary information for identifying an nvshare client */
struct nvshare_client {
  int fd;      /* server-side socket for the persistent connection */
  uint64_t id; /* Unique */
  char pod_name[POD_NAME_LEN_MAX];
  char pod_namespace[POD_NAMESPACE_LEN_MAX];
  struct gpu_context* context; /* The GPU this client is assigned to */
  struct nvshare_client* next;
  /* Memory-aware scheduling fields */
  size_t memory_allocated;    /* Current allocated memory in bytes */
  int is_running;             /* Whether running on GPU */
  time_t last_scheduled_time; /* Last time this client was scheduled */
  /* Dynamic memory limit from pod annotation */
  size_t memory_limit; /* Annotation-based limit, 0 = no limit */
  /* Compute limit fields */
  int core_limit;             /* 1-100, default 100 */
  long run_time_in_window_ms; /* Runtime in current window (ms) */
  long current_run_start_ms;  /* Start time of current run (ms) */
  int is_throttled;           /* Set to 1 if quota exceeded */
};

static int send_update_limit(struct nvshare_client* client, size_t new_limit);
static long current_time_ms(void);

struct gpu_context* gpu_contexts = NULL;

/* Holds the requests for the GPU lock, which we serve in an FCFS manner */
struct nvshare_request {
  struct nvshare_client* client;
  struct nvshare_request* next;
};

struct nvshare_client* clients = NULL;
/* requests is now per-context */

struct nvshare_request* requests = NULL;
/* requests is now per-context */

void* timer_thr_fn(void* arg);

static struct gpu_context* get_or_create_gpu_context(const char* uuid) {
  struct gpu_context* ctx;
  LL_FOREACH(gpu_contexts, ctx) {
    if (strncmp(ctx->uuid, uuid, NVSHARE_GPU_UUID_LEN) == 0) return ctx;
  }

  /* Create new context */
  true_or_exit(ctx = malloc(sizeof(*ctx)));
  strlcpy(ctx->uuid, uuid, NVSHARE_GPU_UUID_LEN);
  ctx->requests = NULL;
  ctx->running_list = NULL;
  ctx->lock_held = 0;
  ctx->must_reset_timer = 0;
  ctx->next = NULL;
  /* Initialize memory-aware scheduling fields */
  ctx->total_memory = config.default_gpu_memory;
  ctx->available_memory = ctx->total_memory;
  ctx->running_memory_usage = 0;
  ctx->peak_memory_usage = 0;
  ctx->memory_overloaded = 0;
  ctx->wait_queue = NULL;
  true_or_exit(pthread_cond_init(&ctx->timer_cv, NULL) == 0);
  true_or_exit(pthread_cond_init(&ctx->sched_cv, NULL) == 0);

  /* Initialize quota window */
  ctx->window_start_time = 0;

  /* Spawn timer thread for this context */
  true_or_exit(pthread_create(&ctx->timer_tid, NULL, timer_thr_fn, ctx) == 0);

  LL_APPEND(gpu_contexts, ctx);
  log_info("Created new GPU context for UUID %s (memory: %zu MB)", uuid,
           ctx->total_memory / (1024 * 1024));
  return ctx;
}

static void bcast_status(void);
static int send_message(struct nvshare_client* client, struct message* msg_p);
static int receive_message(struct nvshare_client* client,
                           struct message* msg_p);
static void try_schedule(struct gpu_context* ctx);
static int register_client(struct nvshare_client* client,
                           const struct message* in_msg);
static int has_registered(struct nvshare_client* client);
static void client_id_as_string(char* buf, size_t buflen, uint64_t id);
static void delete_client(struct nvshare_client* client);
static void insert_req(struct nvshare_client* client);
static void remove_req(struct nvshare_client* client);
static int count_running_clients(struct gpu_context* ctx);
static long calculate_weighted_usage(struct gpu_context* ctx, long wall_time);

static int has_registered(struct nvshare_client* client) {
  return (client->id != NVSHARE_UNREGISTERED_ID);
}

/* Print an nvshare client ID as a hex string */
static void client_id_as_string(char* buf, size_t buflen, uint64_t id) {
  if (id == NVSHARE_UNREGISTERED_ID)
    strlcpy(buf, "<UNREGISTERED>", buflen);
  else
    snprintf(buf, buflen, "%016" PRIx64, id);
}

static void delete_client(struct nvshare_client* client) {
  int cfd = client->fd;
  char id_str[HEX_STR_LEN(client->id)];
  struct nvshare_client *tmp, *c;

  client_id_as_string(id_str, sizeof(id_str), client->id);
  log_info("Removing client %s", id_str);
  remove_req(client);

  /* Remove from clients list */
  LL_FOREACH_SAFE(clients, c, tmp) {
    if (c->fd == client->fd) {
      LL_DELETE(clients, c);
      free(c);
    }
  }

  true_or_exit(epoll_ctl(epoll_fd, EPOLL_CTL_DEL, cfd, NULL) == 0);
  /* See man close(2) for EINTR behavior on Linux */
  if (close(cfd) < 0 && errno != EINTR)
    log_fatal_errno("Failed to close FD %d", cfd);
}

static void insert_req(struct nvshare_client* client) {
  struct nvshare_request* r;
  struct gpu_context* ctx = client->context;
  if (!ctx) return;

  LL_FOREACH(ctx->requests, r) {
    if (r->client->fd == client->fd) {
      log_warn("Client %016" PRIx64
               " has already requested"
               " the lock",
               r->client->id);
      return;
    }
  }
  true_or_exit(r = malloc(sizeof *r));
  r->next = NULL;
  r->client = client;
  LL_APPEND(ctx->requests, r);
}

static int can_run(struct gpu_context* ctx, struct nvshare_client* client);
static void check_wait_queue(struct gpu_context* ctx);

static void remove_req(struct nvshare_client* client) {
  struct nvshare_request *tmp, *r;
  struct gpu_context* ctx = client->context;
  if (!ctx) return;

  /* Check if this client is in the running_list */
  LL_FOREACH_SAFE(ctx->running_list, r, tmp) {
    if (r->client->fd == client->fd) {
      /* Always update memory tracking when removing from running_list */
      size_t mem_to_free = client->memory_allocated;
      if (ctx->running_memory_usage >= mem_to_free) {
        ctx->running_memory_usage -= mem_to_free;
      } else {
        log_warn("Memory accounting mismatch: running=%zu, freeing=%zu",
                 ctx->running_memory_usage, mem_to_free);
        ctx->running_memory_usage = 0;
      }

      /* Update compute usage with weighted billing */
      long now_ms = current_time_ms();
      long duration = now_ms - client->current_run_start_ms;
      if (duration > 0) {
        /* Apply weighted billing: divide by concurrent count */
        long weighted_duration = calculate_weighted_usage(ctx, duration);
        client->run_time_in_window_ms += weighted_duration;
        log_debug(
            "Weighted billing: wall %ld ms / %d concurrent = %ld ms billed",
            duration, count_running_clients(ctx), weighted_duration);
      }

      client->is_running = 0;
      log_info("Client %016" PRIx64
               " released from running_list (ran for %ld ms). Mem: %zu MB",
               client->id, duration, ctx->running_memory_usage / (1024 * 1024));
      LL_DELETE(ctx->running_list, r);
      free(r);
    }
  }

  /* Update lock_held based on whether any tasks are still running */
  if (ctx->running_list == NULL) {
    ctx->lock_held = 0;
    /* Check if we can schedule waiting processes */
    check_wait_queue(ctx);
    try_schedule(ctx);
  }

  /* Remove from requests list (pending requests) */
  LL_FOREACH_SAFE(ctx->requests, r, tmp) {
    if (r->client->fd == client->fd) {
      LL_DELETE(ctx->requests, r);
      free(r);
    }
  }

  /* Also remove from wait_queue if present */
  LL_FOREACH_SAFE(ctx->wait_queue, r, tmp) {
    if (r->client->fd == client->fd) {
      log_info("Removing client %016" PRIx64 " from wait queue", client->id);
      LL_DELETE(ctx->wait_queue, r);
      free(r);
    }
  }
}

/*
 * Force preemption of all running tasks on this GPU.
 * Called when memory overload is detected to fall back to serial mode.
 */
static void force_preemption(struct gpu_context* ctx) {
  struct nvshare_request *r, *tmp;
  struct message msg = {0};
  msg.type = DROP_LOCK;

  log_warn(
      "Forcing preemption on GPU %s due to memory overload (running: %zu MB, "
      "limit: %zu MB)",
      ctx->uuid, ctx->running_memory_usage / (1024 * 1024),
      ctx->total_memory * (100 - config.memory_reserve_percent) / 100 /
          (1024 * 1024));

  LL_FOREACH_SAFE(ctx->running_list, r, tmp) {
    if (send_message(r->client, &msg) >= 0) {
      log_info("Sent DROP_LOCK to client %016" PRIx64
               " for fallback to serial mode",
               r->client->id);
    }
  }
}

/* Check if client can run with current memory usage and scheduling mode */
static int can_run_with_memory(struct gpu_context* ctx,
                               struct nvshare_client* client) {
  size_t safe_limit =
      ctx->total_memory * (100 - config.memory_reserve_percent) / 100;

  /* If memory overload was detected, fall back to serial mode */
  if (ctx->memory_overloaded) {
    if (ctx->lock_held) {
      log_debug("Overload fallback: GPU %s using serial mode", ctx->uuid);
      return 0;
    }
    /* Allow task to start if no one is running (serial behavior) */
    return 1;
  }

  /* Serial mode: only one task at a time per GPU */
  if (config.scheduling_mode == SCHED_MODE_SERIAL) {
    if (ctx->lock_held) {
      log_debug("Serial mode: GPU %s already has running task, deferring",
                ctx->uuid);
      return 0;
    }
    /* In serial mode, allow if no one is running */
    return 1;
  }

  /* Concurrent mode: use original logic (allow multiple tasks) */
  if (config.scheduling_mode == SCHED_MODE_CONCURRENT) {
    /* Always allow if running memory is 0 (first process) to avoid deadlocks */
    if (ctx->running_memory_usage == 0) return 1;
    return (ctx->running_memory_usage + client->memory_allocated) <= safe_limit;
  }

  /* AUTO mode (smart): serial if memory would exceed limit, concurrent
   * otherwise */
  /* Always allow if this is the first task */
  if (ctx->running_memory_usage == 0) return 1;

  /* Check if adding this task would exceed memory limit */
  size_t needed = ctx->running_memory_usage + client->memory_allocated;
  if (needed <= safe_limit) {
    /* Memory fits, allow concurrent */
    log_debug(
        "Auto mode: memory fits (%zu + %zu <= %zu MB), allowing concurrent",
        ctx->running_memory_usage / (1024 * 1024),
        client->memory_allocated / (1024 * 1024), safe_limit / (1024 * 1024));
    return 1;
  }

  /* Memory would exceed limit, switch to serial behavior */
  if (ctx->lock_held) {
    log_debug(
        "Auto mode: memory oversubscribed, GPU %s has running task, deferring",
        ctx->uuid);
    return 0;
  }

  /* No one running, allow this task to start */
  return 1;
}

static void move_to_wait_queue(struct gpu_context* ctx,
                               struct nvshare_request* req) {
  struct nvshare_request* w_req;

  /* Check if already in wait queue (paranoid) */
  LL_FOREACH(ctx->wait_queue, w_req) {
    if (w_req->client == req->client) return;
  }

  LL_DELETE(ctx->requests, req);
  LL_APPEND(ctx->wait_queue, req);

  /* Inform client to wait */
  /* Only send WAIT_FOR_MEM if not throttled (i.e. waiting for memory) */
  if (req->client->core_limit < 100 && req->client->is_throttled) {
    log_debug("Client %016" PRIx64 " moved to wait queue (throttled)",
              req->client->id);
  } else {
    out_msg.type = WAIT_FOR_MEM;
    send_message(req->client, &out_msg);
    log_info("Client %016" PRIx64 " moved to wait queue (wait for mem)",
             req->client->id);
  }
}

static void check_wait_queue(struct gpu_context* ctx) {
  struct nvshare_request *r, *tmp;

  LL_FOREACH_SAFE(ctx->wait_queue, r, tmp) {
    if (can_run(ctx, r->client)) {
      LL_DELETE(ctx->wait_queue, r);
      /* Prepend to requests queue to prioritize it */
      LL_PREPEND(ctx->requests, r);

      log_info("Client %016" PRIx64 " promoted from wait queue", r->client->id);

      /* Inform client memory is available */
      out_msg.type = MEM_AVAILABLE;
      send_message(r->client, &out_msg);

      /* Only promote one at a time for simplicity in FCFS flow,
       * try_schedule will pick it up */
      return;
    }
  }
}

static int register_client(struct nvshare_client* client,
                           const struct message* in_msg) {
  int ret;
  struct nvshare_client* c;
  uint64_t nvshare_client_id;
  struct gpu_context* ctx;

  if (has_registered(client)) {
    log_warn("Client %016" PRIx64 " is already registered", client->id);
    return -1;
  }

again:
  nvshare_client_id = nvshare_generate_id();
  if (nvshare_client_id == NVSHARE_UNREGISTERED_ID) /* Tough luck */
    goto again;
  LL_FOREACH(clients, c) {
    if (c->id == nvshare_client_id) { /* ID clash */
      goto again;
    }
  }

  /*
   * Store the rest of the client information.
   */
  client->id = nvshare_client_id;
  strlcpy(client->pod_name, in_msg->pod_name, sizeof(client->pod_name));
  strlcpy(client->pod_namespace, in_msg->pod_namespace,
          sizeof(client->pod_namespace));

  /* Map context */
  ctx = get_or_create_gpu_context(in_msg->gpu_uuid);
  client->context = ctx;

  /*
   * Inform the client of the current status of our current status, as
   * well as the ID we generated for it.
   *
   * It will henceforth present this ID to interact with us.
   */
  true_or_exit(
      snprintf(out_msg.data, 16 + 1, "%016" PRIx64, nvshare_client_id) == 16);
  out_msg.type = scheduler_on ? SCHED_ON : SCHED_OFF;
  if ((ret = send_message(client, &out_msg)) < 0) goto out_with_msg;

  /* Check for memory limit annotation immediately to prevent race condition */
  char* limit_str = k8s_get_pod_annotation(
      client->pod_namespace, client->pod_name, MEMORY_LIMIT_ANNOTATION);
  if (limit_str) {
    size_t new_limit = parse_memory_size(limit_str);
    if (new_limit > 0) {
      log_info("Applying initial memory limit for %s/%s: %zu bytes",
               client->pod_namespace, client->pod_name, new_limit);
      client->memory_limit = new_limit;
      send_update_limit(client, new_limit);
    }
    free(limit_str);
  }

  /* Initialize compute limit fields */
  client->core_limit = 100;
  client->run_time_in_window_ms = 0;
  client->current_run_start_ms = 0;
  client->is_throttled = 0;

  /* Check for compute limit annotation */
  char* core_limit_str = k8s_get_pod_annotation(
      client->pod_namespace, client->pod_name, CORE_LIMIT_ANNOTATION);
  if (core_limit_str) {
    int new_limit = atoi(core_limit_str);
    if (new_limit >= 1 && new_limit <= 100) {
      client->core_limit = new_limit;
      log_info("Applying initial compute limit for %s/%s: %d%%",
               client->pod_namespace, client->pod_name, new_limit);
    } else {
      log_warn("Invalid compute limit for %s/%s: %d (must be 1-100)",
               client->pod_namespace, client->pod_name, new_limit);
    }
    free(core_limit_str);
  }

out_with_msg:
  /* out_msg is global, so make sure we've zeroed it out */
  memset(&out_msg.data, 0, sizeof(out_msg.data));

  return ret;
}

static void bcast_status(void) {
  struct nvshare_client *tmp, *c;
  LL_FOREACH_SAFE(clients, c, tmp) {
    if (!has_registered(c)) continue;

    out_msg.type = scheduler_on ? SCHED_ON : SCHED_OFF;
    if (send_message(c, &out_msg) < 0) delete_client(c);
  }
}

/*
 * Send a given message to a given client.
 *
 * We are particularly strict and consider the client dead if we encounter any
 * (even possibly recoverable if we were more lenient) error.
 */
static int send_message(struct nvshare_client* client, struct message* msg_p) {
  ssize_t ret;
  char id_str[HEX_STR_LEN(client->id)];

  client_id_as_string(id_str, sizeof(id_str), client->id);

  ret = nvshare_send_noblock(client->fd, msg_p, sizeof(*msg_p));

  if (ret >= 0 && (size_t)ret < sizeof(*msg_p)) /* Partial send */
    return -1;
  else if (ret < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNRESET ||
        errno == EPIPE) { /* Recoverable errors, but we're strict */
      log_info("Failed to send message to client %s", id_str);
      return -1;
    } else
      log_fatal("nvshare_send_noblock() failed unrecoverably");
  } else { /* ret == 0 */
    log_info("Sent %s to client %s", message_type_string[msg_p->type], id_str);
  }
  return 0;
}

/*
 * Send a given message to a given client.
 *
 * We are particularly strict and consider the client dead if we encounter any
 * (even possibly recoverable if we were more lenient) error.
 */
static int receive_message(struct nvshare_client* client,
                           struct message* msg_p) {
  ssize_t ret;
  char id_str[HEX_STR_LEN(client->id)];

  client_id_as_string(id_str, sizeof(id_str), client->id);

  ret = nvshare_receive_noblock(client->fd, msg_p, sizeof(*msg_p));

  if (ret == 0) { /* Client closed the other end of the connection */
    errno = ENOTCONN;
    log_debug("Client %s has closed the connection", id_str);
    return -1;
  } else if (ret > 0 && (size_t)ret < sizeof(*msg_p)) { /* Partial receive */
    return -1;
  } else if (ret < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ECONNRESET ||
        errno == EPIPE) {
      log_info("Failed to receive message from client %s", id_str);
      return -1;
    } else
      log_fatal("nvshare_receive_noblock() failed unrecoverably");
  }
  return 0;
}

/* Helper: Get current time in milliseconds (monotonic) */
static long current_time_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

/* Helper: Calculate total quota of all active clients on this GPU */
static int calculate_total_quota(struct gpu_context* ctx) {
  int total = 0;
  struct nvshare_client* c;
  LL_FOREACH(clients, c) {
    if (c->context == ctx && c->core_limit < 100) {
      total += c->core_limit;
    }
  }
  /* If no limited clients or total is 0, return 100 (no scaling needed) */
  return total > 0 ? total : 100;
}

/* Helper: Count currently running clients on this GPU */
static int count_running_clients(struct gpu_context* ctx) {
  int count = 0;
  struct nvshare_request* req;
  LL_FOREACH(ctx->running_list, req) count++;
  return count > 0 ? count : 1;
}

/* Helper: Get effective quota with proportional scaling for oversubscription */
static long get_effective_quota_ms(struct gpu_context* ctx,
                                   struct nvshare_client* c) {
  int total_quota = calculate_total_quota(ctx);
  long base_quota_ms = (long)COMPUTE_WINDOW_SIZE_MS * c->core_limit / 100;

  if (total_quota <= 100) {
    return base_quota_ms; /* No oversubscription, return original */
  }

  /* Oversubscribed: scale down proportionally */
  long scaled = base_quota_ms * 100 / total_quota;
  log_debug(
      "Quota scaling: client limit %d%%, total %d%%, base %ld ms -> scaled %ld "
      "ms",
      c->core_limit, total_quota, base_quota_ms, scaled);
  return scaled;
}

/* Helper: Calculate weighted billing (divides by concurrent count) */
static long calculate_weighted_usage(struct gpu_context* ctx, long wall_time) {
  int n = count_running_clients(ctx);
  return wall_time / n;
}

/* Helper: Check and reset compute limits window */
static int check_and_reset_window(struct gpu_context* ctx) {
  struct nvshare_client* c;
  time_t now = time(NULL);
  int reset_occured = 0;

  if (ctx->window_start_time == 0) ctx->window_start_time = now;

  if (now >= ctx->window_start_time + COMPUTE_WINDOW_SIZE_MS / 1000) {
    ctx->window_start_time = now;
    long now_ms = current_time_ms();

    /* Reset all clients on this GPU */
    LL_FOREACH(clients, c) {
      if (c->context == ctx) {
        c->run_time_in_window_ms = 0;
        c->is_throttled = 0;
        /* If running, reset start time to avoid double counting or negative
         * duration on next removal */
        if (c->is_running) {
          c->current_run_start_ms = now_ms;
        }
      }
    }
    /* Signal try_schedule in case we are called from timer thread */
    pthread_cond_signal(&ctx->sched_cv);
    reset_occured = 1;
  }
  return reset_occured;
}

/* Check if client can run (Memory + Compute Limit) */
static int can_run(struct gpu_context* ctx, struct nvshare_client* client) {
  /* Ensure window is fresh */
  check_and_reset_window(ctx);

  /* Check compute quota (with proportional scaling for oversubscription) */
  if (client->core_limit < 100) {
    if (client->is_throttled) return 0;
    long limit_ms = get_effective_quota_ms(ctx, client);
    if (client->run_time_in_window_ms >= limit_ms) return 0;
  }

  /* Check memory fit */
  return can_run_with_memory(ctx, client);
}

/*
 * Try to assign the GPU lock to a client in the requests list in FCFS order.
 *
 * In SERIAL mode: schedules at most one client.
 * In CONCURRENT/AUTO mode: continues scheduling as long as memory permits.
 */
static void try_schedule(struct gpu_context* ctx) {
  int ret;
  struct nvshare_client* scheduled_client;
  struct nvshare_request* req;
  int scheduled_count = 0;

try_again:
  if (ctx->requests == NULL) {
    /* If requests empty, try to see if anyone in wait queue fits now
     * (e.g. if memory checks changed or logic permits)
     */
    check_wait_queue(ctx);
    if (ctx->requests == NULL) {
      if (scheduled_count == 0) {
        log_debug("try_schedule() called with no pending requests for UUID %s",
                  ctx->uuid);
      }
      return;
    }
  }

  /* Check admission control for the head of the queue */
  req = ctx->requests;
  scheduled_client = req->client;

  if (!can_run(ctx, scheduled_client)) {
    /* Cannot run, move to wait queue */
    move_to_wait_queue(ctx, req);
    /* Recursively try next request */
    goto try_again;
  }

  /* Pass admission control, schedule it */
  out_msg.type = LOCK_OK;
  /* FCFS, use head of requests list */
  ret = send_message(scheduled_client, &out_msg);
  if (ret < 0) { /* Client's dead to us */
    delete_client(scheduled_client);
    goto try_again;
  }

  /* Move the scheduled request from requests list to running_list */
  LL_DELETE(ctx->requests, req);
  LL_APPEND(ctx->running_list, req);

  ctx->lock_held = 1;
  ctx->must_reset_timer = 1;

  /* Mark client as running and update memory tracking */
  scheduled_client->is_running = 1;
  scheduled_client->current_run_start_ms = current_time_ms();
  scheduled_client->last_scheduled_time = time(NULL);
  ctx->running_memory_usage += scheduled_client->memory_allocated;
  scheduled_count++;
  log_info(
      "Scheduled client %016" PRIx64 " (mem: %zu MB, total running: %zu MB)",
      scheduled_client->id, scheduled_client->memory_allocated / (1024 * 1024),
      ctx->running_memory_usage / (1024 * 1024));

  pthread_cond_broadcast(&ctx->timer_cv);

  /* In non-serial modes, continue trying to schedule more tasks */
  if (config.scheduling_mode != SCHED_MODE_SERIAL) {
    goto try_again;
  }
}

static int calculate_switch_time(struct gpu_context* ctx) {
  if (config.mode == SWITCH_TIME_FIXED) {
    return config.fixed_switch_time;
  }
  /* Auto mode: calculated based on memory usage */
  size_t mem_gb = ctx->running_memory_usage / (1024 * 1024 * 1024);
  int swap_time = (int)(mem_gb > 0 ? mem_gb : 1);
  int switch_time = swap_time * config.time_multiplier;

  /* Clamp between 10s and 300s */
  if (switch_time < 10) switch_time = 10;
  if (switch_time > 300) switch_time = 300;

  return switch_time;
}

/*
 * The timer thread's sole responsibility is to implement the Time Quantum
 * (TQ) notion of nvshare.
 *
 * It uses dynamic TQ based on memory usage, and only preempts if there
 * are other clients waiting.
 */
#define MIN(a, b) ((a) < (b) ? (a) : (b))

/*
 * The timer thread implements the Time Quantum (TQ) and Compute Limits.
 *
 * It manages:
 * 1. Global TQ for fair scheduling.
 * 2. Per-client compute quota enforcement (window-based).
 * 3. Concurrent accounting for multiple running clients.
 */
void* timer_thr_fn(void* arg) {
  struct gpu_context* ctx = (struct gpu_context*)arg;
  struct message drop_msg = {0};
  drop_msg.id = 1337;
  drop_msg.type = DROP_LOCK;

  struct timespec ts;
  struct nvshare_request *req, *tmp;
  long now_ms, sleep_start_ms, actual_elapsed;
  long min_sleep_ms;
  int default_tq_ms;

  true_or_exit(pthread_mutex_lock(&global_mutex) == 0);

  while (1) {
    /* 1. Reset window if expired */
    if (check_and_reset_window(ctx)) {
      /*
       * Window reset occurred! This means throttled clients might be able
       * to run now. Attempt to schedule them immediately.
       * Since we hold global_mutex, we can safely call try_schedule.
       */
      /*
       * IMPORTANT: In concurrent mode, we should NOT disturb running tasks
       * unnecessarily. try_schedule will pick up finding tasks from waiting
       * lists.
       */
      try_schedule(ctx);
    }

    /* 2. Calculate next sleep duration */
    /* Base TQ is either fixed or auto-calculated */
    int current_tq_sec = calculate_switch_time(ctx);
    default_tq_ms = current_tq_sec * 1000;
    min_sleep_ms = default_tq_ms;

    /* Get current time for dynamic calculation */
    now_ms = current_time_ms();

    /* Check remaining quota for all running clients */
    int n_running = count_running_clients(ctx);
    LL_FOREACH(ctx->running_list, req) {
      struct nvshare_client* c = req->client;
      if (c->core_limit < 100) {
        long limit_ms = get_effective_quota_ms(ctx, c);

        /* Use weighted billing: current wall time divided by concurrent count
         */
        long pending_wall_time = now_ms - c->current_run_start_ms;
        long pending_billed = pending_wall_time / n_running;
        long current_usage = c->run_time_in_window_ms + pending_billed;
        long remaining = limit_ms - current_usage;

        if (remaining <= 0) {
          min_sleep_ms = 0; /* Already exceeded, process immediately */
        } else {
          /* Scale remaining time back to wall time for sleep calculation */
          min_sleep_ms = MIN(min_sleep_ms, remaining * n_running);
        }
      }
    }

    /* Clamp min sleep to avoid busy loop */
    if (min_sleep_ms < 10) min_sleep_ms = 10;

    /* Cap sleep to window size to ensure timely window resets */
    if (min_sleep_ms > COMPUTE_WINDOW_SIZE_MS) {
      min_sleep_ms = COMPUTE_WINDOW_SIZE_MS;
    }

    /* 3. Sleep */
    sleep_start_ms = current_time_ms();
    clock_gettime(CLOCK_REALTIME, &ts);

    long sec = min_sleep_ms / 1000;
    long nsec = (min_sleep_ms % 1000) * 1000000;
    ts.tv_sec += sec;
    ts.tv_nsec += nsec;
    if (ts.tv_nsec >= 1000000000) {
      ts.tv_sec++;
      ts.tv_nsec -= 1000000000;
    }

    int ret = pthread_cond_timedwait(&ctx->timer_cv, &global_mutex, &ts);

    /* 4. Update Usage (Full Accounting) - REMOVED */
    /* We now update usage on remove_req for precise accounting. */
    now_ms = current_time_ms();

    /* 5. Enforce Limits (Targeted Throttling) with weighted billing */
    int n_running_now = count_running_clients(ctx);
    LL_FOREACH_SAFE(ctx->running_list, req, tmp) {
      struct nvshare_client* c = req->client;
      if (c->core_limit < 100 && !c->is_throttled) {
        long limit_ms = get_effective_quota_ms(ctx, c);

        /* Dynamic check with weighted billing: accumulated + weighted pending
         */
        long pending_wall_time = now_ms - c->current_run_start_ms;
        long pending_billed = pending_wall_time / n_running_now;
        long current_usage = c->run_time_in_window_ms + pending_billed;

        if (current_usage >= limit_ms) {
          log_info("Throttling client %016" PRIx64
                   " (Used: %ld/%ld ms, weighted)",
                   c->id, current_usage, limit_ms);
          c->is_throttled = 1;
          /* Update stored usage with weighted billing */
          c->run_time_in_window_ms += pending_billed;
          c->current_run_start_ms = now_ms; /* Avoid double counting */

          send_message(c, &drop_msg);
          /*
           * We don't remove from running_list here. Client will
           * reply with LOCK_RELEASED, which triggers removal.
           */
        }
      }
    }

    /* 6. Enforce Global Preemption (if TQ elapsed) */
    if (ret == ETIMEDOUT && min_sleep_ms >= default_tq_ms) {
      /* If we slept for the full TQ, check if we need to preempt everyone */
      /* Logic for global rotation if multiple tasks are waiting */
      if (ctx->requests != NULL || ctx->wait_queue != NULL) {
        /* Send DROP_LOCK to all running clients to force rotation */
        /* Note: This simplistic approach complements targeted throttling */
        LL_FOREACH(ctx->running_list, req) {
          if (!req->client->is_throttled) {
            send_message(req->client, &drop_msg);
          }
        }
      }
    }

    /* Handle must_reset_timer flag */
    if (ctx->must_reset_timer) {
      ctx->must_reset_timer = 0;
      continue;
    }
  }
}

/* Annotation watcher configuration */
#define ANNOTATION_CHECK_INTERVAL_SEC 5

/* Send UPDATE_LIMIT message to a client */
static int send_update_limit(struct nvshare_client* client, size_t new_limit) {
  struct message out_msg = {0};
  char id_str[HEX_STR_LEN(client->id)];

  out_msg.type = UPDATE_LIMIT;
  out_msg.id = client->id;
  out_msg.memory_limit = new_limit;

  client_id_as_string(id_str, sizeof(id_str), client->id);
  log_info("Sending UPDATE_LIMIT to client %s: %zu bytes (%.2f GiB)", id_str,
           new_limit, (double)new_limit / (1024.0 * 1024.0 * 1024.0));

  return send_message(client, &out_msg);
}

/*
 * Annotation watcher thread - periodically checks pod annotations
 * for memory limit changes and notifies clients.
 */
/* Helper struct for snapshotting clients to avoid holding lock during I/O */
struct client_info {
  uint64_t id;
  char pod_name[POD_NAME_LEN_MAX];
  char pod_namespace[POD_NAMESPACE_LEN_MAX];
  struct client_info* next;
};

/*
 * Annotation watcher thread - periodically checks pod annotations
 * for memory limit changes and notifies clients.
 */
void* annotation_watcher_fn(void* arg __attribute__((unused))) {
  log_info("Annotation watcher thread started (interval: %d sec)",
           ANNOTATION_CHECK_INTERVAL_SEC);

  while (1) {
    sleep(ANNOTATION_CHECK_INTERVAL_SEC);

    /* 1. Snapshot registered clients quickly while holding lock */
    struct client_info* snapshot = NULL;
    struct nvshare_client* client;

    true_or_exit(pthread_mutex_lock(&global_mutex) == 0);
    LL_FOREACH(clients, client) {
      /* Skip clients without pod info */
      if (client->pod_name[0] != '\0' && client->pod_namespace[0] != '\0') {
        struct client_info* info = malloc(sizeof(struct client_info));
        info->id = client->id;
        strlcpy(info->pod_name, client->pod_name, sizeof(info->pod_name));
        strlcpy(info->pod_namespace, client->pod_namespace,
                sizeof(info->pod_namespace));
        LL_APPEND(snapshot, info);
      }
    }
    true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);

    /* 2. Perform slow network I/O without lock */
    struct client_info *info, *tmp;
    LL_FOREACH_SAFE(snapshot, info, tmp) {
      /* Query K8s API for annotation */
      char* mem_limit_str = k8s_get_pod_annotation(
          info->pod_namespace, info->pod_name, MEMORY_LIMIT_ANNOTATION);

      char* core_limit_str = k8s_get_pod_annotation(
          info->pod_namespace, info->pod_name, CORE_LIMIT_ANNOTATION);

      /* 3. Re-acquire lock to update client state */
      true_or_exit(pthread_mutex_lock(&global_mutex) == 0);

      /* Must find the client again as it might have disconnected */
      struct nvshare_client* target_client = NULL;
      LL_FOREACH(clients, client) {
        if (client->id == info->id) {
          target_client = client;
          break;
        }
      }

      if (target_client) {
        /* Update Memory Limit */
        if (mem_limit_str) {
          size_t new_limit = parse_memory_size(mem_limit_str);
          if (new_limit > 0 && new_limit != target_client->memory_limit) {
            log_info("Memory limit changed for pod %s/%s: %zu -> %zu bytes",
                     target_client->pod_namespace, target_client->pod_name,
                     target_client->memory_limit, new_limit);
            target_client->memory_limit = new_limit;
            send_update_limit(target_client, new_limit);
          }
        }

        /* Update Compute Limit */
        int new_core_limit = 100;
        if (core_limit_str) {
          int val = atoi(core_limit_str);
          if (val >= 1 && val <= 100) new_core_limit = val;
        }

        if (new_core_limit != target_client->core_limit) {
          log_info("Compute limit changed for pod %s/%s: %d%% -> %d%%",
                   target_client->pod_namespace, target_client->pod_name,
                   target_client->core_limit, new_core_limit);
          target_client->core_limit = new_core_limit;
          /* Wake up timer thread to re-evaluate immediately if running */
          if (target_client->is_running && target_client->context) {
            pthread_cond_broadcast(&target_client->context->timer_cv);
          }
        }
      }

      true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);

      if (mem_limit_str) free(mem_limit_str);
      if (core_limit_str) free(core_limit_str);

      LL_DELETE(snapshot, info);
      free(info);
    }
  }

  return NULL;
}

static void process_msg(struct nvshare_client* client,
                        const struct message* in_msg) {
  int newtq;
  char id_str[HEX_STR_LEN(client->id)];
  char* endptr;
  struct gpu_context* ctx = client->context;
  /* Note: ctx might be NULL if client is not registered yet (except for
   * REGISTER) */

  client_id_as_string(id_str, sizeof(id_str), client->id);

  switch (in_msg->type) {
    case REGISTER:
      log_info("Received %s", message_type_string[in_msg->type]);

      if (register_client(client, in_msg) < 0)
        delete_client(client);
      else
        log_info("Registered client %016" PRIx64
                 " on GPU %s with Pod"
                 " name = %s, Pod namespace = %s",
                 client->id, client->context->uuid, client->pod_name,
                 client->pod_namespace);
      break;

    case SCHED_ON: /* nvsharectl */
      log_info("Received %s from %s", message_type_string[in_msg->type],
               id_str);

      if (!scheduler_on) {
        scheduler_on = 1;
        log_info("Scheduler turned ON, broadcasting it...");
        bcast_status();
      }
      break;

    case SCHED_OFF: /* nvsharectl */
      log_info("Received %s from %s", message_type_string[in_msg->type],
               id_str);

      if (scheduler_on) {
        log_info("Scheduler turned OFF, broadcasting it...");
        scheduler_on = 0;
        bcast_status();

        struct gpu_context* c_ctx;
        LL_FOREACH(gpu_contexts, c_ctx) {
          struct nvshare_request *tmp, *r;
          LL_FOREACH_SAFE(c_ctx->requests, r, tmp) {
            LL_DELETE(c_ctx->requests, r);
            free(r);
          }
          c_ctx->lock_held = 0;
        }
      }
      break;

    case SET_TQ: /* nvsharectl */
      log_info("Received %s from %s", message_type_string[in_msg->type],
               id_str);

      errno = 0;
      newtq = (int)strtoll(in_msg->data, &endptr, 0);
      if (in_msg->data != endptr && *endptr == '\0' && errno == 0) {
        tq = newtq;
        struct gpu_context* c_ctx;
        LL_FOREACH(gpu_contexts, c_ctx) {
          c_ctx->must_reset_timer = 1;
          pthread_cond_broadcast(&c_ctx->timer_cv);
        }
        log_info("New TQ = %d", tq);
      } else
        log_info("Failed to parse new TQ from message");
      break;

    case REQ_LOCK: /* client */
      log_info("Received %s from %s", message_type_string[in_msg->type],
               id_str);

      if (has_registered(client)) {
        if (scheduler_on) {
          if (!ctx) {
            log_warn("Registered client %s has no context!", id_str);
            delete_client(client);
            break;
          }
          insert_req(client);
          /* In CONCURRENT/AUTO modes, always try to schedule - memory might
           * fit. In SERIAL mode, only schedule if no one is running. */
          if (config.scheduling_mode == SCHED_MODE_SERIAL) {
            if (!ctx->lock_held) try_schedule(ctx);
          } else {
            try_schedule(ctx); /* Let try_schedule check memory limits */
          }
        }
      } else { /* The client is not registered. Slam the door. */
        delete_client(client);
      }
      break;

    case LOCK_RELEASED: /* From client */
      log_info("Received %s from %s", message_type_string[in_msg->type],
               id_str);

      if (has_registered(client)) {
        if (scheduler_on) {
          if (!ctx) {
            delete_client(client);
            break;
          }
          remove_req(client);
          if (!ctx->lock_held) try_schedule(ctx);
        }
      } else { /* The client is not registered. Slam the door. */
        delete_client(client);
      }
      break;

    case MEM_UPDATE: /* Memory usage update from client */
      log_debug("Received %s from %s: %zu MB",
                message_type_string[in_msg->type], id_str,
                in_msg->memory_usage / (1024 * 1024));

      if (has_registered(client) && ctx) {
        size_t old_mem = client->memory_allocated;
        client->memory_allocated = in_msg->memory_usage;

        /* Update running memory usage if client is running */
        if (client->is_running) {
          if (ctx->running_memory_usage >= old_mem) {
            ctx->running_memory_usage -= old_mem;
          }
          ctx->running_memory_usage += client->memory_allocated;

          /* Track peak memory usage */
          if (ctx->running_memory_usage > ctx->peak_memory_usage) {
            ctx->peak_memory_usage = ctx->running_memory_usage;
          }

          log_debug("GPU %s running memory updated: %zu MB (peak: %zu MB)",
                    ctx->uuid, ctx->running_memory_usage / (1024 * 1024),
                    ctx->peak_memory_usage / (1024 * 1024));

          /* Check for memory overload - only if not already in overload mode */
          size_t safe_limit =
              ctx->total_memory * (100 - config.memory_reserve_percent) / 100;
          if (!ctx->memory_overloaded &&
              ctx->running_memory_usage > safe_limit) {
            ctx->memory_overloaded = 1;
            log_warn(
                "Memory overload detected on GPU %s: %zu MB > %zu MB limit",
                ctx->uuid, ctx->running_memory_usage / (1024 * 1024),
                safe_limit / (1024 * 1024));
            /* Force preemption to fall back to serial mode */
            force_preemption(ctx);
          }
        }
      }
      break;

    default: /* Unknown message type */
      log_info(
          "Received message of unknown type %d"
          " from %s",
          (int)in_msg->type, id_str);
      break;
  }
}

int main(int argc __attribute__((unused)),
         char* argv[] __attribute__((unused))) {
  struct nvshare_client* client;
  int ret, err, lsock, rsock, num_fds;
  char* debug_val;
  struct message in_msg = {0};
  struct epoll_event event, events[EPOLL_MAX_EVENTS];

  debug_val = getenv(ENV_NVSHARE_DEBUG);
  if (debug_val != NULL) {
    __debug = 1;
    log_info("nvshare-scheduler started in debug mode");
  } else
    log_info("nvshare-scheduler started in normal mode");

  err = mkdir(NVSHARE_SOCK_DIR, S_IRWXU | S_IXGRP | S_IXOTH);
  if (err != 0 && errno != EEXIST)
    log_fatal("Could not create scheduler socket directory %s",
              NVSHARE_SOCK_DIR);

  if (chmod(NVSHARE_SOCK_DIR, S_IRWXU | S_IXGRP | S_IXOTH) != 0)
    log_fatal("chmod() failed for %s", NVSHARE_SOCK_DIR);

  /* Initialize memory-aware scheduling configuration */
  init_config();

  if (getenv(ENV_NVSHARE_DEBUG)) __debug = 1;

  scheduler_on = 1;
  tq = NVSHARE_DEFAULT_TQ;

  srand((unsigned int)(time(NULL)));

  true_or_exit(pthread_mutex_init(&global_mutex, NULL) == 0);

  if (nvshare_get_scheduler_path(nvscheduler_socket_path) != 0)
    log_fatal("nvshare_get_scheduler_path() failed!");

  /* Timer threads are spawned per GPU context */

  /* Initialize K8s API and start annotation watcher thread */
  if (k8s_api_init() == 0) {
    pthread_t annotation_watcher_tid;
    true_or_exit(pthread_create(&annotation_watcher_tid, NULL,
                                annotation_watcher_fn, NULL) == 0);
    log_info("Annotation watcher enabled for dynamic memory limits");
  } else {
    log_warn(
        "K8s API init failed, dynamic memory limit via annotation disabled");
  }

  true_or_exit((epoll_fd = epoll_create(1)) >= 0);

  true_or_exit(nvshare_bind_and_listen(&lsock, nvscheduler_socket_path) == 0);

  event.data.fd = lsock;
  event.events = EPOLLIN;
  true_or_exit(epoll_ctl(epoll_fd, EPOLL_CTL_ADD, lsock, &event) == 0);

  if (chmod(nvscheduler_socket_path, S_IRWXU | S_IWGRP | S_IWOTH) != 0)
    log_fatal("chmod() failed for %s", nvscheduler_socket_path);

  out_msg.id = 7331;

  log_info("nvshare-scheduler listening on %s", nvscheduler_socket_path);

  for (;;) {
    num_fds = RETRY_INTR(epoll_wait(epoll_fd, events, EPOLL_MAX_EVENTS, -1));

    if (num_fds < 0) log_fatal("epoll_wait() failed");

    true_or_exit(pthread_mutex_lock(&global_mutex) == 0);

    for (int i = 0; i < num_fds; i++) {
      if (events[i].data.fd == lsock) {
        ret = nvshare_accept(events[i].data.fd, &rsock);
        if (ret == 0) { /* OK */
          client = malloc(sizeof(*client));
          client->fd = rsock;
          client->id = NVSHARE_UNREGISTERED_ID;
          client->next = NULL;
          client->context = NULL;

          event.data.ptr = client;
          event.events = EPOLLIN;
          if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, rsock, &event) < 0) {
            log_warn("Couldn't add %d to the epoll interest list", rsock);
            close(rsock);
            free(client);
          } else
            LL_APPEND(clients, client); /* OK */
        } else if (errno != ECONNABORTED && errno != EAGAIN &&
                   errno != EWOULDBLOCK)
          log_fatal("accept() failed non-transiently");

      } else { /* Some event other than new connection */
        client = (struct nvshare_client*)events[i].data.ptr;

        if (events[i].events & EPOLLIN) {
          ret = receive_message(client, &in_msg);
          if (ret < 0) {
            struct gpu_context* ctx =
                client->context;  // Save context before delete
            delete_client(client);
            if (ctx && !ctx->lock_held && scheduler_on) try_schedule(ctx);
          } else
            process_msg(client, &in_msg); /* OK */

        } else if (events[i].events & (EPOLLERR | EPOLLHUP)) {
          struct gpu_context* ctx = client->context;  // Save context
          delete_client(client);
          if (ctx && !ctx->lock_held && scheduler_on) try_schedule(ctx);
        }
      }
    }
    true_or_exit(pthread_mutex_unlock(&global_mutex) == 0);
  }

  return -1;
}
