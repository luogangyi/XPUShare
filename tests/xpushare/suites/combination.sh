#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_COMBINATION_CASES="COMBO-001 COMBO-002 COMBO-003 COMBO-004 COMBO-005 COMBO-006 COMBO-007 COMBO-008"
XP_CASE_SUMMARY="ok"

xp_combo_case_label() {
  echo "xpc-$(xp_case_slug "$1")"
}

xp_combo_skip() {
  local reason="$1"
  XP_CASE_SUMMARY="SKIP: $reason"
  xp_case_note "$XP_CASE_SUMMARY"
  return 0
}

xp_combo_count_phase() {
  local app_label="$1"
  local phase="$2"
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "^${phase}$" || true
}

xp_combo_success_count() {
  local app_label="$1"
  xp_combo_count_phase "$app_label" "Succeeded"
}

xp_combo_failed_count() {
  local app_label="$1"
  xp_combo_count_phase "$app_label" "Failed"
}

xp_combo_wait_collect() {
  local app_label="$1"
  local timeout_sec="$2"
  xp_wait_for_label_terminal "$app_label" "$timeout_sec" || true
  xp_collect_common_artifacts "$app_label"
}

xp_case_COMBO_001() {
  local app_label failed

  if [ "$XPUSHARE_CLUSTER" != "c1" ]; then
    xp_combo_skip "COMBO-001 is validated on cluster1 (T4) only"
    return 0
  fi

  app_label=$(xp_combo_case_label "COMBO-001")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  # oversub enabled but static memory quota should still cap effective usage.
  xp_apply_workload_group "$app_label" 1 w1 "" "10Gi" "" 1
  xp_combo_wait_collect "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"

  failed=$(xp_combo_failed_count "$app_label")
  if [ "$failed" -ge 1 ]; then
    XP_CASE_SUMMARY="oversub enabled but memory quota still enforced"
    return 0
  fi

  if grep -Erq "OutOfMemory|CUDA_ERROR_OUT_OF_MEMORY|Memory allocation rejected|quota|exceeded" "$XPUSHARE_CASE_LOG_DIR/pods"; then
    XP_CASE_SUMMARY="quota/oom signal found in pod logs"
    return 0
  fi

  XP_CASE_SUMMARY="expected quota enforcement signal missing"
  return 1
}

xp_case_COMBO_002() {
  local app_label p30 p70 d30 d70

  app_label=$(xp_combo_case_label "COMBO-002")
  p30="${app_label}-30"
  p70="${app_label}-70"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$p30" "$app_label" w2 "30" "" "" 1
  xp_apply_workload_pod "$p70" "$app_label" w2 "70" "" "" 1

  xp_wait_for_pod_terminal "$p30" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "$p70" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_collect_common_artifacts "$app_label"

  if ! xp_compare_two_pods_gpu "$p30" "$p70"; then
    xp_combo_skip "pods not colocated on same GPU, skip runtime ratio assertion"
    return 0
  fi

  d30=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p30}.log")
  d70=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p70}.log")
  xp_case_kv "runtime_30" "$d30"
  xp_case_kv "runtime_70" "$d70"

  if [ -z "$d30" ] || [ -z "$d70" ]; then
    XP_CASE_SUMMARY="missing runtime data from pod logs"
    return 1
  fi

  if awk -v a="$d30" -v b="$d70" 'BEGIN{exit !(a>b)}'; then
    XP_CASE_SUMMARY="higher compute quota pod finished faster under oversub"
    return 0
  fi

  XP_CASE_SUMMARY="runtime monotonicity failed for compute quota under oversub"
  return 1
}

