/*
 * NVML Sampler for nvshare-scheduler Prometheus metrics.
 *
 * Uses runtime dlopen("libnvidia-ml.so.1") to load NVML symbols,
 * avoiding build-time NVML dependency. If NVML is unavailable,
 * the sampler gracefully degrades (GPU metrics show zeros).
 */

#include "nvml_sampler.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "common.h"

/* ---- NVML type definitions (subset needed for our use) ---- */

typedef int nvmlReturn_t;
#define NVML_SUCCESS 0

typedef void* nvmlDevice_t;

typedef struct {
  unsigned long long total;
  unsigned long long free;
  unsigned long long used;
} nvmlMemory_t;

typedef struct {
  unsigned int gpu;
  unsigned int memory;
} nvmlUtilization_t;

typedef struct {
  unsigned int pid;
  unsigned long long usedGpuMemory;
  /* We don't need the other fields */
  unsigned int gpuInstanceId;
  unsigned int computeInstanceId;
} nvmlProcessInfo_t;

/* ---- NVML function pointers (resolved via dlsym) ---- */

static nvmlReturn_t (*fn_nvmlInit)(void);
static nvmlReturn_t (*fn_nvmlShutdown)(void);
static nvmlReturn_t (*fn_nvmlDeviceGetCount)(unsigned int*);
static nvmlReturn_t (*fn_nvmlDeviceGetHandleByIndex)(unsigned int,
                                                     nvmlDevice_t*);
static nvmlReturn_t (*fn_nvmlDeviceGetUUID)(nvmlDevice_t, char*, unsigned int);
static nvmlReturn_t (*fn_nvmlDeviceGetName)(nvmlDevice_t, char*, unsigned int);
static nvmlReturn_t (*fn_nvmlDeviceGetMemoryInfo)(nvmlDevice_t, nvmlMemory_t*);
static nvmlReturn_t (*fn_nvmlDeviceGetUtilizationRates)(nvmlDevice_t,
                                                        nvmlUtilization_t*);
static nvmlReturn_t (*fn_nvmlDeviceGetComputeRunningProcesses)(
    nvmlDevice_t, unsigned int*, nvmlProcessInfo_t*);

/* ---- Global state ---- */

struct nvml_snapshot g_nvml_snapshot;
static int g_interval_ms = 1000;
static void* nvml_lib_handle = NULL;

/* Cached device handles (resolved once during init) */
static nvmlDevice_t device_handles[NVML_MAX_GPUS];
static int device_count = 0;

/* ---- Helper: load a symbol or fail ---- */
static void* load_sym(const char* name) {
  void* sym = dlsym(nvml_lib_handle, name);
  if (!sym) {
    log_warn("NVML dlsym failed for %s: %s", name, dlerror());
  }
  return sym;
}

void nvml_sampler_set_interval_ms(int interval_ms) {
  if (interval_ms >= 100 && interval_ms <= 30000) {
    g_interval_ms = interval_ms;
  }
}

