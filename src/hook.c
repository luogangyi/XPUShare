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

aclrtMalloc_func real_aclrtMalloc = NULL;
aclrtMallocAlign32_func real_aclrtMallocAlign32 = NULL;
aclrtMallocCached_func real_aclrtMallocCached = NULL;
aclrtMallocWithCfg_func real_aclrtMallocWithCfg = NULL;
aclrtFree_func real_aclrtFree = NULL;
aclrtGetMemInfo_func real_aclrtGetMemInfo = NULL;
aclrtLaunchKernel_func real_aclrtLaunchKernel = NULL;
aclrtLaunchKernelWithConfig_func real_aclrtLaunchKernelWithConfig = NULL;
aclrtLaunchKernelV2_func real_aclrtLaunchKernelV2 = NULL;
aclrtLaunchKernelWithHostArgs_func real_aclrtLaunchKernelWithHostArgs = NULL;
aclrtMemcpy_func real_aclrtMemcpy = NULL;
aclrtMemcpyAsync_func real_aclrtMemcpyAsync = NULL;
aclrtSynchronizeDevice_func real_aclrtSynchronizeDevice = NULL;
aclrtGetDevice_func real_aclrtGetDevice = NULL;
aclrtGetDeviceResLimit_func real_aclrtGetDeviceResLimit = NULL;
aclrtSetDeviceResLimit_func real_aclrtSetDeviceResLimit = NULL;
rtKernelLaunch_func real_rtKernelLaunch = NULL;
rtKernelLaunchWithFlag_func real_rtKernelLaunchWithFlag = NULL;
rtLaunchKernelByFuncHandleV3_func real_rtLaunchKernelByFuncHandleV3 = NULL;
rtsLaunchKernelWithDevArgs_func real_rtsLaunchKernelWithDevArgs = NULL;
rtsLaunchKernelWithHostArgs_func real_rtsLaunchKernelWithHostArgs = NULL;
rtVectorCoreKernelLaunch_func real_rtVectorCoreKernelLaunch = NULL;

size_t nvshare_size_mem_allocatable = 0;
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
static pthread_mutex_t npu_reslimit_mutex = PTHREAD_MUTEX_INITIALIZER;
static int npu_reslimit_cached_device = -1;
static int npu_reslimit_last_percent = -1;
static uint32_t npu_reslimit_cube_max = 0;
static uint32_t npu_reslimit_vector_max = 0;

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
  struct npu_mem_allocation* next;
};

/* Linked list that holds all memory allocations of current application. */
struct cuda_mem_allocation* cuda_allocation_list = NULL;
struct npu_mem_allocation* npu_allocation_list = NULL;

/* Initializaters will be executed only once per client application */
static pthread_once_t init_libnvshare_done = PTHREAD_ONCE_INIT;
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

  LOAD_ACL_SYM(aclrtMalloc);
  LOAD_ACL_SYM(aclrtMallocAlign32);
  LOAD_ACL_SYM(aclrtMallocCached);
  LOAD_ACL_SYM(aclrtMallocWithCfg);
  LOAD_ACL_SYM(aclrtFree);
  LOAD_ACL_SYM(aclrtGetMemInfo);
  LOAD_ACL_SYM(aclrtLaunchKernel);
  LOAD_ACL_SYM(aclrtLaunchKernelWithConfig);
  LOAD_ACL_SYM(aclrtLaunchKernelV2);
  LOAD_ACL_SYM(aclrtLaunchKernelWithHostArgs);
  LOAD_ACL_SYM(aclrtMemcpy);
  LOAD_ACL_SYM(aclrtMemcpyAsync);
  LOAD_ACL_SYM(aclrtSynchronizeDevice);
  LOAD_ACL_SYM(aclrtGetDevice);
  LOAD_ACL_SYM(aclrtGetDeviceResLimit);
  LOAD_ACL_SYM(aclrtSetDeviceResLimit);

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
  LOAD_RT_NEXT_SYM(rtLaunchKernelByFuncHandleV3);
  LOAD_RT_NEXT_SYM(rtsLaunchKernelWithDevArgs);
  LOAD_RT_NEXT_SYM(rtsLaunchKernelWithHostArgs);
  LOAD_RT_NEXT_SYM(rtVectorCoreKernelLaunch);

#undef LOAD_RT_NEXT_SYM

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

/* Append a new ACL memory allocation at the end of the list. */
static void insert_npu_allocation(void* ptr, size_t bytesize) {
  struct npu_mem_allocation* allocation;

  sum_allocated += bytesize;
  log_debug("Total allocated memory on NPU is %.2f MiB", toMiB(sum_allocated));

  true_or_exit(allocation = malloc(sizeof(*allocation)));
  allocation->ptr = ptr;
  allocation->size = bytesize;
  allocation->next = NULL;
  LL_APPEND(npu_allocation_list, allocation);

  report_memory_usage_to_scheduler(sum_allocated);
}

