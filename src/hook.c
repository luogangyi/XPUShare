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
 * Hook CUDA function calls.
 */

/*
 * Defining _GNU_SOURCE allows us to call dlvsym().
 *
 * More on _GNU_SOURCE: https://stackoverflow.com/a/5583764
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif /* _GNU_SOURCE */

#include <dlfcn.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "client.h"
#include "comm.h"
#include "common.h"
#include "backend.h"
#include "cuda_defs.h"
#include "npu_defs.h"
#include "utlist.h"

#if !defined(__GLIBC__)
extern void* dlvsym(void* handle, const char* symbol, const char* version);
#endif

#define ENV_NVSHARE_ENABLE_SINGLE_OVERSUB "NVSHARE_ENABLE_SINGLE_OVERSUB"

#define MEMINFO_RESERVE_MIB 1536           /* MiB */
#define KERN_SYNC_WINDOW_STEPDOWN_THRESH 1 /* seconds */
#define KERN_SYNC_WINDOW_MAX 2048          /* Pending Kernels */
#define NPU_GETCOUNT_RETRY_TIMES 12
#define NPU_GETCOUNT_RETRY_SLEEP_US 50000
#define NPU_ACLINIT_RETRY_TIMES 16
#define NPU_ACLINIT_RETRY_SLEEP_US 50000
#define NPU_ACLINIT_TRANSIENT_ERR_A 507000
#define NPU_ACLINIT_TRANSIENT_ERR_B 0x50100001
#define NPU_MANAGED_MODULE_ID_DEFAULT 255U

/* Configurable parameters with defaults */
int kern_sync_duration_big = 10;      /* Critical timeout seconds */
double kern_sync_duration_mild = 1.0; /* Mild timeout seconds */
int kern_window_min_floor = 4;        /* Minimum window size */
int kern_warmup_period_sec = 30;      /* Warmup grace period */

/* External: client's compute quota from client.c */
extern int client_core_limit;

/* Calculate dynamic kernel window max based on client's compute quota.
 * Lower quotas should have smaller windows to avoid excessive lock release
 * delays when cuCtxSynchronize() waits for all pending kernels to complete.
 * Formula: Allow roughly 0.5 seconds worth of kernels at full speed.
 * Assuming 10ms per kernel average: 30% → 30 kernels, 60% → 60 kernels, etc.
 * But maintain minimum of 30 for throughput. */
static int get_kernel_window_max(void) {
  int dynamic_max;

  if (client_core_limit >= 100) {
    dynamic_max = KERN_SYNC_WINDOW_MAX;
  } else {
    /* For quota-limited workloads, keep a tighter cap to avoid long
     * cuCtxSynchronize() tails at DROP_LOCK, which disproportionately hurts
     * high quotas (e.g., 60%+) under frequent preemption. */
    dynamic_max = client_core_limit / 2;
    if (dynamic_max < 16) dynamic_max = 16;
    if (dynamic_max > 32) dynamic_max = 32;
  }

  if (dynamic_max > KERN_SYNC_WINDOW_MAX) dynamic_max = KERN_SYNC_WINDOW_MAX;
  return dynamic_max;
}

static void* real_dlsym_225(void* handle, const char* symbol);
static void* real_dlsym_217(void* handle, const char* symbol);
static void* real_dlsym_234(void* handle, const char* symbol);

static void maybe_select_backend(int backend, const char* trigger) {
  if (nvshare_backend_mode == NVSHARE_BACKEND_UNKNOWN) {
    nvshare_backend_mode = backend;
    log_info("Selected runtime backend: %s (trigger=%s)",
             nvshare_backend_mode_name(backend), trigger);
    return;
  }

  if (nvshare_backend_mode != backend) {
    log_warn("Ignoring backend switch %s -> %s (trigger=%s)",
             nvshare_backend_mode_name(nvshare_backend_mode),
             nvshare_backend_mode_name(backend), trigger);
  }
}

int nvshare_backend_mode = NVSHARE_BACKEND_UNKNOWN;
static int npu_api_trace_enabled = -1;
static pthread_mutex_t npu_api_trace_mutex = PTHREAD_MUTEX_INITIALIZER;
static int npu_quota_post_sync_sleep_cap_ms = -1;
static int npu_quota_post_sync_sleep_gain_percent = -1;
static int npu_quota_post_sync_sleep_gain_from_env = 0;
static int npu_quota_post_sync_sleep_adaptive = -1;
static int npu_managed_alloc_mode = -1;
static int npu_managed_fallback_mode = -1;
static int npu_managed_withcfg_mode = -1;
static uint16_t npu_managed_module_id = UINT16_MAX;
static void* npu_runtime_handle = NULL;

enum npu_managed_fallback_reason {
  NPU_FALLBACK_SYMBOL_UNAVAILABLE = 0,
  NPU_FALLBACK_ALIGN_OVERFLOW = 1,
  NPU_FALLBACK_ALLOC_FAILED = 2,
  NPU_FALLBACK_CFG_NONNULL = 3,
  NPU_FALLBACK_REASON_COUNT = 4,
};
static unsigned long
    npu_managed_fallback_counters[NPU_FALLBACK_REASON_COUNT] = {0};
static unsigned long npu_prefetch_ok_total = 0;
static unsigned long npu_prefetch_fail_total = 0;
static int npu_prefetch_enable_mode = -1;
static int npu_prefetch_runtime_disabled = 0;
static size_t npu_prefetch_min_bytes = 0;
static int npu_prefetch_max_ops_per_cycle = -1;
static time_t npu_prefetch_cycle_sec = 0;
static int npu_prefetch_ops_in_cycle = 0;
static pthread_mutex_t npu_prefetch_mutex = PTHREAD_MUTEX_INITIALIZER;

#define NPU_API_TRACE_MAX 64
struct npu_api_trace_entry {
  const char* api;
  unsigned long hits;
};
static struct npu_api_trace_entry npu_api_trace_entries[NPU_API_TRACE_MAX];
static int npu_api_trace_entry_count = 0;

static int npu_api_trace_is_enabled(void) {
  const char* env = NULL;
  int enabled = 0;
  int parsed = 0;

  if (npu_api_trace_enabled >= 0) return npu_api_trace_enabled;

  env = getenv("NVSHARE_NPU_API_TRACE");
  if (env != NULL && env[0] != '\0') {
    int v = atoi(env);
    if (v > 0) {
      enabled = 1;
      parsed = 1;
    } else if (strcmp(env, "true") == 0 || strcmp(env, "TRUE") == 0 ||
               strcmp(env, "on") == 0 || strcmp(env, "ON") == 0 ||
               strcmp(env, "yes") == 0 || strcmp(env, "YES") == 0) {
      enabled = 1;
      parsed = 1;
    }
  }

  if (!parsed) enabled = 0;
  npu_api_trace_enabled = enabled;
  if (enabled) {
    log_info("Enabled NPU API trace (NVSHARE_NPU_API_TRACE=%s)", env);
  }
  return npu_api_trace_enabled;
}

static void npu_api_trace_hit(const char* api) {
  int i;
  unsigned long hits = 0;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;
  if (!npu_api_trace_is_enabled()) return;
  if (api == NULL || api[0] == '\0') return;

  true_or_exit(pthread_mutex_lock(&npu_api_trace_mutex) == 0);
  for (i = 0; i < npu_api_trace_entry_count; ++i) {
    if (strcmp(npu_api_trace_entries[i].api, api) == 0) {
      npu_api_trace_entries[i].hits++;
      hits = npu_api_trace_entries[i].hits;
      true_or_exit(pthread_mutex_unlock(&npu_api_trace_mutex) == 0);
      if (hits == 1 || hits == 10 || hits == 100 || (hits % 1000) == 0) {
        log_info("NPU API trace: %s hits=%lu", api, hits);
      }
      return;
    }
  }

  if (npu_api_trace_entry_count < NPU_API_TRACE_MAX) {
    npu_api_trace_entries[npu_api_trace_entry_count].api = api;
    npu_api_trace_entries[npu_api_trace_entry_count].hits = 1;
    npu_api_trace_entry_count++;
    hits = 1;
  }
  true_or_exit(pthread_mutex_unlock(&npu_api_trace_mutex) == 0);

  if (hits == 1) {
    log_info("NPU API trace: %s hits=1", api);
  }
}

static int npu_managed_alloc_enabled(void) {
  const char* env = NULL;

  if (npu_managed_alloc_mode >= 0) return npu_managed_alloc_mode;

  env = getenv("NVSHARE_NPU_OVERSUB_ALLOC_MODE");
  if (env == NULL || env[0] == '\0' || strcmp(env, "managed") == 0) {
    npu_managed_alloc_mode = 1;
  } else if (strcmp(env, "acl") == 0 || strcmp(env, "native") == 0) {
    npu_managed_alloc_mode = 0;
  } else {
    npu_managed_alloc_mode = 1;
    log_warn("Unknown NVSHARE_NPU_OVERSUB_ALLOC_MODE=%s, fallback to managed",
             env);
  }

  if (npu_managed_alloc_mode) {
    log_info("NPU oversub allocation mode: managed");
  } else {
    log_info("NPU oversub allocation mode: acl/native");
  }
  return npu_managed_alloc_mode;
}

static int npu_managed_alloc_fallback_enabled(void) {
  const char* env = NULL;
  int val = 1;

  if (npu_managed_fallback_mode >= 0) return npu_managed_fallback_mode;

  env = getenv("NVSHARE_NPU_MANAGED_FALLBACK");
  if (env != NULL && env[0] != '\0') val = atoi(env);
  npu_managed_fallback_mode = (val != 0) ? 1 : 0;
  return npu_managed_fallback_mode;
}

static int npu_managed_withcfg_enabled(void) {
  const char* env = NULL;
  int enabled = 0;

  if (npu_managed_withcfg_mode >= 0) return npu_managed_withcfg_mode;

  env = getenv("NVSHARE_NPU_MANAGED_WITHCFG");
  if (env != NULL && env[0] != '\0') {
    if (strcmp(env, "managed") == 0 || strcmp(env, "1") == 0 ||
        strcmp(env, "true") == 0 || strcmp(env, "TRUE") == 0 ||
        strcmp(env, "on") == 0 || strcmp(env, "ON") == 0 ||
        strcmp(env, "yes") == 0 || strcmp(env, "YES") == 0) {
      enabled = 1;
    } else if (strcmp(env, "acl") == 0 || strcmp(env, "native") == 0 ||
               strcmp(env, "0") == 0 || strcmp(env, "false") == 0 ||
               strcmp(env, "FALSE") == 0 || strcmp(env, "off") == 0 ||
               strcmp(env, "OFF") == 0 || strcmp(env, "no") == 0 ||
               strcmp(env, "NO") == 0) {
      enabled = 0;
    } else {
      enabled = 0;
      log_warn("Unknown NVSHARE_NPU_MANAGED_WITHCFG=%s, fallback to acl/native",
               env);
    }
  }

  npu_managed_withcfg_mode = enabled;
  if (enabled) {
    log_info("NPU managed path enabled for aclrtMallocWithCfg");
  }
  return npu_managed_withcfg_mode;
}

static uint16_t get_npu_managed_module_id(void) {
  const char* env = NULL;
  char* end = NULL;
  unsigned long parsed = NPU_MANAGED_MODULE_ID_DEFAULT;

  if (npu_managed_module_id != UINT16_MAX) return npu_managed_module_id;

  env = getenv("NVSHARE_NPU_MANAGED_MODULE_ID");
  if (env != NULL && env[0] != '\0') {
    parsed = strtoul(env, &end, 10);
    if (end == env || *end != '\0' || parsed > 65535UL) {
      parsed = NPU_MANAGED_MODULE_ID_DEFAULT;
      log_warn("Invalid NVSHARE_NPU_MANAGED_MODULE_ID=%s, fallback to %u", env,
               (unsigned)NPU_MANAGED_MODULE_ID_DEFAULT);
    }
  }

  npu_managed_module_id = (uint16_t)parsed;
  return npu_managed_module_id;
}

static void npu_record_managed_fallback(enum npu_managed_fallback_reason reason,
                                        const char* api_name,
                                        const char* detail) {
  if (reason < 0 || reason >= NPU_FALLBACK_REASON_COUNT) return;
  __sync_fetch_and_add(&npu_managed_fallback_counters[reason], 1);
  log_debug("%s: managed fallback reason=%d detail=%s",
            api_name ? api_name : "unknown", (int)reason,
            detail ? detail : "none");
}

static unsigned long npu_fallback_counter(enum npu_managed_fallback_reason reason) {
  if (reason < 0 || reason >= NPU_FALLBACK_REASON_COUNT) return 0;
  return __sync_add_and_fetch(&npu_managed_fallback_counters[reason], 0);
}

static int npu_prefetch_enabled(void) {
  const char* env = NULL;
  int enabled = 0;

  if (npu_prefetch_enable_mode >= 0) return npu_prefetch_enable_mode;

  env = getenv("NVSHARE_NPU_PREFETCH_ENABLE");
  if (env != NULL && env[0] != '\0') {
    if (strcmp(env, "0") == 0 || strcmp(env, "false") == 0 ||
        strcmp(env, "FALSE") == 0 || strcmp(env, "off") == 0 ||
        strcmp(env, "OFF") == 0 || strcmp(env, "no") == 0 ||
        strcmp(env, "NO") == 0) {
      enabled = 0;
    } else {
      enabled = 1;
    }
  }

  npu_prefetch_enable_mode = enabled;
  if (enabled) {
    log_info("NPU managed prefetch is enabled");
  } else {
    log_info("NPU managed prefetch is disabled");
  }
  return npu_prefetch_enable_mode;
}

static size_t get_npu_prefetch_min_bytes(void) {
  const char* env = NULL;
  unsigned long long parsed = 32ULL * 1024ULL * 1024ULL;

  if (npu_prefetch_min_bytes > 0) return npu_prefetch_min_bytes;

  env = getenv("NVSHARE_NPU_PREFETCH_MIN_BYTES");
  if (env != NULL && env[0] != '\0') {
    parsed = strtoull(env, NULL, 10);
    if (parsed < 1024ULL) parsed = 1024ULL;
  }
  npu_prefetch_min_bytes = (size_t)parsed;
  return npu_prefetch_min_bytes;
}

static int get_npu_prefetch_max_ops_per_cycle(void) {
  const char* env = NULL;
  int parsed = 4;

  if (npu_prefetch_max_ops_per_cycle >= 0) return npu_prefetch_max_ops_per_cycle;

  env = getenv("NVSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE");
  if (env != NULL && env[0] != '\0') parsed = atoi(env);
  if (parsed < 0) parsed = 0;
  if (parsed > 1024) parsed = 1024;
  npu_prefetch_max_ops_per_cycle = parsed;
  return npu_prefetch_max_ops_per_cycle;
}

static int npu_prefetch_allow_this_allocation(size_t bytesize) {
  int max_ops;
  time_t now_sec;

  if (!npu_prefetch_enabled()) return 0;
  if (__sync_add_and_fetch(&npu_prefetch_runtime_disabled, 0) != 0) return 0;
  if (real_rtMemPrefetchToDevice == NULL) return 0;
  if (bytesize < get_npu_prefetch_min_bytes()) return 0;

  max_ops = get_npu_prefetch_max_ops_per_cycle();
  if (max_ops == 0) return 0;

  true_or_exit(pthread_mutex_lock(&npu_prefetch_mutex) == 0);
  now_sec = time(NULL);
  if (npu_prefetch_cycle_sec != now_sec) {
    npu_prefetch_cycle_sec = now_sec;
    npu_prefetch_ops_in_cycle = 0;
  }
  if (npu_prefetch_ops_in_cycle >= max_ops) {
    true_or_exit(pthread_mutex_unlock(&npu_prefetch_mutex) == 0);
    return 0;
  }
  npu_prefetch_ops_in_cycle++;
  true_or_exit(pthread_mutex_unlock(&npu_prefetch_mutex) == 0);
  return 1;
}

static void npu_record_prefetch_result(int ok) {
  if (ok) {
    __sync_fetch_and_add(&npu_prefetch_ok_total, 1);
  } else {
    __sync_fetch_and_add(&npu_prefetch_fail_total, 1);
  }
}

static int maybe_prefetch_npu_allocation(void* ptr, size_t bytesize,
                                         const char* api_name) {
  int32_t device_id = 0;
  aclError acl_err = ACL_SUCCESS;
  rtError_t rt_err = RT_ERROR_NONE;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return 0;
  if (ptr == NULL || bytesize == 0) return 0;
  if (!npu_prefetch_allow_this_allocation(bytesize)) return 0;

  if (real_aclrtGetDevice != NULL) {
    acl_err = real_aclrtGetDevice(&device_id);
    if (acl_err != ACL_SUCCESS) {
      device_id = 0;
    }
  }

  rt_err = real_rtMemPrefetchToDevice(ptr, (uint64_t)bytesize, device_id);
  if (rt_err == RT_ERROR_NONE) {
    npu_record_prefetch_result(1);
    log_debug("%s: prefetched managed allocation size=%zu device=%d",
              api_name ? api_name : "unknown", bytesize, (int)device_id);
    return 1;
  } else {
    npu_record_prefetch_result(0);
    log_warn("%s: rtMemPrefetchToDevice failed ret=%d size=%zu device=%d",
             api_name ? api_name : "unknown", (int)rt_err, bytesize,
             (int)device_id);
    if (__sync_bool_compare_and_swap(&npu_prefetch_runtime_disabled, 0, 1)) {
      log_warn("%s: disabling NPU managed prefetch for this process after first "
               "failure",
               api_name ? api_name : "unknown");
    }
    return 1;
  }
  return 0;
}

static int align_acl_malloc_size(size_t size, int is_padding, size_t* aligned) {
  size_t append_size = is_padding ? 64UL : 32UL;
  size_t addend = append_size - 1UL;

  if (aligned == NULL) return 0;
  if (size > SIZE_MAX - addend) return 0;
  *aligned = ((size + addend) / 32UL) * 32UL;
  return 1;
}

