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
#include <strings.h>
#include <string.h>
#include <time.h>
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

#define ENV_XPUSHARE_ENABLE_SINGLE_OVERSUB "XPUSHARE_ENABLE_SINGLE_OVERSUB"
#define ENV_XPUSHARE_NPU_ENABLE_HOOK "XPUSHARE_NPU_ENABLE_HOOK"
#define ENV_XPUSHARE_NPU_ENABLE_CLIENT "XPUSHARE_NPU_ENABLE_CLIENT"
#define ENV_XPUSHARE_NPU_STATIC_CORE_LIMIT "XPUSHARE_NPU_STATIC_CORE_LIMIT"
#define ENV_XPUSHARE_NPU_NATIVE_QUOTA "XPUSHARE_NPU_NATIVE_QUOTA"
#define ENV_XPUSHARE_NPU_STREAM_QUOTA "XPUSHARE_NPU_STREAM_QUOTA"
#define ENV_XPUSHARE_NPU_STREAM_QUOTA_INTERVAL \
  "XPUSHARE_NPU_STREAM_QUOTA_INTERVAL"
#define ENV_XPUSHARE_NPU_API_TRACE "XPUSHARE_NPU_API_TRACE"
#define ENV_XPUSHARE_NPU_CUBE_CORES_TOTAL "XPUSHARE_NPU_CUBE_CORES_TOTAL"
#define ENV_XPUSHARE_NPU_VECTOR_CORES_TOTAL "XPUSHARE_NPU_VECTOR_CORES_TOTAL"
#define ENV_XPUSHARE_NPU_OVERSUB_ALLOC_MODE "XPUSHARE_NPU_OVERSUB_ALLOC_MODE"
#define ENV_XPUSHARE_NPU_MANAGED_FALLBACK "XPUSHARE_NPU_MANAGED_FALLBACK"
#define ENV_XPUSHARE_NPU_MANAGED_WITHCFG "XPUSHARE_NPU_MANAGED_WITHCFG"
#define ENV_XPUSHARE_NPU_MANAGED_ALIGN32 "XPUSHARE_NPU_MANAGED_ALIGN32"
#define ENV_XPUSHARE_NPU_PREFETCH_ENABLE "XPUSHARE_NPU_PREFETCH_ENABLE"
#define ENV_XPUSHARE_NPU_PREFETCH_MIN_BYTES "XPUSHARE_NPU_PREFETCH_MIN_BYTES"
#define ENV_XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE \
  "XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE"

#define MEMINFO_RESERVE_MIB 1536           /* MiB */
#define KERN_SYNC_WINDOW_STEPDOWN_THRESH 1 /* seconds */
#define KERN_SYNC_WINDOW_MAX 2048          /* Pending Kernels */
#define NPU_QUOTA_FAILURE_THRESHOLD 8

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
static int npu_alloc_mode_from_env(const char* value);
static const char* npu_alloc_mode_name(void);
static int npu_managed_mode_enabled(void);
static int npu_should_try_managed_alloc(int exceeds_physical);
static int npu_get_aligned_size(size_t size, int with_padding,
                                size_t* aligned_size);
static void npu_record_managed_fallback(int reason, const char* api_name,
                                        const char* detail);
static unsigned long monotonic_time_ms(void);

static void maybe_select_backend(int backend, const char* trigger) {
  if (xpushare_backend_mode == XPUSHARE_BACKEND_UNKNOWN) {
    xpushare_backend_mode = backend;
    log_info("Selected runtime backend: %s (trigger=%s)",
             xpushare_backend_mode_name(backend), trigger);
    return;
  }

  if (xpushare_backend_mode != backend) {
    log_warn("Ignoring backend switch %s -> %s (trigger=%s)",
             xpushare_backend_mode_name(xpushare_backend_mode),
             xpushare_backend_mode_name(backend), trigger);
  }
}

int xpushare_backend_mode = XPUSHARE_BACKEND_UNKNOWN;