/* Remove an ACL memory allocation given the pointer it starts at. */
static void remove_npu_allocation(void* rm_ptr) {
  struct npu_mem_allocation *tmp, *a;

  LL_FOREACH_SAFE(npu_allocation_list, a, tmp) {
    if (a->ptr == rm_ptr) {
      sum_allocated -= a->size;
      log_debug("Total allocated memory on NPU is %.2f MiB",
                toMiB(sum_allocated));
      LL_DELETE(npu_allocation_list, a);
      free(a);
      report_memory_usage_to_scheduler(sum_allocated);
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
  }

  return NULL;
}

static void* resolve_rt_symbol(const char* symbol) {
  if (strcmp(symbol, "rtKernelLaunch") == 0) {
    return (void*)(&rtKernelLaunch);
  } else if (strcmp(symbol, "rtKernelLaunchWithFlag") == 0) {
    return (void*)(&rtKernelLaunchWithFlag);
  } else if (strcmp(symbol, "rtLaunchKernelByFuncHandleV3") == 0) {
    return (void*)(&rtLaunchKernelByFuncHandleV3);
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
  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuGetProcAddress");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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
  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuGetProcAddress_v2");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemAlloc");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemFree");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_cuMemFree == NULL) return CUDA_ERROR_NOT_INITIALIZED;
  result = real_cuMemFree(dptr);
  if (result == CUDA_SUCCESS) remove_cuda_allocation(dptr);

  return result;
}

CUresult cuMemGetInfo(size_t* free, size_t* total) {
  long long reserve_mib;
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemGetInfo");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuInit");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuLaunchKernel");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpy");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_cuMemcpyAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpyAsync(dst, src, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyAsync));

  return result;
}

CUresult cuMemcpyDtoH(void* dstHost, CUdeviceptr srcDevice, size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyDtoH");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyDtoHAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyHtoD");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyHtoDAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyDtoD");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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

  maybe_select_backend(NVSHARE_BACKEND_CUDA, "cuMemcpyDtoDAsync");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
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
  if (real_aclrtGetMemInfo(ACL_HBM_MEM, &free_mem, &total_mem) != ACL_SUCCESS) {
    return 0;
  }

  *allocatable_out = free_mem;
  return 1;
}

static aclError acl_malloc_common(void** devPtr, size_t size,
                                  aclrtMemMallocPolicy policy,
                                  aclrtMalloc_func malloc_fn,
                                  const char* api_name) {
  int exceeds_physical = 0;
  aclError ret;

  if (malloc_fn == NULL) return ACL_ERROR_UNINITIALIZE;
  if (!check_allocation_limit(size, api_name, &exceeds_physical,
                              npu_size_mem_allocatable)) {
    return ACL_ERROR_BAD_ALLOC;
  }
  if (exceeds_physical) {
    log_warn("%s exceeds physical NPU memory; oversub mode enabled", api_name);
  }

  nvshare_apply_npu_core_limit();

  ret = malloc_fn(devPtr, size, policy);
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, size);
  }

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
                           "aclrtMalloc");
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
                           "aclrtMallocAlign32");
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
                           "aclrtMallocCached");
}

aclError aclrtMallocWithCfg(void** devPtr, size_t size,
                            aclrtMemMallocPolicy policy, void* cfg) {
  int exceeds_physical = 0;
  aclError ret;

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

  ret = real_aclrtMallocWithCfg(devPtr, size, policy, cfg);
  if (ret == ACL_SUCCESS && devPtr != NULL && *devPtr != NULL) {
    insert_npu_allocation(*devPtr, size);
  }

  return ret;
}

aclError aclrtFree(void* devPtr) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtFree");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtFree == NULL) return ACL_ERROR_UNINITIALIZE;
  ret = real_aclrtFree(devPtr);
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

aclError aclrtLaunchKernel(aclrtFuncHandle funcHandle, uint32_t numBlocks,
                           const void* argsData, size_t argsSize,
                           aclrtStream stream) {
  aclError ret;

  maybe_select_backend(NVSHARE_BACKEND_NPU, "aclrtLaunchKernel");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);

  if (real_aclrtLaunchKernel == NULL) return ACL_ERROR_UNINITIALIZE;

  nvshare_apply_npu_core_limit();
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

  nvshare_apply_npu_core_limit();
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

  nvshare_apply_npu_core_limit();
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

  nvshare_apply_npu_core_limit();
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

  nvshare_apply_npu_core_limit();
  continue_with_lock();
  ret = real_aclrtMemcpyAsync(dst, destMax, src, count, kind, stream);
  return ret;
}

rtError_t rtKernelLaunch(const void* stubFunc, uint32_t numBlocks, void* args,
                         uint32_t argsSize, void* smDesc, void* stm) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunch");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunch == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
  continue_with_lock();
  return real_rtKernelLaunch(stubFunc, numBlocks, args, argsSize, smDesc, stm);
}

rtError_t rtKernelLaunchWithFlag(const void* stubFunc, uint32_t numBlocks,
                                 const void* argsInfo, void* smDesc, void* stm,
                                 uint32_t flags) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtKernelLaunchWithFlag");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtKernelLaunchWithFlag == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
  continue_with_lock();
  return real_rtKernelLaunchWithFlag(stubFunc, numBlocks, argsInfo, smDesc, stm,
                                     flags);
}

rtError_t rtLaunchKernelByFuncHandleV3(void* funcHandle, uint32_t numBlocks,
                                       const void* argsInfo, void* stm,
                                       const void* cfgInfo) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtLaunchKernelByFuncHandleV3");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtLaunchKernelByFuncHandleV3 == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
  continue_with_lock();
  return real_rtLaunchKernelByFuncHandleV3(funcHandle, numBlocks, argsInfo, stm,
                                           cfgInfo);
}

rtError_t rtsLaunchKernelWithDevArgs(void* funcHandle, uint32_t numBlocks,
                                     void* stm, void* cfg, const void* args,
                                     uint32_t argsSize, void* reserve) {
  maybe_select_backend(NVSHARE_BACKEND_NPU, "rtsLaunchKernelWithDevArgs");
  true_or_exit(pthread_once(&init_libnvshare_done, initialize_libnvshare) == 0);
  true_or_exit(pthread_once(&init_done, initialize_client) == 0);
  if (real_rtsLaunchKernelWithDevArgs == NULL) return RT_ERROR_NONE;
  nvshare_apply_npu_core_limit();
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
  nvshare_apply_npu_core_limit();
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
  nvshare_apply_npu_core_limit();
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
