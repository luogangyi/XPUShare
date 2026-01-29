# Multi-GPU Support Walkthrough

I have implemented multi-GPU support for `nvshare`. The solution allows `nvshare` to detect and manage multiple GPUs independently, ensuring that exclusive access (locking) is enforced per physical GPU.

## Changes Overview

### 1. Protocol Update (`comm.h`)
-   **GPU UUID in Messages**: Updated `struct message` to include `char gpu_uuid[64]`. This allows the client to inform the scheduler which GPU it is using.
-   Added `NVSHARE_GPU_UUID_LEN` definition.

### 2. Client-Side Identification (`client.c`, `hook.c`)
-   **UUID Detection**: The client now detects the physical GPU UUID using `cuDeviceGetUuid` (via `hook.c` symbol loading) at startup.
-   **Registration**: When registering with the scheduler, the client sends this UUID.
-   **Resource Monitoring**: `release_early_fn` now uses `nvmlDeviceGetHandleByUUID` to monitor the correct GPU's utilization.

### 3. Scheduler Refactoring (`scheduler.c`)
-   **Per-GPU State**: Introduced `struct gpu_state` to track the lock status (`lock_held`, `owner`, `expiration`) for each unique GPU UUID discovered.
-   **Global Request Queue**: Maintained a global FCFS `requests` list.
-   **Scheduling Logic (`try_schedule`)**:
    -   Iterates through the request queue.
    -   Checks the state of the requested GPU.
    -   If the GPU is free, grants the lock to that client and marks the specific GPU as busy.
-   **Timer Thread (`timer_thr_fn`)**:
    -   Now manages multiple concurrent deadlines.
    -   Calculates the nearest expiration time among all held locks to determine sleep duration.
    -   On wakeup, checks each GPU state and sends `DROP_LOCK` to any owner whose time quantum has elapsed.

## Verification
To verify the changes, you can run multiple instances of the test scripts on a multi-GPU machine (or simulate it).

1.  **Build**: Run `make` to rebuild `libnvshare.so`, `nvshare-scheduler`, etc.
2.  **Run Scheduler**: Start `nvshare-scheduler`.
3.  **Run Clients**:
    -   Client A (GPU 0): `CUDA_VISIBLE_DEVICES=0 LD_PRELOAD=./libnvshare.so python tests/tf-matmul.py`
    -   Client B (GPU 1): `CUDA_VISIBLE_DEVICES=1 LD_PRELOAD=./libnvshare.so python tests/tf-matmul.py`
    -   Client C (GPU 0): `CUDA_VISIBLE_DEVICES=0 LD_PRELOAD=./libnvshare.so python tests/tf-matmul.py`
4.  **Expected Behavior**:
    -   Client A and Client B should run **in parallel** (different GPUs).
    -   Client C should wait for Client A to finish (same GPU).
