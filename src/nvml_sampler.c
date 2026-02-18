/*
 * GPU sampler for nvshare-scheduler Prometheus metrics.
 *
 * Backend selection order (runtime dlopen):
 * 1) NVML (NVIDIA)
 * 2) DCMI (CANN management interface)
 * 3) ACL Runtime (CANN fallback)
 */

#include "nvml_sampler.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "common.h"
#include "npu_defs.h"

/* ---- NVML type definitions (subset) ---- */

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
  unsigned int gpuInstanceId;
  unsigned int computeInstanceId;
} nvmlProcessInfo_t;

/* ---- DCMI type definitions (subset) ---- */

#define DCMI_OK 0
#define DCMI_UTILIZATION_RATE_AICORE 2
#define DCMI_UTILIZATION_RATE_NPU 13

struct dcmi_get_memory_info_stru {
  unsigned long long memory_size;      /* unit: MB */
  unsigned long long memory_available; /* unit differs by platform */
  unsigned int freq;
  unsigned long hugepagesize; /* unit: KB */
  unsigned long hugepages_total;
  unsigned long hugepages_free;
  unsigned int utiliza;
  unsigned char reserve[60];
};

/* ---- ACL fallback type definitions (subset) ---- */

struct aclrt_utilization_info {
  int32_t cubeUtilization;
  int32_t vectorUtilization;
  int32_t aicpuUtilization;
  int32_t memoryUtilization;
  void* utilizationExtend;
};

/* ---- Backend function pointers ---- */

/* NVML */
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

/* DCMI */
static int (*fn_dcmi_init)(void);
static int (*fn_dcmi_get_card_list)(int* card_num, int* card_list, int list_len);
static int (*fn_dcmi_get_device_num_in_card)(int card_id, int* device_num);
static int (*fn_dcmi_get_device_memory_info_v3)(
    int card_id, int device_id, struct dcmi_get_memory_info_stru* memory_info);
static int (*fn_dcmi_get_device_utilization_rate)(
    int card_id, int device_id, int input_type, unsigned int* utilization_rate);

/* ACL fallback */
static aclError (*fn_aclInit)(const char* configPath);
static aclError (*fn_aclrtGetDeviceCount)(uint32_t* count);
static aclError (*fn_aclrtSetDevice)(int32_t deviceId);
static aclrtGetMemInfo_func fn_aclrtGetMemInfo;
static aclError (*fn_aclrtGetDeviceUtilizationRate)(
    int32_t deviceId, struct aclrt_utilization_info* utilizationInfo);

/* ---- Global state ---- */

struct nvml_snapshot g_nvml_snapshot;

static int g_interval_ms = 1000;
static enum gpu_sampler_backend_kind g_backend_kind = GPU_SAMPLER_BACKEND_NONE;

static void* nvml_lib_handle = NULL;
static void* dcmi_lib_handle = NULL;
static void* acl_lib_handle = NULL;

/* NVML backend cache */
static nvmlDevice_t nvml_devices[NVML_MAX_GPUS];
static int nvml_device_count = 0;

/* DCMI backend cache */
struct dcmi_device_ref {
  int card_id;
  int device_id;
};
static struct dcmi_device_ref dcmi_devices[NVML_MAX_GPUS];
static int dcmi_device_count = 0;

/* ACL backend cache */
static int acl_device_count = 0;

/* ---- Helpers ---- */

static const char* backend_to_string(enum gpu_sampler_backend_kind kind) {
  switch (kind) {
    case GPU_SAMPLER_BACKEND_NVML:
      return "nvml";
    case GPU_SAMPLER_BACKEND_DCMI:
      return "dcmi";
    case GPU_SAMPLER_BACKEND_ACL:
      return "acl";
    default:
      return "none";
  }
}

static void* load_sym(void* lib, const char* name) {
  void* sym;
  dlerror();
  sym = dlsym(lib, name);
  if (!sym) {
    char* err = dlerror();
    log_debug("dlsym(%s) failed: %s", name, err ? err : "unknown");
  }
  return sym;
}

static float util_to_ratio(unsigned int pct) {
  if (pct > 100U) pct = 100U;
  return (float)pct / 100.0f;
}