static int get_npu_quota_post_sync_sleep_cap_ms(void) {
  const char* env = NULL;
  int val = 2000;

  if (npu_quota_post_sync_sleep_cap_ms >= 0)
    return npu_quota_post_sync_sleep_cap_ms;

  env = getenv("NVSHARE_NPU_SYNC_SLEEP_CAP_MS");
  if (env != NULL && env[0] != '\0') val = atoi(env);

  if (val < 0) val = 0;
  if (val > 10000) val = 10000;
  npu_quota_post_sync_sleep_cap_ms = val;
  return npu_quota_post_sync_sleep_cap_ms;
}

static int get_npu_quota_post_sync_sleep_gain_percent(void) {
  const char* env = NULL;
  int val = 60;

  if (npu_quota_post_sync_sleep_gain_percent >= 0)
    return npu_quota_post_sync_sleep_gain_percent;

  env = getenv("NVSHARE_NPU_SYNC_SLEEP_GAIN_PERCENT");
  if (env != NULL && env[0] != '\0') {
    val = atoi(env);
    npu_quota_post_sync_sleep_gain_from_env = 1;
  } else {
    npu_quota_post_sync_sleep_gain_from_env = 0;
  }

  if (val < 0) val = 0;
  if (val > 300) val = 300;
  npu_quota_post_sync_sleep_gain_percent = val;
  return npu_quota_post_sync_sleep_gain_percent;
}

static int get_npu_quota_post_sync_sleep_adaptive_enabled(void) {
  const char* env = NULL;
  int val = 1;

  if (npu_quota_post_sync_sleep_adaptive >= 0)
    return npu_quota_post_sync_sleep_adaptive;

  env = getenv("NVSHARE_NPU_SYNC_SLEEP_ADAPTIVE");
  if (env != NULL && env[0] != '\0') {
    val = atoi(env) != 0 ? 1 : 0;
  } else if (npu_quota_post_sync_sleep_gain_from_env) {
    /*
     * If user explicitly sets fixed gain, default to fixed mode unless
     * NVSHARE_NPU_SYNC_SLEEP_ADAPTIVE is also explicitly enabled.
     */
    val = 0;
  }

  npu_quota_post_sync_sleep_adaptive = val;
  return npu_quota_post_sync_sleep_adaptive;
}

static int get_npu_quota_post_sync_effective_gain_percent(int limit) {
  int base = get_npu_quota_post_sync_sleep_gain_percent();
  int gain = base;
  int adaptive = get_npu_quota_post_sync_sleep_adaptive_enabled();

  if (!adaptive) return base;
  if (limit >= 100 || limit <= 0) return base;

  if (limit <= 25) {
    gain = (base * 11 + 2) / 5; /* ~2.20x */
  } else if (limit <= 35) {
    gain = (base * 23 + 5) / 10; /* ~2.30x */
  } else if (limit <= 50) {
    gain = (base * 12 + 2) / 5; /* ~2.40x */
  } else if (limit <= 60) {
    gain = (base * 9 + 2) / 4; /* ~2.25x */
  } else if (limit <= 75) {
    gain = (base * 21 + 5) / 10; /* ~2.10x */
  }

  if (gain < 0) gain = 0;
  if (gain > 300) gain = 300;
  return gain;
}

static void maybe_apply_npu_post_sync_quota_sleep(const char* api_name,
                                                  long elapsed_ms) {
  int limit;
  int gain_percent;
  long sleep_ms;
  int cap_ms;
  int interrupted;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;
  if (elapsed_ms <= 0) return;

  limit = client_core_limit;
  if (limit <= 0 || limit >= 100) return;

  gain_percent = get_npu_quota_post_sync_effective_gain_percent(limit);
  if (gain_percent <= 0) return;

  sleep_ms = (elapsed_ms * (100 - limit) * gain_percent) / (limit * 100);
  if (sleep_ms <= 0) return;

  cap_ms = get_npu_quota_post_sync_sleep_cap_ms();
  if (cap_ms > 0 && sleep_ms > cap_ms) sleep_ms = cap_ms;
  if (sleep_ms <= 0) return;

  log_debug("NPU post-sync quota sleep: api=%s limit=%d%% elapsed=%ldms "
            "sleep=%ldms gain=%d%%",
            api_name ? api_name : "unknown", limit, elapsed_ms, sleep_ms,
            gain_percent);
  interrupted = nvshare_npu_quota_sleep_interruptible_ms(sleep_ms);
  if (interrupted) {
    log_debug("NPU post-sync sleep interrupted after lock loss: api=%s",
              api_name ? api_name : "unknown");
  }
}

const char* nvshare_backend_mode_name(int mode) {
  switch (mode) {
    case NVSHARE_BACKEND_CUDA:
      return "cuda";
    case NVSHARE_BACKEND_NPU:
      return "npu";
    default:
      return "unknown";
  }
}

cuCtxSynchronize_func real_cuCtxSynchronize = NULL;
cuLaunchKernel_func real_cuLaunchKernel = NULL;
cuMemcpy_func real_cuMemcpy = NULL;
cuMemcpyAsync_func real_cuMemcpyAsync = NULL;
cuMemcpyDtoH_func real_cuMemcpyDtoH = NULL;
cuMemcpyDtoHAsync_func real_cuMemcpyDtoHAsync = NULL;
cuMemcpyHtoD_func real_cuMemcpyHtoD = NULL;
cuMemcpyHtoDAsync_func real_cuMemcpyHtoDAsync = NULL;
cuMemcpyDtoD_func real_cuMemcpyDtoD = NULL;
cuMemcpyDtoDAsync_func real_cuMemcpyDtoDAsync = NULL;
cuGetProcAddress_func real_cuGetProcAddress = NULL;
cuGetProcAddress_v2_func real_cuGetProcAddress_v2 = NULL;
cuMemAllocManaged_func real_cuMemAllocManaged = NULL;
cuMemFree_func real_cuMemFree = NULL;
cuMemGetInfo_func real_cuMemGetInfo = NULL;
cuGetErrorString_func real_cuGetErrorString = NULL;
cuGetErrorName_func real_cuGetErrorName = NULL;
cuCtxSetCurrent_func real_cuCtxSetCurrent = NULL;
cuCtxGetCurrent_func real_cuCtxGetCurrent = NULL;
cuInit_func real_cuInit = NULL;
cuMemAdvise_func real_cuMemAdvise = NULL;

nvmlDeviceGetUtilizationRates_func real_nvmlDeviceGetUtilizationRates = NULL;
nvmlInit_func real_nvmlInit = NULL;
nvmlDeviceGetHandleByIndex_func real_nvmlDeviceGetHandleByIndex = NULL;
nvmlDeviceGetHandleByUUID_func real_nvmlDeviceGetHandleByUUID = NULL;

aclInit_func real_aclInit = NULL;
aclrtMalloc_func real_aclrtMalloc = NULL;
aclrtMallocAlign32_func real_aclrtMallocAlign32 = NULL;
aclrtMallocCached_func real_aclrtMallocCached = NULL;
aclrtMallocWithCfg_func real_aclrtMallocWithCfg = NULL;
aclrtFree_func real_aclrtFree = NULL;
aclrtGetMemInfo_func real_aclrtGetMemInfo = NULL;
aclrtCreateEvent_func real_aclrtCreateEvent = NULL;
aclrtDestroyEvent_func real_aclrtDestroyEvent = NULL;
aclrtRecordEvent_func real_aclrtRecordEvent = NULL;
aclrtQueryEventStatus_func real_aclrtQueryEventStatus = NULL;
aclrtEventElapsedTime_func real_aclrtEventElapsedTime = NULL;
aclrtGetDeviceCount_func real_aclrtGetDeviceCount = NULL;
aclrtLaunchKernel_func real_aclrtLaunchKernel = NULL;
aclrtLaunchKernelWithConfig_func real_aclrtLaunchKernelWithConfig = NULL;
aclrtLaunchKernelV2_func real_aclrtLaunchKernelV2 = NULL;
aclrtLaunchKernelWithHostArgs_func real_aclrtLaunchKernelWithHostArgs = NULL;
aclrtMemcpy_func real_aclrtMemcpy = NULL;
aclrtMemcpyAsync_func real_aclrtMemcpyAsync = NULL;
aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice = NULL;
aclrtSynchronizeStream_func real_aclrtSynchronizeStream = NULL;
aclrtSetDevice_func real_aclrtSetDevice = NULL;
aclrtGetDevice_func real_aclrtGetDevice = NULL;
aclrtSetCurrentContext_func real_aclrtSetCurrentContext = NULL;
aclrtGetCurrentContext_func real_aclrtGetCurrentContext = NULL;
aclrtGetDeviceResLimit_func real_aclrtGetDeviceResLimit = NULL;
aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit = NULL;
aclrtGetStreamResLimit_func real_aclrtGetStreamResLimit = NULL;
aclrtSetStreamResLimit_func real_aclrtSetStreamResLimit = NULL;
aclrtUseStreamResInCurrentThread_func real_aclrtUseStreamResInCurrentThread =
    NULL;
aclopExecute_func real_aclopExecute = NULL;
aclopExecuteV2_func real_aclopExecuteV2 = NULL;
aclopExecWithHandle_func real_aclopExecWithHandle = NULL;
aclmdlExecute_func real_aclmdlExecute = NULL;
aclmdlExecuteV2_func real_aclmdlExecuteV2 = NULL;
aclmdlExecuteAsync_func real_aclmdlExecuteAsync = NULL;
aclmdlExecuteAsyncV2_func real_aclmdlExecuteAsyncV2 = NULL;
rtDeviceSynchronize_func real_rtDeviceSynchronize = NULL;
rtDeviceSynchronizeWithTimeout_func real_rtDeviceSynchronizeWithTimeout = NULL;
rtStreamSynchronize_func real_rtStreamSynchronize = NULL;
rtStreamSynchronizeWithTimeout_func real_rtStreamSynchronizeWithTimeout = NULL;
rtKernelLaunch_func real_rtKernelLaunch = NULL;
rtKernelLaunchWithFlag_func real_rtKernelLaunchWithFlag = NULL;
rtKernelLaunchWithFlagV2_func real_rtKernelLaunchWithFlagV2 = NULL;
rtKernelLaunchEx_func real_rtKernelLaunchEx = NULL;
rtLaunchKernelByFuncHandleV3_func real_rtLaunchKernelByFuncHandleV3 = NULL;
rtsLaunchKernelWithConfig_func real_rtsLaunchKernelWithConfig = NULL;
rtsLaunchKernelWithDevArgs_func real_rtsLaunchKernelWithDevArgs = NULL;
rtsLaunchKernelWithHostArgs_func real_rtsLaunchKernelWithHostArgs = NULL;
rtVectorCoreKernelLaunch_func real_rtVectorCoreKernelLaunch = NULL;
rtMemAllocManaged_func real_rtMemAllocManaged = NULL;
rtMemFreeManaged_func real_rtMemFreeManaged = NULL;
rtMemPrefetchToDevice_func real_rtMemPrefetchToDevice = NULL;
rtMemAdvise_func real_rtMemAdvise = NULL;

size_t nvshare_size_mem_allocatable = 0;
size_t npu_size_mem_allocatable = 0;
size_t sum_allocated = 0;
size_t sum_npu_managed_allocated = 0;
size_t sum_npu_native_allocated = 0;
size_t memory_limit = 0; /* User-specified memory limit, 0 = no limit */
pthread_mutex_t limit_mutex =
    PTHREAD_MUTEX_INITIALIZER; /* Protect memory_limit */

int kern_since_sync = 0;
int pending_kernel_window = 64; /* Start optimistic */
int consecutive_timeout_count = 0;
pthread_mutex_t kcount_mutex;

int enable_single_oversub = 0;
int nvml_ok = 1;
int acl_ok = 0;
static int cuda_bootstrapped = 0;
static int acl_bootstrapped = 0;
static pthread_mutex_t npu_reslimit_mutex = PTHREAD_MUTEX_INITIALIZER;
static int npu_reslimit_cached_device = -1;
static int npu_reslimit_last_percent = -1;
static uint32_t npu_reslimit_cube_max = 0;
static uint32_t npu_reslimit_vector_max = 0;
static __thread aclrtStream npu_stream_reslimit_last_stream = NULL;
static __thread int npu_stream_reslimit_last_percent = -1;
static pthread_mutex_t npu_context_mutex = PTHREAD_MUTEX_INITIALIZER;
static int npu_context_cached_device = -1;
static aclrtContext npu_context_cached_ctx = NULL;
static pthread_mutex_t npu_init_gate_state_mutex = PTHREAD_MUTEX_INITIALIZER;
/*
 * When aclInit() succeeds, keep scheduler init gate held across the first
 * device-binding call (aclrtSetDevice/aclrtGetDevice). This closes the gap
 * where a second process could enter aclInit while GE/runtime is still
 * stabilizing in the first process.
 */
static int npu_init_gate_deferred = 0;
/*
 * After aclrtSetDevice succeeds, defer INIT_DONE once more until we observe
 * the first post-bind ACL runtime API (typically aclrtMalloc). This keeps
 * init serialization over torch_npu allocator/bootstrap work.
 */
static int npu_init_gate_post_setdevice_pending = 0;
static pthread_mutex_t npu_active_meter_mutex = PTHREAD_MUTEX_INITIALIZER;
static aclrtEvent npu_active_meter_start_event = NULL;
static aclrtEvent npu_active_meter_end_event = NULL;
static int npu_active_meter_enabled = -1;
static int npu_active_meter_interval_ms = -1;
static int npu_active_meter_window_open = 0;
static int npu_active_meter_end_pending = 0;
static int npu_active_meter_seen_launch = 0;
static uint64_t npu_active_meter_last_split_ms = 0;
static uint64_t npu_active_meter_pending_delta_ms = 0;

/* Thread-safe update of memory_limit from scheduler UPDATE_LIMIT message */
void update_memory_limit(size_t new_limit) {
  pthread_mutex_lock(&limit_mutex);
  size_t old_limit = memory_limit;
  memory_limit = new_limit;
  pthread_mutex_unlock(&limit_mutex);

  if (new_limit == 0) {
    log_info("Memory limit removed (was %zu bytes)", old_limit);
  } else {
    log_info("Memory limit updated: %zu -> %zu bytes (%.2f GiB)", old_limit,
             new_limit, (double)new_limit / (1024.0 * 1024.0 * 1024.0));
  }
}

/* Representation of a CUDA memory allocation */
struct cuda_mem_allocation {
  CUdeviceptr ptr;
  size_t size;
  struct cuda_mem_allocation* next;
};

/* Representation of an ACL/NPU memory allocation */
enum npu_alloc_mode {
  NPU_ALLOC_MODE_ACL = 0,
  NPU_ALLOC_MODE_RT_MANAGED = 1,
};

struct npu_mem_allocation {
  void* ptr;
  size_t size;
  size_t requested_size;
  size_t effective_size;
  uint64_t alloc_ts_ms;
  int alloc_mode;
  struct npu_mem_allocation* next;
};

/* Linked list that holds all memory allocations of current application. */
struct cuda_mem_allocation* cuda_allocation_list = NULL;
struct npu_mem_allocation* npu_allocation_list = NULL;

/* Initializaters will be executed only once per client application */
static pthread_once_t init_libnvshare_done = PTHREAD_ONCE_INIT;
static pthread_once_t init_done = PTHREAD_ONCE_INIT;
/* Fast-path hint: set after CUDA-side one-time initialization is complete. */
static int cuda_client_initialized = 0;
static void initialize_libnvshare(void);

