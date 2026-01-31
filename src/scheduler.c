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
#include "utlist.h"

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
  SWITCH_TIME_FIXED /* Fixed switch time */
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
  pthread_t timer_tid;
  struct gpu_context* next;
  /* Memory-aware scheduling fields */
  size_t total_memory;                /* Total GPU memory in bytes */
  size_t available_memory;            /* Available memory in bytes */
  size_t running_memory_usage;        /* Memory used by running processes */
  struct nvshare_request* wait_queue; /* Processes waiting for memory */
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
};

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
  ctx->wait_queue = NULL;
  true_or_exit(pthread_cond_init(&ctx->timer_cv, NULL) == 0);

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

static void check_wait_queue(struct gpu_context* ctx);

static void remove_req(struct nvshare_client* client) {
  struct nvshare_request *tmp, *r;
  struct gpu_context* ctx = client->context;
  if (!ctx) return;

  /* Check if this client is in the running_list */
  LL_FOREACH_SAFE(ctx->running_list, r, tmp) {
    if (r->client->fd == client->fd) {
      /* Update memory tracking when client releases lock */
      if (client->is_running) {
        if (ctx->running_memory_usage >= client->memory_allocated) {
          ctx->running_memory_usage -= client->memory_allocated;
        } else {
          ctx->running_memory_usage = 0;
        }
        client->is_running = 0;
        log_info("Client %016" PRIx64 " released, running_memory: %zu MB",
                 client->id, ctx->running_memory_usage / (1024 * 1024));
      }
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

/* Check if client can run with current memory usage and scheduling mode */
static int can_run_with_memory(struct gpu_context* ctx,
                               struct nvshare_client* client) {
  size_t safe_limit =
      ctx->total_memory * (100 - config.memory_reserve_percent) / 100;

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
  out_msg.type = WAIT_FOR_MEM;
  send_message(req->client, &out_msg);

  log_info("Client %016" PRIx64
           " moved to wait queue (req: %zu MB, avail: %zu MB)",
           req->client->id, req->client->memory_allocated / (1024 * 1024),
           (ctx->total_memory - ctx->running_memory_usage) / (1024 * 1024));
}

static void check_wait_queue(struct gpu_context* ctx) {
  struct nvshare_request *r, *tmp;

  LL_FOREACH_SAFE(ctx->wait_queue, r, tmp) {
    if (can_run_with_memory(ctx, r->client)) {
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

  if (!can_run_with_memory(ctx, scheduled_client)) {
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
void* timer_thr_fn(void* arg) {
  struct gpu_context* ctx = (struct gpu_context*)arg;
  struct message t_msg = {0};
  struct message swap_msg = {0};
  unsigned int round_at_start;
  struct timespec timer_end_ts = {0, 0};
  struct timespec max_runtime_end_ts = {0, 0};
  int ret;
  int drop_lock_sent = 0;
  int swap_out_sent = 0;
  int current_tq;
  time_t task_start_time = 0;

  t_msg.id = 1337; /* Nobody checks this */
  t_msg.type = DROP_LOCK;
  swap_msg.id = 1337;
  swap_msg.type = PREPARE_SWAP_OUT;

  true_or_exit(pthread_mutex_lock(&global_mutex) == 0);
  while (1) {
    ctx->must_reset_timer = 0;
    round_at_start = ctx->scheduling_round;
    drop_lock_sent = 0;
    swap_out_sent = 0;

    current_tq = calculate_switch_time(ctx);

    /* Record task start time */
    task_start_time = time(NULL);

    true_or_exit(clock_gettime(CLOCK_REALTIME, &timer_end_ts) == 0);
    timer_end_ts.tv_sec += current_tq;

    /* Also calculate max runtime timeout */
    max_runtime_end_ts = timer_end_ts;
    if (config.max_runtime_sec > 0 && config.max_runtime_sec < current_tq) {
      /* Use max_runtime_sec if it's shorter than current TQ */
      true_or_exit(clock_gettime(CLOCK_REALTIME, &max_runtime_end_ts) == 0);
      max_runtime_end_ts.tv_sec += config.max_runtime_sec;
    }

  remainder:
    ret = pthread_cond_timedwait(&ctx->timer_cv, &global_mutex, &timer_end_ts);
    /* Wake up with global_mutex held, can do whatever we want */
    if (ret == ETIMEDOUT) { /* TQ elapsed */
      log_debug("TQ (%d s) elapsed for %s", current_tq, ctx->uuid);
      if (!ctx->lock_held) continue; /* Life is meaningless :( */
      if (drop_lock_sent) continue;  /* Send it only once */

      if (round_at_start != ctx->scheduling_round) {
        drop_lock_sent = 0;
        swap_out_sent = 0;
        continue;
      }

      /* Check max runtime enforcement */
      time_t elapsed = time(NULL) - task_start_time;
      int force_switch =
          (config.max_runtime_sec > 0 && elapsed >= config.max_runtime_sec);

      /* Smart Preemption: Check if anyone else is waiting.
       * 1. Pending requests (tasks waiting to be scheduled)
       * 2. Wait queue (waiting for memory)
       */
      int someone_waiting =
          (ctx->requests != NULL) || (ctx->wait_queue != NULL);

      if (!someone_waiting && !force_switch) {
        log_debug("TQ elapsed but no one waiting, extending slice for %s",
                  ctx->uuid);
        continue; /* Loop back to calculate new TQ and wait again */
      }

      if (force_switch && !someone_waiting) {
        log_info(
            "Max runtime (%d s) exceeded for %s, but no one waiting - "
            "extending",
            config.max_runtime_sec, ctx->uuid);
        continue;
      }

      /*
       * Send PREPARE_SWAP_OUT and DROP_LOCK to all running tasks.
       * This is needed when there are tasks waiting to be scheduled.
       */
      if (ctx->running_list != NULL) {
        struct nvshare_request *run_req, *run_tmp;

        /* First send PREPARE_SWAP_OUT to all running tasks */
        if (!swap_out_sent) {
          log_info(
              "Sending PREPARE_SWAP_OUT to %d running clients before switch "
              "(elapsed: %ld s)",
              ctx->running_list ? 1 : 0, elapsed);
          LL_FOREACH_SAFE(ctx->running_list, run_req, run_tmp) {
            send_message(run_req->client, &swap_msg);
          }
          swap_out_sent = 1;
        }

        /* Then send DROP_LOCK to all running tasks */
        LL_FOREACH_SAFE(ctx->running_list, run_req, run_tmp) {
          if (send_message(run_req->client, &t_msg) < 0) {
            delete_client(run_req->client);
          }
        }
        drop_lock_sent = 1;
        log_info(
            "Sent DROP_LOCK to running clients after %ld seconds of runtime",
            elapsed);
      }
    } else if (ret != 0) { /* Unrecoverable error */
      errno = ret;
      log_fatal("pthread_cond_timedwait()");
    } else { /* ret == 0, someone signaled the condvar */
      if (ctx->must_reset_timer) {
        drop_lock_sent = 0;
        swap_out_sent = 0;
        continue;
      } else { /* Spurious wakeup */
        goto remainder;
      }
    }
  }
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
                 " with Pod"
                 " name = %s, Pod namespace = %s",
                 client->id, client->pod_name, client->pod_namespace);
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
          log_debug("GPU %s running memory updated: %zu MB", ctx->uuid,
                    ctx->running_memory_usage / (1024 * 1024));
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

  scheduler_on = 1;
  tq = NVSHARE_DEFAULT_TQ;

  srand((unsigned int)(time(NULL)));

  true_or_exit(pthread_mutex_init(&global_mutex, NULL) == 0);

  if (nvshare_get_scheduler_path(nvscheduler_socket_path) != 0)
    log_fatal("nvshare_get_scheduler_path() failed!");

  /* Timer threads are spawned per GPU context */

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