static unsigned long long mul_u64_sat(unsigned long long a,
                                      unsigned long long b) {
  if (a == 0 || b == 0) return 0;
  if (a > ULLONG_MAX / b) return ULLONG_MAX;
  return a * b;
}

static size_t clamp_u64_to_size(unsigned long long v) {
  if (v > (unsigned long long)SIZE_MAX) return SIZE_MAX;
  return (size_t)v;
}

/*
 * DCMI memory_available unit differs by platform (bytes / KB / MB).
 * Try multiple interpretations and pick the one closest to total bytes.
 */
static size_t dcmi_available_to_bytes(unsigned long long raw,
                                      size_t total_bytes) {
  if (total_bytes == 0) return 0;

  unsigned long long total = (unsigned long long)total_bytes;
  unsigned long long cand[3];
  unsigned long long best = 0;
  unsigned long long best_diff = ULLONG_MAX;

  cand[0] = raw;
  cand[1] = mul_u64_sat(raw, 1024ULL);
  cand[2] = mul_u64_sat(raw, 1024ULL * 1024ULL);

  for (int i = 0; i < 3; i++) {
    if (cand[i] == ULLONG_MAX) continue;
    if (cand[i] > total * 2ULL) continue;
    unsigned long long diff = (cand[i] > total) ? (cand[i] - total)
                                                 : (total - cand[i]);
    if (diff < best_diff) {
      best_diff = diff;
      best = cand[i];
    }
  }

  if (best == 0) {
    best = (raw <= total) ? raw : total;
  }
  if (best > total) best = total;
  return clamp_u64_to_size(best);
}

void nvml_sampler_set_interval_ms(int interval_ms) {
  if (interval_ms >= 100 && interval_ms <= 30000) {
    g_interval_ms = interval_ms;
  }
}

/* ---- NVML backend ---- */