static uint64_t monotonic_time_ms_u64(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static int get_npu_active_meter_enabled(void) {
  const char* env = NULL;
  int enabled = 1;

  if (npu_active_meter_enabled >= 0) return npu_active_meter_enabled;

  env = getenv("NVSHARE_NPU_ACTIVE_METER_ENABLE");
  if (env != NULL && env[0] != '\0') enabled = atoi(env);
  npu_active_meter_enabled = enabled > 0 ? 1 : 0;
  return npu_active_meter_enabled;
}

static int get_npu_active_meter_interval_ms(void) {
  const char* env = NULL;
  int val = 300;

  if (npu_active_meter_interval_ms > 0) return npu_active_meter_interval_ms;

  env = getenv("NVSHARE_NPU_ACTIVE_METER_INTERVAL_MS");
  if (env != NULL && env[0] != '\0') val = atoi(env);
  if (val < 50) val = 50;
  if (val > 5000) val = 5000;
  npu_active_meter_interval_ms = val;
  return npu_active_meter_interval_ms;
}

static int npu_active_meter_event_available(void) {
  return real_aclrtCreateEvent != NULL && real_aclrtDestroyEvent != NULL &&
         real_aclrtRecordEvent != NULL &&
         real_aclrtQueryEventStatus != NULL &&
         real_aclrtEventElapsedTime != NULL;
}

static void npu_active_meter_try_collect_locked(void) {
  aclrtEventRecordedStatus status = ACL_EVENT_RECORDED_STATUS_NOT_READY;
  float ms = 0.0f;
  aclError ret;
  uint64_t delta_ms;

  if (!npu_active_meter_end_pending) return;
  if (!npu_active_meter_event_available()) return;
  if (npu_active_meter_start_event == NULL || npu_active_meter_end_event == NULL)
    return;

  ret = real_aclrtQueryEventStatus(npu_active_meter_end_event, &status);
  if (ret != ACL_SUCCESS) return;
  if (status != ACL_EVENT_RECORDED_STATUS_COMPLETE) return;

  ret = real_aclrtEventElapsedTime(&ms, npu_active_meter_start_event,
                                   npu_active_meter_end_event);
  if (ret == ACL_SUCCESS && ms > 0.0f) {
    delta_ms = (uint64_t)(ms + 0.5f);
    npu_active_meter_pending_delta_ms += delta_ms;
  }

  npu_active_meter_end_pending = 0;
  npu_active_meter_window_open = 0;
}

static int npu_active_meter_init_locked(void) {
  aclError ret;

  if (npu_active_meter_start_event != NULL && npu_active_meter_end_event != NULL) {
    return 1;
  }
  if (!npu_active_meter_event_available()) return 0;

  if (npu_active_meter_start_event == NULL) {
    ret = real_aclrtCreateEvent(&npu_active_meter_start_event);
    if (ret != ACL_SUCCESS || npu_active_meter_start_event == NULL) {
      log_warn("Failed to create NPU active meter start event: %d", ret);
      npu_active_meter_start_event = NULL;
      return 0;
    }
  }
  if (npu_active_meter_end_event == NULL) {
    ret = real_aclrtCreateEvent(&npu_active_meter_end_event);
    if (ret != ACL_SUCCESS || npu_active_meter_end_event == NULL) {
      log_warn("Failed to create NPU active meter end event: %d", ret);
      if (npu_active_meter_start_event != NULL && real_aclrtDestroyEvent != NULL) {
        (void)real_aclrtDestroyEvent(npu_active_meter_start_event);
      }
      npu_active_meter_start_event = NULL;
      npu_active_meter_end_event = NULL;
      return 0;
    }
  }

  return 1;
}

static void npu_active_meter_on_launch(aclrtStream stream, const char* api_name) {
  uint64_t now_ms;
  int interval_ms;
  aclError ret;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;
  if (!get_npu_active_meter_enabled()) return;
  if (!npu_active_meter_event_available()) return;

  interval_ms = get_npu_active_meter_interval_ms();
  if (interval_ms <= 0) return;

  true_or_exit(pthread_mutex_lock(&npu_active_meter_mutex) == 0);

  if (!npu_active_meter_init_locked()) {
    true_or_exit(pthread_mutex_unlock(&npu_active_meter_mutex) == 0);
    return;
  }

  npu_active_meter_try_collect_locked();
  now_ms = monotonic_time_ms_u64();

  if (!npu_active_meter_window_open && !npu_active_meter_end_pending) {
    ret = real_aclrtRecordEvent(npu_active_meter_start_event, stream);
    if (ret == ACL_SUCCESS) {
      npu_active_meter_seen_launch = 1;
      npu_active_meter_window_open = 1;
      npu_active_meter_last_split_ms = now_ms;
    } else {
      log_debug("NPU active meter start record failed (%s): %d",
                api_name ? api_name : "unknown", ret);
    }
  } else if (npu_active_meter_window_open && !npu_active_meter_end_pending &&
             now_ms >=
                 npu_active_meter_last_split_ms + (uint64_t)interval_ms) {
    ret = real_aclrtRecordEvent(npu_active_meter_end_event, stream);
    if (ret == ACL_SUCCESS) {
      npu_active_meter_seen_launch = 1;
      npu_active_meter_end_pending = 1;
      npu_active_meter_last_split_ms = now_ms;
    } else {
      log_debug("NPU active meter end record failed (%s): %d",
                api_name ? api_name : "unknown", ret);
    }
  }

  true_or_exit(pthread_mutex_unlock(&npu_active_meter_mutex) == 0);
}

/*
 * Fallback active-time source for runtime paths where kernel-launch hooks are
 * not observable (some CANN stacks). Only used before any launch-based event
 * has been observed to avoid double counting.
 */
static void npu_active_meter_on_sync(long elapsed_ms, const char* api_name) {
  uint64_t delta;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;
  if (!get_npu_active_meter_enabled()) return;
  if (elapsed_ms <= 0) return;

  true_or_exit(pthread_mutex_lock(&npu_active_meter_mutex) == 0);
  if (!npu_active_meter_seen_launch) {
    delta = (uint64_t)elapsed_ms;
    if (UINT64_MAX - npu_active_meter_pending_delta_ms < delta) {
      npu_active_meter_pending_delta_ms = UINT64_MAX;
    } else {
      npu_active_meter_pending_delta_ms += delta;
    }
    log_debug("%s: active-meter sync fallback +%ld ms",
              api_name ? api_name : "unknown", elapsed_ms);
  }
  true_or_exit(pthread_mutex_unlock(&npu_active_meter_mutex) == 0);
}

uint32_t nvshare_get_npu_capability_flags(void) {
  uint32_t flags = 0;

  if (real_aclrtGetDeviceResLimit != NULL && real_aclrtSetDeviceResLimit != NULL) {
    flags |= NVSHARE_CAP_DEVICE_RESLIMIT;
  }
  if (real_aclrtSetStreamResLimit != NULL) {
    flags |= NVSHARE_CAP_STREAM_RESLIMIT;
  }
  if (real_aclrtUseStreamResInCurrentThread != NULL) {
    flags |= NVSHARE_CAP_STREAM_THREAD_BIND;
  }
  if (get_npu_active_meter_enabled() && npu_active_meter_event_available()) {
    flags |= NVSHARE_CAP_ACTIVE_METER_EVENT;
  }

  return flags;
}

uint64_t nvshare_collect_npu_active_time_delta_ms(void) {
  uint64_t delta = 0;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return 0;
  if (!get_npu_active_meter_enabled()) return 0;

  true_or_exit(pthread_mutex_lock(&npu_active_meter_mutex) == 0);
  npu_active_meter_try_collect_locked();
  delta = npu_active_meter_pending_delta_ms;
  npu_active_meter_pending_delta_ms = 0;
  true_or_exit(pthread_mutex_unlock(&npu_active_meter_mutex) == 0);

  return delta;
}

/*
 * CUDA hot wrappers are called at very high frequency (kernel/memcpy paths).
 * Keep their steady-state overhead minimal by avoiding repeated pthread_once().
 */
static inline void ensure_cuda_client_initialized(const char* trigger) {
  int backend_mode = __atomic_load_n(&nvshare_backend_mode, __ATOMIC_ACQUIRE);

  if (__builtin_expect(backend_mode != NVSHARE_BACKEND_CUDA, 0)) {
    maybe_select_backend(NVSHARE_BACKEND_CUDA, trigger);
  }

  if (__builtin_expect(__atomic_load_n(&cuda_client_initialized,
                                       __ATOMIC_RELAXED),
                       1)) {
    return;
  }

  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  __atomic_store_n(&cuda_client_initialized, 1, __ATOMIC_RELEASE);
}

/* Load real CUDA {Driver API, NVML} functions and bootstrap auxiliary stuff. */
static void bootstrap_cuda(void) {
  char* error;
  void* cuda_handle;
  void* nvml_handle;

  if (cuda_bootstrapped) return;
  cuda_bootstrapped = 1;

  true_or_exit(pthread_mutex_init(&kcount_mutex, NULL) == 0);

  nvml_handle = dlopen("libnvidia-ml.so.1", RTLD_LAZY);
  if (!nvml_handle) {
    error = dlerror();
    if (error != NULL) log_debug("%s", error);
    nvml_ok = 0;
  } else {
    dlerror();
    real_nvmlDeviceGetUtilizationRates =
        (nvmlDeviceGetUtilizationRates_func)real_dlsym_225(
            nvml_handle, CUDA_SYMBOL_STRING(nvmlDeviceGetUtilizationRates));
    error = dlerror();
    if (error != NULL) {
      log_debug("%s", error);
      nvml_ok = 0;
    }
    real_nvmlInit = (nvmlInit_func)real_dlsym_225(nvml_handle,
                                                  CUDA_SYMBOL_STRING(nvmlInit));
    error = dlerror();
    if (error != NULL) {
      log_debug("Failed to find %s, falling back to nvmlInit",
                CUDA_SYMBOL_STRING(nvmlInit));
      real_nvmlInit = (nvmlInit_func)real_dlsym_225(nvml_handle, "nvmlInit");
      error = dlerror();
    }
    if (error != NULL) {
      log_debug("%s", error);
      nvml_ok = 0;
    }
    real_nvmlDeviceGetHandleByIndex =
        (nvmlDeviceGetHandleByIndex_func)real_dlsym_225(
            nvml_handle, CUDA_SYMBOL_STRING(nvmlDeviceGetHandleByIndex));
    error = dlerror();
    if (error != NULL) {
      log_debug("Failed to find %s, falling back to nvmlDeviceGetHandleByIndex",
                CUDA_SYMBOL_STRING(nvmlDeviceGetHandleByIndex));
      real_nvmlDeviceGetHandleByIndex =
          (nvmlDeviceGetHandleByIndex_func)real_dlsym_225(
              nvml_handle, "nvmlDeviceGetHandleByIndex");
      error = dlerror();
    }
    if (error != NULL) {
      log_debug("%s", error);
      nvml_ok = 0;
    }
    real_nvmlDeviceGetHandleByUUID =
        (nvmlDeviceGetHandleByUUID_func)real_dlsym_225(
            nvml_handle, CUDA_SYMBOL_STRING(nvmlDeviceGetHandleByUUID));
    error = dlerror();
    if (error != NULL) {
      log_debug("Failed to find %s, falling back to nvmlDeviceGetHandleByUUID",
                CUDA_SYMBOL_STRING(nvmlDeviceGetHandleByUUID));
      real_nvmlDeviceGetHandleByUUID =
          (nvmlDeviceGetHandleByUUID_func)real_dlsym_225(
              nvml_handle, "nvmlDeviceGetHandleByUUID");
      error = dlerror();
    }
    if (error != NULL) {
      log_debug("%s", error);
      nvml_ok = 0;
    }
  }

  if (nvml_ok)
    log_debug("Found NVML");
  else
    log_debug("Could not find NVML");

  cuda_handle = dlopen("libcuda.so.1", RTLD_LAZY);
  if (!cuda_handle) cuda_handle = dlopen("libcuda.so", RTLD_LAZY);
  if (!cuda_handle) {
    error = dlerror();
    if (error != NULL) log_debug("CUDA driver not available: %s", error);
    return;
  }

  dlerror();
  real_cuMemAllocManaged = (cuMemAllocManaged_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemAllocManaged));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemFree = (cuMemFree_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemFree));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuGetProcAddress = (cuGetProcAddress_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuGetProcAddress));
  error = dlerror();
  if (error != NULL) log_debug("%s", error);
  real_cuGetProcAddress_v2 = (cuGetProcAddress_v2_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuGetProcAddress_v2));
  error = dlerror();
  if (error != NULL) log_debug("%s", error);
  real_cuMemGetInfo = (cuMemGetInfo_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemGetInfo));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuGetErrorString = (cuGetErrorString_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuGetErrorString));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuGetErrorName = (cuGetErrorString_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuGetErrorName));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuCtxSetCurrent = (cuCtxSetCurrent_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuCtxSetCurrent));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuCtxGetCurrent = (cuCtxGetCurrent_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuCtxGetCurrent));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuInit =
      (cuInit_func)real_dlsym_225(cuda_handle, CUDA_SYMBOL_STRING(cuInit));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuCtxSynchronize = (cuCtxSynchronize_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuCtxSynchronize));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemAdvise = (cuMemAdvise_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemAdvise));
  error = dlerror();
  if (error != NULL) {
    log_debug("cuMemAdvise not available: %s", error);
    real_cuMemAdvise = NULL;
  }
  real_cuLaunchKernel = (cuLaunchKernel_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuLaunchKernel));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpy =
      (cuMemcpy_func)real_dlsym_225(cuda_handle, CUDA_SYMBOL_STRING(cuMemcpy));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyAsync = (cuMemcpyAsync_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyAsync));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyDtoH = (cuMemcpyDtoH_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyDtoH));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyDtoHAsync = (cuMemcpyDtoHAsync_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyDtoHAsync));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyHtoD = (cuMemcpyHtoD_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyHtoD));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyHtoDAsync = (cuMemcpyHtoDAsync_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyHtoDAsync));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyDtoD = (cuMemcpyDtoD_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyDtoD));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
  real_cuMemcpyDtoDAsync = (cuMemcpyDtoDAsync_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuMemcpyDtoDAsync));
  error = dlerror();
  if (error != NULL) log_fatal("%s", error);
}

static void bootstrap_acl(void) {
  char* error;
  void* acl_handle;

  if (acl_bootstrapped) return;
  acl_bootstrapped = 1;
  acl_ok = 0;

  acl_handle = dlopen("libascendcl.so", RTLD_LAZY);
  if (!acl_handle) {
    acl_handle = dlopen("libascendcl.so.1", RTLD_LAZY);
  }
  if (!acl_handle) {
    error = dlerror();
    if (error != NULL) log_debug("ACL runtime not available: %s", error);
    return;
  }

#define LOAD_ACL_SYM(name)                                                  \
  do {                                                                      \
    dlerror();                                                              \
    real_##name = (name##_func)real_dlsym_225(acl_handle, #name);          \
    error = dlerror();                                                      \
    if (error != NULL) {                                                    \
      log_debug("Failed to load ACL symbol %s: %s", #name, error);         \
      real_##name = NULL;                                                   \
    }                                                                       \
  } while (0)

  LOAD_ACL_SYM(aclInit);
  LOAD_ACL_SYM(aclrtMalloc);
  LOAD_ACL_SYM(aclrtMallocAlign32);
  LOAD_ACL_SYM(aclrtMallocCached);
  LOAD_ACL_SYM(aclrtMallocWithCfg);
  LOAD_ACL_SYM(aclrtFree);
  LOAD_ACL_SYM(aclrtGetMemInfo);
  LOAD_ACL_SYM(aclrtCreateEvent);
  LOAD_ACL_SYM(aclrtDestroyEvent);
  LOAD_ACL_SYM(aclrtRecordEvent);
  LOAD_ACL_SYM(aclrtQueryEventStatus);
  LOAD_ACL_SYM(aclrtEventElapsedTime);
  LOAD_ACL_SYM(aclrtGetDeviceCount);
  LOAD_ACL_SYM(aclrtLaunchKernel);
  LOAD_ACL_SYM(aclrtLaunchKernelWithConfig);
  LOAD_ACL_SYM(aclrtLaunchKernelV2);
  LOAD_ACL_SYM(aclrtLaunchKernelWithHostArgs);
  LOAD_ACL_SYM(aclrtMemcpy);
  LOAD_ACL_SYM(aclrtMemcpyAsync);
  LOAD_ACL_SYM(aclrtSynchronizeDevice);
  LOAD_ACL_SYM(aclrtSynchronizeStream);
  LOAD_ACL_SYM(aclrtSetDevice);
  LOAD_ACL_SYM(aclrtGetDevice);
  LOAD_ACL_SYM(aclrtSetCurrentContext);
  LOAD_ACL_SYM(aclrtGetCurrentContext);
  LOAD_ACL_SYM(aclrtGetDeviceResLimit);
  LOAD_ACL_SYM(aclrtSetDeviceResLimit);
  LOAD_ACL_SYM(aclrtGetStreamResLimit);
  LOAD_ACL_SYM(aclrtSetStreamResLimit);
  LOAD_ACL_SYM(aclrtUseStreamResInCurrentThread);
  LOAD_ACL_SYM(aclopExecute);
  LOAD_ACL_SYM(aclopExecuteV2);
  LOAD_ACL_SYM(aclopExecWithHandle);
  LOAD_ACL_SYM(aclmdlExecute);
  LOAD_ACL_SYM(aclmdlExecuteV2);
  LOAD_ACL_SYM(aclmdlExecuteAsync);
  LOAD_ACL_SYM(aclmdlExecuteAsyncV2);

#undef LOAD_ACL_SYM

#define LOAD_RT_NEXT_SYM(name)                                              \
  do {                                                                      \
    dlerror();                                                              \
    real_##name = (name##_func)real_dlsym_225(RTLD_NEXT, #name);           \
    error = dlerror();                                                      \
    if (error != NULL) {                                                    \
      real_##name = NULL;                                                   \
    }                                                                       \
  } while (0)

  LOAD_RT_NEXT_SYM(rtKernelLaunch);
  LOAD_RT_NEXT_SYM(rtKernelLaunchWithFlag);
  LOAD_RT_NEXT_SYM(rtKernelLaunchWithFlagV2);
  LOAD_RT_NEXT_SYM(rtKernelLaunchEx);
  LOAD_RT_NEXT_SYM(rtDeviceSynchronize);
  LOAD_RT_NEXT_SYM(rtDeviceSynchronizeWithTimeout);
  LOAD_RT_NEXT_SYM(rtStreamSynchronize);
  LOAD_RT_NEXT_SYM(rtStreamSynchronizeWithTimeout);
  LOAD_RT_NEXT_SYM(rtLaunchKernelByFuncHandleV3);
  LOAD_RT_NEXT_SYM(rtsLaunchKernelWithConfig);
  LOAD_RT_NEXT_SYM(rtsLaunchKernelWithDevArgs);
  LOAD_RT_NEXT_SYM(rtsLaunchKernelWithHostArgs);
  LOAD_RT_NEXT_SYM(rtVectorCoreKernelLaunch);
  LOAD_RT_NEXT_SYM(rtMemAllocManaged);
  LOAD_RT_NEXT_SYM(rtMemFreeManaged);
  LOAD_RT_NEXT_SYM(rtMemPrefetchToDevice);
  LOAD_RT_NEXT_SYM(rtMemAdvise);

#undef LOAD_RT_NEXT_SYM

  if (real_rtMemAllocManaged == NULL || real_rtMemFreeManaged == NULL ||
      real_rtMemPrefetchToDevice == NULL || real_rtMemAdvise == NULL) {
    static const char* runtime_candidates[] = {
        "libruntime.so",
        "libruntime.so.1",
        "/usr/local/Ascend/ascend-toolkit/latest/lib64/libruntime.so",
        "/usr/local/Ascend/ascend-toolkit/latest/lib64/libruntime.so.1",
    };
    size_t i;

    if (npu_runtime_handle == NULL) {
      for (i = 0; i < sizeof(runtime_candidates) / sizeof(runtime_candidates[0]);
           ++i) {
        npu_runtime_handle = dlopen(runtime_candidates[i], RTLD_LAZY | RTLD_GLOBAL);
        if (npu_runtime_handle != NULL) {
          log_debug("Loaded NPU runtime library for managed symbols: %s",
                    runtime_candidates[i]);
          break;
        }
      }
    }

    if (npu_runtime_handle != NULL) {
#define LOAD_RT_HANDLE_SYM(name)                                            \
  do {                                                                      \
    if (real_##name == NULL) {                                              \
      dlerror();                                                            \
      real_##name = (name##_func)real_dlsym_225(npu_runtime_handle, #name); \
      error = dlerror();                                                    \
      if (error != NULL) real_##name = NULL;                               \
    }                                                                       \
  } while (0)

      LOAD_RT_HANDLE_SYM(rtMemAllocManaged);
      LOAD_RT_HANDLE_SYM(rtMemFreeManaged);
      LOAD_RT_HANDLE_SYM(rtMemPrefetchToDevice);
      LOAD_RT_HANDLE_SYM(rtMemAdvise);

#undef LOAD_RT_HANDLE_SYM
    }
  }

  if (real_aclrtMalloc && real_aclrtFree && real_aclrtGetMemInfo &&
      real_aclrtLaunchKernel) {
    acl_ok = 1;
    log_info("ACL runtime hook initialized");
  } else {
    log_warn("ACL runtime hook partially initialized, some symbols missing");
  }
}

static uint32_t scale_npu_res_limit(uint32_t max_limit, int percent) {
  uint64_t scaled;

  if (max_limit == 0) return 0;
  if (percent <= 0) return 1;
  if (percent >= 100) return max_limit;

  scaled = ((uint64_t)max_limit * (uint64_t)percent) / 100ULL;
  if (scaled == 0) scaled = 1;
  if (scaled > max_limit) scaled = max_limit;
  return (uint32_t)scaled;
}

static int parse_first_visible_npu_device(const char* raw, int32_t* device_id) {
  const char* p = raw;
  char* end = NULL;
  long v;

  if (raw == NULL || device_id == NULL) return 0;

  while (*p == ' ' || *p == '\t' || *p == '\n') p++;
  if (*p == '\0') return 0;

  v = strtol(p, &end, 10);
  if (end == p) return 0;
  if (v < 0 || v > INT32_MAX) return 0;

  while (*end == ' ' || *end == '\t') end++;
  if (*end != '\0' && *end != ',' && *end != ';') return 0;

  *device_id = (int32_t)v;
  return 1;
}

static int count_visible_npu_devices(const char* raw, uint32_t* count_out) {
  const char* p = raw;
  uint32_t count = 0;

  if (raw == NULL || count_out == NULL) return 0;

  while (*p != '\0') {
    char* end = NULL;
    long v;

    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == ',') p++;
    if (*p == '\0') break;

    v = strtol(p, &end, 10);
    if (end == p || v < 0 || v > INT32_MAX) return 0;
    count++;
    p = end;

    while (*p == ' ' || *p == '\t') p++;
    if (*p == '\0') break;
    if (*p != ',') return 0;
  }

  if (count == 0) return 0;
  *count_out = count;
  return 1;
}

