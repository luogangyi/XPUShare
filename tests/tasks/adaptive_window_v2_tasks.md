# Task: Adaptive Kernel Window V2

## Meta
- **Design Path**: [adaptive_window_v2_design.md](../adaptive_window_v2_design.md)
- **Goal**: Fix the logical flaw where warm-up protection expires during long page faults, causing unnecessary performance degradation.

## Steps

### Phase 1: Implementation
- [x] 1.1 Modify `hook.c`: Move `in_warmup` check before `real_cuCtxSynchronize`.
- [x] 1.2 Modify `hook.c`: Ensure `in_warmup` snapshot is used for decision making after sync.

### Phase 2: Configuration & Build
- [/] 2.1 Recompile `libnvshare.so` (Docker build) - *Stuck/Slow*
- [ ] 2.2 Update test manifests to use `NVSHARE_KERN_WARMUP_PERIOD_SEC=60`.

### Phase 3: Verification
- [ ] 3.1 Run `test-cross-gpu.sh` (4 Pods).
- [ ] 3.2 Analyze logs to confirm `Ignored critical timeout` appears even for >20s delays.
