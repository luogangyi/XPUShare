# Implementation Plan - Multi-GPU Support

## Goal
Enable `nvshare` to support nodes with multiple GPUs. Currently, the scheduler enforces a single global lock, serializing access across all GPUs as if they were one resource. The goal is to manage locks and scheduling independently for each physical GPU.

## User Review Required
> [!IMPORTANT]
> **Protocol Change**: The communication protocol between `libnvshare` (client) and `nvshare-scheduler` will be updated. `struct message` will now include a `gpu_uuid` field. This is a compatible change if we append it or use reserved space, but effectively requires rebuilding both components.

> [!WARNING]
> **Scheduling Logic**: The single timer thread in the scheduler will be refactored to handle multiple concurrent deadlines (one per active GPU lock).

## Proposed Changes

### Communication Layer (`src/comm.h`)
-   Update `struct message` to include `char gpu_uuid[64]`.
-   Define `NVSHARE_GPU_UUID_LEN 64`.

### Client Side (`src/client.c`, `src/hook.c`)
-   **Identify GPU**: In `client_fn` (or during initialization), determine which physical GPU the application is using.
    -   Use `cuDeviceGet` (device 0 relative to process) to `cuDeviceGetUuid` (or `cuDeviceGetPCIBusId`) to get a unique identifier code.
    -   We will leverage NVML or CUDA Driver API to get the UUID. Since `hook.c` already loads CUDA symbols, we can use `cuDeviceGetUuid`.
-   **Register with UUID**: When sending `REGISTER` message, populate `gpu_uuid`.
-   **Request Lock**: `REQ_LOCK` messages (or the client registration context) will associate the client with a specific GPU.
-   **Early Release**: Update `release_early_fn` logic. Instead of finding device index 0 (`nvmlDeviceGetHandleByIndex(0, ...)`), finding the device handle by UUID (`nvmlDeviceGetHandleByUUID`).

### Scheduler (`src/scheduler.c`)
-   **Data Structures**:
    -   Modify `struct nvshare_client` to store the `gpu_uuid` it is registered for.
    -   Maintain a mapped structure for locks: `struct gpu_state { char uuid[64]; int lock_held; struct nvshare_client *owner; ... }`.
    -   Alternatively, keep a list of `gpu_states`.
-   **Request Queue**:
    -   The single `requests` list can remain, but `try_schedule` must traverse it to find the first request *for a GPU that is currently free*.
    -   OR maintain separate request queues per GPU. A global list is simpler to implement FCFS globally or per-GPU (if we skip requests for busy GPUs, it's FCFS per-GPU).
-   **Timer Thread**:
    -   Refactor `timer_thr_fn`. instead of waiting for a single deadline, it needs to handle multiple.
    -   Since we likely have few GPUs (e.g., < 8), we can iterate over all active GPU locks to find the nearest deadline.
    -   Wait for `min(deadlines)`.
    -   When waking up, check which GPUs have exceeded their TQ.

## Verification Plan

### Automated Tests
-   The repo has `tests/`. We can simulate multiple clients.
-   To simulate multi-GPU on a single GPU machine (likely the dev environment), we might need to mock UUIDs or manually force clients to claim different "virtual" UUIDs.
-   If the user has a multi-GPU environment, we can run `tf-matmul.py` instances on different GPUs (via `CUDA_VISIBLE_DEVICES`) and verify they can run in parallel.

### Manual Verification
1.  **Single GPU Regression**: Ensure existing single-GPU workflow still works.
2.  **Multi-GPU Parallelism**:
    -   Bind Client A to GPU 0.
    -   Bind Client B to GPU 1.
    -   Verify A and B can hold locks simultaneously.
    -   Bind Client C to GPU 0.
    -   Verify C waits for A, while B continues running.