static void cache_npu_thread_binding(int32_t device_id) {
  aclrtContext ctx = NULL;

  if (real_aclrtGetCurrentContext != NULL) {
    aclError ret = real_aclrtGetCurrentContext(&ctx);
    if (ret != ACL_SUCCESS || ctx == NULL) {
      ctx = NULL;
    }
  }

  true_or_exit(pthread_mutex_lock(&npu_context_mutex) == 0);
  npu_context_cached_device = device_id;
  if (ctx != NULL) npu_context_cached_ctx = ctx;
  true_or_exit(pthread_mutex_unlock(&npu_context_mutex) == 0);
}

static int is_npu_aclinit_transient_error(aclError ret) {
  return ((int)ret == NPU_ACLINIT_TRANSIENT_ERR_A ||
          (int)ret == NPU_ACLINIT_TRANSIENT_ERR_B ||
          (int)ret == ACL_ERROR_RT_CONTEXT_NULL);
}

static aclError call_real_aclinit_with_retry(const char* configPath) {
  aclError ret = ACL_SUCCESS;
  int attempt;

  if (real_aclInit == NULL) return ACL_ERROR_UNINITIALIZE;

  ret = real_aclInit(configPath);
  if (ret == ACL_SUCCESS) return ret;
  if (!is_npu_aclinit_transient_error(ret)) return ret;

  for (attempt = 1; attempt <= NPU_ACLINIT_RETRY_TIMES; ++attempt) {
    usleep(NPU_ACLINIT_RETRY_SLEEP_US * attempt);
    ret = real_aclInit(configPath);
    if (ret == ACL_SUCCESS) {
      log_warn("aclInit recovered after %d retries", attempt);
      return ret;
    }
    if (!is_npu_aclinit_transient_error(ret)) return ret;
  }

  log_warn("aclInit failed after retries, ret=%d", (int)ret);
  return ret;
}

static int npu_init_gate_peek_deferred(void) {
  int deferred;
  true_or_exit(pthread_mutex_lock(&npu_init_gate_state_mutex) == 0);
  deferred = npu_init_gate_deferred;
  true_or_exit(pthread_mutex_unlock(&npu_init_gate_state_mutex) == 0);
  return deferred;
}

static void npu_init_gate_mark_deferred(void) {
  true_or_exit(pthread_mutex_lock(&npu_init_gate_state_mutex) == 0);
  npu_init_gate_deferred = 1;
  true_or_exit(pthread_mutex_unlock(&npu_init_gate_state_mutex) == 0);
}

static int npu_init_gate_take_deferred(void) {
  int deferred = 0;
  true_or_exit(pthread_mutex_lock(&npu_init_gate_state_mutex) == 0);
  if (npu_init_gate_deferred) {
    deferred = 1;
    npu_init_gate_deferred = 0;
  }
  true_or_exit(pthread_mutex_unlock(&npu_init_gate_state_mutex) == 0);
  return deferred;
}

static void npu_init_gate_mark_post_setdevice_pending(void) {
  true_or_exit(pthread_mutex_lock(&npu_init_gate_state_mutex) == 0);
  npu_init_gate_post_setdevice_pending = 1;
  true_or_exit(pthread_mutex_unlock(&npu_init_gate_state_mutex) == 0);
}

static int npu_init_gate_take_post_setdevice_pending(void) {
  int pending = 0;
  true_or_exit(pthread_mutex_lock(&npu_init_gate_state_mutex) == 0);
  if (npu_init_gate_post_setdevice_pending) {
    pending = 1;
    npu_init_gate_post_setdevice_pending = 0;
  }
  true_or_exit(pthread_mutex_unlock(&npu_init_gate_state_mutex) == 0);
  return pending;
}

static void npu_init_gate_maybe_finish_post_setdevice(const char* reason) {
  if (npu_init_gate_take_post_setdevice_pending()) {
    log_debug("Completing deferred NPU init gate after %s",
              reason ? reason : "post-setdevice-api");
    end_npu_init_gate(1, ACL_SUCCESS);
  }
}

int nvshare_prepare_npu_sync_context(void) {
  int32_t cached_device = -1;
  aclrtContext cached_ctx = NULL;
  aclError ret = ACL_ERROR_RT_CONTEXT_NULL;
  int32_t env_device = -1;
  const char* env = NULL;

  if (real_aclrtGetCurrentContext != NULL) {
    aclrtContext current_ctx = NULL;
    ret = real_aclrtGetCurrentContext(&current_ctx);
    if (ret == ACL_SUCCESS && current_ctx != NULL) return ACL_SUCCESS;
  }

  true_or_exit(pthread_mutex_lock(&npu_context_mutex) == 0);
  cached_device = npu_context_cached_device;
  cached_ctx = npu_context_cached_ctx;
  true_or_exit(pthread_mutex_unlock(&npu_context_mutex) == 0);

  if (cached_ctx != NULL && real_aclrtSetCurrentContext != NULL) {
    ret = real_aclrtSetCurrentContext(cached_ctx);
    if (ret == ACL_SUCCESS) return ACL_SUCCESS;
  }

  if (cached_device >= 0 && real_aclrtSetDevice != NULL) {
    ret = real_aclrtSetDevice(cached_device);
    if (ret == ACL_SUCCESS) return ACL_SUCCESS;
  }

  if (real_aclrtSetDevice == NULL) return ret;

  env = getenv("ASCEND_RT_VISIBLE_DEVICES");
  if (parse_first_visible_npu_device(env, &env_device)) {
    ret = real_aclrtSetDevice(env_device);
    if (ret == ACL_SUCCESS) return ACL_SUCCESS;
  }

  env = getenv("ASCEND_VISIBLE_DEVICES");
  if (parse_first_visible_npu_device(env, &env_device)) {
    ret = real_aclrtSetDevice(env_device);
    if (ret == ACL_SUCCESS) return ACL_SUCCESS;
  }

  return ret;
}

/*
 * Apply CANN native process-level core limit.
 *
 * This is a fallback for workloads that bypass aclrtLaunchKernel-style hooks
 * (e.g., some torch_npu/aclnn paths). It keeps single-process core quota
 * effective even when lock-based throttling is not continuously exercised.
 */
void nvshare_apply_npu_core_limit(void) {
  int percent;
  int32_t device_id;
  aclError ret;
  uint32_t cube_target = 0;
  uint32_t vector_target = 0;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;
  if (real_aclrtGetDevice == NULL || real_aclrtGetDeviceResLimit == NULL ||
      real_aclrtSetDeviceResLimit == NULL) {
    return;
  }

  percent = client_core_limit;
  if (percent < 1 || percent > 100) return;

  ret = real_aclrtGetDevice(&device_id);
  if (ret != ACL_SUCCESS) return;
  cache_npu_thread_binding(device_id);

  true_or_exit(pthread_mutex_lock(&npu_reslimit_mutex) == 0);

  if (npu_reslimit_cached_device != device_id || npu_reslimit_cube_max == 0 ||
      npu_reslimit_vector_max == 0) {
    uint32_t tmp = 0;

    npu_reslimit_cached_device = device_id;
    npu_reslimit_last_percent = -1;

    if (real_aclrtGetDeviceResLimit(device_id, ACL_RT_DEV_RES_CUBE_CORE, &tmp) ==
        ACL_SUCCESS) {
      npu_reslimit_cube_max = tmp;
    } else {
      npu_reslimit_cube_max = 0;
    }

    tmp = 0;
    if (real_aclrtGetDeviceResLimit(device_id, ACL_RT_DEV_RES_VECTOR_CORE,
                                    &tmp) == ACL_SUCCESS) {
      npu_reslimit_vector_max = tmp;
    } else {
      npu_reslimit_vector_max = 0;
    }
  }

  if (npu_reslimit_last_percent == percent) {
    true_or_exit(pthread_mutex_unlock(&npu_reslimit_mutex) == 0);
    return;
  }

  /*
   * Keep startup behavior identical to native when quota is 100%.
   * Some CANN 8.2 stacks show unstable first-sync behavior after an explicit
   * "set max resource limit" during initial bootstrap. We therefore avoid the
   * first no-op write (100% -> max) and only record cache state. If runtime
   * quota was previously reduced, a later transition back to 100% still
   * performs an explicit restore to max.
   */
  if (percent == 100 && npu_reslimit_last_percent < 0) {
    npu_reslimit_last_percent = percent;
    log_debug("Skip initial NPU core limit apply at 100%% (device=%d)",
              device_id);
    true_or_exit(pthread_mutex_unlock(&npu_reslimit_mutex) == 0);
    return;
  }

  cube_target = scale_npu_res_limit(npu_reslimit_cube_max, percent);
  vector_target = scale_npu_res_limit(npu_reslimit_vector_max, percent);

  if (cube_target > 0) {
    ret = real_aclrtSetDeviceResLimit(device_id, ACL_RT_DEV_RES_CUBE_CORE,
                                      cube_target);
    if (ret != ACL_SUCCESS) {
      log_warn("aclrtSetDeviceResLimit(CUBE_CORE=%u) failed with %d",
               cube_target, ret);
    }
  }

  if (vector_target > 0) {
    ret = real_aclrtSetDeviceResLimit(device_id, ACL_RT_DEV_RES_VECTOR_CORE,
                                      vector_target);
    if (ret != ACL_SUCCESS) {
      log_warn("aclrtSetDeviceResLimit(VECTOR_CORE=%u) failed with %d",
               vector_target, ret);
    }
  }

  npu_reslimit_last_percent = percent;
  log_info(
      "Applied NPU core limit=%d%% (device=%d, cube=%u/%u, vector=%u/%u)",
      percent, device_id, cube_target, npu_reslimit_cube_max, vector_target,
      npu_reslimit_vector_max);

  true_or_exit(pthread_mutex_unlock(&npu_reslimit_mutex) == 0);
}

/*
 * Apply stream-level core limit when stream handle is available.
 *
 * According to CANN docs, stream limit requires:
 * 1) aclrtSetStreamResLimit(stream, ...)
 * 2) aclrtUseStreamResInCurrentThread(stream)
 *
 * We still keep process-level device limit as a fallback.
 */
void nvshare_apply_npu_core_limit_for_stream(aclrtStream stream,
                                             const char* api_name) {
  int percent;
  uint32_t cube_max = 0;
  uint32_t vector_max = 0;
  uint32_t cube_target = 0;
  uint32_t vector_target = 0;
  aclError ret;
  int ok = 1;

  if (nvshare_backend_mode != NVSHARE_BACKEND_NPU) return;

  /* Always refresh device-level fallback first. */
  nvshare_apply_npu_core_limit();

  if (stream == NULL) return;
  if (real_aclrtSetStreamResLimit == NULL ||
      real_aclrtUseStreamResInCurrentThread == NULL) {
    return;
  }

  percent = client_core_limit;
  if (percent < 1 || percent > 100) return;

  if (npu_stream_reslimit_last_stream == stream &&
      npu_stream_reslimit_last_percent == percent) {
    return;
  }

  true_or_exit(pthread_mutex_lock(&npu_reslimit_mutex) == 0);
  cube_max = npu_reslimit_cube_max;
  vector_max = npu_reslimit_vector_max;
  true_or_exit(pthread_mutex_unlock(&npu_reslimit_mutex) == 0);

  cube_target = scale_npu_res_limit(cube_max, percent);
  vector_target = scale_npu_res_limit(vector_max, percent);

  if (cube_target > 0) {
    ret = real_aclrtSetStreamResLimit(stream, ACL_RT_DEV_RES_CUBE_CORE,
                                      cube_target);
    if (ret != ACL_SUCCESS) {
      ok = 0;
      log_warn(
          "aclrtSetStreamResLimit(CUBE_CORE=%u) failed with %d (api=%s)",
          cube_target, ret, api_name ? api_name : "unknown");
    }
  }
  if (vector_target > 0) {
    ret = real_aclrtSetStreamResLimit(stream, ACL_RT_DEV_RES_VECTOR_CORE,
                                      vector_target);
    if (ret != ACL_SUCCESS) {
      ok = 0;
      log_warn(
          "aclrtSetStreamResLimit(VECTOR_CORE=%u) failed with %d (api=%s)",
          vector_target, ret, api_name ? api_name : "unknown");
    }
  }

  ret = real_aclrtUseStreamResInCurrentThread(stream);
  if (ret != ACL_SUCCESS) {
    ok = 0;
    log_warn("aclrtUseStreamResInCurrentThread failed with %d (api=%s)", ret,
             api_name ? api_name : "unknown");
  }

  if (ok) {
    npu_stream_reslimit_last_stream = stream;
    npu_stream_reslimit_last_percent = percent;
    log_debug("Applied NPU stream core limit=%d%% (api=%s)", percent,
              api_name ? api_name : "unknown");
  }
}

/* Append a new CUDA memory allocation at the end of the list. */
static void insert_cuda_allocation(CUdeviceptr dptr, size_t bytesize) {
  struct cuda_mem_allocation* allocation;

  sum_allocated += bytesize;
  log_debug("Total allocated memory on GPU is %.2f MiB", toMiB(sum_allocated));

  true_or_exit(allocation = malloc(sizeof(*allocation)));

  allocation->ptr = dptr;
  allocation->size = bytesize;
  allocation->next = NULL;
  LL_APPEND(cuda_allocation_list, allocation);

  /* Report memory usage to scheduler for memory-aware scheduling */
  report_memory_usage_to_scheduler(sum_allocated);
}

/* Remove a CUDA memory allocation given the pointer it starts at */
static void remove_cuda_allocation(CUdeviceptr rm_ptr) {
  struct cuda_mem_allocation *tmp, *a;

  LL_FOREACH_SAFE(cuda_allocation_list, a, tmp) {
    if (a->ptr == rm_ptr) {
      sum_allocated -= a->size;
      log_debug("Total allocated memory on GPU is %.2f MiB",
                toMiB(sum_allocated));
      LL_DELETE(cuda_allocation_list, a);
      free(a);

      /* Report memory usage to scheduler for memory-aware scheduling */
      report_memory_usage_to_scheduler(sum_allocated);
    }
  }
}

static int check_allocation_limit(size_t bytesize, const char* api_name,
                                  int* out_exceeds_physical,
                                  size_t physical_allocatable) {
  if (memory_limit > 0 && (sum_allocated + bytesize) > memory_limit) {
    log_warn(
        "%s rejected: %zu + %zu = %zu would exceed limit %zu bytes (%.2f MiB)",
        api_name, sum_allocated, bytesize, sum_allocated + bytesize,
        memory_limit, (double)memory_limit / (1024.0 * 1024.0));
    return 0;
  }

  *out_exceeds_physical = 0;
  if (physical_allocatable > 0 && (sum_allocated + bytesize) > physical_allocatable) {
    if (enable_single_oversub == 0) {
      log_warn("%s rejected: %zu + %zu exceeds physical allocatable %zu bytes",
               api_name, sum_allocated, bytesize, physical_allocatable);
      return 0;
    }
    *out_exceeds_physical = 1;
  }
  return 1;
}