const char* xpushare_backend_mode_name(int mode) {
  switch (mode) {
    case XPUSHARE_BACKEND_CUDA:
      return "cuda";
    case XPUSHARE_BACKEND_NPU:
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

aclrtMalloc_func real_aclrtMalloc = NULL;
aclrtMallocAlign32_func real_aclrtMallocAlign32 = NULL;
aclrtMallocCached_func real_aclrtMallocCached = NULL;
aclrtMallocWithCfg_func real_aclrtMallocWithCfg = NULL;
aclrtFree_func real_aclrtFree = NULL;
aclrtGetMemInfo_func real_aclrtGetMemInfo = NULL;
aclrtSetDevice_func real_aclrtSetDevice = NULL;
aclrtLaunchKernel_func real_aclrtLaunchKernel = NULL;
aclrtMemcpy_func real_aclrtMemcpy = NULL;
aclrtMemcpyAsync_func real_aclrtMemcpyAsync = NULL;
aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice = NULL;
aclrtSynchronizeDeviceWithTimeout_func real_aclrtSynchronizeDeviceWithTimeout =
    NULL;
aclrtSynchronizeStream_func real_aclrtSynchronizeStream = NULL;
aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit = NULL;
aclrtSetStreamResLimit_func real_aclrtSetStreamResLimit = NULL;
aclrtUseStreamResInCurrentThread_func real_aclrtUseStreamResInCurrentThread =
    NULL;
aclrtGetDeviceInfo_func real_aclrtGetDeviceInfo = NULL;
rtMemAllocManaged_func real_rtMemAllocManaged = NULL;
rtMemFreeManaged_func real_rtMemFreeManaged = NULL;
rtMemPrefetchToDevice_func real_rtMemPrefetchToDevice = NULL;
rtMemAdvise_func real_rtMemAdvise = NULL;

size_t xpushare_size_mem_allocatable = 0;
size_t npu_size_mem_allocatable = 0;
size_t sum_allocated = 0;
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

static pthread_mutex_t npu_quota_mutex = PTHREAD_MUTEX_INITIALIZER;
static int npu_native_quota_enabled = 1;
static int npu_stream_quota_enabled = 1;
static int npu_stream_quota_interval = 1;
static int npu_acl_hook_env_checked = 0;
static int npu_acl_hook_env_enabled = 0;
static int npu_client_env_checked = 0;
static int npu_client_env_enabled = 0;
static int npu_static_core_limit = -1;
static int npu_native_quota_fallback = 0;
static int npu_native_quota_failures = 0;
static int npu_stream_quota_failures = 0;
static int npu_applied_core_limit = -1;
static uint32_t npu_applied_cube_cores = 0;
static uint32_t npu_applied_vector_cores = 0;
static int64_t npu_total_cube_cores = 0;
static int64_t npu_total_vector_cores = 0;
static int64_t npu_fallback_cube_cores = 24;
static int64_t npu_fallback_vector_cores = 48;
static unsigned long npu_stream_apply_counter = 0;
static unsigned long npu_device_apply_attempts = 0;
static unsigned long npu_device_apply_success = 0;
static unsigned long npu_device_apply_fail = 0;
static unsigned long npu_stream_apply_attempts = 0;
static unsigned long npu_stream_apply_success = 0;
static unsigned long npu_stream_apply_fail = 0;
static unsigned long npu_native_trigger_calls = 0;
static int npu_native_not_ready_logged = 0;
static int npu_api_trace_enabled = 0;
static int npu_api_trace_env_checked = 0;
static int npu_api_trace_env_enabled = 0;
static unsigned long npu_api_trace_symbol_queries = 0;
static __thread int npu_acl_interpose_bypass = 0;
static int npu_current_device_id = 0;

enum npu_alloc_mode {
  NPU_ALLOC_MODE_ACL = 0,
  NPU_ALLOC_MODE_MANAGED = 1,
  NPU_ALLOC_MODE_AUTO = 2,
};

enum npu_alloc_api {
  NPU_ALLOC_API_ACL_NATIVE = 0,
  NPU_ALLOC_API_RT_MANAGED = 1,
};

enum npu_managed_fallback_reason {
  NPU_MANAGED_FB_SYMBOL_MISSING = 0,
  NPU_MANAGED_FB_ALLOC_FAILED = 1,
  NPU_MANAGED_FB_WITHCFG_DISABLED = 2,
  NPU_MANAGED_FB_CFG_NONNULL = 3,
  NPU_MANAGED_FB_ALIGN32_DISABLED = 4,
  NPU_MANAGED_FB_COUNT = 5,
};

static int npu_oversub_alloc_mode = NPU_ALLOC_MODE_MANAGED;
static int npu_managed_fallback_enabled = 1;
static int npu_managed_withcfg_enabled = 0;
static int npu_managed_align32_enabled = 1;
static int npu_prefetch_enabled = 1;
static size_t npu_prefetch_min_bytes = 32UL * 1024UL * 1024UL;
static unsigned int npu_prefetch_max_ops_per_cycle = 4;
static unsigned long npu_prefetch_cycle = 0;
static time_t npu_prefetch_cycle_sec = 0;
static unsigned long npu_prefetch_ok_total = 0;
static unsigned long npu_prefetch_fail_total = 0;
static unsigned long npu_managed_fallback_total[NPU_MANAGED_FB_COUNT] = {0};
static size_t npu_managed_allocated_bytes = 0;
static size_t npu_native_allocated_bytes = 0;
static size_t npu_managed_peak_allocated_bytes = 0;
static size_t npu_native_peak_allocated_bytes = 0;

static void npu_acl_call_enter(void) { npu_acl_interpose_bypass++; }

static void npu_acl_call_exit(void) {
  if (npu_acl_interpose_bypass > 0) npu_acl_interpose_bypass--;
}

#define ACL_REAL_CALL(call_expr) \
  ({                             \
    aclError _ret;               \
    npu_acl_call_enter();        \
    _ret = (call_expr);          \
    npu_acl_call_exit();         \
    _ret;                        \
  })

#define RT_REAL_CALL(call_expr)  \
  ({                             \
    rtError_t _ret;              \
    npu_acl_call_enter();        \
    _ret = (call_expr);          \
    npu_acl_call_exit();         \
    _ret;                        \
  })

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
struct npu_mem_allocation {
  void* ptr;
  size_t size;
  size_t requested_size;
  size_t effective_size;
  unsigned long alloc_ts_ms;
  uint8_t alloc_api;
  uint8_t prefetch_state;
  struct npu_mem_allocation* next;
};

/* Linked list that holds all memory allocations of current application. */
struct cuda_mem_allocation* cuda_allocation_list = NULL;
struct npu_mem_allocation* npu_allocation_list = NULL;

/* Initializaters will be executed only once per client application */
static pthread_once_t init_libxpushare_done = PTHREAD_ONCE_INIT;
static pthread_once_t init_done = PTHREAD_ONCE_INIT;

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
  void* runtime_handle;

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

  runtime_handle = dlopen("libruntime.so", RTLD_LAZY);
  if (!runtime_handle) {
    runtime_handle = dlopen("libruntime.so.1", RTLD_LAZY);
  }
  if (!runtime_handle) {
    /*
     * Some deployments may export runtime symbols from libascendcl itself.
     * Keep this as a best-effort fallback handle.
     */
    runtime_handle = acl_handle;
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

  LOAD_ACL_SYM(aclrtMalloc);
  LOAD_ACL_SYM(aclrtMallocAlign32);
  LOAD_ACL_SYM(aclrtMallocCached);
  LOAD_ACL_SYM(aclrtMallocWithCfg);
  LOAD_ACL_SYM(aclrtFree);
  LOAD_ACL_SYM(aclrtGetMemInfo);
  LOAD_ACL_SYM(aclrtSetDevice);
  LOAD_ACL_SYM(aclrtLaunchKernel);
  LOAD_ACL_SYM(aclrtMemcpy);
  LOAD_ACL_SYM(aclrtMemcpyAsync);
  LOAD_ACL_SYM(aclrtSynchronizeDevice);
  LOAD_ACL_SYM(aclrtSynchronizeDeviceWithTimeout);
  LOAD_ACL_SYM(aclrtSynchronizeStream);
  LOAD_ACL_SYM(aclrtSetDeviceResLimit);
  LOAD_ACL_SYM(aclrtSetStreamResLimit);
  LOAD_ACL_SYM(aclrtUseStreamResInCurrentThread);
  LOAD_ACL_SYM(aclrtGetDeviceInfo);

#undef LOAD_ACL_SYM

#define LOAD_RT_SYM(name)                                                   \
  do {                                                                      \
    dlerror();                                                              \
    real_##name = (name##_func)real_dlsym_225(runtime_handle, #name);      \
    error = dlerror();                                                      \
    if (error != NULL) {                                                    \
      log_debug("Failed to load runtime symbol %s: %s", #name, error);     \
      real_##name = NULL;                                                   \
    }                                                                       \
  } while (0)

  LOAD_RT_SYM(rtMemAllocManaged);
  LOAD_RT_SYM(rtMemFreeManaged);
  LOAD_RT_SYM(rtMemPrefetchToDevice);
  LOAD_RT_SYM(rtMemAdvise);

#undef LOAD_RT_SYM

  if (real_aclrtMalloc && real_aclrtFree && real_aclrtGetMemInfo &&
      real_aclrtLaunchKernel) {
    acl_ok = 1;
    log_info("ACL runtime hook initialized");
    if (__debug) {
      log_info("ACL symbol ptrs: setDevice=%p wrapper=%p launch=%p wrapper=%p",
               (void*)real_aclrtSetDevice, (void*)&aclrtSetDevice,
               (void*)real_aclrtLaunchKernel, (void*)&aclrtLaunchKernel);
    }
    if (!npu_native_quota_enabled) {
      log_info("Native ACL quota path disabled by env (%s=0)",
               ENV_XPUSHARE_NPU_NATIVE_QUOTA);
    } else if (real_aclrtSetDeviceResLimit == NULL ||
               real_aclrtGetDeviceInfo == NULL) {
      log_warn("Native ACL quota path unavailable (missing "
               "aclrtSetDeviceResLimit/aclrtGetDeviceInfo), fallback to "
               "lock-control");
    } else if (npu_stream_quota_enabled &&
               real_aclrtSetStreamResLimit != NULL &&
               real_aclrtUseStreamResInCurrentThread != NULL) {
      log_info("Native ACL quota tier: stream+device (interval=%d)",
               npu_stream_quota_interval);
    } else {
      log_info("Native ACL quota tier: device-only");
    }

    if (npu_managed_mode_enabled()) {
      if (real_rtMemAllocManaged != NULL && real_rtMemFreeManaged != NULL) {
        log_info("NPU oversub allocation mode=%s (runtime managed path ready)",
                 npu_alloc_mode_name());
      } else {
        log_warn("NPU oversub allocation mode=%s but managed runtime symbols "
                 "are not ready",
                 npu_alloc_mode_name());
      }
    } else {
      log_info("NPU oversub allocation mode=%s (managed path disabled)",
               npu_alloc_mode_name());
    }
  } else {
    log_warn("ACL runtime hook partially initialized, some symbols missing");
  }
}

static int env_switch_default_on(const char* value) {
  if (value == NULL || value[0] == '\0') return 1;
  if (strcmp(value, "0") == 0 || strcasecmp(value, "false") == 0 ||
      strcasecmp(value, "off") == 0 || strcasecmp(value, "no") == 0) {
    return 0;
  }
  return 1;
}

static const char* npu_managed_fallback_reason_name(int reason) {
  switch (reason) {
    case NPU_MANAGED_FB_SYMBOL_MISSING:
      return "symbol_missing";
    case NPU_MANAGED_FB_ALLOC_FAILED:
      return "alloc_failed";
    case NPU_MANAGED_FB_WITHCFG_DISABLED:
      return "withcfg_disabled";
    case NPU_MANAGED_FB_CFG_NONNULL:
      return "cfg_nonnull";
    case NPU_MANAGED_FB_ALIGN32_DISABLED:
      return "align32_disabled";
    default:
      return "unknown";
  }
}

static int npu_alloc_mode_from_env(const char* value) {
  if (value == NULL || value[0] == '\0') return NPU_ALLOC_MODE_AUTO;
  if (strcasecmp(value, "acl") == 0 || strcasecmp(value, "native") == 0) {
    return NPU_ALLOC_MODE_ACL;
  }
  if (strcasecmp(value, "managed") == 0) {
    return NPU_ALLOC_MODE_MANAGED;
  }
  if (strcasecmp(value, "auto") == 0) {
    return NPU_ALLOC_MODE_AUTO;
  }
  return NPU_ALLOC_MODE_AUTO;
}

static const char* npu_alloc_mode_name(void) {
  switch (npu_oversub_alloc_mode) {
    case NPU_ALLOC_MODE_ACL:
      return "acl";
    case NPU_ALLOC_MODE_AUTO:
      return "auto";
    case NPU_ALLOC_MODE_MANAGED:
    default:
      return "managed";
  }
}

static int npu_managed_mode_enabled(void) {
  return (npu_oversub_alloc_mode == NPU_ALLOC_MODE_MANAGED ||
          npu_oversub_alloc_mode == NPU_ALLOC_MODE_AUTO);
}

/*
 * Managed allocation decision:
 * - managed: always try managed
 * - auto: only try managed when current allocation is predicted to exceed
 *         physical allocatable memory
 * - acl: never try managed
 */
static int npu_should_try_managed_alloc(int exceeds_physical) {
  if (npu_oversub_alloc_mode == NPU_ALLOC_MODE_MANAGED) return 1;
  if (npu_oversub_alloc_mode == NPU_ALLOC_MODE_AUTO) return exceeds_physical;
  return 0;
}

static unsigned long monotonic_time_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((unsigned long)ts.tv_sec * 1000UL) +
         ((unsigned long)ts.tv_nsec / 1000000UL);
}

static int npu_get_aligned_size(size_t size, int with_padding,
                                size_t* aligned_size) {
  size_t append_size;
  size_t target;

  if (aligned_size == NULL) return 0;
  if (size == 0) return 0;

  append_size = with_padding ? 64UL : 32UL;
  if ((size + append_size) < size) return 0;
  target = ((size + append_size - 1UL) / 32UL) * 32UL;
  if (target < size) return 0;

  *aligned_size = target;
  return 1;
}

static void npu_record_managed_fallback(int reason, const char* api_name,
                                        const char* detail) {
  unsigned long count = 0;

  if (reason >= 0 && reason < NPU_MANAGED_FB_COUNT) {
    npu_managed_fallback_total[reason]++;
    count = npu_managed_fallback_total[reason];
  }

  if (__debug || count <= 8 || (count % 128) == 0) {
    log_warn("%s managed path fallback: reason=%s count=%lu detail=%s",
             (api_name != NULL) ? api_name : "unknown",
             npu_managed_fallback_reason_name(reason), count,
             (detail != NULL) ? detail : "none");
  }
}

static int npu_acl_hook_enabled(void) {
  if (!npu_acl_hook_env_checked) {
    char* value = getenv(ENV_XPUSHARE_NPU_ENABLE_HOOK);
    npu_acl_hook_env_enabled =
        (value != NULL && value[0] != '\0') ? env_switch_default_on(value) : 1;
    npu_acl_hook_env_checked = 1;
  }

  return npu_acl_hook_env_enabled;
}

static int npu_client_enabled(void) {
  if (!npu_client_env_checked) {
    char* value = getenv(ENV_XPUSHARE_NPU_ENABLE_CLIENT);
    npu_client_env_enabled =
        (value != NULL && value[0] != '\0') ? env_switch_default_on(value) : 1;
    npu_client_env_checked = 1;
  }

  return npu_client_env_enabled;
}

static int npu_effective_core_limit(void) {
  if (npu_static_core_limit >= 1 && npu_static_core_limit <= 100) {
    return npu_static_core_limit;
  }
  return client_core_limit;
}

static int npu_static_core_quota_required(void) {
  int core_limit = npu_effective_core_limit();
  return (core_limit >= 1 && core_limit < 100);
}

static void maybe_init_npu_client(void) {
  if (!npu_client_enabled()) return;
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
}

static void maybe_trace_npu_api(const char* api_name) {
  static unsigned long trace_count = 0;
  int quota_required;
  int core_limit;

  core_limit = npu_effective_core_limit();
  if (npu_client_enabled()) {
    quota_required = xpushare_native_compute_quota_required();
  } else {
    quota_required = npu_static_core_quota_required();
  }

  if (!npu_api_trace_enabled || api_name == NULL) return;
  trace_count++;
  if (trace_count <= 16 || (trace_count % 200) == 0) {
    log_info("NPU API trace #%lu api=%s core_limit=%d quota_required=%d",
             trace_count, api_name, core_limit, quota_required);
  }
}

static int npu_api_trace_active(void) {
  if (!npu_api_trace_env_checked) {
    char* value = getenv(ENV_XPUSHARE_NPU_API_TRACE);
    npu_api_trace_env_enabled =
        (value != NULL && value[0] != '\0') ? env_switch_default_on(value) : 0;
    npu_api_trace_env_checked = 1;
  }

  return npu_api_trace_enabled || npu_api_trace_env_enabled;
}

static void maybe_trace_acl_symbol_query(const char* symbol) {
  if (symbol == NULL || !npu_api_trace_active()) return;
  npu_api_trace_symbol_queries++;
  if (npu_api_trace_symbol_queries <= 256 ||
      (npu_api_trace_symbol_queries % 500) == 0) {
    log_info("quota-observe: dlsym acl symbol=%s", symbol);
  }
}

static uint32_t quota_percent_to_core_count(int core_limit, int64_t total_cores) {
  uint64_t scaled;
  uint32_t target;

  if (total_cores <= 0) return 0;
  if (core_limit >= 100) return (uint32_t)total_cores;
  if (core_limit <= 0) core_limit = 1;

  scaled = (uint64_t)total_cores * (uint64_t)core_limit + 99;
  target = (uint32_t)(scaled / 100);
  if (target == 0) target = 1;
  if ((int64_t)target > total_cores) target = (uint32_t)total_cores;
  return target;
}

static int npu_native_quota_device_ready(void) {
  if (!npu_native_quota_enabled || npu_native_quota_fallback) return 0;
  if (real_aclrtSetDeviceResLimit == NULL) return 0;
  if (real_aclrtGetDeviceInfo == NULL) return 0;
  return 1;
}

static int refresh_npu_core_capacity_locked(void) {
  aclError ret;
  int64_t cube = 0;
  int64_t vector = 0;

  if (npu_total_cube_cores > 0 && npu_total_vector_cores > 0) return 1;
  if (real_aclrtGetDeviceInfo == NULL) return 0;

  ret = ACL_REAL_CALL(real_aclrtGetDeviceInfo(0, ACL_DEV_ATTR_CUBE_CORE_NUM,
                                               &cube));
  if (ret != ACL_SUCCESS || cube <= 0) cube = 0;

  ret = ACL_REAL_CALL(real_aclrtGetDeviceInfo(0, ACL_DEV_ATTR_VECTOR_CORE_NUM,
                                               &vector));
  if (ret != ACL_SUCCESS || vector <= 0) vector = 0;

  if (cube <= 0 && vector <= 0) {
    if (npu_fallback_cube_cores > 0 || npu_fallback_vector_cores > 0) {
      cube = npu_fallback_cube_cores;
      vector = npu_fallback_vector_cores;
      if (cube <= 0) cube = vector;
      if (vector <= 0) vector = cube;
      log_warn("aclrtGetDeviceInfo unavailable, fallback core totals cube=%" PRId64
               " vector=%" PRId64,
               cube, vector);
    } else {
      return 0;
    }
  }
  if (cube <= 0) cube = vector;
  if (vector <= 0) vector = cube;

  npu_total_cube_cores = cube;
  npu_total_vector_cores = vector;
  return 1;
}

static int apply_npu_device_quota_locked(int core_limit) {
  aclError ret;
  uint32_t cube_target;
  uint32_t vector_target;
  int success = 0;

  if (!npu_native_quota_device_ready()) return 0;
  if (npu_applied_core_limit == core_limit) return 1;
  if (!refresh_npu_core_capacity_locked()) return 0;

  cube_target = quota_percent_to_core_count(core_limit, npu_total_cube_cores);
  vector_target =
      quota_percent_to_core_count(core_limit, npu_total_vector_cores);
  if (cube_target == 0 && vector_target == 0) return 0;

  npu_device_apply_attempts++;
  if (cube_target > 0) {
    ret = ACL_REAL_CALL(
        real_aclrtSetDeviceResLimit(0, ACL_RT_DEV_RES_CUBE_CORE, cube_target));
    if (npu_device_apply_attempts <= 8 ||
        (npu_device_apply_attempts % 64) == 0) {
      log_info("quota-observe: aclrtSetDeviceResLimit(CUBE=%u) ret=%d",
               cube_target, ret);
    }
    if (ret == ACL_SUCCESS) {
      success++;
      npu_device_apply_success++;
    } else {
      npu_device_apply_fail++;
      log_warn("aclrtSetDeviceResLimit(CUBE=%u) failed with %d", cube_target,
               ret);
    }
  }

  if (vector_target > 0) {
    ret = ACL_REAL_CALL(real_aclrtSetDeviceResLimit(
        0, ACL_RT_DEV_RES_VECTOR_CORE, vector_target));
    if (npu_device_apply_attempts <= 8 ||
        (npu_device_apply_attempts % 64) == 0) {
      log_info("quota-observe: aclrtSetDeviceResLimit(VECTOR=%u) ret=%d",
               vector_target, ret);
    }
    if (ret == ACL_SUCCESS) {
      success++;
      npu_device_apply_success++;
    } else {
      npu_device_apply_fail++;
      log_warn("aclrtSetDeviceResLimit(VECTOR=%u) failed with %d",
               vector_target, ret);
    }
  }

  if (success == 0) {
    npu_native_quota_failures++;
    if (npu_native_quota_failures >= NPU_QUOTA_FAILURE_THRESHOLD &&
        !npu_native_quota_fallback) {
      npu_native_quota_fallback = 1;
      log_warn("Disable native NPU quota path after %d consecutive failures; "
               "falling back to scheduler lock-control",
               npu_native_quota_failures);
    }
    return 0;
  }

  npu_native_quota_failures = 0;
  npu_applied_core_limit = core_limit;
  npu_applied_cube_cores = cube_target;
  npu_applied_vector_cores = vector_target;
  log_info("Applied native NPU quota: core=%d%% -> cube=%u/%" PRId64
           ", vector=%u/%" PRId64,
           core_limit, npu_applied_cube_cores, npu_total_cube_cores,
           npu_applied_vector_cores, npu_total_vector_cores);
  return 1;
}

static void maybe_apply_npu_stream_quota_locked(aclrtStream stream) {
  aclError ret;
  int failed = 0;

  if (!npu_stream_quota_enabled) return;
  if (stream == NULL) return;
  if (real_aclrtSetStreamResLimit == NULL ||
      real_aclrtUseStreamResInCurrentThread == NULL) {
    return;
  }
  if (npu_applied_core_limit < 0 || npu_applied_core_limit >= 100) return;

  if (npu_stream_quota_interval > 1) {
    npu_stream_apply_counter++;
  if ((npu_stream_apply_counter %
         (unsigned long)npu_stream_quota_interval) != 0) {
      return;
    }
  }

  npu_stream_apply_attempts++;
  if (npu_applied_cube_cores > 0) {
    ret = ACL_REAL_CALL(real_aclrtSetStreamResLimit(
        stream, ACL_RT_DEV_RES_CUBE_CORE, npu_applied_cube_cores));
    if (ret != ACL_SUCCESS) {
      failed = 1;
      npu_stream_apply_fail++;
      log_debug("aclrtSetStreamResLimit(CUBE=%u) failed with %d",
                npu_applied_cube_cores, ret);
    } else if (npu_api_trace_enabled &&
               (npu_stream_apply_attempts <= 8 ||
                (npu_stream_apply_attempts % 128) == 0)) {
      log_info("quota-observe: aclrtSetStreamResLimit(CUBE=%u) ret=%d",
               npu_applied_cube_cores, ret);
    }
  }

  if (npu_applied_vector_cores > 0) {
    ret = ACL_REAL_CALL(real_aclrtSetStreamResLimit(
        stream, ACL_RT_DEV_RES_VECTOR_CORE, npu_applied_vector_cores));
    if (ret != ACL_SUCCESS) {
      failed = 1;
      npu_stream_apply_fail++;
      log_debug("aclrtSetStreamResLimit(VECTOR=%u) failed with %d",
                npu_applied_vector_cores, ret);
    } else if (npu_api_trace_enabled &&
               (npu_stream_apply_attempts <= 8 ||
                (npu_stream_apply_attempts % 128) == 0)) {
      log_info("quota-observe: aclrtSetStreamResLimit(VECTOR=%u) ret=%d",
               npu_applied_vector_cores, ret);
    }
  }

  ret = ACL_REAL_CALL(real_aclrtUseStreamResInCurrentThread(stream));
  if (ret != ACL_SUCCESS) {
    failed = 1;
    npu_stream_apply_fail++;
    log_debug("aclrtUseStreamResInCurrentThread failed with %d", ret);
  } else if (npu_api_trace_enabled &&
             (npu_stream_apply_attempts <= 8 ||
              (npu_stream_apply_attempts % 128) == 0)) {
    log_info("quota-observe: aclrtUseStreamResInCurrentThread ret=%d", ret);
  }

  if (!failed) {
    npu_stream_quota_failures = 0;
    npu_stream_apply_success++;
    return;
  }

  npu_stream_quota_failures++;
  if (npu_stream_quota_failures >= NPU_QUOTA_FAILURE_THRESHOLD) {
    npu_stream_quota_enabled = 0;
    log_warn("Disable NPU stream quota path after %d failures; continue with "
             "device-level quota only",
             npu_stream_quota_failures);
  }
}

/*
 * Try native ACL compute quota control first for compute-only quota case.
 * Return 1 if native path is active and call sites should skip lock-control.
 * Return 0 to indicate caller should use legacy lock-control fallback.
 */
static int apply_npu_native_compute_quota(aclrtStream stream,
                                          const char* trigger_api) {
  int should_use_native = xpushare_native_compute_quota_required();

  pthread_mutex_lock(&npu_quota_mutex);

  if (!should_use_native) {
    if (npu_applied_core_limit >= 0 && npu_applied_core_limit != 100 &&
        npu_native_quota_device_ready()) {
      (void)apply_npu_device_quota_locked(100);
    }
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  npu_native_trigger_calls++;
  if (npu_native_trigger_calls <= 16 ||
      (npu_native_trigger_calls % 200) == 0) {
    log_info("quota-observe: native-quota trigger api=%s core=%d stream=%p",
             (trigger_api != NULL) ? trigger_api : "unknown", client_core_limit,
             stream);
  }

  if (!npu_native_quota_device_ready()) {
    if (!npu_native_not_ready_logged || npu_api_trace_enabled) {
      log_warn("Native quota skipped at api=%s: device quota path not ready",
               (trigger_api != NULL) ? trigger_api : "unknown");
      npu_native_not_ready_logged = 1;
    }
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  if (!apply_npu_device_quota_locked(client_core_limit)) {
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  maybe_apply_npu_stream_quota_locked(stream);
  pthread_mutex_unlock(&npu_quota_mutex);
  return 1;
}

/*
 * Static NPU quota path used when hook is enabled but client thread is
 * disabled. Core limit is sourced from ENV_XPUSHARE_NPU_STATIC_CORE_LIMIT.
 */
static int apply_npu_static_compute_quota(aclrtStream stream,
                                          const char* trigger_api) {
  int core_limit;

  pthread_mutex_lock(&npu_quota_mutex);
  core_limit = npu_effective_core_limit();

  if (!(core_limit >= 1 && core_limit < 100)) {
    if (npu_applied_core_limit >= 0 && npu_applied_core_limit != 100 &&
        npu_native_quota_device_ready()) {
      (void)apply_npu_device_quota_locked(100);
    }
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  if (!npu_native_quota_device_ready()) {
    if (!npu_native_not_ready_logged || npu_api_trace_enabled) {
      log_warn("Static native quota skipped at api=%s: device quota path not ready",
               (trigger_api != NULL) ? trigger_api : "unknown");
      npu_native_not_ready_logged = 1;
    }
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  if (!apply_npu_device_quota_locked(core_limit)) {
    pthread_mutex_unlock(&npu_quota_mutex);
    return 0;
  }

  maybe_apply_npu_stream_quota_locked(stream);
  pthread_mutex_unlock(&npu_quota_mutex);
  return 1;
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

static void npu_on_allocation_added(int alloc_api, size_t effective_size) {
  if (alloc_api == NPU_ALLOC_API_RT_MANAGED) {
    npu_managed_allocated_bytes += effective_size;
    if (npu_managed_allocated_bytes > npu_managed_peak_allocated_bytes) {
      npu_managed_peak_allocated_bytes = npu_managed_allocated_bytes;
    }
  } else {
    npu_native_allocated_bytes += effective_size;
    if (npu_native_allocated_bytes > npu_native_peak_allocated_bytes) {
      npu_native_peak_allocated_bytes = npu_native_allocated_bytes;
    }
  }
}

static void npu_on_allocation_removed(int alloc_api, size_t effective_size) {
  if (alloc_api == NPU_ALLOC_API_RT_MANAGED) {
    if (npu_managed_allocated_bytes >= effective_size) {
      npu_managed_allocated_bytes -= effective_size;
    } else {
      npu_managed_allocated_bytes = 0;
    }
  } else {
    if (npu_native_allocated_bytes >= effective_size) {
      npu_native_allocated_bytes -= effective_size;
    } else {
      npu_native_allocated_bytes = 0;
    }
  }
}

/* Append a new ACL/NPU memory allocation at the end of the list. */
static void insert_npu_allocation(void* ptr, size_t requested_size,
                                  size_t effective_size, int alloc_api) {
  struct npu_mem_allocation* allocation;

  sum_allocated += effective_size;
  npu_on_allocation_added(alloc_api, effective_size);
  log_debug("Total allocated memory on NPU is %.2f MiB (managed=%.2f MiB, "
            "native=%.2f MiB)",
            toMiB(sum_allocated), toMiB(npu_managed_allocated_bytes),
            toMiB(npu_native_allocated_bytes));

  true_or_exit(allocation = malloc(sizeof(*allocation)));
  allocation->ptr = ptr;
  allocation->size = effective_size;
  allocation->requested_size = requested_size;
  allocation->effective_size = effective_size;
  allocation->alloc_ts_ms = monotonic_time_ms();
  allocation->alloc_api = (uint8_t)alloc_api;
  allocation->prefetch_state = 0;
  allocation->next = NULL;
  LL_APPEND(npu_allocation_list, allocation);

  report_memory_usage_to_scheduler(sum_allocated);
}

/* Remove an ACL/NPU memory allocation by pointer. */
static int remove_npu_allocation(void* rm_ptr, int* out_alloc_api) {
  struct npu_mem_allocation *tmp, *a;

  LL_FOREACH_SAFE(npu_allocation_list, a, tmp) {
    if (a->ptr == rm_ptr) {
      if (sum_allocated >= a->effective_size) {
        sum_allocated -= a->effective_size;
      } else {
        sum_allocated = 0;
      }
      npu_on_allocation_removed((int)a->alloc_api, a->effective_size);
      log_debug("Total allocated memory on NPU is %.2f MiB (managed=%.2f MiB, "
                "native=%.2f MiB)",
                toMiB(sum_allocated), toMiB(npu_managed_allocated_bytes),
                toMiB(npu_native_allocated_bytes));
      LL_DELETE(npu_allocation_list, a);
      if (out_alloc_api != NULL) *out_alloc_api = (int)a->alloc_api;
      free(a);
      report_memory_usage_to_scheduler(sum_allocated);
      return 1;
    }
  }

  return 0;
}

static int peek_npu_allocation_api(void* ptr, int* out_alloc_api) {
  struct npu_mem_allocation* a;

  LL_FOREACH(npu_allocation_list, a) {
    if (a->ptr != ptr) continue;
    if (out_alloc_api != NULL) *out_alloc_api = (int)a->alloc_api;
    return 1;
  }
  return 0;
}

static int npu_managed_path_ready(void) {
  return (real_rtMemAllocManaged != NULL && real_rtMemFreeManaged != NULL);
}

static int npu_try_managed_alloc(void** devPtr, size_t requested_size,
                                 size_t effective_size, int exceeds_physical,
                                 const char* api_name) {
  rtError_t rt_err;

  if (!npu_should_try_managed_alloc(exceeds_physical)) return 0;

  if (!npu_managed_path_ready()) {
    npu_record_managed_fallback(NPU_MANAGED_FB_SYMBOL_MISSING, api_name,
                                "rtMemAllocManaged/rtMemFreeManaged missing");
    if (!npu_managed_fallback_enabled) return -1;
    return 0;
  }

  if (devPtr == NULL) return -1;
  *devPtr = NULL;
  rt_err = RT_REAL_CALL(real_rtMemAllocManaged(
      devPtr, (uint64_t)effective_size, RT_MEMORY_SVM, (uint16_t)0));
  if (rt_err == RT_SUCCESS && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, requested_size, effective_size,
                          NPU_ALLOC_API_RT_MANAGED);
    if (__debug) {
      log_info("%s managed alloc success ptr=%p requested=%zu effective=%zu",
               (api_name != NULL) ? api_name : "npu_alloc", *devPtr,
               requested_size, effective_size);
    }
    return 1;
  }

  npu_record_managed_fallback(NPU_MANAGED_FB_ALLOC_FAILED, api_name,
                              "rtMemAllocManaged returned error");
  if (!npu_managed_fallback_enabled) {
    if (__debug) {
      log_warn("%s managed alloc failed strict mode rt_err=%d ptr=%p",
               (api_name != NULL) ? api_name : "npu_alloc", rt_err,
               (devPtr != NULL) ? *devPtr : NULL);
    }
    return -1;
  }
  return 0;
}

static void npu_reset_prefetch_cycle_if_needed(time_t now_sec) {
  struct npu_mem_allocation* a;
  if (now_sec == npu_prefetch_cycle_sec) return;
  npu_prefetch_cycle_sec = now_sec;
  npu_prefetch_cycle = 0;
  LL_FOREACH(npu_allocation_list, a) { a->prefetch_state = 0; }
}

static void npu_prefetch_managed_allocations(void) {
  struct npu_mem_allocation* a;
  rtError_t rt_err;
  time_t now_sec;

  if (!npu_prefetch_enabled) return;
  if (!npu_managed_mode_enabled()) return;
  if (real_rtMemPrefetchToDevice == NULL) return;
  if (npu_prefetch_max_ops_per_cycle == 0) return;

  now_sec = time(NULL);
  npu_reset_prefetch_cycle_if_needed(now_sec);
  if (npu_prefetch_cycle >= npu_prefetch_max_ops_per_cycle) return;

  LL_FOREACH(npu_allocation_list, a) {
    if (a->alloc_api != NPU_ALLOC_API_RT_MANAGED) continue;
    if (a->prefetch_state != 0) continue;
    if (a->effective_size < npu_prefetch_min_bytes) continue;
    if (npu_prefetch_cycle >= npu_prefetch_max_ops_per_cycle) break;

    rt_err = RT_REAL_CALL(real_rtMemPrefetchToDevice(
        a->ptr, (uint64_t)a->effective_size, npu_current_device_id));
    npu_prefetch_cycle++;
    if (rt_err == RT_SUCCESS) {
      a->prefetch_state = 1;
      npu_prefetch_ok_total++;
      if (__debug) {
        log_debug("NPU managed prefetch ok ptr=%p size=%zu dev=%d", a->ptr,
                  a->effective_size, npu_current_device_id);
      }
    } else {
      npu_prefetch_fail_total++;
      if (__debug || npu_prefetch_fail_total <= 8 ||
          (npu_prefetch_fail_total % 128) == 0) {
        log_warn("NPU managed prefetch failed ptr=%p size=%zu dev=%d rt_err=%d",
                 a->ptr, a->effective_size, npu_current_device_id, rt_err);
      }
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

  if (xpushare_backend_mode != XPUSHARE_BACKEND_CUDA) {
    log_debug("swap_out_all_allocations: no-op for backend=%s",
              xpushare_backend_mode_name(xpushare_backend_mode));
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

  if (xpushare_backend_mode != XPUSHARE_BACKEND_CUDA) return;

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
static void initialize_libxpushare(void) {
  char* value;
  value = getenv(ENV_XPUSHARE_DEBUG);
  if (value != NULL) __debug = 1;
  value = getenv(ENV_XPUSHARE_ENABLE_SINGLE_OVERSUB);
  if (value != NULL) {
    enable_single_oversub = 1;
    log_warn(
        "Enabling GPU memory oversubscription for this"
        " application");
  }

  value = getenv(ENV_XPUSHARE_NPU_NATIVE_QUOTA);
  npu_native_quota_enabled = env_switch_default_on(value);

  value = getenv(ENV_XPUSHARE_NPU_STREAM_QUOTA);
  npu_stream_quota_enabled = env_switch_default_on(value);

  if (!npu_acl_hook_enabled()) {
    log_info("NPU ACL hook path disabled by env (%s=0)",
             ENV_XPUSHARE_NPU_ENABLE_HOOK);
  } else if (!npu_client_enabled()) {
    log_info("NPU hook enabled without client thread (%s=0)",
             ENV_XPUSHARE_NPU_ENABLE_CLIENT);
  }

  value = getenv(ENV_XPUSHARE_NPU_STATIC_CORE_LIMIT);
  if (value != NULL && value[0] != '\0') {
    int parsed_limit = atoi(value);
    if (parsed_limit >= 1 && parsed_limit <= 100) {
      npu_static_core_limit = parsed_limit;
      log_info("NPU static core limit configured: %d%%", npu_static_core_limit);
    } else {
      log_warn("Ignore invalid %s=%s (expect 1..100)",
               ENV_XPUSHARE_NPU_STATIC_CORE_LIMIT, value);
    }
  }

  value = getenv(ENV_XPUSHARE_NPU_STREAM_QUOTA_INTERVAL);
  if (value != NULL && value[0] != '\0') {
    int parsed_interval = atoi(value);
    if (parsed_interval >= 1) {
      npu_stream_quota_interval = parsed_interval;
    }
  }

  value = getenv(ENV_XPUSHARE_NPU_API_TRACE);
  npu_api_trace_enabled =
      (value != NULL && value[0] != '\0') ? env_switch_default_on(value) : 0;

  value = getenv(ENV_XPUSHARE_NPU_CUBE_CORES_TOTAL);
  if (value != NULL && value[0] != '\0') {
    int64_t parsed = (int64_t)atoll(value);
    if (parsed > 0) npu_fallback_cube_cores = parsed;
  }

  value = getenv(ENV_XPUSHARE_NPU_VECTOR_CORES_TOTAL);
  if (value != NULL && value[0] != '\0') {
    int64_t parsed = (int64_t)atoll(value);
    if (parsed > 0) npu_fallback_vector_cores = parsed;
  }

  value = getenv(ENV_XPUSHARE_NPU_OVERSUB_ALLOC_MODE);
  npu_oversub_alloc_mode = npu_alloc_mode_from_env(value);

  value = getenv(ENV_XPUSHARE_NPU_MANAGED_FALLBACK);
  npu_managed_fallback_enabled = env_switch_default_on(value);

  value = getenv(ENV_XPUSHARE_NPU_MANAGED_WITHCFG);
  if (value != NULL && value[0] != '\0') {
    npu_managed_withcfg_enabled = env_switch_default_on(value);
  }

  value = getenv(ENV_XPUSHARE_NPU_MANAGED_ALIGN32);
  npu_managed_align32_enabled = env_switch_default_on(value);

  value = getenv(ENV_XPUSHARE_NPU_PREFETCH_ENABLE);
  npu_prefetch_enabled = env_switch_default_on(value);

  value = getenv(ENV_XPUSHARE_NPU_PREFETCH_MIN_BYTES);
  if (value != NULL && value[0] != '\0') {
    char* endptr = NULL;
    unsigned long long parsed = strtoull(value, &endptr, 10);
    if (endptr != value && parsed > 0ULL) {
      npu_prefetch_min_bytes = (size_t)parsed;
    } else {
      log_warn("Ignore invalid %s=%s", ENV_XPUSHARE_NPU_PREFETCH_MIN_BYTES, value);
    }
  }

  value = getenv(ENV_XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE);
  if (value != NULL && value[0] != '\0') {
    int parsed = atoi(value);
    if (parsed >= 0) {
      npu_prefetch_max_ops_per_cycle = (unsigned int)parsed;
    } else {
      log_warn("Ignore invalid %s=%s",
               ENV_XPUSHARE_NPU_PREFETCH_MAX_OPS_PER_CYCLE, value);
    }
  }

  log_info("NPU oversub mode=%s managed_fallback=%d withcfg=%d align32=%d "
           "prefetch=%d prefetch_min=%zu prefetch_ops=%u",
           npu_alloc_mode_name(), npu_managed_fallback_enabled,
           npu_managed_withcfg_enabled, npu_managed_align32_enabled,
           npu_prefetch_enabled,
           npu_prefetch_min_bytes, npu_prefetch_max_ops_per_cycle);

  /* GPU Memory Limit Configuration */
  value = getenv("XPUSHARE_GPU_MEMORY_LIMIT");
  if (value != NULL) {
    memory_limit = parse_memory_size(value);
    log_info("GPU memory limit set to %zu bytes (%.2f GiB)", memory_limit,
             (double)memory_limit / (1024.0 * 1024.0 * 1024.0));
  }

  /* Adaptive Window Configuration */
  value = getenv("XPUSHARE_KERN_SYNC_DURATION_BIG");
  if (value) kern_sync_duration_big = atoi(value);

  value = getenv("XPUSHARE_KERN_WINDOW_MIN_FLOOR");
  if (value) kern_window_min_floor = atoi(value);

  value = getenv("XPUSHARE_KERN_WARMUP_PERIOD_SEC");
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
 * Since we're interposing dlsym() in libxpushare, we use dlvsym() to obtain the
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
  if (!npu_acl_hook_enabled()) return NULL;

  /*
   * NPU ACL interposition is controlled by XPUSHARE_NPU_ENABLE_HOOK.
   * When enabled, expose allocator and compute hooks so callers resolving ACL
   * symbols via dlsym() (e.g. ctypes) still hit xpushare wrappers.
   */
  if (strcmp(symbol, "aclrtMalloc") == 0) {
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
  } else if (strcmp(symbol, "aclrtSetDevice") == 0) {
    return (void*)(&aclrtSetDevice);
  } else if (strcmp(symbol, "aclrtSynchronizeDevice") == 0) {
    return (void*)(&aclrtSynchronizeDevice);
  } else if (strcmp(symbol, "aclrtSynchronizeStream") == 0) {
    return (void*)(&aclrtSynchronizeStream);
  } else if (strcmp(symbol, "aclrtLaunchKernel") == 0) {
    return (void*)(&aclrtLaunchKernel);
  } else if (strcmp(symbol, "aclrtMemcpy") == 0) {
    return (void*)(&aclrtMemcpy);
  } else if (strcmp(symbol, "aclrtMemcpyAsync") == 0) {
    return (void*)(&aclrtMemcpyAsync);
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
    if (!npu_acl_interpose_bypass) {
      maybe_trace_acl_symbol_query(symbol);
      resolved = resolve_acl_symbol(symbol);
      if (resolved != NULL) return resolved;
    }
  }

  return (real_dlsym_225(handle, symbol));
}

void* dlsym_217(void* handle, const char* symbol) {
  void* resolved;

  if (strncmp(symbol, "cu", 2) == 0) {
    resolved = resolve_cuda_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "acl", 3) == 0) {
    if (!npu_acl_interpose_bypass) {
      maybe_trace_acl_symbol_query(symbol);
      resolved = resolve_acl_symbol(symbol);
      if (resolved != NULL) return resolved;
    }
  }

  return (real_dlsym_217(handle, symbol));
}

void* dlsym_234(void* handle, const char* symbol) {
  void* resolved;

  if (strncmp(symbol, "cu", 2) == 0) {
    resolved = resolve_cuda_symbol(symbol);
    if (resolved != NULL) return resolved;
  } else if (strncmp(symbol, "acl", 3) == 0) {
    if (!npu_acl_interpose_bypass) {
      maybe_trace_acl_symbol_query(symbol);
      resolved = resolve_acl_symbol(symbol);
      if (resolved != NULL) return resolved;
    }
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
  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuGetProcAddress");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
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
  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuGetProcAddress_v2");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemAlloc");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  /* Return immediately if not initialized */
  if (real_cuMemAllocManaged == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  if (got_max_mem_size == 0) {
    result = cuMemGetInfo(&xpushare_size_mem_allocatable, &junk);
    cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemGetInfo));
    got_max_mem_size = 1;
  }

  if (!check_allocation_limit(bytesize, "cuMemAlloc", &exceeds_physical,
                              xpushare_size_mem_allocatable)) {
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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemFree");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_cuMemFree == NULL) return CUDA_ERROR_NOT_INITIALIZED;
  result = real_cuMemFree(dptr);
  if (result == CUDA_SUCCESS) remove_cuda_allocation(dptr);

  return result;
}

CUresult cuMemGetInfo(size_t* free, size_t* total) {
  long long reserve_mib;
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemGetInfo");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  /* Return immediately if not initialized */
  if (real_cuMemGetInfo == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  result = real_cuMemGetInfo(free, total);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemGetInfo));

  log_debug("real_cuMemGetInfo returned free=%.2f MiB, total=%.2f MiB",
            toMiB(*free), toMiB(*total));

  /* If user specified a memory limit, report that as total/free */
  if (memory_limit > 0) {
    *total = memory_limit;
    *free = (memory_limit > sum_allocated) ? (memory_limit - sum_allocated) : 0;
    log_debug(
        "xpushare's cuMemGetInfo (with limit): free=%.2f MiB, total=%.2f MiB",
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
      "xpushare's cuMemGetInfo returning free=%.2f MiB,"
      " total=%.2f MiB",
      toMiB(*free), toMiB(*total));
  return result;
}

/*
 * A call to cuInit is an indicator that the present application is a CUDA
 * application and that we should bootstrap xpushare.
 */
CUresult cuInit(unsigned int flags) {
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuInit");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuLaunchKernel");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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
   * For xpushare, this means that they would still have pending kernels
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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpy");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_cuMemcpy == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpy(dst, src, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpy));

  return result;
}

CUresult cuMemcpyAsync(CUdeviceptr dst, CUdeviceptr src, size_t ByteCount,
                       CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyAsync");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_cuMemcpyAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpyAsync(dst, src, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyAsync));

  return result;
}

CUresult cuMemcpyDtoH(void* dstHost, CUdeviceptr srcDevice, size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyDtoH");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyDtoHAsync");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyHtoD");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyHtoDAsync");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyDtoD");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(XPUSHARE_BACKEND_CUDA, "cuMemcpyDtoDAsync");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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
  if (ACL_REAL_CALL(real_aclrtGetMemInfo(ACL_HBM_MEM, &free_mem, &total_mem)) !=
      ACL_SUCCESS) {
    return 0;
  }

  *allocatable_out = free_mem;
  return 1;
}

static int npu_get_effective_alloc_size(size_t requested_size, int with_padding,
                                        size_t* effective_size) {
  if (effective_size == NULL) return 0;
  if (requested_size == 0) {
    *effective_size = 0;
    return 1;
  }
  return npu_get_aligned_size(requested_size, with_padding, effective_size);
}

static aclError acl_malloc_common(void** devPtr, size_t requested_size,
                                  size_t effective_size,
                                  aclrtMemMallocPolicy policy,
                                  aclrtMalloc_func malloc_fn,
                                  const char* api_name,
                                  int allow_managed) {
  int managed_ret;
  int exceeds_physical = 0;
  aclError ret;

  if (malloc_fn == NULL) return ACL_ERROR_UNINITIALIZE;
  if (requested_size == 0 || devPtr == NULL) {
    return ACL_REAL_CALL(malloc_fn(devPtr, requested_size, policy));
  }
  if (!check_allocation_limit(effective_size, api_name, &exceeds_physical,
                              npu_size_mem_allocatable)) {
    return ACL_ERROR_BAD_ALLOC;
  }
  if (exceeds_physical) {
    log_warn("%s exceeds physical NPU memory; oversub mode enabled", api_name);
  }

  if (allow_managed) {
    managed_ret = npu_try_managed_alloc(devPtr, requested_size, effective_size,
                                        exceeds_physical, api_name);
    if (managed_ret > 0) return ACL_SUCCESS;
    if (managed_ret < 0) return ACL_ERROR_BAD_ALLOC;
  } else if (exceeds_physical && npu_managed_mode_enabled()) {
    npu_record_managed_fallback(NPU_MANAGED_FB_ALIGN32_DISABLED, api_name,
                                "managed path disabled for this API");
  }

  ret = ACL_REAL_CALL(malloc_fn(devPtr, requested_size, policy));
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, requested_size, effective_size,
                          NPU_ALLOC_API_ACL_NATIVE);
    return ret;
  }

  /*
   * Auto mode fallback:
   * If native ACL allocation failed before we could predict physical overflow
   * (e.g. stale allocatable snapshot), retry once with managed path.
   */
  if (ret != ACL_SUCCESS && devPtr != NULL && allow_managed &&
      npu_oversub_alloc_mode == NPU_ALLOC_MODE_AUTO &&
      enable_single_oversub != 0) {
    if (__debug) {
      log_warn("%s auto fallback: native alloc ret=%d, retry managed",
               (api_name != NULL) ? api_name : "acl_malloc_common", ret);
    }
    managed_ret = npu_try_managed_alloc(devPtr, requested_size, effective_size,
                                        1, api_name);
    if (managed_ret > 0) return ACL_SUCCESS;
    if (managed_ret < 0) return ACL_ERROR_BAD_ALLOC;
  }

  return ret;
}

aclError aclrtMalloc(void** devPtr, size_t size, aclrtMemMallocPolicy policy) {
  size_t effective_size = 0;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMalloc");
  maybe_trace_npu_api("aclrtMalloc");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMalloc == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMalloc(devPtr, size, policy));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtMalloc == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMalloc(devPtr, size, policy));
  }
  if (real_aclrtMalloc == NULL) return ACL_ERROR_UNINITIALIZE;

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }
  if (!npu_get_effective_alloc_size(size, 1, &effective_size)) {
    log_warn("aclrtMalloc invalid size=%zu for alignment", size);
    return ACL_ERROR_BAD_ALLOC;
  }

  return acl_malloc_common(devPtr, size, effective_size, policy, real_aclrtMalloc,
                           "aclrtMalloc", 1);
}

aclError aclrtMallocAlign32(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy) {
  size_t effective_size = 0;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMallocAlign32");
  maybe_trace_npu_api("aclrtMallocAlign32");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMallocAlign32 == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocAlign32(devPtr, size, policy));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtMallocAlign32 == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocAlign32(devPtr, size, policy));
  }
  if (real_aclrtMallocAlign32 == NULL) return ACL_ERROR_UNINITIALIZE;

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }
  if (!npu_get_effective_alloc_size(size, 0, &effective_size)) {
    log_warn("aclrtMallocAlign32 invalid size=%zu for alignment", size);
    return ACL_ERROR_BAD_ALLOC;
  }

  return acl_malloc_common(devPtr, size, effective_size, policy,
                           real_aclrtMallocAlign32, "aclrtMallocAlign32",
                           npu_managed_align32_enabled);
}

