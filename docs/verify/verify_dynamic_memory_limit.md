# Dynamic GPU Memory Limit via Annotations - Walkthrough

## Summary
Implemented dynamic GPU memory limit adjustment using Kubernetes Pod annotations. Clients can now have their memory limits updated at runtime without Pod restart via `kubectl annotate`.

## Changes Made

### Protocol Extension
| File | Change |
|------|--------|
| [comm.h](file:///Users/luogangyi/Code/nvshare/src/comm.h) | Added `UPDATE_LIMIT=13` to `message_type` enum and `memory_limit` field to `message` struct |
| [comm.c](file:///Users/luogangyi/Code/nvshare/src/comm.c) | Added `UPDATE_LIMIT` string to message type array |

### Client Handling
| File | Change |
|------|--------|
| [hook.c](file:///Users/luogangyi/Code/nvshare/src/hook.c) | Added `limit_mutex` and thread-safe `update_memory_limit()` function |
| [client.c](file:///Users/luogangyi/Code/nvshare/src/client.c) | Added `UPDATE_LIMIT` case handler calling `update_memory_limit()` |

### K8s API Integration
| File | Change |
|------|--------|
| [k8s_api.h](file:///Users/luogangyi/Code/nvshare/src/k8s_api.h) | **NEW** - Header for K8s API helper functions |
| [k8s_api.c](file:///Users/luogangyi/Code/nvshare/src/k8s_api.c) | **NEW** - libcurl-based K8s API client for reading Pod annotations |
| [scheduler.c](file:///Users/luogangyi/Code/nvshare/src/scheduler.c) | Added `memory_limit` to client struct, `annotation_watcher_fn()` thread, `send_update_limit()`, and thread startup in main |

### Build System
| File | Change |
|------|--------|
| [Makefile](file:///Users/luogangyi/Code/nvshare/src/Makefile) | Added `k8s_api.o` to scheduler deps and `-lcurl` to SCHEDULER_LDLIBS |
| [Dockerfile.baseubuntu](file:///Users/luogangyi/Code/nvshare/Dockerfile.baseubuntu) | Added `libcurl4-openssl-dev` |

### Deployment
| File | Change |
|------|--------|
| [scheduler-rbac.yaml](file:///Users/luogangyi/Code/nvshare/kubernetes/manifests/scheduler-rbac.yaml) | **NEW** - ServiceAccount + ClusterRole for Pod read access |
| [scheduler.yaml](file:///Users/luogangyi/Code/nvshare/kubernetes/manifests/scheduler.yaml) | Added `serviceAccountName: nvshare-scheduler` |

## Verification Results

The feature was verified using the `tests/remote-test-dynamic-limit.sh` script, which performs the following steps:
1. Deploys a Pod with no initial memory limit.
2. Annotates the Pod with `nvshare.com/gpu-memory-limit=2Gi`.
3. Updates the annotation to `4Gi`.
4. Removes the annotation.

Scheduler logs confirm the correct behavior:

```
[NVSHARE][INFO]: Client registered: ...
[NVSHARE][INFO]: Memory limit changed for pod default/dynamic-limit-test: 0 -> 2147483648 bytes
[NVSHARE][INFO]: Sending UPDATE_LIMIT to client 6ccb: 2147483648 bytes (2.00 GiB)
[NVSHARE][INFO]: Memory limit changed for pod default/dynamic-limit-test: 2147483648 -> 4294967296 bytes
[NVSHARE][INFO]: Sending UPDATE_LIMIT to client 6ccb: 4294967296 bytes (4.00 GiB)
[NVSHARE][INFO]: Memory limit changed for pod default/dynamic-limit-test: 4294967296 -> 0 bytes
[NVSHARE][INFO]: Sending UPDATE_LIMIT to client 6ccb: 0 bytes (0.00 GiB)
```

The test confirms that:
- Annotations are correctly detected by the scheduler's watcher thread.
- `UPDATE_LIMIT` messages are correctly dispatched to the client.
- The protocol handles dynamic adjustments without restarting the Pod.

## Usage

### Set Dynamic Limit
```bash
kubectl annotate pod <pod-name> nvshare.com/gpu-memory-limit=2Gi
```

### Update Limit
```bash
kubectl annotate pod <pod-name> nvshare.com/gpu-memory-limit=4Gi --overwrite
```

### Remove Limit
```bash
kubectl annotate pod <pod-name> nvshare.com/gpu-memory-limit-
```

## Architecture
```mermaid
sequenceDiagram
    participant User as kubectl
    participant K8s as K8s API
    participant Scheduler as nvshare-scheduler
    participant Client as libnvshare

    User->>K8s: annotate pod (nvshare.com/gpu-memory-limit=4Gi)
    Scheduler->>K8s: Poll annotations (every 5s)
    K8s-->>Scheduler: Return annotation value
    Scheduler->>Client: UPDATE_LIMIT message
    Client->>Client: update_memory_limit(new_limit)
    Note over Client: cuMemAlloc enforces new limit
```

## Phase 2: Complex Verification Scenarios (Test Plan)

This plan utilizes existing images (`nvshare:pytorch-add-small` ~4GB usage, `nvshare:pytorch-add` ~12GB usage) and `kubectl exec` code injection for flexible verification without building new images.

### 1. Multi-Pod Isolation Verification
**Objective:** Verify that limits are enforced independently for multiple pods on the same/different GPUs.
**Prerequisites:**
- Image: `registry.cn-hangzhou.aliyuncs.com/lgytest1/nvshare:pytorch-add-small` (or similar base image with PyTorch)
- Test Script Injection: Use `kubectl exec` to run precise allocations.

**Steps:**
1. **Deploy Pods**:
   - `pod-a`: No initial limit.
   - `pod-b`: No initial limit.
2. **Apply Limits & Verify**:
   - **Pod A (Strict Limit)**:
     - Annotate `pod-a` with limit `1Gi`.
     - Exec injection (Target 2Gi allocation):
       ```bash
       kubectl exec -i pod-a -- python3 -c "import torch; print('Allocating 2Gi...'); x = torch.empty(512*1024*1024, dtype=torch.float32, device='cuda'); print('Success')"
       ```
     - **Expectation**: OOM (RuntimeError).
   - **Pod B (Loose Limit)**:
     - Annotate `pod-b` with limit `3Gi`.
     - Exec injection (Target 2Gi allocation):
       ```bash
       kubectl exec -i pod-b -- python3 -c "import torch; print('Allocating 2Gi...'); x = torch.empty(512*1024*1024, dtype=torch.float32, device='cuda'); print('Success')"
       ```
     - **Expectation**: Success.
3. **Log Verification**:
   - Check scheduler logs to confirm different limits were sent to different Client IDs.

### 2. Dynamic Limit Expansion (Resize)
**Objective:** Verify that increasing the limit at runtime immediately allows larger allocations.
**Steps:**
1. **Start**: Deploy `dynamic-resize-pod` (image: `nvshare:pytorch-add-small`) with limit `1Gi`.
2. **Fail (OOM)**:
   - Exec workload demanding ~2Gi (e.g., standard `pytorch-add-small.py` or injected code).
   - **Expectation**: Fail (OOM).
3. **Resize**:
   - Annotate `dynamic-resize-pod` with `nvshare.com/gpu-memory-limit=4Gi`.
   - Wait 5-10s for scheduler update (Log: "Sending UPDATE_LIMIT").
4. **Succeed**:
   - Exec same workload (~2Gi) again.
   - **Expectation**: Success.

### 3. Stability & Stress Test (Toggle)
**Objective:** Verify system stability under rapid policy changes and repeated allocations.
**Steps:**
1. **Setup**: Deploy `stress-pod` (limit `4Gi`).
2. **Loop (Scripts)**:
   - Run a loop 20 times:
     1. Annotate limit `1Gi`.
     2. Exec "Allocate 2Gi" -> Expect OOM.
     3. Annotate limit `4Gi`.
     4. Exec "Allocate 2Gi" -> Expect Success.
3. **Verify**: Scheduler should not crash; memory should be correctly reclaimed after each step (check `nvidia-smi` or scheduler logs for leakage).

---
**Status:** Plan pending approval.