static void report_npu_usage_to_scheduler(void) {
  report_npu_memory_stats_to_scheduler(
      sum_allocated, sum_npu_managed_allocated, sum_npu_native_allocated,
      npu_fallback_counter(NPU_FALLBACK_SYMBOL_UNAVAILABLE),
      npu_fallback_counter(NPU_FALLBACK_ALIGN_OVERFLOW),
      npu_fallback_counter(NPU_FALLBACK_ALLOC_FAILED),
      npu_fallback_counter(NPU_FALLBACK_CFG_NONNULL),
      __sync_add_and_fetch(&npu_prefetch_ok_total, 0),
      __sync_add_and_fetch(&npu_prefetch_fail_total, 0));
}

/* Append a new ACL/NPU memory allocation at the end of the list. */
static void insert_npu_allocation(void* ptr, size_t requested_size,
                                  size_t effective_size, int alloc_mode) {
  struct npu_mem_allocation* allocation;

  sum_allocated += requested_size;
  if (alloc_mode == NPU_ALLOC_MODE_RT_MANAGED) {
    sum_npu_managed_allocated += requested_size;
  } else {
    sum_npu_native_allocated += requested_size;
  }
  log_debug("Total allocated memory on NPU is %.2f MiB", toMiB(sum_allocated));

  true_or_exit(allocation = malloc(sizeof(*allocation)));
  allocation->ptr = ptr;
  allocation->size = requested_size;
  allocation->requested_size = requested_size;
  allocation->effective_size = effective_size;
  allocation->alloc_ts_ms = monotonic_time_ms_u64();
  allocation->alloc_mode = alloc_mode;
  allocation->next = NULL;
  LL_APPEND(npu_allocation_list, allocation);

  report_npu_usage_to_scheduler();
}

static int find_npu_allocation_mode(void* ptr, int* alloc_mode_out) {
  struct npu_mem_allocation* a;

  if (alloc_mode_out == NULL) return 0;

  LL_FOREACH(npu_allocation_list, a) {
    if (a->ptr == ptr) {
      *alloc_mode_out = a->alloc_mode;
      return 1;
    }
  }
  return 0;
}

/* Remove an ACL/NPU memory allocation given the pointer it starts at. */
static void remove_npu_allocation(void* rm_ptr) {
  struct npu_mem_allocation *tmp, *a;

  LL_FOREACH_SAFE(npu_allocation_list, a, tmp) {
    if (a->ptr == rm_ptr) {
      sum_allocated -= a->size;
      if (a->alloc_mode == NPU_ALLOC_MODE_RT_MANAGED) {
        if (sum_npu_managed_allocated >= a->size) {
          sum_npu_managed_allocated -= a->size;
        } else {
          sum_npu_managed_allocated = 0;
        }
      } else {
        if (sum_npu_native_allocated >= a->size) {
          sum_npu_native_allocated -= a->size;
        } else {
          sum_npu_native_allocated = 0;
        }
      }
      log_debug("Total allocated memory on NPU is %.2f MiB",
                toMiB(sum_allocated));
      LL_DELETE(npu_allocation_list, a);
      free(a);
      report_npu_usage_to_scheduler();
      break;
    }
  }
}

/*
 * Hint driver to evict all allocations to Host memory before context switch.
 * This is called when receiving PREPARE_SWAP_OUT from scheduler.
 * The goal is to reduce page faults when the next task starts.
 */
void swap_out_all_allocations(void) {
  struct cuda_mem_allocation* a;
  size_t total_evicted = 0;
  int count = 0;

  if (nvshare_backend_mode != NVSHARE_BACKEND_CUDA) {
    log_debug("swap_out_all_allocations: no-op for backend=%s",
              nvshare_backend_mode_name(nvshare_backend_mode));
    return;
  }

  if (real_cuMemAdvise == NULL) {
    log_debug("cuMemAdvise not available, skipping swap-out hints");
    return;
  }

  /* Set CUDA context for this thread - required for cuMemAdvise */
  if (cuda_ctx != NULL && real_cuCtxSetCurrent != NULL) {
    CUresult ctx_res = real_cuCtxSetCurrent(cuda_ctx);
    if (ctx_res != CUDA_SUCCESS) {
      log_debug("Failed to set CUDA context for swap-out: %d", (int)ctx_res);
      return;
    }
  }

  log_info("Hinting driver to evict memory to Host (preparing for swap-out)");

  LL_FOREACH(cuda_allocation_list, a) {
    CUresult res = real_cuMemAdvise(
        a->ptr, a->size, CU_MEM_ADVISE_SET_PREFERRED_LOCATION, CU_DEVICE_CPU);
    if (res == CUDA_SUCCESS) {
      total_evicted += a->size;
      count++;
    } else {
      const char* err_name = "UNKNOWN";
      if (real_cuGetErrorName) {
        real_cuGetErrorName(res, &err_name);
      }
      log_debug("cuMemAdvise failed for allocation at %p (size %zu): %s (%d)",
                (void*)a->ptr, a->size, err_name, (int)res);
    }
  }

  /* Synchronize to ensure hints are processed */
  if (count > 0) {
    real_cuCtxSynchronize();
    log_info("Swap-out hints sent for %d allocations (%.2f MB total)", count,
             (double)total_evicted / (1024 * 1024));
  }
}

/*
 * Reset memory preferred location after receiving LOCK_OK.
 * This undoes the SET_PREFERRED_LOCATION CPU hint from swap-out,
 * allowing GPU to keep pages after accessing them.
 */
void swap_in_all_allocations(void) {
  struct cuda_mem_allocation* a;
  int count = 0;

  if (nvshare_backend_mode != NVSHARE_BACKEND_CUDA) return;

  if (real_cuMemAdvise == NULL) {
    return;
  }

  /* Set CUDA context for this thread */
  if (cuda_ctx != NULL && real_cuCtxSetCurrent != NULL) {
    CUresult ctx_res = real_cuCtxSetCurrent(cuda_ctx);
    if (ctx_res != CUDA_SUCCESS) {
      log_debug("Failed to set CUDA context for swap-in: %d", (int)ctx_res);
      return;
    }
  }

  LL_FOREACH(cuda_allocation_list, a) {
    /* Unset preferred location - allows GPU to keep pages after access */
    CUresult res = real_cuMemAdvise(
        a->ptr, a->size, CU_MEM_ADVISE_UNSET_PREFERRED_LOCATION, CU_DEVICE_CPU);
    if (res == CUDA_SUCCESS) {
      count++;
    }
  }

  if (count > 0) {
    log_debug("Reset preferred location for %d allocations", count);
  }
}

/* Parse memory size string with optional Mi/Gi suffix */
static size_t parse_memory_size(const char* str) {
  char* endptr;
  double value = strtod(str, &endptr);
  while (*endptr == ' ') endptr++; /* Skip spaces */

  if (*endptr == 'G' || *endptr == 'g') {
    if (*(endptr + 1) == 'i' || *(endptr + 1) == 'I') {
      value *= 1024 * 1024 * 1024; /* GiB */
    } else {
      value *= 1000 * 1000 * 1000; /* GB */
    }
  } else if (*endptr == 'M' || *endptr == 'm') {
    if (*(endptr + 1) == 'i' || *(endptr + 1) == 'I') {
      value *= 1024 * 1024; /* MiB */
    } else {
      value *= 1000 * 1000; /* MB */
    }
  } else if (*endptr == 'K' || *endptr == 'k') {
    if (*(endptr + 1) == 'i' || *(endptr + 1) == 'I') {
      value *= 1024; /* KiB */
    } else {
      value *= 1000; /* KB */
    }
  }
  /* else: raw bytes */

  return (size_t)value;
}

/* Toggle debug mode and single process oversubscription based on envvars */
static void initialize_libnvshare(void) {
  char* value;
  int i;

  sum_allocated = 0;
  sum_npu_managed_allocated = 0;
  sum_npu_native_allocated = 0;
  npu_prefetch_ok_total = 0;
  npu_prefetch_fail_total = 0;
  npu_prefetch_runtime_disabled = 0;
  npu_active_meter_seen_launch = 0;
  npu_active_meter_pending_delta_ms = 0;
  for (i = 0; i < NPU_FALLBACK_REASON_COUNT; i++) {
    npu_managed_fallback_counters[i] = 0;
  }

  value = getenv(ENV_NVSHARE_DEBUG);
  if (value != NULL) __debug = 1;
  value = getenv(ENV_NVSHARE_ENABLE_SINGLE_OVERSUB);
  if (value != NULL) {
    enable_single_oversub = 1;
    log_warn(
        "Enabling GPU memory oversubscription for this"
        " application");
  }

  /* GPU Memory Limit Configuration */
  value = getenv("NVSHARE_GPU_MEMORY_LIMIT");
  if (value != NULL) {
    memory_limit = parse_memory_size(value);
    log_info("GPU memory limit set to %zu bytes (%.2f GiB)", memory_limit,
             (double)memory_limit / (1024.0 * 1024.0 * 1024.0));
  }

  /* Adaptive Window Configuration */
  value = getenv("NVSHARE_KERN_SYNC_DURATION_BIG");
  if (value) kern_sync_duration_big = atoi(value);

  value = getenv("NVSHARE_KERN_WINDOW_MIN_FLOOR");
  if (value) kern_window_min_floor = atoi(value);

  value = getenv("NVSHARE_KERN_WARMUP_PERIOD_SEC");
  if (value) kern_warmup_period_sec = atoi(value);

  bootstrap_cuda();
  bootstrap_acl();
}

/*
 * Check the return value of a CUDA Driver API function call for errors.
 *
 * Interpret using the Driver API functions:
 * - cuGetErrorString
 * - cuGetErrorName
 */
void cuda_driver_check_error(CUresult err, const char* func_name) {
  if (err != CUDA_SUCCESS) {
    const char* err_string;
    const char* err_name;
    real_cuGetErrorString(err, &err_string);
    real_cuGetErrorName(err, &err_name);
    log_warn("%s returned %s: %s", func_name, err_name, err_string);
  }
}

/*
 * Since we're interposing dlsym() in libnvshare, we use dlvsym() to obtain the
 * address of the real dlsym function.
 *
 * Depending on glibc version and architecture, dlsym may be exported with
 * GLIBC_2.2.5 (common on x86_64), GLIBC_2.17 (common on aarch64), or
 * GLIBC_2.34 (newer distros). We try all known versions in priority order.
 */
typedef void*(dlsym_t)(void*, const char*);

static dlsym_t* resolve_real_dlsym(const char* const* versions,
                                   size_t version_count) {
  size_t i;
  dlsym_t* resolved;
  char* err;

  for (i = 0; i < version_count; ++i) {
    dlerror();
    resolved = (dlsym_t*)dlvsym(RTLD_NEXT, "dlsym", versions[i]);
    err = dlerror();
    if (err == NULL && resolved != NULL) {
      log_debug("resolved real dlsym with symbol version %s", versions[i]);
      return resolved;
    }
  }

  log_fatal("failed to resolve real dlsym via dlvsym()");
  return NULL;
}

static void* real_dlsym_225(void* handle, const char* symbol) {
  static dlsym_t* r_dlsym;
  static const char* versions[] = {"GLIBC_2.2.5", "GLIBC_2.17", "GLIBC_2.34"};

  if (!r_dlsym) {
    r_dlsym = resolve_real_dlsym(versions, sizeof(versions) / sizeof(versions[0]));
  }

  return (*r_dlsym)(handle, symbol);
}

static void* real_dlsym_217(void* handle, const char* symbol) {
  static dlsym_t* r_dlsym;
  static const char* versions[] = {"GLIBC_2.17", "GLIBC_2.34", "GLIBC_2.2.5"};

  if (!r_dlsym) {
    r_dlsym = resolve_real_dlsym(versions, sizeof(versions) / sizeof(versions[0]));
  }

  return (*r_dlsym)(handle, symbol);
}

static void* real_dlsym_234(void* handle, const char* symbol) {
  static dlsym_t* r_dlsym;
  static const char* versions[] = {"GLIBC_2.34", "GLIBC_2.17", "GLIBC_2.2.5"};

  if (!r_dlsym) {
    r_dlsym = resolve_real_dlsym(versions, sizeof(versions) / sizeof(versions[0]));
  }

  return (*r_dlsym)(handle, symbol);
}

static void* resolve_cuda_symbol(const char* symbol) {
  if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemAlloc)) == 0) {
    return (void*)(&cuMemAlloc);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemFree)) == 0) {
    return (void*)(&cuMemFree);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemGetInfo)) == 0) {
    return (void*)(&cuMemGetInfo);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuGetProcAddress)) == 0) {
    return (void*)(&cuGetProcAddress);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuGetProcAddress_v2)) == 0) {
    return (void*)(&cuGetProcAddress_v2);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuInit)) == 0) {
    return (void*)(&cuInit);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuLaunchKernel)) == 0) {
    return (void*)(&cuLaunchKernel);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpy)) == 0) {
    return (void*)(&cuMemcpy);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyAsync)) == 0) {
    return (void*)(&cuMemcpyAsync);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyDtoH)) == 0) {
    return (void*)(&cuMemcpyDtoH);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyDtoHAsync)) == 0) {
    return (void*)(&cuMemcpyDtoHAsync);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyHtoD)) == 0) {
    return (void*)(&cuMemcpyHtoD);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyHtoDAsync)) == 0) {
    return (void*)(&cuMemcpyHtoDAsync);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyDtoD)) == 0) {
    return (void*)(&cuMemcpyDtoD);
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemcpyDtoDAsync)) == 0) {
    return (void*)(&cuMemcpyDtoDAsync);
  }

  return NULL;
}

static void* resolve_acl_symbol(const char* symbol) {
  if (strcmp(symbol, "aclInit") == 0) {
    return (void*)(&aclInit);
  } else if (strcmp(symbol, "aclrtGetDeviceCount") == 0) {
    return (void*)(&aclrtGetDeviceCount);
  } else if (strcmp(symbol, "aclrtSetDevice") == 0) {
    return (void*)(&aclrtSetDevice);
  } else if (strcmp(symbol, "aclrtGetDevice") == 0) {
    return (void*)(&aclrtGetDevice);
  } else if (strcmp(symbol, "aclrtMalloc") == 0) {
    return (void*)(&aclrtMalloc);
  } else if (strcmp(symbol, "aclrtMallocAlign32") == 0) {
    return (void*)(&aclrtMallocAlign32);
  } else if (strcmp(symbol, "aclrtMallocCached") == 0) {
    return (void*)(&aclrtMallocCached);
  } else if (strcmp(symbol, "aclrtMallocWithCfg") == 0) {
    return (void*)(&aclrtMallocWithCfg);
  } else if (strcmp(symbol, "aclrtFree") == 0) {
    return (void*)(&aclrtFree);
  } else if (strcmp(symbol, "aclrtGetMemInfo") == 0) {
    return (void*)(&aclrtGetMemInfo);
  } else if (strcmp(symbol, "aclrtLaunchKernel") == 0) {
    return (void*)(&aclrtLaunchKernel);
  } else if (strcmp(symbol, "aclrtLaunchKernelWithConfig") == 0) {
    return (void*)(&aclrtLaunchKernelWithConfig);
  } else if (strcmp(symbol, "aclrtLaunchKernelV2") == 0) {
    return (void*)(&aclrtLaunchKernelV2);
  } else if (strcmp(symbol, "aclrtLaunchKernelWithHostArgs") == 0) {
    return (void*)(&aclrtLaunchKernelWithHostArgs);
  } else if (strcmp(symbol, "aclrtMemcpy") == 0) {
    return (void*)(&aclrtMemcpy);
  } else if (strcmp(symbol, "aclrtMemcpyAsync") == 0) {
    return (void*)(&aclrtMemcpyAsync);
  } else if (strcmp(symbol, "aclrtSynchronizeDevice") == 0) {
    return (void*)(&aclrtSynchronizeDevice);
  } else if (strcmp(symbol, "aclrtSynchronizeStream") == 0) {
    return (void*)(&aclrtSynchronizeStream);
  } else if (strcmp(symbol, "aclrtGetStreamResLimit") == 0) {
    return (void*)(&aclrtGetStreamResLimit);
  } else if (strcmp(symbol, "aclrtSetStreamResLimit") == 0) {
    return (void*)(&aclrtSetStreamResLimit);
  } else if (strcmp(symbol, "aclrtUseStreamResInCurrentThread") == 0) {
    return (void*)(&aclrtUseStreamResInCurrentThread);
  } else if (strcmp(symbol, "aclopExecute") == 0) {
    return (void*)(&aclopExecute);
  } else if (strcmp(symbol, "aclopExecuteV2") == 0) {
    return (void*)(&aclopExecuteV2);
  } else if (strcmp(symbol, "aclopExecWithHandle") == 0) {
    return (void*)(&aclopExecWithHandle);
  } else if (strcmp(symbol, "aclmdlExecute") == 0) {
    return (void*)(&aclmdlExecute);
  } else if (strcmp(symbol, "aclmdlExecuteV2") == 0) {
    return (void*)(&aclmdlExecuteV2);
  } else if (strcmp(symbol, "aclmdlExecuteAsync") == 0) {
    return (void*)(&aclmdlExecuteAsync);
  } else if (strcmp(symbol, "aclmdlExecuteAsyncV2") == 0) {
    return (void*)(&aclmdlExecuteAsyncV2);
  }

  return NULL;
}