aclError aclrtMallocCached(void** devPtr, size_t size,
                           aclrtMemMallocPolicy policy) {
  size_t effective_size = 0;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMallocCached");
  maybe_trace_npu_api("aclrtMallocCached");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMallocCached == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocCached(devPtr, size, policy));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtMallocCached == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocCached(devPtr, size, policy));
  }
  if (real_aclrtMallocCached == NULL) return ACL_ERROR_UNINITIALIZE;

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }
  if (!npu_get_effective_alloc_size(size, 1, &effective_size)) {
    log_warn("aclrtMallocCached invalid size=%zu for alignment", size);
    return ACL_ERROR_BAD_ALLOC;
  }

  return acl_malloc_common(devPtr, size, effective_size, policy,
                           real_aclrtMallocCached, "aclrtMallocCached", 1);
}

aclError aclrtMallocWithCfg(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy, void* cfg) {
  int managed_ret;
  int exceeds_physical = 0;
  size_t effective_size = size;
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMallocWithCfg");
  maybe_trace_npu_api("aclrtMallocWithCfg");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMallocWithCfg == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocWithCfg(devPtr, size, policy, cfg));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtMallocWithCfg == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMallocWithCfg(devPtr, size, policy, cfg));
  }
  if (real_aclrtMallocWithCfg == NULL) return ACL_ERROR_UNINITIALIZE;
  if (size == 0 || devPtr == NULL) {
    return ACL_REAL_CALL(real_aclrtMallocWithCfg(devPtr, size, policy, cfg));
  }

  if (npu_size_mem_allocatable == 0) {
    size_t allocatable = 0;
    if (ensure_npu_physical_cap(&allocatable)) {
      npu_size_mem_allocatable = allocatable;
    }
  }

  if (!check_allocation_limit(effective_size, "aclrtMallocWithCfg",
                              &exceeds_physical,
                              npu_size_mem_allocatable)) {
    return ACL_ERROR_BAD_ALLOC;
  }
  if (exceeds_physical) {
    log_warn(
        "aclrtMallocWithCfg exceeds physical NPU memory; oversub mode enabled");
  }

  if (npu_managed_mode_enabled()) {
    if (!npu_managed_withcfg_enabled) {
      npu_record_managed_fallback(
          NPU_MANAGED_FB_WITHCFG_DISABLED, "aclrtMallocWithCfg",
          "managed withcfg path disabled");
    } else if (cfg != NULL) {
      npu_record_managed_fallback(NPU_MANAGED_FB_CFG_NONNULL,
                                  "aclrtMallocWithCfg", "cfg is not NULL");
      if (!npu_managed_fallback_enabled) return ACL_ERROR_BAD_ALLOC;
    } else {
      log_info("NPU managed path enabled for aclrtMallocWithCfg");
      managed_ret =
          npu_try_managed_alloc(devPtr, size, effective_size, exceeds_physical,
                                "aclrtMallocWithCfg");
      if (managed_ret > 0) return ACL_SUCCESS;
      if (managed_ret < 0) return ACL_ERROR_BAD_ALLOC;
    }
  }

  ret = ACL_REAL_CALL(real_aclrtMallocWithCfg(devPtr, size, policy, cfg));
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, size, effective_size,
                          NPU_ALLOC_API_ACL_NATIVE);
  }

  return ret;
}

