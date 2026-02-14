/*
 * NVML Sampler for nvshare-scheduler Prometheus metrics.
 *
 * Periodically samples GPU-level and per-process metrics via NVML
 * using runtime dlopen to avoid build-time NVML dependency.
 */

#ifndef _NVSHARE_NVML_SAMPLER_H_
#define _NVSHARE_NVML_SAMPLER_H_

#include <pthread.h>
#include <stddef.h>
#include <sys/types.h>

#define NVML_MAX_GPUS 16
#define NVML_MAX_PROCESSES_PER_GPU 64

/* Per-process NVML info */
struct nvml_process_info {
  pid_t pid;
  size_t used_memory; /* bytes */
};

/* Per-GPU NVML snapshot */
struct nvml_gpu_snapshot {
  char uuid[96];
  int gpu_index;
  char gpu_name[96];
  size_t memory_total;
  size_t memory_used;
  size_t memory_free;
  float gpu_util; /* 0.0 ~ 1.0 */
  float mem_util; /* 0.0 ~ 1.0 */
  int process_count;
  struct nvml_process_info processes[NVML_MAX_PROCESSES_PER_GPU];
  int valid; /* 1 if data is valid, 0 if NVML call failed */
};

/* Global NVML snapshot (read by metrics exporter) */
struct nvml_snapshot {
  pthread_rwlock_t lock;
  int gpu_count;
  struct nvml_gpu_snapshot gpus[NVML_MAX_GPUS];
  int nvml_available; /* 1 if NVML was loaded successfully */
};

/* Global snapshot instance */
extern struct nvml_snapshot g_nvml_snapshot;

/*
 * Initialize the NVML sampler. Loads NVML via dlopen.
 * Returns 0 on success, -1 if NVML is not available (non-fatal).
 */
int nvml_sampler_init(void);

/*
 * NVML sampler thread function (pass NULL arg).
 * Runs in a loop, refreshing g_nvml_snapshot at the configured interval.
 */
void* nvml_sampler_thread_fn(void* arg);

/*
 * Set the sampling interval in milliseconds (default 1000).
 */
void nvml_sampler_set_interval_ms(int interval_ms);

#endif /* _NVSHARE_NVML_SAMPLER_H_ */
