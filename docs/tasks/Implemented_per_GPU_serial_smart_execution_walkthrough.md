# Serial/Smart Execution Mode Implementation

## Summary

Implemented per-GPU serial/smart execution mode to address performance degradation caused by UVM thrashing during multi-task scenarios.

## Changes Made

### Scheduler (src/scheduler.c)

**New Environment Variables:**
- `NVSHARE_SCHEDULING_MODE`: Controls task scheduling
  - `auto` (default): Smart mode - concurrent if memory fits, serial otherwise
  - `serial`: Force one task at a time per GPU
  - `concurrent`: Original behavior with time-slicing
- `NVSHARE_MAX_RUNTIME_SEC`: Maximum task runtime before forced switch (default: 300s)

**Core Changes:**
- Added `scheduling_mode` enum and config field
- Modified `can_run_with_memory()` to implement smart/serial/concurrent modes
- Updated `timer_thr_fn()` to:
  - Enforce max runtime limit
  - Send `PREPARE_SWAP_OUT` before `DROP_LOCK` for memory eviction hints

---

### Communication (src/comm.h, src/comm.c)

- Added `PREPARE_SWAP_OUT` message type (value: 12) for pre-switch memory eviction

---

### Client (src/client.c)

- Added `PREPARE_SWAP_OUT` case handler that calls `swap_out_all_allocations()`

---

### Hook (src/hook.c, src/cuda_defs.h)

**CUDA API Extensions:**
- Added `CUmem_advise` enum with `CU_MEM_ADVISE_SET_PREFERRED_LOCATION`
- Added `cuMemAdvise_func` typedef and `real_cuMemAdvise` function pointer
- Loaded `cuMemAdvise` symbol in `bootstrap_cuda()`

**New Function:**
- `swap_out_all_allocations()`: Iterates all managed allocations and calls `cuMemAdvise(..., CU_MEM_ADVISE_SET_PREFERRED_LOCATION, CU_DEVICE_CPU)` to hint driver to evict memory to host

---

### Device Plugin (kubernetes/device-plugin/server.go)

**Load Balancing:**
- Enabled `GetPreferredAllocationAvailable` flag
- Implemented `GetPreferredAllocation()` with least-loaded GPU selection
- Added `gpuAllocationCount` map to track allocations per physical GPU

## Verification

| Component | Status |
|-----------|--------|
| Go device-plugin build | ✅ Pass |
| Scheduler compilation | ✅ Verified on target Linux |
| Client/Hook compilation | ✅ Verified on target Linux |

## Environment Variables Summary

| Variable | Default | Values | Description |
|----------|---------|--------|-------------|
| `NVSHARE_SCHEDULING_MODE` | `auto` | auto/serial/concurrent | Scheduling strategy |
| `NVSHARE_MAX_RUNTIME_SEC` | 300 | 10+ | Max task runtime (seconds) |

## Files Modified

| File | Changes |
|------|---------|
| [comm.h](file:///Users/luogangyi/Code/nvshare/src/comm.h) | Added PREPARE_SWAP_OUT message type |
| [comm.c](file:///Users/luogangyi/Code/nvshare/src/comm.c) | Added message type string |
| [cuda_defs.h](file:///Users/luogangyi/Code/nvshare/src/cuda_defs.h) | Added CUmem_advise, cuMemAdvise |
| [scheduler.c](file:///Users/luogangyi/Code/nvshare/src/scheduler.c) | Smart/serial mode, max runtime |
| [hook.c](file:///Users/luogangyi/Code/nvshare/src/hook.c) | swap_out_all_allocations() |
| [client.c](file:///Users/luogangyi/Code/nvshare/src/client.c) | PREPARE_SWAP_OUT handler |
| [server.go](file:///Users/luogangyi/Code/nvshare/kubernetes/device-plugin/server.go) | GetPreferredAllocation load balancing |