aclError aclrtFree(void* devPtr) {
  int tracked_alloc_api = NPU_ALLOC_API_ACL_NATIVE;
  int has_tracked_alloc = 0;
  rtError_t rt_err = RT_SUCCESS;
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtFree");
  maybe_trace_npu_api("aclrtFree");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtFree == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtFree(devPtr));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtFree == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtFree(devPtr));
  }
  if (real_aclrtFree == NULL) return ACL_ERROR_UNINITIALIZE;
  has_tracked_alloc = peek_npu_allocation_api(devPtr, &tracked_alloc_api);

  if (has_tracked_alloc && tracked_alloc_api == NPU_ALLOC_API_RT_MANAGED) {
    if (real_rtMemFreeManaged == NULL) {
      npu_record_managed_fallback(NPU_MANAGED_FB_SYMBOL_MISSING, "aclrtFree",
                                  "rtMemFreeManaged missing");
      if (!npu_managed_fallback_enabled) return ACL_ERROR_BAD_ALLOC;
      ret = ACL_REAL_CALL(real_aclrtFree(devPtr));
    } else {
      rt_err = RT_REAL_CALL(real_rtMemFreeManaged(devPtr));
      if (rt_err == RT_SUCCESS) {
        ret = ACL_SUCCESS;
      } else {
        npu_record_managed_fallback(NPU_MANAGED_FB_ALLOC_FAILED, "aclrtFree",
                                    "rtMemFreeManaged returned error");
        if (!npu_managed_fallback_enabled) return ACL_ERROR_BAD_ALLOC;
        ret = ACL_REAL_CALL(real_aclrtFree(devPtr));
      }
    }
  } else {
    ret = ACL_REAL_CALL(real_aclrtFree(devPtr));
  }

  if (ret == ACL_SUCCESS) {
    (void)remove_npu_allocation(devPtr, NULL);
  }

  return ret;
}