static int init_nvml_backend(void) {
  nvmlReturn_t ret;
  unsigned int count = 0;

  nvml_lib_handle = dlopen("libnvidia-ml.so.1", RTLD_LAZY);
  if (!nvml_lib_handle) nvml_lib_handle = dlopen("libnvidia-ml.so", RTLD_LAZY);
  if (!nvml_lib_handle) return -1;

  fn_nvmlInit = load_sym(nvml_lib_handle, "nvmlInit_v2");
  if (!fn_nvmlInit) fn_nvmlInit = load_sym(nvml_lib_handle, "nvmlInit");
  fn_nvmlShutdown = load_sym(nvml_lib_handle, "nvmlShutdown");
  fn_nvmlDeviceGetCount = load_sym(nvml_lib_handle, "nvmlDeviceGetCount_v2");
  if (!fn_nvmlDeviceGetCount) {
    fn_nvmlDeviceGetCount = load_sym(nvml_lib_handle, "nvmlDeviceGetCount");
  }
  fn_nvmlDeviceGetHandleByIndex =
      load_sym(nvml_lib_handle, "nvmlDeviceGetHandleByIndex_v2");
  if (!fn_nvmlDeviceGetHandleByIndex) {
    fn_nvmlDeviceGetHandleByIndex =
        load_sym(nvml_lib_handle, "nvmlDeviceGetHandleByIndex");
  }
  fn_nvmlDeviceGetUUID = load_sym(nvml_lib_handle, "nvmlDeviceGetUUID");
  fn_nvmlDeviceGetName = load_sym(nvml_lib_handle, "nvmlDeviceGetName");
  fn_nvmlDeviceGetMemoryInfo = load_sym(nvml_lib_handle, "nvmlDeviceGetMemoryInfo");
  fn_nvmlDeviceGetUtilizationRates =
      load_sym(nvml_lib_handle, "nvmlDeviceGetUtilizationRates");
  fn_nvmlDeviceGetComputeRunningProcesses =
      load_sym(nvml_lib_handle, "nvmlDeviceGetComputeRunningProcesses_v3");
  if (!fn_nvmlDeviceGetComputeRunningProcesses) {
    fn_nvmlDeviceGetComputeRunningProcesses =
        load_sym(nvml_lib_handle, "nvmlDeviceGetComputeRunningProcesses");
  }

  if (!fn_nvmlInit || !fn_nvmlDeviceGetCount || !fn_nvmlDeviceGetHandleByIndex ||
      !fn_nvmlDeviceGetMemoryInfo) {
    log_warn("NVML backend missing critical symbols");
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  ret = fn_nvmlInit();
  if (ret != NVML_SUCCESS) {
    log_warn("nvmlInit failed with %d", ret);
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  ret = fn_nvmlDeviceGetCount(&count);
  if (ret != NVML_SUCCESS || count == 0) {
    log_warn("nvmlDeviceGetCount failed with %d", ret);
    if (fn_nvmlShutdown) fn_nvmlShutdown();
    dlclose(nvml_lib_handle);
    nvml_lib_handle = NULL;
    return -1;
  }

  nvml_device_count = (int)(count < NVML_MAX_GPUS ? count : NVML_MAX_GPUS);
  for (int i = 0; i < nvml_device_count; i++) {
    ret = fn_nvmlDeviceGetHandleByIndex((unsigned int)i, &nvml_devices[i]);
    if (ret != NVML_SUCCESS) {
      log_warn("nvmlDeviceGetHandleByIndex(%d) failed with %d", i, ret);
      nvml_devices[i] = NULL;
    }
  }

  g_backend_kind = GPU_SAMPLER_BACKEND_NVML;
  return 0;
}

static void sample_nvml_gpu(int index, struct nvml_gpu_snapshot* snap) {
  nvmlDevice_t dev = nvml_devices[index];
  nvmlReturn_t ret;

  snap->gpu_index = index;
  snap->valid = 0;
  snap->process_count = 0;

  if (!dev) return;

  if (fn_nvmlDeviceGetUUID) {
    ret = fn_nvmlDeviceGetUUID(dev, snap->uuid, sizeof(snap->uuid));
    if (ret != NVML_SUCCESS) snprintf(snap->uuid, sizeof(snap->uuid), "GPU-%d", index);
  } else {
    snprintf(snap->uuid, sizeof(snap->uuid), "GPU-%d", index);
  }

  if (snap->gpu_name[0] == '\0' && fn_nvmlDeviceGetName) {
    ret = fn_nvmlDeviceGetName(dev, snap->gpu_name, sizeof(snap->gpu_name));
    if (ret != NVML_SUCCESS) snprintf(snap->gpu_name, sizeof(snap->gpu_name), "NVIDIA-GPU");
  }

  nvmlMemory_t mem_info;
  ret = fn_nvmlDeviceGetMemoryInfo(dev, &mem_info);
  if (ret == NVML_SUCCESS) {
    snap->memory_total = (size_t)mem_info.total;
    snap->memory_used = (size_t)mem_info.used;
    snap->memory_free = (size_t)mem_info.free;
  }

  if (fn_nvmlDeviceGetUtilizationRates) {
    nvmlUtilization_t util;
    ret = fn_nvmlDeviceGetUtilizationRates(dev, &util);
    if (ret == NVML_SUCCESS) {
      snap->gpu_util = util_to_ratio(util.gpu);
      snap->mem_util = util_to_ratio(util.memory);
    }
  }

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

/* ---- DCMI backend ---- */

static int init_dcmi_backend(void) {
  int card_list[NVML_MAX_GPUS] = {0};
  int card_num = NVML_MAX_GPUS;
  int count = 0;

  dcmi_lib_handle = dlopen("libdcmi.so", RTLD_LAZY);
  if (!dcmi_lib_handle) dcmi_lib_handle = dlopen("libdcmi.so.1", RTLD_LAZY);
  if (!dcmi_lib_handle) dcmi_lib_handle = dlopen("libdrvdcmi_host.so", RTLD_LAZY);
  if (!dcmi_lib_handle) return -1;

  fn_dcmi_init = load_sym(dcmi_lib_handle, "dcmi_init");
  fn_dcmi_get_card_list = load_sym(dcmi_lib_handle, "dcmi_get_card_list");
  if (!fn_dcmi_get_card_list) {
    fn_dcmi_get_card_list = load_sym(dcmi_lib_handle, "dcmi_get_card_num_list");
  }
  fn_dcmi_get_device_num_in_card =
      load_sym(dcmi_lib_handle, "dcmi_get_device_num_in_card");
  fn_dcmi_get_device_memory_info_v3 =
      load_sym(dcmi_lib_handle, "dcmi_get_device_memory_info_v3");
  fn_dcmi_get_device_utilization_rate =
      load_sym(dcmi_lib_handle, "dcmi_get_device_utilization_rate");

  if (!fn_dcmi_init || !fn_dcmi_get_card_list || !fn_dcmi_get_device_num_in_card ||
      !fn_dcmi_get_device_memory_info_v3 || !fn_dcmi_get_device_utilization_rate) {
    log_warn("DCMI backend missing critical symbols");
    dlclose(dcmi_lib_handle);
    dcmi_lib_handle = NULL;
    return -1;
  }

  if (fn_dcmi_init() != DCMI_OK) {
    log_warn("dcmi_init failed");
    dlclose(dcmi_lib_handle);
    dcmi_lib_handle = NULL;
    return -1;
  }

  if (fn_dcmi_get_card_list(&card_num, card_list, NVML_MAX_GPUS) != DCMI_OK ||
      card_num <= 0) {
    log_warn("dcmi_get_card_list failed");
    dlclose(dcmi_lib_handle);
    dcmi_lib_handle = NULL;
    return -1;
  }

  for (int i = 0; i < card_num && count < NVML_MAX_GPUS; i++) {
    int device_num = 0;
    int card_id = card_list[i];

    if (fn_dcmi_get_device_num_in_card(card_id, &device_num) != DCMI_OK ||
        device_num <= 0) {
      continue;
    }

    for (int d = 0; d < device_num && count < NVML_MAX_GPUS; d++) {
      dcmi_devices[count].card_id = card_id;
      dcmi_devices[count].device_id = d;
      count++;
    }
  }

  if (count <= 0) {
    log_warn("DCMI backend found no devices");
    dlclose(dcmi_lib_handle);
    dcmi_lib_handle = NULL;
    return -1;
  }

  dcmi_device_count = count;
  g_backend_kind = GPU_SAMPLER_BACKEND_DCMI;
  return 0;
}

static void sample_dcmi_gpu(int index, struct nvml_gpu_snapshot* snap) {
  struct dcmi_device_ref* dev = &dcmi_devices[index];
  struct dcmi_get_memory_info_stru mem_info;
  unsigned int util = 0;

  snap->gpu_index = index;
  snap->valid = 0;
  snap->process_count = 0;
  snprintf(snap->uuid, sizeof(snap->uuid), "NPU-card%d-dev%d", dev->card_id,
           dev->device_id);
  snprintf(snap->gpu_name, sizeof(snap->gpu_name), "Ascend-NPU");

  memset(&mem_info, 0, sizeof(mem_info));
  if (fn_dcmi_get_device_memory_info_v3(dev->card_id, dev->device_id,
                                        &mem_info) == DCMI_OK) {
    unsigned long long total_u64 =
        mul_u64_sat(mem_info.memory_size, 1024ULL * 1024ULL);
    snap->memory_total = clamp_u64_to_size(total_u64);
    snap->memory_free =
        dcmi_available_to_bytes(mem_info.memory_available, snap->memory_total);
    if (snap->memory_free > snap->memory_total) snap->memory_free = snap->memory_total;
    snap->memory_used = snap->memory_total - snap->memory_free;
    snap->mem_util = util_to_ratio(mem_info.utiliza);
    snap->valid = 1;
  }

  if (fn_dcmi_get_device_utilization_rate(dev->card_id, dev->device_id,
                                          DCMI_UTILIZATION_RATE_NPU,
                                          &util) != DCMI_OK) {
    fn_dcmi_get_device_utilization_rate(dev->card_id, dev->device_id,
                                        DCMI_UTILIZATION_RATE_AICORE, &util);
  }
  snap->gpu_util = util_to_ratio(util);
  if (util > 0) snap->valid = 1;
}

/* ---- ACL fallback backend ---- */

static int init_acl_backend(void) {
  uint32_t count = 0;

  acl_lib_handle = dlopen("libascendcl.so", RTLD_LAZY);
  if (!acl_lib_handle) acl_lib_handle = dlopen("libascendcl.so.1", RTLD_LAZY);
  if (!acl_lib_handle) return -1;

  fn_aclInit = load_sym(acl_lib_handle, "aclInit");
  fn_aclrtGetDeviceCount = load_sym(acl_lib_handle, "aclrtGetDeviceCount");
  fn_aclrtSetDevice = load_sym(acl_lib_handle, "aclrtSetDevice");
  fn_aclrtGetMemInfo = load_sym(acl_lib_handle, "aclrtGetMemInfo");
  fn_aclrtGetDeviceUtilizationRate =
      load_sym(acl_lib_handle, "aclrtGetDeviceUtilizationRate");

  if (!fn_aclrtGetDeviceCount || !fn_aclrtGetMemInfo ||
      !fn_aclrtGetDeviceUtilizationRate) {
    log_warn("ACL backend missing critical symbols");
    dlclose(acl_lib_handle);
    acl_lib_handle = NULL;
    return -1;
  }

  if (fn_aclInit) {
    aclError acl_ret = fn_aclInit(NULL);
    if (acl_ret != ACL_SUCCESS) {
      log_debug("aclInit returned %d (continuing)", acl_ret);
    }
  }

  if (fn_aclrtGetDeviceCount(&count) != ACL_SUCCESS || count == 0) {
    log_warn("aclrtGetDeviceCount failed");
    dlclose(acl_lib_handle);
    acl_lib_handle = NULL;
    return -1;
  }

  acl_device_count = (int)(count < NVML_MAX_GPUS ? count : NVML_MAX_GPUS);
  g_backend_kind = GPU_SAMPLER_BACKEND_ACL;
  return 0;
}

static void sample_acl_gpu(int index, struct nvml_gpu_snapshot* snap) {
  size_t free_mem = 0;
  size_t total_mem = 0;
  unsigned int gpu_pct = 0;
  struct aclrt_utilization_info util_info;

  snap->gpu_index = index;
  snap->valid = 0;
  snap->process_count = 0;
  snprintf(snap->uuid, sizeof(snap->uuid), "NPU-%d", index);
  snprintf(snap->gpu_name, sizeof(snap->gpu_name), "Ascend-NPU");

  if (fn_aclrtSetDevice) {
    fn_aclrtSetDevice(index);
  }

  if (fn_aclrtGetMemInfo(ACL_HBM_MEM, &free_mem, &total_mem) != ACL_SUCCESS) {
    fn_aclrtGetMemInfo(ACL_MEM_NORMAL, &free_mem, &total_mem);
  }
  if (total_mem > 0) {
    snap->memory_total = total_mem;
    snap->memory_free = (free_mem <= total_mem) ? free_mem : total_mem;
    snap->memory_used = total_mem - snap->memory_free;
    snap->valid = 1;
  }

  memset(&util_info, 0, sizeof(util_info));
  if (fn_aclrtGetDeviceUtilizationRate(index, &util_info) == ACL_SUCCESS) {
    if (util_info.cubeUtilization > 0) {
      gpu_pct = (unsigned int)util_info.cubeUtilization;
    }
    if ((unsigned int)util_info.vectorUtilization > gpu_pct) {
      gpu_pct = (unsigned int)util_info.vectorUtilization;
    }
    if (util_info.memoryUtilization > 0) {
      snap->mem_util = util_to_ratio((unsigned int)util_info.memoryUtilization);
    }
    snap->gpu_util = util_to_ratio(gpu_pct);
    if (gpu_pct > 0 || util_info.memoryUtilization > 0) snap->valid = 1;
  }
}

/* ---- Public API ---- */

int nvml_sampler_init(void) {
  pthread_rwlock_init(&g_nvml_snapshot.lock, NULL);
  g_nvml_snapshot.gpu_count = 0;
  g_nvml_snapshot.nvml_available = 0;
  g_nvml_snapshot.sampler_available = 0;
  g_nvml_snapshot.backend_kind = GPU_SAMPLER_BACKEND_NONE;

  if (init_nvml_backend() == 0) {
    g_nvml_snapshot.gpu_count = nvml_device_count;
    g_nvml_snapshot.nvml_available = 1;
    g_nvml_snapshot.sampler_available = 1;
    g_nvml_snapshot.backend_kind = GPU_SAMPLER_BACKEND_NVML;
    log_info("GPU sampler initialized with NVML: %d device(s)", nvml_device_count);
    return 0;
  }

  if (init_dcmi_backend() == 0) {
    g_nvml_snapshot.gpu_count = dcmi_device_count;
    g_nvml_snapshot.nvml_available = 0;
    g_nvml_snapshot.sampler_available = 1;
    g_nvml_snapshot.backend_kind = GPU_SAMPLER_BACKEND_DCMI;
    log_info("GPU sampler initialized with DCMI: %d device(s)", dcmi_device_count);
    return 0;
  }

  if (init_acl_backend() == 0) {
    g_nvml_snapshot.gpu_count = acl_device_count;
    g_nvml_snapshot.nvml_available = 0;
    g_nvml_snapshot.sampler_available = 1;
    g_nvml_snapshot.backend_kind = GPU_SAMPLER_BACKEND_ACL;
    log_info("GPU sampler initialized with ACL fallback: %d device(s)",
             acl_device_count);
    return 0;
  }

  log_warn("No GPU sampler backend available (NVML/DCMI/ACL all unavailable)");
  return -1;
}

void* nvml_sampler_thread_fn(void* arg __attribute__((unused))) {
  struct timespec sleep_ts;

  log_info("GPU sampler thread started (backend=%s, interval=%d ms)",
           backend_to_string(g_backend_kind), g_interval_ms);

  while (1) {
    struct nvml_gpu_snapshot local_snaps[NVML_MAX_GPUS];
    int sample_count = 0;

    memset(local_snaps, 0, sizeof(local_snaps));

    if (g_backend_kind == GPU_SAMPLER_BACKEND_NVML) {
      sample_count = nvml_device_count;
      pthread_rwlock_rdlock(&g_nvml_snapshot.lock);
      for (int i = 0; i < sample_count; i++) {
        memcpy(local_snaps[i].gpu_name, g_nvml_snapshot.gpus[i].gpu_name,
               sizeof(local_snaps[i].gpu_name));
      }
      pthread_rwlock_unlock(&g_nvml_snapshot.lock);

      for (int i = 0; i < sample_count; i++) {
        sample_nvml_gpu(i, &local_snaps[i]);
      }
    } else if (g_backend_kind == GPU_SAMPLER_BACKEND_DCMI) {
      sample_count = dcmi_device_count;
      for (int i = 0; i < sample_count; i++) {
        sample_dcmi_gpu(i, &local_snaps[i]);
      }
    } else if (g_backend_kind == GPU_SAMPLER_BACKEND_ACL) {
      sample_count = acl_device_count;
      for (int i = 0; i < sample_count; i++) {
        sample_acl_gpu(i, &local_snaps[i]);
      }
    }

    pthread_rwlock_wrlock(&g_nvml_snapshot.lock);
    g_nvml_snapshot.gpu_count = sample_count;
    g_nvml_snapshot.nvml_available =
        (g_backend_kind == GPU_SAMPLER_BACKEND_NVML) ? 1 : 0;
    g_nvml_snapshot.sampler_available =
        (g_backend_kind == GPU_SAMPLER_BACKEND_NONE) ? 0 : 1;
    g_nvml_snapshot.backend_kind = g_backend_kind;
    memcpy(g_nvml_snapshot.gpus, local_snaps, sizeof(local_snaps));
    pthread_rwlock_unlock(&g_nvml_snapshot.lock);

    sleep_ts.tv_sec = g_interval_ms / 1000;
    sleep_ts.tv_nsec = (g_interval_ms % 1000) * 1000000L;
    nanosleep(&sleep_ts, NULL);
  }

  return NULL;
}
