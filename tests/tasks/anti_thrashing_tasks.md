# Task: Anti-Thrashing Scheduler Logic

## Meta
- **Design Path**: [anti_thrashing_design.md](../anti_thrashing_design.md)
- **Goal**: Prevent "Live Lock" in high memory contention scenarios by dynamically extending Time Quantum (TQ) when oversubscription is detected.

## Steps

### Phase 1: Scheduler Logic Update
- [x] 1.1 Implement helper `get_total_requested_memory(ctx)` in `scheduler.c`.
- [x] 1.2 Implement helper `get_waiting_client_count(ctx)` in `scheduler.c`.
- [x] 1.3 Modify `calculate_switch_time` to use "Thrashing Logic":
    - If `total_mem > physical_mem`: Double the multiplier.
    - If `wait_count > 0`: Increase Base TQ.
    - Enforce `MIN_TQ = 60s` when under pressure.

### Phase 2: Build & Deploy
- [ ] 2.1 Recompile `nvshare-scheduler` (Docker build).
- [ ] 2.2 Update deployment manifest (if needed) or just redeploy pods.

### Phase 3: Verification
- [ ] 3.1 Run `test-cross-gpu.sh` again.
- [ ] 3.2 Verify logs show TQ >= 60s for the congested GPU.
- [ ] 3.3 Verify completion time is reasonable (< 10-15 mins).