aclError aclrtGetMemInfo(aclrtMemAttr attr, size_t* free, size_t* total) {
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtGetMemInfo");
  maybe_trace_npu_api("aclrtGetMemInfo");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtGetMemInfo == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtGetMemInfo(attr, free, total));
  }
  maybe_init_npu_client();
  if (!npu_client_enabled()) {
    if (real_aclrtGetMemInfo == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtGetMemInfo(attr, free, total));
  }

  if (real_aclrtGetMemInfo == NULL) return ACL_ERROR_UNINITIALIZE;
  if (!xpushare_quota_control_required()) {
    return ACL_REAL_CALL(real_aclrtGetMemInfo(attr, free, total));
  }

  ret = ACL_REAL_CALL(real_aclrtGetMemInfo(attr, free, total));
  if (ret != ACL_SUCCESS) return ret;

  if (memory_limit > 0) {
    *total = memory_limit;
    *free = (memory_limit > sum_allocated) ? (memory_limit - sum_allocated) : 0;
    log_debug(
        "xpushare aclrtGetMemInfo (with limit): free=%.2f MiB, total=%.2f MiB",
        toMiB(*free), toMiB(*total));
    return ret;
  }

  return ret;
}

aclError aclrtSetDevice(int32_t deviceId) {
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtSetDevice");
  maybe_trace_npu_api("aclrtSetDevice");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtSetDevice == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtSetDevice(deviceId));
  }
  maybe_init_npu_client();

  if (real_aclrtSetDevice == NULL) return ACL_ERROR_UNINITIALIZE;
  ret = ACL_REAL_CALL(real_aclrtSetDevice(deviceId));
  if (ret != ACL_SUCCESS) return ret;
  npu_current_device_id = (int)deviceId;

  /*
   * Apply static native quota right after device selection to avoid relying on
   * less stable synchronize-timeout hooks.
   */
  if (npu_client_enabled()) {
    if (xpushare_quota_control_required()) {
      if (!apply_npu_native_compute_quota(NULL, "aclrtSetDevice")) {
        continue_with_lock();
      }
    }
  } else {
    (void)apply_npu_static_compute_quota(NULL, "aclrtSetDevice");
  }
  npu_prefetch_managed_allocations();

  return ret;
}