static void* resolve_rt_symbol(const char* symbol) {
  if (strcmp(symbol, "rtDeviceSynchronize") == 0) {
    return (void*)(&rtDeviceSynchronize);
  } else if (strcmp(symbol, "rtDeviceSynchronizeWithTimeout") == 0) {
    return (void*)(&rtDeviceSynchronizeWithTimeout);
  } else if (strcmp(symbol, "rtStreamSynchronize") == 0) {
    return (void*)(&rtStreamSynchronize);
  } else if (strcmp(symbol, "rtStreamSynchronizeWithTimeout") == 0) {
    return (void*)(&rtStreamSynchronizeWithTimeout);
  } else if (strcmp(symbol, "rtKernelLaunch") == 0) {
    return (void*)(&rtKernelLaunch);
  } else if (strcmp(symbol, "rtKernelLaunchWithFlag") == 0) {
    return (void*)(&rtKernelLaunchWithFlag);
  } else if (strcmp(symbol, "rtKernelLaunchWithFlagV2") == 0) {
    return (void*)(&rtKernelLaunchWithFlagV2);
  } else if (strcmp(symbol, "rtKernelLaunchEx") == 0) {
    return (void*)(&rtKernelLaunchEx);
  } else if (strcmp(symbol, "rtLaunchKernelByFuncHandleV3") == 0) {
    return (void*)(&rtLaunchKernelByFuncHandleV3);
  } else if (strcmp(symbol, "rtsLaunchKernelWithConfig") == 0) {
    return (void*)(&rtsLaunchKernelWithConfig);
  } else if (strcmp(symbol, "rtsLaunchKernelWithDevArgs") == 0) {
    return (void*)(&rtsLaunchKernelWithDevArgs);
  } else if (strcmp(symbol, "rtsLaunchKernelWithHostArgs") == 0) {
    return (void*)(&rtsLaunchKernelWithHostArgs);
  } else if (strcmp(symbol, "rtVectorCoreKernelLaunch") == 0) {
    return (void*)(&rtVectorCoreKernelLaunch);
  }

  return NULL;
}

/*
 * CUDA Runtime API uses dlopen()/dlsym() to obtain addresses of the Driver API
 * functions.
 *
 * [spoiler: from CUDA 11.3 onwards, it only uses dlsym() to get the address
 *  of cuGetProcAddress() and then uses the latter to obtain the addresses
 *  of all other Driver API functions/symbols.]
 *
 * When the user program calls dlsym() requesting a Driver API symbol, return
 * our interposed version.
 *
 * In all other cases, call the real dlsym() from glibc and pass on the
 * requested symbol string.
 */
void* dlsym_225(void* handle, const char* symbol) {
  void* resolved;

  if (strncmp(symbol, "cu", 2) == 0) {
    resolved = resolve_cuda_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "acl", 3) == 0) {
    resolved = resolve_acl_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rt", 2) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rts", 3) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  }

  return (real_dlsym_225(handle, symbol));
}

void* dlsym_217(void* handle, const char* symbol) {
  void* resolved;

  if (strncmp(symbol, "cu", 2) == 0) {
    resolved = resolve_cuda_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "acl", 3) == 0) {
    resolved = resolve_acl_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rt", 2) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rts", 3) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  }

  return (real_dlsym_217(handle, symbol));
}

void* dlsym_234(void* handle, const char* symbol) {
  void* resolved;

  if (strncmp(symbol, "cu", 2) == 0) {
    resolved = resolve_cuda_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "acl", 3) == 0) {
    resolved = resolve_acl_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rt", 2) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "rts", 3) == 0) {
    resolved = resolve_rt_symbol(symbol);
    if (resolved != NULL) return resolved;
  }

  return (real_dlsym_234(handle, symbol));
}

/*
 * Older CUDA Runtime API (version <=11.2) does the following during internal
 * initialization (when the user program calls it for the first time):
 * 1. Calls dlopen("libcuda.so.1")
 * 2. Calls dlsym() for each function in the Driver API
 *
 * Newer CUDA Runtime API (version >=11.3) works like this:
 * 1. Calls dlopen("libcuda.so.1") and then dlsym("cuGetProcAddress")
 * 2. Calls cuGetProcAddress("cuGetProcAddress")
 *     1. If the pointer to "cuGetProcAddress" is NULL, it falls back to using
 *        dlsym() to get the Driver API function pointers
 *     2. If the pointer to "cuGetProcAddress" is not NULL, it uses
 *        cuGetProcAddress to get the Driver API function pointers.
 *
 * Interpose both, to cover all cases.
 *
 * The logic is the same as when interposing dlsym().
 */
CUresult cuGetProcAddress(const char* symbol, void** pfn, int cudaVersion,
                          cuuint64_t flags) {
  /*
   * cuGetProcAddress() will be called before cuInit() in CUDA
   * Runtime API (version >=11.3), so cuGetProcAddress() should also
   * serve as an entrypoint.
   * Otherwise, real_cuGetProcAddress may be a NULL pointer
   * when it is called.
   */
  ensure_cuda_client_initialized("cuGetProcAddress");
  CUresult result = CUDA_SUCCESS;

  if (real_cuGetProcAddress == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  if (strcmp(symbol, "cuMemAlloc") == 0) {
    *pfn = (void*)(&cuMemAlloc);
  } else if (strcmp(symbol, "cuMemFree") == 0) {
    *pfn = (void*)(&cuMemFree);
  } else if (strcmp(symbol, "cuMemGetInfo") == 0) {
    *pfn = (void*)(&cuMemGetInfo);
  } else if (strcmp(symbol, "cuGetProcAddress") == 0) {
    *pfn = (void*)(&cuGetProcAddress);
  } else if (strcmp(symbol, "cuGetProcAddress_v2") == 0) {
    *pfn = (void*)(&cuGetProcAddress_v2);
  } else if (strcmp(symbol, "cuInit") == 0) {
    *pfn = (void*)(&cuInit);
  } else if (strcmp(symbol, "cuLaunchKernel") == 0) {
    *pfn = (void*)(&cuLaunchKernel);
  } else if (strcmp(symbol, "cuMemcpy") == 0) {
    *pfn = (void*)(&cuMemcpy);
  } else if (strcmp(symbol, "cuMemcpyAsync") == 0) {
    *pfn = (void*)(&cuMemcpyAsync);
  } else if (strcmp(symbol, "cuMemcpyDtoH") == 0) {
    *pfn = (void*)(&cuMemcpyDtoH);
  } else if (strcmp(symbol, "cuMemcpyDtoHAsync") == 0) {
    *pfn = (void*)(&cuMemcpyDtoHAsync);
  } else if (strcmp(symbol, "cuMemcpyHtoD") == 0) {
    *pfn = (void*)(&cuMemcpyHtoD);
  } else if (strcmp(symbol, "cuMemcpyHtoDAsync") == 0) {
    *pfn = (void*)(&cuMemcpyHtoDAsync);
  } else if (strcmp(symbol, "cuMemcpyDtoD") == 0) {
    *pfn = (void*)(&cuMemcpyDtoD);
  } else if (strcmp(symbol, "cuMemcpyDtoDAsync") == 0) {
    *pfn = (void*)(&cuMemcpyDtoDAsync);
  } else {
    result = real_cuGetProcAddress(symbol, pfn, cudaVersion, flags);
  }

  return result;
}

CUresult cuGetProcAddress_v2(const char* symbol, void** pfn, int cudaVersion,
                             cuuint64_t flags,
                             CUdriverProcAddressQueryResult* symbolStatus) {
  /*
   * cuGetProcAddress_v2() will be called before cuInit() in CUDA
   * Runtime API (version >=12.0), so cuGetProcAddress_v2()
   * should also serve as an entrypoint.
   *
   * Otherwise, real_cuGetProcAddress_v2 may be a
   * NULL pointer when it is called.
   */
  ensure_cuda_client_initialized("cuGetProcAddress_v2");
  CUresult result = CUDA_SUCCESS;

  if (real_cuGetProcAddress_v2 == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  /* This covers our custom "if" conditions.
   * If we end up calling the real cuGetProcAddress_v2,
   * it will overwrite this value.
   */
  if (symbolStatus != NULL) *symbolStatus = CU_GET_PROC_ADDRESS_SUCCESS;

  if (strcmp(symbol, "cuMemAlloc") == 0) {
    *pfn = (void*)(&cuMemAlloc);
  } else if (strcmp(symbol, "cuMemFree") == 0) {
    *pfn = (void*)(&cuMemFree);
  } else if (strcmp(symbol, "cuMemGetInfo") == 0) {
    *pfn = (void*)(&cuMemGetInfo);
  } else if (strcmp(symbol, "cuGetProcAddress") == 0) {
    *pfn = (void*)(&cuGetProcAddress);
  } else if (strcmp(symbol, "cuGetProcAddress_v2") == 0) {
    *pfn = (void*)(&cuGetProcAddress_v2);
  } else if (strcmp(symbol, "cuInit") == 0) {
    *pfn = (void*)(&cuInit);
  } else if (strcmp(symbol, "cuLaunchKernel") == 0) {
    *pfn = (void*)(&cuLaunchKernel);
  } else if (strcmp(symbol, "cuMemcpy") == 0) {
    *pfn = (void*)(&cuMemcpy);
  } else if (strcmp(symbol, "cuMemcpyAsync") == 0) {
    *pfn = (void*)(&cuMemcpyAsync);
  } else if (strcmp(symbol, "cuMemcpyDtoH") == 0) {
    *pfn = (void*)(&cuMemcpyDtoH);
  } else if (strcmp(symbol, "cuMemcpyDtoHAsync") == 0) {
    *pfn = (void*)(&cuMemcpyDtoHAsync);
  } else if (strcmp(symbol, "cuMemcpyHtoD") == 0) {
    *pfn = (void*)(&cuMemcpyHtoD);
  } else if (strcmp(symbol, "cuMemcpyHtoDAsync") == 0) {
    *pfn = (void*)(&cuMemcpyHtoDAsync);
  } else if (strcmp(symbol, "cuMemcpyDtoD") == 0) {
    *pfn = (void*)(&cuMemcpyDtoD);
  } else if (strcmp(symbol, "cuMemcpyDtoDAsync") == 0) {
    *pfn = (void*)(&cuMemcpyDtoDAsync);
  } else {
    result =
        real_cuGetProcAddress_v2(symbol, pfn, cudaVersion, flags, symbolStatus);
  }

  return result;
}

CUresult cuMemAlloc(CUdeviceptr* dptr, size_t bytesize) {
  static int got_max_mem_size = 0;
  size_t junk;
  CUresult result = CUDA_SUCCESS;
  int exceeds_physical = 0;

  ensure_cuda_client_initialized("cuMemAlloc");

  /* Return immediately if not initialized */
  if (real_cuMemAllocManaged == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  if (got_max_mem_size == 0) {
    result = cuMemGetInfo(&nvshare_size_mem_allocatable, &junk);
    cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemGetInfo));
    got_max_mem_size = 1;
  }

  if (!check_allocation_limit(bytesize, "cuMemAlloc", &exceeds_physical,
                              nvshare_size_mem_allocatable)) {
    return CUDA_ERROR_OUT_OF_MEMORY;
  }
  if (exceeds_physical) {
    log_warn("cuMemAlloc exceeds physical GPU memory; oversub mode enabled");
  }

  log_debug("cuMemAlloc requested %zu bytes", bytesize);
  result = real_cuMemAllocManaged(dptr, bytesize, CU_MEM_ATTACH_GLOBAL);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemAllocManaged));
  log_debug("cuMemAllocManaged allocated %zu bytes at 0x%llx", bytesize, *dptr);
  if (result == CUDA_SUCCESS) {
    insert_cuda_allocation(*dptr, bytesize);
  }

  return result;
}

CUresult cuMemFree(CUdeviceptr dptr) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemFree");

  if (real_cuMemFree == NULL) return CUDA_ERROR_NOT_INITIALIZED;
  result = real_cuMemFree(dptr);
  if (result == CUDA_SUCCESS) remove_cuda_allocation(dptr);

  return result;
}

CUresult cuMemGetInfo(size_t* free, size_t* total) {
  long long reserve_mib;
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemGetInfo");

  /* Return immediately if not initialized */
  if (real_cuMemGetInfo == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  result = real_cuMemGetInfo(free, total);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemGetInfo));

  log_debug("real_cuMemGetInfo returned free=%.2f MiB, total=%.2f MiB",
            toMiB(*free), toMiB(*total));
  report_total_memory_to_scheduler(*total);

  /* If user specified a memory limit, report that as total/free */
  if (memory_limit > 0) {
    *total = memory_limit;
    *free = (memory_limit > sum_allocated) ? (memory_limit - sum_allocated) : 0;
    log_debug(
        "nvshare's cuMemGetInfo (with limit): free=%.2f MiB, total=%.2f MiB",
        toMiB(*free), toMiB(*total));
    return result;
  }

  /*
   * Hide a static amount of GPU memory from the applications. CUDA uses
   * this memory to store context information and it is not pageable.
   *
   * In practice, this amount of memory is not static and depends on
   * the number of colocated applications. Each one has its own context,
   * which eats away some physical, non-pageable GPU memory.
   *
   * The first application that runs theoretically has (TOTAL_GPU_MEM -
   * CONTEXT_SIZE) memory available.
   *
   * CONTEXT_SIZE typically uses a few hundred MB and depends on the GPU
   * model.
   *
   * cuBLAS and other CUDA libraries also eat away at this memory.
   *
   * When another app runs, this "working memory size" shrinks further
   * and can lead to thrashing within the first application, even when
   * it runs alone.
   *
   * We cannot shrink the memory allocations of a running app, and the
   * app thinks all of its memory is physically backed, since it's
   * programmed with cuMemAlloc semantics in mind.
   *
   * To avoid internal thrashing, we empirically choose a sane value for
   * MEMINFO_RESERVE_MIB.
   */
  reserve_mib = (MEMINFO_RESERVE_MIB)MiB;
  *free = *total - (size_t)reserve_mib;

  log_debug(
      "nvshare's cuMemGetInfo returning free=%.2f MiB,"
      " total=%.2f MiB",
      toMiB(*free), toMiB(*total));
  return result;
}

/*
 * A call to cuInit is an indicator that the present application is a CUDA
 * application and that we should bootstrap nvshare.
 */
CUresult cuInit(unsigned int flags) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuInit");

  result = real_cuInit(flags);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuInit));

  return result;
}

CUresult cuLaunchKernel(CUfunction f, unsigned int gridDimX,
                        unsigned int gridDimY, unsigned int gridDimZ,
                        unsigned int blockDimX, unsigned int blockDimY,
                        unsigned int blockDimZ, unsigned int sharedMemBytes,
                        CUstream hStream, void** kernelParams, void** extra) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuLaunchKernel");

  /* Return immediately if not initialized */
  if (real_cuLaunchKernel == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuLaunchKernel(f, gridDimX, gridDimY, gridDimZ, blockDimX,
                               blockDimY, blockDimZ, sharedMemBytes, hStream,
                               kernelParams, extra);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuLaunchKernel));

  true_or_exit(pthread_mutex_lock(&kcount_mutex) == 0);

  /*
   * Dynamic kernel submissing rate control.
   *
   * Some applications like to submit a huge amount of kernels in a short
   * period of time.
   *
   * For nvshare, this means that they would still have pending kernels
   * on the GPU when asked to relinquish the GPU lock.
   *
   * Since we sync the CUDA context before releasing the lock, this
   * would mean we would hold the lock for much longer than TQ seconds,
   * as that sync could possible take a very long time.
   *
   * To alleviate this source of unfairness, try to keep the completion
   * time of submitted kernels to within 5 seconds, while simultaneously
   * trying to maintain a good throughput rate for smaller kernels.
   */
  kern_since_sync++;
  if (kern_since_sync >= pending_kernel_window) {
    struct timespec cuda_cuda_sync_start_time = {0, 0};
    struct timespec cuda_sync_complete_time = {0, 0};
    struct timespec cuda_sync_duration = {0, 0};
    true_or_exit(clock_gettime(CLOCK_MONOTONIC, &cuda_cuda_sync_start_time) ==
                 0);
    result = real_cuCtxSynchronize();
    cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuCtxSynchronize));
    true_or_exit(clock_gettime(CLOCK_MONOTONIC, &cuda_sync_complete_time) == 0);
    timespecsub(&cuda_sync_complete_time, &cuda_cuda_sync_start_time,
                &cuda_sync_duration);

    /*
     * Adaptive Flow Control Logic (AIMD + Warmup)
     *
     * 1. Warm-up Grace Period:
     *    If we just acquired the lock (<30s ago), we ignore timeouts caused by
     *    initial page faults and allow window to grow to fill the pipeline.
     */
    int in_warmup = 0;
    time_t now = time(NULL);
    if (lock_acquire_time > 0 &&
        (now - lock_acquire_time) < kern_warmup_period_sec) {
      in_warmup = 1;
    }

    if (cuda_sync_duration.tv_sec >= kern_sync_duration_big) {
      /* Critical Timeout (>10s) */
      if (in_warmup) {
        /* Ignore critical timeout during warmup, duplicate window to fill pipe
         */
        pending_kernel_window =
            min(pending_kernel_window * 2, get_kernel_window_max());
        log_info(
            "Warmup: Ignored critical timeout (%ld s), growing window to %d",
            cuda_sync_duration.tv_sec, pending_kernel_window);
      } else {
        consecutive_timeout_count++;
        if (consecutive_timeout_count > 3) {
          /* Anti-abuse: Consecutive critical timeouts force minimum window */
          pending_kernel_window = 1;
          log_warn(
              "Abuse detected: %d consecutive critical timeouts. Forcing sync "
              "mode.",
              consecutive_timeout_count);
        } else {
          /* AIMD: Multiplicative Decrease */
          pending_kernel_window =
              max(kern_window_min_floor, pending_kernel_window / 2);
          log_warn("Critical timeout (%ld s). AIMD reduced window to %d",
                   cuda_sync_duration.tv_sec, pending_kernel_window);
        }
      }
    } else if (cuda_sync_duration.tv_sec >=
               (time_t)kern_sync_duration_mild) {  // >= 1.0s
      /* Mild Timeout */
      consecutive_timeout_count = 0; /* Reset critical counter */
      if (in_warmup) {
        pending_kernel_window =
            min(pending_kernel_window * 2, get_kernel_window_max());
      } else {
        /* Mild backoff */
        pending_kernel_window =
            max(kern_window_min_floor, (int)(pending_kernel_window * 0.8));
      }
    } else {
      /* No Timeout - Geometric Growth (or Linear) */
      consecutive_timeout_count = 0;

      /* Aggressive growth to recover throughput */
      pending_kernel_window =
          min(pending_kernel_window * 2, get_kernel_window_max());
    }

    log_debug("Pending Kernel Window is %d (warmup=%d).", pending_kernel_window,
              in_warmup);
    kern_since_sync = 0;
  }

  true_or_exit(pthread_mutex_unlock(&kcount_mutex) == 0);
  return result;
}

