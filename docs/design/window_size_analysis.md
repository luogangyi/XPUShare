# Kernel Window Instability Analysis

## Symptom
The kernel window size oscillates (2 -> 4 -> 8 -> 16 -> 2) and fails to reach the optimal size (64+), resulting in poor GPU utilization. Logs show "Early release timer elapsed" but no explicit "Critical timeout" errors, yet the window resets.

## Root Cause Analysis
1.  **Strict AIMD Logic**: The current Adaptive Flow Control reduces the window size significantly (`/2`) upon critical timeouts (>10s) and resets to 1 upon "Abuse detection" (3 consecutive timeouts).
2.  **Insufficient Swap Tolerance**: The recently implemented "First Sync Exemption" only ignores the *very first* `cuCtxSynchronize` call after lock acquisition.
3.  **Extended Swap Phase**: In severe oversubscription (300%), the "Swap-In" process (page faults) may last longer than a single sync window, or occur intermittently during the initial phase of the time slice.
    -   If the first sync takes 20s (exempted), the window grows (e.g., 2 -> 4).
    -   The next batch of kernels (window=4) might *also* hit page faults or contend for PCIe bandwidth, causing another timeout (e.g., 12s).
    -   Since this is the *second* sync, it is NOT exempted. The window is halved (4 -> 2) and the violation counter increments.
    -   Repeated violations trigger "Abuse Detection", forcing the window to 1.

## Proposed Solution: Global Grace Period
Instead of exempting only the *first* sync, we should implement a **Time-Based Grace Period**.
-   **Logic**: Ignore ALL timeouts (Critical or Mild) that occur within the first **X seconds** (e.g., 30s) of acquiring the lock.
-   **Rationale**: This covers the entire "Swap-In" transient phase. Once the memory is fully resident (after ~30s), the timeouts will accurately reflect actual GPU contention/overload, allowing AIMD to work correctly for the remainder of the slice (which is now 60s+ thanks to Anti-Thrashing).

## Implementation Plan
Modify `src/hook.c`:
1.  Calculate `time_since_lock_acquire = now - lock_acquire_time`.
2.  In the timeout check logic:
    ```c
    if (time_since_lock_acquire < 30) {
        // In Grace Period: Ignore timeout, force growth or maintain window
        log_info("Grace Period (%lds): Ignoring timeout...", time_since_lock_acquire);
        // grow or keep window
    } else {
        // Standard AIMD logic
    }
    ```