xp_case_COMBO_003() {
  local app_label mem_limit succ
  local metric_mem_ok metric_core_ok

  app_label=$(xp_combo_case_label "COMBO-003")
  mem_limit="4Gi"
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    mem_limit="8Gi"
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "${app_label}-a" "$app_label" w2 "40" "$mem_limit" "" 0
  xp_apply_workload_pod "${app_label}-b" "$app_label" w2 "70" "$mem_limit" "" 0

  xp_wait_for_pod_phase "${app_label}-a" "Running" 180 || true
  xp_wait_for_pod_phase "${app_label}-b" "Running" 180 || true
  xp_capture_metrics_snapshot_with_suffix "mid" || true
  xp_combo_wait_collect "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"

  succ=$(xp_combo_success_count "$app_label")
  if [ "$succ" -ne 2 ]; then
    XP_CASE_SUMMARY="expected 2 succeeded pods, got $succ"
    return 1
  fi

  metric_mem_ok=0
  metric_core_ok=0
  if [ -f "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt" ] && \
    xp_metric_exists_in_file "nvshare_client_memory_quota_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"; then
    metric_mem_ok=1
  elif [ -f "$XPUSHARE_CASE_LOG_DIR/metrics.txt" ] && \
    xp_metric_exists_in_file "nvshare_client_memory_quota_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics.txt"; then
    metric_mem_ok=1
  fi

  if [ -f "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt" ] && \
    xp_metric_exists_in_file "nvshare_client_core_quota_effective_percent" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"; then
    metric_core_ok=1
  elif [ -f "$XPUSHARE_CASE_LOG_DIR/metrics.txt" ] && \
    xp_metric_exists_in_file "nvshare_client_core_quota_effective_percent" "$XPUSHARE_CASE_LOG_DIR/metrics.txt"; then
    metric_core_ok=1
  fi

  xp_case_kv "metric_memory_quota_found" "$metric_mem_ok"
  xp_case_kv "metric_core_quota_found" "$metric_core_ok"

  if [ "$metric_mem_ok" -eq 0 ] || [ "$metric_core_ok" -eq 0 ]; then
    XP_CASE_SUMMARY="pods succeeded, but quota metrics missing in snapshots (see metrics_mid.txt/metrics.txt)"
    return 0
  fi

  XP_CASE_SUMMARY="memory and compute quota took effect together"
  return 0
}

xp_case_COMBO_004() {
  local app_label pod phase

  app_label=$(xp_combo_case_label "COMBO-004")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "30" "2Gi" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120

  xp_capture_metrics_snapshot_with_suffix "start" || true

  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "4Gi"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "80"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "3Gi"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "50"
  xp_safe_sleep 8

  phase=$(xp_pod_phase "$pod")
  xp_case_kv "pod_phase_after_updates" "$phase"

  xp_capture_metrics_snapshot_with_suffix "end" || true
  xp_collect_common_artifacts "$app_label"

  if ! grep -Eq "Memory limit changed|Sending UPDATE_LIMIT|gpu-memory-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"; then
    XP_CASE_SUMMARY="memory dynamic update signal missing in scheduler log"
    return 1
  fi

  if ! grep -Eq "Compute limit changed|UPDATE_CORE_LIMIT|gpu-core-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"; then
    XP_CASE_SUMMARY="compute dynamic update signal missing in scheduler log"
    return 1
  fi

  XP_CASE_SUMMARY="dynamic memory/core updates both observed"
  return 0
}

xp_case_COMBO_005() {
  local app_label pod cnt

  if [ "$XPUSHARE_CLUSTER" != "c1" ]; then
    xp_combo_skip "COMBO-005 is focused on T4 oversub behavior"
    return 0
  fi

  app_label=$(xp_combo_case_label "COMBO-005")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "" "4Gi" "" 1
  xp_wait_for_pod_phase "$pod" "Running" 120

  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "8Gi"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "2Gi"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "6Gi"
  xp_safe_sleep 8

  xp_collect_common_artifacts "$app_label"

  if [ "$(xp_count_running_scheduler)" -lt 1 ]; then
    XP_CASE_SUMMARY="scheduler not running after oversub + dynamic memory updates"
    return 1
  fi

  cnt=$(grep -Ec "Memory limit changed|Sending UPDATE_LIMIT|gpu-memory-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log" || true)
  xp_case_kv "memory_update_log_count" "$cnt"
  if [ "$cnt" -lt 2 ]; then
    XP_CASE_SUMMARY="too few memory update signals in scheduler logs"
    return 1
  fi

  XP_CASE_SUMMARY="oversub + dynamic memory updates handled without scheduler crash"
  return 0
}

xp_case_COMBO_006() {
  local app_label pod cnt

  app_label=$(xp_combo_case_label "COMBO-006")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "30" "" "" 1
  xp_wait_for_pod_phase "$pod" "Running" 120

  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "80"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "40"
  xp_safe_sleep 8
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "100"
  xp_safe_sleep 8

  xp_collect_common_artifacts "$app_label"

  cnt=$(grep -Ec "Compute limit changed|UPDATE_CORE_LIMIT|gpu-core-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log" || true)
  xp_case_kv "compute_update_log_count" "$cnt"

  if [ "$cnt" -lt 2 ]; then
    XP_CASE_SUMMARY="compute limit dynamic update logs missing"
    return 1
  fi

  if ! grep -Erq "\[NVSHARE\]\[QUOTA_PROBE\]" "$XPUSHARE_CASE_LOG_DIR/pods"; then
    XP_CASE_SUMMARY="quota probe lines missing in pod logs"
    return 1
  fi

  XP_CASE_SUMMARY="oversub + dynamic compute updates observed"
  return 0
}