aclError aclrtSynchronizeDevice(void) {
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtSynchronizeDevice");
  maybe_trace_npu_api("aclrtSynchronizeDevice");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtSynchronizeDevice == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtSynchronizeDevice());
  }
  maybe_init_npu_client();

  if (real_aclrtSynchronizeDevice == NULL) return ACL_ERROR_UNINITIALIZE;
  if (npu_client_enabled()) {
    if (xpushare_quota_control_required()) {
      if (!apply_npu_native_compute_quota(NULL, "aclrtSynchronizeDevice")) {
        continue_with_lock();
      }
    }
  } else {
    (void)apply_npu_static_compute_quota(NULL, "aclrtSynchronizeDevice");
  }

  ret = ACL_REAL_CALL(real_aclrtSynchronizeDevice());
  return ret;
}

aclError aclrtSynchronizeDeviceWithTimeout(int32_t timeout) {
  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtSynchronizeDeviceWithTimeout");
  maybe_trace_npu_api("aclrtSynchronizeDeviceWithTimeout");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (real_aclrtSynchronizeDeviceWithTimeout == NULL) {
    return ACL_ERROR_UNINITIALIZE;
  }
  return ACL_REAL_CALL(real_aclrtSynchronizeDeviceWithTimeout(timeout));
}