/*
 * Memory copy functions can affect the resident pages on GPU, so we must
 * block them as well when the client doesn't have the GPU lock.
 */
CUresult cuMemcpy(CUdeviceptr dst, CUdeviceptr src, size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpy");

  if (real_cuMemcpy == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpy(dst, src, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpy));

  return result;
}

CUresult cuMemcpyAsync(CUdeviceptr dst, CUdeviceptr src, size_t ByteCount,
                       CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyAsync");

  if (real_cuMemcpyAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpyAsync(dst, src, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyAsync));

  return result;
}

CUresult cuMemcpyDtoH(void* dstHost, CUdeviceptr srcDevice, size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyDtoH");

  /* Return immediately if not initialized */
  if (real_cuMemcpyDtoH == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyDtoH(dstHost, srcDevice, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyDtoH));

  return result;
}

CUresult cuMemcpyDtoHAsync(void* dstHost, CUdeviceptr srcDevice,
                           size_t ByteCount, CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyDtoHAsync");

  /* Return immediately if not initialized */
  if (real_cuMemcpyDtoHAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyDtoHAsync(dstHost, srcDevice, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyDtoHAsync));

  return result;
}

CUresult cuMemcpyHtoD(CUdeviceptr dstDevice, const void* srcHost,
                      size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyHtoD");

  /* Return immediately if not initialized */
  if (real_cuMemcpyHtoD == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyHtoD(dstDevice, srcHost, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyHtoD));

  return result;
}

CUresult cuMemcpyHtoDAsync(CUdeviceptr dstDevice, const void* srcHost,
                           size_t ByteCount, CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyHtoDAsync");

  /* Return immediately if not initialized */
  if (real_cuMemcpyHtoDAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyHtoDAsync(dstDevice, srcHost, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyHtoDAsync));

  return result;
}

CUresult cuMemcpyDtoD(CUdeviceptr dstDevice, CUdeviceptr srcDevice,
                      size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyDtoD");

  /* Return immediately if not initialized */
  if (real_cuMemcpyDtoD == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyDtoD(dstDevice, srcDevice, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyDtoD));

  return result;
}

CUresult cuMemcpyDtoDAsync(CUdeviceptr dstDevice, CUdeviceptr srcDevice,
                           size_t ByteCount, CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  ensure_cuda_client_initialized("cuMemcpyDtoDAsync");

  /* Return immediately if not initialized */
  if (real_cuMemcpyDtoDAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyDtoDAsync(dstDevice, srcDevice, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyDtoDAsync));

  return result;
}

static int ensure_npu_physical_cap(size_t* allocatable_out) {
  size_t free_mem = 0;
  size_t total_mem = 0;

  if (real_aclrtGetMemInfo == NULL) return 0;
  if (real_aclrtGetMemInfo(ACL_HBM_MEM, &free_mem, &total_mem) != ACL_SUCCESS) {
    return 0;
  }

  report_total_memory_to_scheduler(total_mem);
  *allocatable_out = free_mem;
  return 1;
}

aclError aclInit(const char* configPath) {
  aclError ret;
  int should_init = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclInit");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (npu_init_gate_peek_deferred()) {
    log_debug("aclInit skipped: deferred NPU init gate already active");
    return ACL_SUCCESS;
  }

  should_init = begin_npu_init_gate("aclInit");
  if (!should_init) return ACL_SUCCESS;

  ret = call_real_aclinit_with_retry(configPath);
  if (ret == ACL_SUCCESS) {
    npu_init_gate_mark_deferred();
    log_info("Deferred NPU init gate completion until device bind API");
    return ACL_SUCCESS;
  }
  end_npu_init_gate(0, (int)ret);
  return ret;
}

aclError aclrtGetDeviceCount(uint32_t* count) {
  aclError ret;
  aclError init_ret = ACL_SUCCESS;
  int attempt;
  int should_init = 0;
  uint32_t visible_count = 0;
  const char* env = NULL;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtGetDeviceCount");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);

  if (count != NULL) {
    env = getenv("ASCEND_RT_VISIBLE_DEVICES");
    if (count_visible_npu_devices(env, &visible_count) ||
        count_visible_npu_devices(getenv("ASCEND_VISIBLE_DEVICES"),
                                  &visible_count)) {
      *count = visible_count;
      return ACL_SUCCESS;
    }
  }

  if (real_aclrtGetDeviceCount == NULL) return ACL_ERROR_UNINITIALIZE;

  ret = real_aclrtGetDeviceCount(count);
  if (ret == ACL_SUCCESS) return ret;

  /*
   * aclInit succeeded earlier and gate is intentionally held for subsequent
   * device bind API. Avoid re-entering begin_npu_init_gate() and waiting on
   * ourselves.
   */
  if (npu_init_gate_peek_deferred()) return ret;

  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  should_init = begin_npu_init_gate("aclrtGetDeviceCount");
  if (should_init) {
    init_ret = call_real_aclinit_with_retry(NULL);
    end_npu_init_gate(init_ret == ACL_SUCCESS, (int)init_ret);
    if (init_ret != ACL_SUCCESS) {
      return init_ret;
    }
  }

  for (attempt = 1; attempt <= NPU_GETCOUNT_RETRY_TIMES; ++attempt) {
    usleep(NPU_GETCOUNT_RETRY_SLEEP_US * attempt);
    ret = real_aclrtGetDeviceCount(count);
    if (ret == ACL_SUCCESS) {
      log_warn(
          "aclrtGetDeviceCount recovered after %d retries (init_ret=%d)",
          attempt, (int)init_ret);
      return ret;
    }
  }

  log_warn("aclrtGetDeviceCount failed after retries, ret=%d init_ret=%d",
           (int)ret, (int)init_ret);
  return ret;
}

aclError aclrtSetDevice(int32_t deviceId) {
  aclError ret;
  int should_init = 0;
  aclError init_ret = ACL_SUCCESS;
  int deferred_owner = 0;
  int direct_owner = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtSetDevice");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  deferred_owner = npu_init_gate_take_deferred();
  if (!deferred_owner) {
    should_init = begin_npu_init_gate("aclrtSetDevice");
    if (should_init) {
      init_ret = call_real_aclinit_with_retry(NULL);
      if (init_ret != ACL_SUCCESS) {
        end_npu_init_gate(0, (int)init_ret);
        return init_ret;
      }
      direct_owner = 1;
    }
  } else {
    log_debug("Completing deferred NPU init gate in aclrtSetDevice");
  }

  if (real_aclrtSetDevice == NULL) {
    if (deferred_owner || direct_owner) {
      end_npu_init_gate(0, ACL_ERROR_UNINITIALIZE);
    }
    return ACL_ERROR_UNINITIALIZE;
  }

  ret = real_aclrtSetDevice(deviceId);
  if (ret == ACL_SUCCESS) {
    cache_npu_thread_binding(deviceId);
    npu_stream_reslimit_last_stream = NULL;
    npu_stream_reslimit_last_percent = -1;
    nvshare_apply_npu_core_limit();
  }
  if (deferred_owner || direct_owner) {
    if (ret == ACL_SUCCESS) {
      npu_init_gate_mark_post_setdevice_pending();
      log_debug("Deferred NPU init gate completion until first post-setDevice ACL runtime API");
    } else {
      end_npu_init_gate(0, (int)ret);
    }
  }
  return ret;
}

aclError aclrtGetDevice(int32_t* deviceId) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtGetDevice");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  if (real_aclrtGetDevice == NULL) return ACL_ERROR_UNINITIALIZE;

  ret = real_aclrtGetDevice(deviceId);
  if (ret == ACL_SUCCESS && deviceId != NULL) {
    cache_npu_thread_binding(*deviceId);
  }
  return ret;
}

static aclError acl_malloc_common(void** devPtr, size_t size,
                                  aclrtMemMallocPolicy policy,
                                  aclrtMalloc_func malloc_fn,
                                  const char* api_name, int is_padding) {
  int exceeds_physical = 0;
  aclError ret;
  rtError_t managed_ret = RT_ERROR_NONE;
  size_t managed_size = size;
  int managed_enabled;
  int fallback_enabled;

  if (!check_allocation_limit(size, api_name, &exceeds_physical,
                              npu_size_mem_allocatable)) {
    return ACL_ERROR_BAD_ALLOC;
  }
  if (exceeds_physical) {
    log_warn("%s exceeds physical NPU memory; oversub mode enabled", api_name);
  }

  nvshare_apply_npu_core_limit();

  managed_enabled = npu_managed_alloc_enabled();
  fallback_enabled = npu_managed_alloc_fallback_enabled();
  if (managed_enabled) {
    if (real_rtMemAllocManaged == NULL) {
      log_warn("%s: rtMemAllocManaged symbol unavailable", api_name);
      npu_record_managed_fallback(NPU_FALLBACK_SYMBOL_UNAVAILABLE, api_name,
                                  "rtMemAllocManaged-missing");
      if (!fallback_enabled) return ACL_ERROR_UNINITIALIZE;
    } else if (devPtr == NULL) {
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else if (!align_acl_malloc_size(size, is_padding, &managed_size)) {
      log_warn("%s: managed size alignment overflow for size=%zu", api_name,
               size);
      npu_record_managed_fallback(NPU_FALLBACK_ALIGN_OVERFLOW, api_name,
                                  "align-overflow");
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else {
      managed_ret = real_rtMemAllocManaged(devPtr, managed_size, RT_MEMORY_SVM,
                                           get_npu_managed_module_id());
      if (managed_ret == RT_ERROR_NONE && *devPtr != NULL) {
        insert_npu_allocation(*devPtr, size, managed_size,
                              NPU_ALLOC_MODE_RT_MANAGED);
        if (maybe_prefetch_npu_allocation(*devPtr, managed_size, api_name)) {
          report_npu_usage_to_scheduler();
        }
        npu_init_gate_maybe_finish_post_setdevice(api_name);
        return ACL_SUCCESS;
      }
      log_warn("%s: rtMemAllocManaged failed, ret=%d (size=%zu aligned=%zu)",
               api_name, (int)managed_ret, size, managed_size);
      npu_record_managed_fallback(NPU_FALLBACK_ALLOC_FAILED, api_name,
                                  "rtMemAllocManaged-failed");
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    }
  }

  if (malloc_fn == NULL) return ACL_ERROR_UNINITIALIZE;
  ret = malloc_fn(devPtr, size, policy);
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, size, size, NPU_ALLOC_MODE_ACL);
  }
  npu_init_gate_maybe_finish_post_setdevice(api_name);

  return ret;
}

aclError aclrtMalloc(void** devPtr, size_t size, aclrtMemMallocPolicy policy) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMalloc");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }

  return acl_malloc_common(devPtr, size, policy, real_aclrtMalloc,
                           "aclrtMalloc", 1);
}

aclError aclrtMallocAlign32(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMallocAlign32");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }

  return acl_malloc_common(devPtr, size, policy, real_aclrtMallocAlign32,
                           "aclrtMallocAlign32", 0);
}

aclError aclrtMallocCached(void** devPtr, size_t size,
                           aclrtMemMallocPolicy policy) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMallocCached");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }

  return acl_malloc_common(devPtr, size, policy, real_aclrtMallocCached,
                           "aclrtMallocCached", 1);
}

aclError aclrtMallocWithCfg(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy, void* cfg) {
  int exceeds_physical = 0;
  aclError ret;
  int managed_enabled = 0;
  int fallback_enabled = 0;
  rtError_t managed_ret = RT_ERROR_NONE;
  size_t managed_size = size;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMallocWithCfg");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtMallocWithCfg == NULL) return ACL_ERROR_UNINITIALIZE;

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }

  if (!check_allocation_limit(size, "aclrtMallocWithCfg", &exceeds_physical,
                              npu_size_mem_allocatable)) {
    return ACL_ERROR_BAD_ALLOC;
  }
  if (exceeds_physical) {
    log_warn(
        "aclrtMallocWithCfg exceeds physical NPU memory; oversub mode enabled");
  }

  nvshare_apply_npu_core_limit();

  managed_enabled = npu_managed_alloc_enabled() && npu_managed_withcfg_enabled();
  fallback_enabled = npu_managed_alloc_fallback_enabled();
  if (managed_enabled) {
    if (cfg != NULL) {
      log_warn("aclrtMallocWithCfg: cfg is not NULL, fallback to acl/native");
      npu_record_managed_fallback(NPU_FALLBACK_CFG_NONNULL,
                                  "aclrtMallocWithCfg", "cfg-not-null");
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else if (real_rtMemAllocManaged == NULL) {
      log_warn("aclrtMallocWithCfg: rtMemAllocManaged symbol unavailable");
      npu_record_managed_fallback(NPU_FALLBACK_SYMBOL_UNAVAILABLE,
                                  "aclrtMallocWithCfg",
                                  "rtMemAllocManaged-missing");
      if (!fallback_enabled) return ACL_ERROR_UNINITIALIZE;
    } else if (devPtr == NULL) {
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else if (!align_acl_malloc_size(size, 1, &managed_size)) {
      log_warn(
          "aclrtMallocWithCfg: managed size alignment overflow for size=%zu",
          size);
      npu_record_managed_fallback(NPU_FALLBACK_ALIGN_OVERFLOW,
                                  "aclrtMallocWithCfg", "align-overflow");
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else {
      managed_ret = real_rtMemAllocManaged(devPtr, managed_size, RT_MEMORY_SVM,
                                           get_npu_managed_module_id());
      if (managed_ret == RT_ERROR_NONE && *devPtr != NULL) {
        insert_npu_allocation(*devPtr, size, managed_size,
                              NPU_ALLOC_MODE_RT_MANAGED);
        if (maybe_prefetch_npu_allocation(*devPtr, managed_size,
                                          "aclrtMallocWithCfg")) {
          report_npu_usage_to_scheduler();
        }
        npu_init_gate_maybe_finish_post_setdevice("aclrtMallocWithCfg");
        return ACL_SUCCESS;
      }
      log_warn(
          "aclrtMallocWithCfg: rtMemAllocManaged failed, ret=%d (size=%zu aligned=%zu)",
          (int)managed_ret, size, managed_size);
      npu_record_managed_fallback(NPU_FALLBACK_ALLOC_FAILED,
                                  "aclrtMallocWithCfg",
                                  "rtMemAllocManaged-failed");
      if (!fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    }
  }

  ret = real_aclrtMallocWithCfg(devPtr, size, policy, cfg);
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, size, size, NPU_ALLOC_MODE_ACL);
  }
  npu_init_gate_maybe_finish_post_setdevice("aclrtMallocWithCfg");

  return ret;
}

aclError aclrtFree(void* devPtr) {
  aclError ret;
  int alloc_mode = NPU_ALLOC_MODE_ACL;
  int has_alloc_mode = 0;
  int fallback_enabled;
  rtError_t managed_ret = RT_ERROR_NONE;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtFree");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  fallback_enabled = npu_managed_alloc_fallback_enabled();
  has_alloc_mode = find_npu_allocation_mode(devPtr, &alloc_mode);

  if (has_alloc_mode && alloc_mode == NPU_ALLOC_MODE_RT_MANAGED) {
    if (real_rtMemFreeManaged != NULL) {
      managed_ret = real_rtMemFreeManaged(devPtr);
      if (managed_ret == RT_ERROR_NONE) {
        ret = ACL_SUCCESS;
      } else if (fallback_enabled && real_aclrtFree != NULL) {
        log_warn("aclrtFree: rtMemFreeManaged failed ret=%d, fallback to aclrtFree",
                 (int)managed_ret);
        ret = real_aclrtFree(devPtr);
      } else {
        log_warn("aclrtFree: rtMemFreeManaged failed ret=%d", (int)managed_ret);
        ret = ACL_ERROR_BAD_ALLOC;
      }
    } else if (fallback_enabled && real_aclrtFree != NULL) {
      log_warn("aclrtFree: rtMemFreeManaged unavailable, fallback to aclrtFree");
      ret = real_aclrtFree(devPtr);
    } else {
      ret = ACL_ERROR_UNINITIALIZE;
    }
  } else {
    if (real_aclrtFree == NULL) return ACL_ERROR_UNINITIALIZE;
    ret = real_aclrtFree(devPtr);
  }

  if (ret == ACL_SUCCESS) {
    remove_npu_allocation(devPtr);
  }

  return ret;
}

aclError aclrtGetMemInfo(aclrtMemAttr attr, size_t* free, size_t* total) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtGetMemInfo");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtGetMemInfo == NULL) return ACL_ERROR_UNINITIALIZE;

  ret = real_aclrtGetMemInfo(attr, free, total);
  if (ret != ACL_SUCCESS) return ret;
  report_total_memory_to_scheduler(*total);

  if (memory_limit > 0) {
    *total = memory_limit;
    *free = (memory_limit > sum_allocated) ? (memory_limit - sum_allocated) : 0;
    log_debug(
        "nvshare aclrtGetMemInfo (with limit): free=%.2f MiB, total=%.2f MiB",
        toMiB(*free), toMiB(*total));
    return ret;
  }

  return ret;
}

aclError aclrtGetStreamResLimit(aclrtStream stream, aclrtDevResLimitType type,
                                uint32_t* value) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtGetStreamResLimit");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtGetStreamResLimit == NULL) return ACL_ERROR_UNINITIALIZE;
  return real_aclrtGetStreamResLimit(stream, type, value);
}

aclError aclrtSetStreamResLimit(aclrtStream stream, aclrtDevResLimitType type,
                                uint32_t value) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtSetStreamResLimit");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtSetStreamResLimit == NULL) return ACL_ERROR_UNINITIALIZE;
  ret = real_aclrtSetStreamResLimit(stream, type, value);
  if (ret == ACL_SUCCESS) {
    npu_stream_reslimit_last_stream = NULL;
    npu_stream_reslimit_last_percent = -1;
  }
  return ret;
}

