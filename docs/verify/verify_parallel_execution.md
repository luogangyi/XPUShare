# Verify Parallel Execution Mode

## Objective
Verify that `nvshare` enables parallel execution of multiple tasks on the same GPU when their combined memory usage fits within the GPU's physical memory capacity.

Current Implementation (Smart Mode) logic:
- If `(sum of currently running usage + new request usage) <= GPU limit`: Allow `SCHED_ON` (Parallel).
- If `(sum of currently running usage + new request usage) > GPU limit`: Enforce Serial execution (Wait for lock).

## Prerequisites
1. `nvshare` components running in the cluster (Scheduler, Device Plugin).
2. `NVSHARE_SCHEDULING_MODE` is set to `auto` (Default) or `concurrent`.
3. A standardized small workload image (e.g., `nvshare-pytorch-small-pod-1.yaml`) where we know the approximate memory usage.
   - Example: If the workload uses ~1GB and GPU has 16GB, running 2-4 pods should result in parallel execution.

## Verification Method

### 1. Test Setup: Small Workload
Use the `.tests/remote-test-small.sh` script to deploy pods with small memory footprints.

**Command:**
```bash
# Run 2 small pods
bash .tests/remote-test-small.sh 2
```

### 2. Observation
Observe the behavior of the pods and the scheduler logs.

#### Expected Parallel Behavior
1. **Pod Status**: All pods generally stay in `Running` state simultaneously.
2. **Scheduler Logs**:
   - You should see multiple `SCHED_ON` messages for different Client IDs without intervening `DROP_LOCK` messages.
   - Example Log pattern:
     ```
     [INFO]: Client A registered
     [INFO]: Client B registered
     [DEBUG]: Sending SCHED_ON to Client A
     [DEBUG]: Sending SCHED_ON to Client B  <-- Parallel execution allowed
     ```
3. **Pod Logs**:
   - `kubectl logs -f <pod-name>`
   - Both pods should show progress (e.g., progress bars updating) at the same time.
   - TIMESTAMPS in the logs should overlap.

### 3. Contrast with Serial Execution (For Confirmation)
To verify the "Smart" logic works (switching to serial when full), you would need to run enough pods to exceed memory, OR force serial mode.

**Force Serial Mode Verification (Optional Contrast):**
1. Set `NVSHARE_SCHEDULING_MODE=serial` in the DaemonSet.
2. Run the same test (`bash .tests/remote-test-small.sh 2`).
3. **Expected Result**:
   - One pod runs while the other halts (logs stop updating or don't start).
   - Scheduler logs show `DROP_LOCK` for one client before `SCHED_ON` for the other (time-slicing) OR one waits until the first finishes.

## Automated Verification Script
A script to analyze the concurrency based on timestamps.

See: `docs/verify/scripts/analyze_concurrency.py` (Proposed)

### Manual Checklist
- [ ] Run `bash .tests/remote-test-small.sh 2`
- [ ] Check `kubectl logs -n nvshare-system -l name=nvshare-scheduler`
- [ ] Confirm multiple clients have active "Running" status in scheduler internal state (if debug logs show it) or imply it by lack of `DROP_LOCK`.
- [ ] Confirm pod logs show overlapping execution times.
