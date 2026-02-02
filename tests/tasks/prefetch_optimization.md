# Task: Simple Prefetch Optimization

## Objective
Implement a "Simple Prefetch" strategy to mitigate the Page Fault Storm observed under 300% oversubscription.
By proactively moving memory to the GPU via DMA (`cuMemPrefetchAsync`) when a time slice begins, we aim to convert the bottleneck from **Latency** (millions of faults) to **Bandwidth** (bulk transfer).

## Scope
-   **File**: `src/hook.c`
-   **Mechanism**:
    1.  Load `cuMemPrefetchAsync` symbol from CUDA driver.
    2.  Implement `prefetch_to_gpu()`:
        -   Check available GPU memory (`cuMemGetInfo`).
        -   Calculate total size of all tracked allocations (`cuda_allocation_list`).
        -   If `Total_Alloc < Free_Mem`, call `cuMemPrefetchAsync` for every allocation.
    3.  Trigger Prefetch:
        -   In `cuLaunchKernel` (or potentially `cuMemcpy`), immediately after `continue_with_lock()` returns.
        -   Detect "New Slice" by comparing `lock_acquire_time` (global) with a static `last_prefetch_time`.

## Steps
- [ ] **Load Symbol**: Add `real_cuMemPrefetchAsync` to `bootstrap_cuda`.
- [ ] **Implement Prefetch Logic**: Create `prefetch_to_gpu` function to iterate `cuda_allocation_list` and call prefetch if memory allows.
- [ ] **Insert Hook**: Add trigger logic in `cuLaunchKernel` after lock acquisition.
- [ ] **Verify**: Build and deploy via `remote-test.sh` and observe if the 50s timeout disappears (or drastically reduces).