aclError aclrtUseStreamResInCurrentThread(aclrtStream stream) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtUseStreamResInCurrentThread");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtUseStreamResInCurrentThread == NULL)
    return ACL_ERROR_UNINITIALIZE;
  return real_aclrtUseStreamResInCurrentThread(stream);
}

aclError aclopExecute(const char* opType, int numInputs,
                      const aclTensorDesc* const inputDesc[],
                      const aclDataBuffer* const inputs[], int numOutputs,
                      const aclTensorDesc* const outputDesc[],
                      aclDataBuffer* const outputs[], const aclopAttr* attr,
                      aclrtStream stream) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclopExecute");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclopExecute == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclopExecute");
  npu_api_trace_hit("aclopExecute");
  npu_active_meter_on_launch(stream, "aclopExecute");
  continue_with_lock();
  return real_aclopExecute(opType, numInputs, inputDesc, inputs, numOutputs,
                           outputDesc, outputs, attr, stream);
}

aclError aclopExecuteV2(const char* opType, int numInputs,
                        aclTensorDesc* inputDesc[], aclDataBuffer* inputs[],
                        int numOutputs, aclTensorDesc* outputDesc[],
                        aclDataBuffer* outputs[], aclopAttr* attr,
                        aclrtStream stream) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclopExecuteV2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclopExecuteV2 == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclopExecuteV2");
  npu_api_trace_hit("aclopExecuteV2");
  npu_active_meter_on_launch(stream, "aclopExecuteV2");
  continue_with_lock();
  return real_aclopExecuteV2(opType, numInputs, inputDesc, inputs, numOutputs,
                             outputDesc, outputs, attr, stream);
}

aclError aclopExecWithHandle(aclopHandle* handle, int numInputs,
                             const aclDataBuffer* const inputs[],
                             int numOutputs, aclDataBuffer* const outputs[],
                             aclrtStream stream) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclopExecWithHandle");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclopExecWithHandle == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclopExecWithHandle");
  npu_api_trace_hit("aclopExecWithHandle");
  npu_active_meter_on_launch(stream, "aclopExecWithHandle");
  continue_with_lock();
  return real_aclopExecWithHandle(handle, numInputs, inputs, numOutputs,
                                  outputs, stream);
}

aclError aclmdlExecute(uint32_t modelId, const aclmdlDataset* input,
                       aclmdlDataset* output) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclmdlExecute");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclmdlExecute == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit();
  npu_api_trace_hit("aclmdlExecute");
  npu_active_meter_on_launch(NULL, "aclmdlExecute");
  continue_with_lock();
  return real_aclmdlExecute(modelId, input, output);
}

aclError aclmdlExecuteV2(uint32_t modelId, const aclmdlDataset* input,
                         aclmdlDataset* output, aclrtStream stream,
                         const aclmdlExecConfigHandle* handle) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclmdlExecuteV2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclmdlExecuteV2 == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclmdlExecuteV2");
  npu_api_trace_hit("aclmdlExecuteV2");
  npu_active_meter_on_launch(stream, "aclmdlExecuteV2");
  continue_with_lock();
  return real_aclmdlExecuteV2(modelId, input, output, stream, handle);
}

aclError aclmdlExecuteAsync(uint32_t modelId, const aclmdlDataset* input,
                            aclmdlDataset* output, aclrtStream stream) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclmdlExecuteAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclmdlExecuteAsync == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclmdlExecuteAsync");
  npu_api_trace_hit("aclmdlExecuteAsync");
  npu_active_meter_on_launch(stream, "aclmdlExecuteAsync");
  continue_with_lock();
  return real_aclmdlExecuteAsync(modelId, input, output, stream);
}

aclError aclmdlExecuteAsyncV2(uint32_t modelId, const aclmdlDataset* input,
                              aclmdlDataset* output, aclrtStream stream,
                              const aclmdlExecConfigHandle* handle) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclmdlExecuteAsyncV2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_aclmdlExecuteAsyncV2 == NULL) return ACL_ERROR_UNINITIALIZE;
  nvshare_apply_npu_core_limit_for_stream(stream, "aclmdlExecuteAsyncV2");
  npu_api_trace_hit("aclmdlExecuteAsyncV2");
  npu_active_meter_on_launch(stream, "aclmdlExecuteAsyncV2");
  continue_with_lock();
  return real_aclmdlExecuteAsyncV2(modelId, input, output, stream, handle);
}

aclError aclrtLaunchKernel(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                           const void* argsData, size_t argsSize,
                           aclrtStream stream) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtLaunchKernel");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtLaunchKernel == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream, "aclrtLaunchKernel");
  npu_api_trace_hit("aclrtLaunchKernel");
  npu_active_meter_on_launch(stream, "aclrtLaunchKernel");
  continue_with_lock();
  ret =
      real_aclrtLaunchKernel(funcHandle, numBlocks, argsData, argsSize, stream);
  return ret;
}

aclError aclrtLaunchKernelWithConfig(aclrtFuncHandle funcHandle,
                                     uint32_t numBlocks, aclrtStream stream,
                                     aclrtLaunchKernelCfg* cfg,
                                     aclrtArgsHandle argsHandle,
                                     void* reserve) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtLaunchKernelWithConfig");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtLaunchKernelWithConfig == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream,
                                          "aclrtLaunchKernelWithConfig");
  npu_api_trace_hit("aclrtLaunchKernelWithConfig");
  npu_active_meter_on_launch(stream, "aclrtLaunchKernelWithConfig");
  continue_with_lock();
  ret = real_aclrtLaunchKernelWithConfig(funcHandle, numBlocks, stream, cfg,
                                         argsHandle, reserve);
  return ret;
}

aclError aclrtLaunchKernelV2(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                             const void* argsData, size_t argsSize,
                             aclrtLaunchKernelCfg* cfg, aclrtStream stream) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtLaunchKernelV2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtLaunchKernelV2 == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream, "aclrtLaunchKernelV2");
  npu_api_trace_hit("aclrtLaunchKernelV2");
  npu_active_meter_on_launch(stream, "aclrtLaunchKernelV2");
  continue_with_lock();
  ret = real_aclrtLaunchKernelV2(funcHandle, numBlocks, argsData, argsSize, cfg,
                                 stream);
  return ret;
}

aclError aclrtLaunchKernelWithHostArgs(
    aclrtFuncHandle funcHandle, uint32_t numBlocks, aclrtStream stream,
    aclrtLaunchKernelCfg* cfg, void* hostArgs, size_t argsSize,
    aclrtPlaceHolderInfo* placeHolderArray, size_t placeHolderNum) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtLaunchKernelWithHostArgs");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtLaunchKernelWithHostArgs == NULL)
    return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream,
                                          "aclrtLaunchKernelWithHostArgs");
  npu_api_trace_hit("aclrtLaunchKernelWithHostArgs");
  npu_active_meter_on_launch(stream, "aclrtLaunchKernelWithHostArgs");
  continue_with_lock();
  ret = real_aclrtLaunchKernelWithHostArgs(
      funcHandle, numBlocks, stream, cfg, hostArgs, argsSize, placeHolderArray,
      placeHolderNum);
  return ret;
}

aclError aclrtMemcpy(void* dst, size_t destMax, const void* src, size_t count,
                     aclrtMemcpyKind kind) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMemcpy");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtMemcpy == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit();
  npu_api_trace_hit("aclrtMemcpy");
  continue_with_lock();
  ret = real_aclrtMemcpy(dst, destMax, src, count, kind);
  return ret;
}

aclError aclrtMemcpyAsync(void* dst, size_t destMax, const void* src,
                          size_t count, aclrtMemcpyKind kind,
                          aclrtStream stream) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtMemcpyAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtMemcpyAsync == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream, "aclrtMemcpyAsync");
  npu_api_trace_hit("aclrtMemcpyAsync");
  continue_with_lock();
  ret = real_aclrtMemcpyAsync(dst, destMax, src, count, kind, stream);
  return ret;
}

aclError aclrtSynchronizeDevice(void) {
  aclError ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtSynchronizeDevice");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtSynchronizeDevice == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit();
  npu_api_trace_hit("aclrtSynchronizeDevice");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_aclrtSynchronizeDevice();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == ACL_SUCCESS) {
    maybe_apply_npu_post_sync_quota_sleep("aclrtSynchronizeDevice",
                                          elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "aclrtSynchronizeDevice");
  }
  return ret;
}

aclError aclrtSynchronizeStream(aclrtStream stream) {
  aclError ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtSynchronizeStream");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtSynchronizeStream == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit_for_stream(stream, "aclrtSynchronizeStream");
  npu_api_trace_hit("aclrtSynchronizeStream");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_aclrtSynchronizeStream(stream);
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == ACL_SUCCESS) {
    maybe_apply_npu_post_sync_quota_sleep("aclrtSynchronizeStream",
                                          elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "aclrtSynchronizeStream");
  }
  return ret;
}

rtError_t rtKernelLaunch(const void* stubFunc, uint32_t numBlocks, void* args,
                         uint32_t argsSize, void* smDesc, void* stm) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunch");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunch == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm, "rtKernelLaunch");
  npu_api_trace_hit("rtKernelLaunch");
  npu_active_meter_on_launch((aclrtStream)stm, "rtKernelLaunch");
  continue_with_lock();
  return real_rtKernelLaunch(stubFunc, numBlocks, args, argsSize, smDesc, stm);
}

rtError_t rtDeviceSynchronize(void) {
  rtError_t ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtDeviceSynchronize");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtDeviceSynchronize == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
  npu_api_trace_hit("rtDeviceSynchronize");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_rtDeviceSynchronize();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == RT_ERROR_NONE) {
    maybe_apply_npu_post_sync_quota_sleep("rtDeviceSynchronize", elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "rtDeviceSynchronize");
  }
  return ret;
}

rtError_t rtDeviceSynchronizeWithTimeout(int32_t timeout) {
  rtError_t ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtDeviceSynchronizeWithTimeout");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtDeviceSynchronizeWithTimeout == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
  npu_api_trace_hit("rtDeviceSynchronizeWithTimeout");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_rtDeviceSynchronizeWithTimeout(timeout);
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == RT_ERROR_NONE) {
    maybe_apply_npu_post_sync_quota_sleep("rtDeviceSynchronizeWithTimeout",
                                          elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "rtDeviceSynchronizeWithTimeout");
  }
  return ret;
}

rtError_t rtStreamSynchronize(void* stream) {
  rtError_t ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtStreamSynchronize");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtStreamSynchronize == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stream,
                                          "rtStreamSynchronize");
  npu_api_trace_hit("rtStreamSynchronize");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_rtStreamSynchronize(stream);
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == RT_ERROR_NONE) {
    maybe_apply_npu_post_sync_quota_sleep("rtStreamSynchronize", elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "rtStreamSynchronize");
  }
  return ret;
}

rtError_t rtStreamSynchronizeWithTimeout(void* stream, int32_t timeout) {
  rtError_t ret;
  struct timespec sync_start = {0, 0};
  struct timespec sync_end = {0, 0};
  struct timespec sync_dur = {0, 0};
  long elapsed_ms = 0;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtStreamSynchronizeWithTimeout");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtStreamSynchronizeWithTimeout == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stream,
                                          "rtStreamSynchronizeWithTimeout");
  npu_api_trace_hit("rtStreamSynchronizeWithTimeout");
  continue_with_lock();
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_start) == 0);
  ret = real_rtStreamSynchronizeWithTimeout(stream, timeout);
  true_or_exit(clock_gettime(CLOCK_MONOTONIC, &sync_end) == 0);
  timespecsub(&sync_end, &sync_start, &sync_dur);
  elapsed_ms = (sync_dur.tv_sec * 1000) + (sync_dur.tv_nsec / 1000000);
  if (ret == RT_ERROR_NONE) {
    maybe_apply_npu_post_sync_quota_sleep("rtStreamSynchronizeWithTimeout",
                                          elapsed_ms);
    npu_active_meter_on_sync(elapsed_ms, "rtStreamSynchronizeWithTimeout");
  }
  return ret;
}

rtError_t rtKernelLaunchWithFlag(const void* stubFunc, uint32_t numBlocks,
                                 const void* argsInfo, void* smDesc, void* stm,
                                 uint32_t flags) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunchWithFlag");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunchWithFlag == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtKernelLaunchWithFlag");
  npu_api_trace_hit("rtKernelLaunchWithFlag");
  npu_active_meter_on_launch((aclrtStream)stm, "rtKernelLaunchWithFlag");
  continue_with_lock();
  return real_rtKernelLaunchWithFlag(stubFunc, numBlocks, argsInfo, smDesc, stm,
                                     flags);
}

rtError_t rtKernelLaunchWithFlagV2(const void* stubFunc, uint32_t numBlocks,
                                   const void* argsInfo, void* smDesc,
                                   void* stm, uint32_t flags,
                                   const void* cfgInfo) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunchWithFlagV2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunchWithFlagV2 == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtKernelLaunchWithFlagV2");
  npu_api_trace_hit("rtKernelLaunchWithFlagV2");
  npu_active_meter_on_launch((aclrtStream)stm, "rtKernelLaunchWithFlagV2");
  continue_with_lock();
  return real_rtKernelLaunchWithFlagV2(stubFunc, numBlocks, argsInfo, smDesc,
                                       stm, flags, cfgInfo);
}

rtError_t rtKernelLaunchEx(void* args, uint32_t argsSize, uint32_t flags,
                           void* stm) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunchEx");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunchEx == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtKernelLaunchEx");
  npu_api_trace_hit("rtKernelLaunchEx");
  npu_active_meter_on_launch((aclrtStream)stm, "rtKernelLaunchEx");
  continue_with_lock();
  return real_rtKernelLaunchEx(args, argsSize, flags, stm);
}

rtError_t rtLaunchKernelByFuncHandleV3(void* funcHandle, uint32_t numBlocks,
                                       const void* argsInfo, void* stm,
                                       const void* cfgInfo) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtLaunchKernelByFuncHandleV3");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtLaunchKernelByFuncHandleV3 == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtLaunchKernelByFuncHandleV3");
  npu_api_trace_hit("rtLaunchKernelByFuncHandleV3");
  npu_active_meter_on_launch((aclrtStream)stm,
                             "rtLaunchKernelByFuncHandleV3");
  continue_with_lock();
  return real_rtLaunchKernelByFuncHandleV3(funcHandle, numBlocks, argsInfo, stm,
                                           cfgInfo);
}

rtError_t rtsLaunchKernelWithConfig(void* funcHandle, uint32_t numBlocks,
                                    void* stm, void* cfg, void* argsHandle,
                                    void* reserve) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtsLaunchKernelWithConfig");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtsLaunchKernelWithConfig == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtsLaunchKernelWithConfig");
  npu_api_trace_hit("rtsLaunchKernelWithConfig");
  npu_active_meter_on_launch((aclrtStream)stm, "rtsLaunchKernelWithConfig");
  continue_with_lock();
  return real_rtsLaunchKernelWithConfig(funcHandle, numBlocks, stm, cfg,
                                        argsHandle, reserve);
}

rtError_t rtsLaunchKernelWithDevArgs(void* funcHandle, uint32_t numBlocks,
                                     void* stm, void* cfg, const void* args,
                                     uint32_t argsSize, void* reserve) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtsLaunchKernelWithDevArgs");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtsLaunchKernelWithDevArgs == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtsLaunchKernelWithDevArgs");
  npu_api_trace_hit("rtsLaunchKernelWithDevArgs");
  npu_active_meter_on_launch((aclrtStream)stm, "rtsLaunchKernelWithDevArgs");
  continue_with_lock();
  return real_rtsLaunchKernelWithDevArgs(funcHandle, numBlocks, stm, cfg, args,
                                         argsSize, reserve);
}

rtError_t rtsLaunchKernelWithHostArgs(void* funcHandle, uint32_t numBlocks,
                                      void* stm, void* cfg, void* hostArgs,
                                      uint32_t argsSize,
                                      void* placeHolderArray,
                                      uint32_t placeHolderNum) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtsLaunchKernelWithHostArgs");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtsLaunchKernelWithHostArgs == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtsLaunchKernelWithHostArgs");
  npu_api_trace_hit("rtsLaunchKernelWithHostArgs");
  npu_active_meter_on_launch((aclrtStream)stm, "rtsLaunchKernelWithHostArgs");
  continue_with_lock();
  return real_rtsLaunchKernelWithHostArgs(funcHandle, numBlocks, stm, cfg,
                                          hostArgs, argsSize, placeHolderArray,
                                          placeHolderNum);
}

rtError_t rtVectorCoreKernelLaunch(const void* stubFunc, uint32_t numBlocks,
                                   const void* argsInfo, void* smDesc,
                                   void* stm, uint32_t flags,
                                   const void* cfgInfo) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtVectorCoreKernelLaunch");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtVectorCoreKernelLaunch == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit_for_stream((aclrtStream)stm,
                                          "rtVectorCoreKernelLaunch");
  npu_api_trace_hit("rtVectorCoreKernelLaunch");
  npu_active_meter_on_launch((aclrtStream)stm, "rtVectorCoreKernelLaunch");
  continue_with_lock();
  return real_rtVectorCoreKernelLaunch(stubFunc, numBlocks, argsInfo, smDesc,
                                       stm, flags, cfgInfo);
}

#if defined(__linux__) && defined(__aarch64__)
__asm__(".symver dlsym_217, dlsym@@GLIBC_2.17");
__asm__(".symver dlsym_234, dlsym@GLIBC_2.34");
__asm__(".symver dlsym_225, dlsym@GLIBC_2.2.5");
#elif defined(__linux__)
__asm__(".symver dlsym_225, dlsym@@GLIBC_2.2.5");
__asm__(".symver dlsym_217, dlsym@GLIBC_2.17");
__asm__(".symver dlsym_234, dlsym@GLIBC_2.34");
#endif
