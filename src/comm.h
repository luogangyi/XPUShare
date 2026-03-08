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
 * Communication primitives header file.
 */

#ifndef _NVSHARE_COMM_H_
#define _NVSHARE_COMM_H_

#include <errno.h>
#include <inttypes.h>
#include <sys/types.h>

/* https://lists.debian.org/debian-glibc/2004/02/msg00232.html */
#include <sys/un.h>
#ifndef UNIX_PATH_MAX
#define UNIX_PATH_MAX sizeof(((struct sockaddr_un*)0)->sun_path)
#endif

/* Maximum length of nvshare socket path */
#define NVSHARE_SOCK_PATH_MAX UNIX_PATH_MAX

/*
 * A message's data segment must comfortably hold 16 HEX characters plus a
 * NULL terminator for the client ID which the scheduler sends as a response
 * to a REGISTER message.
 */
#define MSG_DATA_LEN 20
#define POD_NAME_LEN_MAX 254
#define POD_NAMESPACE_LEN_MAX 254

#define NVSHARE_SOCK_DIR "/var/run/nvshare/"

extern const char* message_type_string[];
extern uint64_t nvshare_generate_id(void);
extern int nvshare_get_scheduler_path(char* sock_path);
extern int nvshare_bind_and_listen(int* lsock, const char* sock_path);
extern int nvshare_connect(int* rsock, const char* rpath);
extern int nvshare_accept(int lsock, int* rsock);
extern ssize_t nvshare_send_noblock(int rsock, const void* msg_p, size_t count);
extern ssize_t nvshare_receive_noblock(int rsock, void* msg_p, size_t count);
extern int nvshare_receive_block(int rsock, void* msg_p, size_t count);

enum message_type {
  REGISTER = 1,
  SCHED_ON = 2,
  SCHED_OFF = 3,
  REQ_LOCK = 4,
  LOCK_OK = 5,
  DROP_LOCK = 6,
  LOCK_RELEASED = 7,
  SET_TQ = 8,
  /* Memory-aware scheduling messages */
  MEM_UPDATE = 9,        /* Client -> Scheduler: report memory usage change */
  WAIT_FOR_MEM = 10,     /* Scheduler -> Client: not enough memory, wait */
  MEM_AVAILABLE = 11,    /* Scheduler -> Client: memory available, proceed */
  PREPARE_SWAP_OUT = 12, /* Scheduler -> Client: evict memory before switch */
  /* Dynamic memory limit adjustment */
  UPDATE_LIMIT =
      13, /* Scheduler -> Client: update memory limit from annotation */
  /* Dynamic compute limit adjustment */
  UPDATE_CORE_LIMIT =
      14, /* Scheduler -> Client: update compute limit from annotation */
  /* NPU init serialization */
  REQ_INIT = 15,      /* Client -> Scheduler: request init gate */
  INIT_GRANTED = 16,  /* Scheduler -> Client: init gate granted */
  INIT_DONE = 17,     /* Client -> Scheduler: init completed successfully */
  INIT_FAIL = 18,     /* Client -> Scheduler: init completed with failure */
  MEM_TOTAL = 19,     /* Client -> Scheduler: report device total memory */
  ACTIVE_TIME_UPDATE =
      20 /* Client -> Scheduler: report active device time delta */
} __attribute__((__packed__));

#define NVSHARE_GPU_UUID_LEN 96

/* Protocol version for forward/backward compatibility */
#define NVSHARE_PROTOCOL_VERSION 3

/* Client capability flags reported through message.capability_flags */
#define NVSHARE_CAP_DEVICE_RESLIMIT (1U << 0)
#define NVSHARE_CAP_STREAM_RESLIMIT (1U << 1)
#define NVSHARE_CAP_STREAM_THREAD_BIND (1U << 2)
#define NVSHARE_CAP_ACTIVE_METER_EVENT (1U << 3)

struct message {
  enum message_type type;
  uint16_t protocol_version; /* 0 = legacy, 2 = with host_pid */
  /*
   * Client id. Used only for debugging purposes (i.e., easily identify
   * scheduler logs for a specific client).
   */
  char pod_name[POD_NAME_LEN_MAX];
  char pod_namespace[POD_NAMESPACE_LEN_MAX];
  char gpu_uuid[NVSHARE_GPU_UUID_LEN];
  uint64_t id;
  char data[MSG_DATA_LEN];
  /* Memory-aware scheduling: current memory usage in bytes */
  size_t memory_usage;
  /* NPU allocation split: managed/native bytes */
  size_t memory_usage_managed;
  size_t memory_usage_native;
  /* NPU managed fallback counters (client-lifetime monotonic) */
  unsigned long npu_managed_fallback_symbol_unavailable;
  unsigned long npu_managed_fallback_align_overflow;
  unsigned long npu_managed_fallback_alloc_failed;
  unsigned long npu_managed_fallback_cfg_nonnull;
  /* NPU prefetch counters (client-lifetime monotonic) */
  unsigned long npu_prefetch_ok_total;
  unsigned long npu_prefetch_fail_total;
  /* Dynamic limit: memory limit in bytes (0 = no limit) */
  size_t memory_limit;
  /* Compute limit: client's compute quota percentage (1-100, default 100) */
  int core_limit;
  /* Host-namespace PID for NVML process-to-client mapping */
  pid_t host_pid;
  /* Capability bitmap for NPU quota control paths */
  uint32_t capability_flags;
  /* Device active-time delta (ms) since previous report */
  uint64_t active_time_ms_delta;
  /* Monotonic active-time report sequence */
  uint64_t active_time_seq;
} __attribute__((__packed__));

#endif /* _NVSHARE_COMM_H_ */