aclError aclrtSynchronizeStream(aclrtStream stream) {
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtSynchronizeStream");
  maybe_trace_npu_api("aclrtSynchronizeStream");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtSynchronizeStream == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtSynchronizeStream(stream));
  }
  maybe_init_npu_client();

  if (real_aclrtSynchronizeStream == NULL) return ACL_ERROR_UNINITIALIZE;
  if (npu_client_enabled()) {
    if (xpushare_quota_control_required()) {
      if (!apply_npu_native_compute_quota(stream, "aclrtSynchronizeStream")) {
        continue_with_lock();
      }
    }
  } else {
    (void)apply_npu_static_compute_quota(stream, "aclrtSynchronizeStream");
  }

  ret = ACL_REAL_CALL(real_aclrtSynchronizeStream(stream));
  return ret;
}

aclError aclrtLaunchKernel(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                           const void* argsData, size_t argsSize,
                           aclrtStream stream) {
  aclError ret;

  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtLaunchKernel");
  maybe_trace_npu_api("aclrtLaunchKernel");
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtLaunchKernel == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(
        real_aclrtLaunchKernel(funcHandle, numBlocks, argsData, argsSize,
                               stream));
  }
  maybe_init_npu_client();

  if (real_aclrtLaunchKernel == NULL) return ACL_ERROR_UNINITIALIZE;
  if (npu_client_enabled()) {
    if (!xpushare_quota_control_required()) {
      npu_prefetch_managed_allocations();
      return ACL_REAL_CALL(
          real_aclrtLaunchKernel(funcHandle, numBlocks, argsData, argsSize,
                                 stream));
    }

    if (!apply_npu_native_compute_quota(stream, "aclrtLaunchKernel")) {
      continue_with_lock();
    }
  } else {
    (void)apply_npu_static_compute_quota(stream, "aclrtLaunchKernel");
  }
  npu_prefetch_managed_allocations();

  ret = ACL_REAL_CALL(
      real_aclrtLaunchKernel(funcHandle, numBlocks, argsData, argsSize, stream));
  return ret;
}