int nvml_sampler_init(void) {
  pthread_rwlock_init(&g_nvml_snapshot.lock, NULL);
  g_nvml_snapshot.gpu_count = 0;
  g_nvml_snapshot.nvml_available = 0;

  /* Try to load NVML shared library */
  nvml_lib_handle = dlopen("libnvidia-ml.so.1", RTLD_LAZY);
  if (!nvml_lib_handle) {
    nvml_lib_handle = dlopen("libnvidia-ml.so", RTLD_LAZY);
  }
  if (!nvml_lib_handle) {
    log_warn("NVML not available (dlopen failed: %s). GPU metrics disabled.",
             dlerror());
    return -1;
  }

  /* Resolve function pointers */
  fn_nvmlInit = load_sym("nvmlInit_v2");
  if (!fn_nvmlInit) fn_nvmlInit = load_sym("nvmlInit");
  fn_nvmlShutdown = load_sym("nvmlShutdown");
  fn_nvmlDeviceGetCount = load_sym("nvmlDeviceGetCount_v2");
  if (!fn_nvmlDeviceGetCount)
    fn_nvmlDeviceGetCount = load_sym("nvmlDeviceGetCount");
  fn_nvmlDeviceGetHandleByIndex = load_sym("nvmlDeviceGetHandleByIndex_v2");
  if (!fn_nvmlDeviceGetHandleByIndex)
    fn_nvmlDeviceGetHandleByIndex = load_sym("nvmlDeviceGetHandleByIndex");
  fn_nvmlDeviceGetUUID = load_sym("nvmlDeviceGetUUID");
  fn_nvmlDeviceGetName = load_sym("nvmlDeviceGetName");
  fn_nvmlDeviceGetMemoryInfo = load_sym("nvmlDeviceGetMemoryInfo");
  fn_nvmlDeviceGetUtilizationRates = load_sym("nvmlDeviceGetUtilizationRates");
  fn_nvmlDeviceGetComputeRunningProcesses =
      load_sym("nvmlDeviceGetComputeRunningProcesses_v3");
  if (!fn_nvmlDeviceGetComputeRunningProcesses)
    fn_nvmlDeviceGetComputeRunningProcesses =
        load_sym("nvmlDeviceGetComputeRunningProcesses");

  if (!fn_nvmlInit || !fn_nvmlDeviceGetCount ||
      !fn_nvmlDeviceGetHandleByIndex || !fn_nvmlDeviceGetMemoryInfo) {
    log_warn("NVML: missing critical symbols. GPU metrics disabled.");
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  /* Initialize NVML */
  nvmlReturn_t ret = fn_nvmlInit();
  if (ret != NVML_SUCCESS) {
    log_warn("nvmlInit failed with %d. GPU metrics disabled.", ret);
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  /* Enumerate GPUs */
  unsigned int count = 0;
  ret = fn_nvmlDeviceGetCount(&count);
  if (ret != NVML_SUCCESS) {
    log_warn("nvmlDeviceGetCount failed with %d", ret);
    fn_nvmlShutdown();
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  device_count = (int)(count < NVML_MAX_GPUS ? count : NVML_MAX_GPUS);

  for (int i = 0; i < device_count; i++) {
    ret = fn_nvmlDeviceGetHandleByIndex((unsigned int)i, &device_handles[i]);
    if (ret != NVML_SUCCESS) {
      log_warn("nvmlDeviceGetHandleByIndex(%d) failed with %d", i, ret);
      device_handles[i] = NULL;
    }
  }

  g_nvml_snapshot.nvml_available = 1;
  g_nvml_snapshot.gpu_count = device_count;
  log_info("NVML sampler initialized: %d GPU(s) detected", device_count);
  return 0;
}

/* ---- Sampling logic ---- */

static void sample_gpu(int index, struct nvml_gpu_snapshot* snap) {
  nvmlDevice_t dev = device_handles[index];
  nvmlReturn_t ret;

  snap->gpu_index = index;
  snap->valid = 0;

  if (!dev) return;

  /* UUID */
  if (fn_nvmlDeviceGetUUID) {
    ret = fn_nvmlDeviceGetUUID(dev, snap->uuid, sizeof(snap->uuid));
    if (ret != NVML_SUCCESS) {
      snprintf(snap->uuid, sizeof(snap->uuid), "GPU-%d", index);
    }
  } else {
    snprintf(snap->uuid, sizeof(snap->uuid), "GPU-%d", index);
  }

  /* Name (cached after first successful read) */
  if (snap->gpu_name[0] == '\0' && fn_nvmlDeviceGetName) {
    ret = fn_nvmlDeviceGetName(dev, snap->gpu_name, sizeof(snap->gpu_name));
    if (ret != NVML_SUCCESS) {
      snprintf(snap->gpu_name, sizeof(snap->gpu_name), "Unknown");
    }
  }

  /* Memory */
  nvmlMemory_t mem_info;
  ret = fn_nvmlDeviceGetMemoryInfo(dev, &mem_info);
  if (ret == NVML_SUCCESS) {
    snap->memory_total = (size_t)mem_info.total;
    snap->memory_used = (size_t)mem_info.used;
    snap->memory_free = (size_t)mem_info.free;
  } else {
    snap->memory_total = snap->memory_used = snap->memory_free = 0;
  }

  /* Utilization */
  if (fn_nvmlDeviceGetUtilizationRates) {
    nvmlUtilization_t util;
    ret = fn_nvmlDeviceGetUtilizationRates(dev, &util);
    if (ret == NVML_SUCCESS) {
      snap->gpu_util = (float)util.gpu / 100.0f;
      snap->mem_util = (float)util.memory / 100.0f;
    } else {
      snap->gpu_util = snap->mem_util = 0.0f;
    }
  }

  /* Per-process GPU memory */
  snap->process_count = 0;
  if (fn_nvmlDeviceGetComputeRunningProcesses) {
    nvmlProcessInfo_t proc_infos[NVML_MAX_PROCESSES_PER_GPU];
    unsigned int proc_count = NVML_MAX_PROCESSES_PER_GPU;
    ret = fn_nvmlDeviceGetComputeRunningProcesses(dev, &proc_count, proc_infos);
    if (ret == NVML_SUCCESS) {
      int n = (int)(proc_count < NVML_MAX_PROCESSES_PER_GPU
                        ? proc_count
                        : NVML_MAX_PROCESSES_PER_GPU);
      snap->process_count = n;
      for (int j = 0; j < n; j++) {
        snap->processes[j].pid = (pid_t)proc_infos[j].pid;
        snap->processes[j].used_memory = (size_t)proc_infos[j].usedGpuMemory;
      }
    }
  }

  snap->valid = 1;
}

void* nvml_sampler_thread_fn(void* arg __attribute__((unused))) {
  struct timespec sleep_ts;

  log_info("NVML sampler thread started (interval: %d ms)", g_interval_ms);

  while (1) {
    /* Sample into a local buffer first, then swap under write lock */
    struct nvml_gpu_snapshot local_snaps[NVML_MAX_GPUS];
    memset(local_snaps, 0, sizeof(local_snaps));

    /* Copy cached gpu_name from previous snapshot before sampling */
    pthread_rwlock_rdlock(&g_nvml_snapshot.lock);
    for (int i = 0; i < device_count; i++) {
      memcpy(local_snaps[i].gpu_name, g_nvml_snapshot.gpus[i].gpu_name,
             sizeof(local_snaps[i].gpu_name));
    }
    pthread_rwlock_unlock(&g_nvml_snapshot.lock);

    for (int i = 0; i < device_count; i++) {
      sample_gpu(i, &local_snaps[i]);
    }

    /* Swap snapshot under write lock */
    pthread_rwlock_wrlock(&g_nvml_snapshot.lock);
    memcpy(g_nvml_snapshot.gpus, local_snaps, sizeof(local_snaps));
    pthread_rwlock_unlock(&g_nvml_snapshot.lock);

    /* Sleep for interval */
    sleep_ts.tv_sec = g_interval_ms / 1000;
    sleep_ts.tv_nsec = (g_interval_ms % 1000) * 1000000L;
    nanosleep(&sleep_ts, NULL);
  }

  return NULL;
}
