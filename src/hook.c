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
#include "cuda_defs.h"
#include "utlist.h"

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

size_t nvshare_size_mem_allocatable = 0;
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

/* Linked list that holds all memory allocations of current application. */
struct cuda_mem_allocation* cuda_allocation_list = NULL;

/* Initializaters will be executed only once per client application */
static pthread_once_t init_libnvshare_done = PTHREAD_ONCE_INIT;
static pthread_once_t init_done = PTHREAD_ONCE_INIT;

/* Load real CUDA {Driver API, NVML} functions and bootstrap auxiliary stuff. */
static void bootstrap_cuda(void) {
  char* error;
  void* cuda_handle;
  void* nvml_handle;

  true_or_exit(pthread_mutex_init(&kcount_mutex, NULL) == 0);

  nvml_handle = dlopen("libnvidia-ml.so.1", RTLD_LAZY);
  if (!nvml_handle) {
    error = dlerror();
    log_debug("%s", error);
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

  cuda_handle = dlopen("libcuda.so", RTLD_LAZY);
  if (!cuda_handle) {
    error = dlerror();
    log_fatal("%s", error);
  }
  /*
   * For dlsym(), a return value of NULL does not necessarily indicate
   * an error. Therefore, we must:
   *  1. clear the previous error state by calling dlerror()
   *  2. call dlsym()
   *  3. call dlerror()
   * If the value which dlerror() returns is not NULL, an error occured.
   */
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
  if (error != NULL)
    /*
     * Print a debug message instead of failing immediately, since
     * this symbol may not be used. This may be the case for CUDA
     * Runtime <11.3.
     */
    log_debug("%s", error);
  real_cuGetProcAddress_v2 = (cuGetProcAddress_v2_func)real_dlsym_225(
      cuda_handle, CUDA_SYMBOL_STRING(cuGetProcAddress_v2));
  error = dlerror();
  if (error != NULL)
    /*
     * Print a debug message instead of failing immediately, since
     * this symbol may not be used. This may be the case for CUDA
     * Runtime <12.0.
     */
    log_debug("%s", error);
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
  /* Load cuMemAdvise for memory hints (may not be available on old CUDA) */
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

/*
 * Hint driver to evict all allocations to Host memory before context switch.
 * This is called when receiving PREPARE_SWAP_OUT from scheduler.
 * The goal is to reduce page faults when the next task starts.
 */
void swap_out_all_allocations(void) {
  struct cuda_mem_allocation* a;
  size_t total_evicted = 0;
  int count = 0;

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
 * Depending on glibc version, we look for the appropriate symbol.
 *
 * Some context on the implementation:
 *
 * glibc 2.34 remove the internal __libc_dlsym() symbol that NVIDIA uses in
 * their cuHook example:
 * https://github.com/phrb/intro-cuda/blob/d38323b81cd799dc09179e2ef27aa8f81b6dac40/src/cuda-samples/7_CUDALibraries/cuHook/libcuhook.cpp#L43
 *
 * One solution, discussed in apitrace's repo is to use dlvsym(), which also
 * takes a version string as a 3rd argument, in order to obtain the real
 * dlsym().
 *
 * This is what user 'manisandro' suggested 8 years ago, when warning about
 * using the private __libc_dlsym():
 * https://github.com/apitrace/apitrace/issues/258
 *
 * The maintainer of the repo didn't heed the warning back then, it came back
 * 8 years later and bit them.
 *
 * This is also what user "derhass" suggests:
 * https://stackoverflow.com/a/18825060
 * (See section "UPDATE FOR 2021/glibc-2.34").
 *
 * Given all the above, we obtain the real `dlsym()` as such:
 * real_dlsym=dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
 *
 * Since we have to explicitly use a version argument in dlvsym(), we also have
 * to define and export two versions of dlsym (hence the linker script.), one
 * for each distinct glibc symbol version.
 *
 */
static void* real_dlsym_225(void* handle, const char* symbol) {
  typedef void*(dlsym_t)(void*, const char*);
  static dlsym_t* r_dlsym;
  char* err;

  if (!r_dlsym) {
    dlerror();
    r_dlsym = (dlsym_t*)dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
    err = dlerror();
    if (err != NULL) log_fatal("%s", err);
  }

  return (*r_dlsym)(handle, symbol);
}

static void* real_dlsym_234(void* handle, const char* symbol) {
  typedef void*(dlsym_t)(void*, const char*);
  static dlsym_t* r_dlsym;
  char* err;

  if (!r_dlsym) {
    dlerror();
    r_dlsym = (dlsym_t*)dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.34");
    err = dlerror();
    if (err != NULL) log_fatal("%s", err);
  }

  return (*r_dlsym)(handle, symbol);
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
  if (strncmp(symbol, "cu", 2) != 0) {
    return (real_dlsym_225(handle, symbol));
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemAlloc)) == 0) {
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

  return (real_dlsym_225(handle, symbol));
}

void* dlsym_234(void* handle, const char* symbol) {
  if (strncmp(symbol, "cu", 2) != 0) {
    return (real_dlsym_234(handle, symbol));
  } else if (strcmp(symbol, CUDA_SYMBOL_STRING(cuMemAlloc)) == 0) {
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

  /* Return immediately if not initialized */
  if (real_cuMemAllocManaged == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  if (got_max_mem_size == 0) {
    result = cuMemGetInfo(&nvshare_size_mem_allocatable, &junk);
    cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemGetInfo));
    got_max_mem_size = 1;
  }

  /* Check user-specified memory limit first */
  if (memory_limit > 0 && (sum_allocated + bytesize) > memory_limit) {
    log_warn(
        "Memory allocation rejected: %zu + %zu = %zu would exceed limit %zu "
        "bytes (%.2f MiB)",
        sum_allocated, bytesize, sum_allocated + bytesize, memory_limit,
        (double)memory_limit / (1024.0 * 1024.0));
    return CUDA_ERROR_OUT_OF_MEMORY;
  }

  /* Check physical GPU memory limit */
  if ((sum_allocated + bytesize) > nvshare_size_mem_allocatable) {
    if (enable_single_oversub == 0) {
      return CUDA_ERROR_OUT_OF_MEMORY;
    } else {
      log_warn(
          "Memory allocations exceeded physical GPU"
          " memory capacity. This can cause extreme"
          " performance degradation!");
    }
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

  if (real_cuMemFree == NULL) return CUDA_ERROR_NOT_INITIALIZED;
  result = real_cuMemFree(dptr);
  if (result == CUDA_SUCCESS) remove_cuda_allocation(dptr);

  return result;
}

CUresult cuMemGetInfo(size_t* free, size_t* total) {
  long long reserve_mib;
  CUresult result = CUDA_SUCCESS;

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

  if (real_cuMemcpy == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpy(dst, src, ByteCount);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpy));

  return result;
}

CUresult cuMemcpyAsync(CUdeviceptr dst, CUdeviceptr src, size_t ByteCount,
                       CUstream hStream) {
  CUresult result = CUDA_SUCCESS;

  if (real_cuMemcpyAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();

  result = real_cuMemcpyAsync(dst, src, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyAsync));

  return result;
}

CUresult cuMemcpyDtoH(void* dstHost, CUdeviceptr srcDevice, size_t ByteCount) {
  CUresult result = CUDA_SUCCESS;

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

  /* Return immediately if not initialized */
  if (real_cuMemcpyDtoDAsync == NULL) return CUDA_ERROR_NOT_INITIALIZED;

  continue_with_lock();
  result = real_cuMemcpyDtoDAsync(dstDevice, srcDevice, ByteCount, hStream);
  cuda_driver_check_error(result, CUDA_SYMBOL_STRING(cuMemcpyDtoDAsync));

  return result;
}

__asm__(".symver dlsym_225, dlsym@@GLIBC_2.2.5");
__asm__(".symver dlsym_234, dlsym@GLIBC_2.34");