aclError aclrtMemcpy(void* dst, size_t destMax, const void* src, size_t count,
                     aclrtMemcpyKind kind) {
  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMemcpy");
  maybe_trace_npu_api("aclrtMemcpy");
  /*
   * Keep memcpy path as transparent passthrough to avoid touching scheduler
   * state during early ACL runtime initialization.
   */
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMemcpy == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(real_aclrtMemcpy(dst, destMax, src, count, kind));
  }
  maybe_init_npu_client();
  if (real_aclrtMemcpy == NULL) return ACL_ERROR_UNINITIALIZE;
  return ACL_REAL_CALL(real_aclrtMemcpy(dst, destMax, src, count, kind));
}

aclError aclrtMemcpyAsync(void* dst, size_t destMax, const void* src,
                          size_t count, aclrtMemcpyKind kind,
                          aclrtStream stream) {
  maybe_select_backend(XPUSHARE_BACKEND_NPU, "aclrtMemcpyAsync");
  maybe_trace_npu_api("aclrtMemcpyAsync");
  /*
   * Keep async memcpy path as transparent passthrough for the same reason as
   * aclrtMemcpy().
   */
  true_or_exit(pthread_once(&init_libxpushare_done, initialize_libxpushare) == 0);
  if (!npu_acl_hook_enabled()) {
    if (real_aclrtMemcpyAsync == NULL) return ACL_ERROR_UNINITIALIZE;
    return ACL_REAL_CALL(
        real_aclrtMemcpyAsync(dst, destMax, src, count, kind, stream));
  }
  maybe_init_npu_client();
  if (real_aclrtMemcpyAsync == NULL) return ACL_ERROR_UNINITIALIZE;
  return ACL_REAL_CALL(
      real_aclrtMemcpyAsync(dst, destMax, src, count, kind, stream));
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