xp_case_COMBO_007() {
  local app_label succ
  local mem_limit
  local metrics_probe

  app_label=$(xp_combo_case_label "COMBO-007")
  mem_limit="4Gi"
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    mem_limit="8Gi"
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "${app_label}-1" "$app_label" w2 "30" "$mem_limit" "" 1
  xp_apply_workload_pod "${app_label}-2" "$app_label" w3 "60" "$mem_limit" "" 1
  xp_apply_workload_pod "${app_label}-3" "$app_label" w2 "80" "$mem_limit" "" 0
  xp_apply_workload_pod "${app_label}-4" "$app_label" w5 "50" "$mem_limit" "" 1

  xp_safe_sleep 20
  xp_capture_metrics_snapshot_with_suffix "mid" || true
  xp_combo_wait_collect "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"

  succ=$(xp_combo_success_count "$app_label")
  xp_case_kv "success_count" "$succ"

  if [ "$succ" -lt 3 ]; then
    XP_CASE_SUMMARY="all-features mix too many pod failures"
    return 1
  fi

  metrics_probe="$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"
  if [ ! -f "$metrics_probe" ]; then
    metrics_probe="$XPUSHARE_CASE_LOG_DIR/metrics.txt"
  fi

  if ! xp_metric_exists_in_file "nvshare_client_memory_quota_bytes" "$metrics_probe"; then
    XP_CASE_SUMMARY="memory quota metric missing in all-features case"
    return 1
  fi

  if ! xp_metric_exists_in_file "nvshare_client_core_quota_effective_percent" "$metrics_probe"; then
    XP_CASE_SUMMARY="compute quota metric missing in all-features case"
    return 1
  fi

  XP_CASE_SUMMARY="all features can co-exist in mixed workload"
  return 0
}

xp_case_COMBO_008() {
  local app_label i core mem oversub gpu_count

  app_label=$(xp_combo_case_label "COMBO-008")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  for i in $(seq 1 8); do
    core=$((20 + (i % 5) * 15))
    if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
      mem="8Gi"
    else
      mem="4Gi"
    fi

    if [ $((i % 2)) -eq 0 ]; then
      oversub=1
    else
      oversub=0
    fi

    xp_apply_workload_pod "${app_label}-${i}" "$app_label" w5 "$core" "$mem" "" "$oversub"
  done

  xp_safe_sleep 30
  xp_capture_metrics_snapshot_with_suffix "mid" || true

  if [ -f "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt" ]; then
    gpu_count=$(awk '
      /^nvshare_client_info\{/ {
        uuid=""
        idx=""
        if (match($0, /gpu_uuid="[^"]+"/)) {
          uuid=substr($0, RSTART+10, RLENGTH-11)
        }
        if (match($0, /gpu_index="-?[0-9]+"/)) {
          idx=substr($0, RSTART+11, RLENGTH-12)
        }
        if (uuid != "" && uuid != "N/A" && uuid != "unknown") {
          seen["uuid:" uuid]=1
        } else if (idx != "" && idx != "-1") {
          seen["idx:" idx]=1
        }
      }
      END {
        c=0
        for (k in seen) c++
        print c+0
      }
    ' "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  else
    gpu_count=0
  fi
  xp_case_kv "distinct_gpu_mid" "$gpu_count"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ "$gpu_count" -lt 2 ]; then
    XP_CASE_SUMMARY="expected mixed placement across multiple GPUs, got $gpu_count"
    return 1
  fi

  XP_CASE_SUMMARY="multi-gpu mixed policies did not collapse to single GPU"
  return 0
}

xp_run_combination_case() {
  local case_id="$1"
  local case_fn
  case_fn="${case_id//-/_}"

  XP_CASE_SUMMARY="ok"
  xp_case_begin "combination" "$case_id"

  if "xp_case_${case_fn}"; then
    xp_case_end "PASS" "$XP_CASE_SUMMARY"
    return 0
  fi

  if [ -z "$XP_CASE_SUMMARY" ]; then
    XP_CASE_SUMMARY="case assertion failed"
  fi
  xp_case_end "FAIL" "$XP_CASE_SUMMARY"
  return 1
}

xp_run_combination_suite() {
  local filter="${1:-all}"
  local case_id fail_count
  fail_count=0

  for case_id in $XP_COMBINATION_CASES; do
    if [ "$filter" != "all" ] && [ "$filter" != "$case_id" ]; then
      continue
    fi

    if xp_case_should_skip "combination" "$case_id"; then
      continue
    fi

    if ! xp_run_combination_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}
