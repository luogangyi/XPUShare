#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_FUNCTIONAL_CASES="FUNC-001 FUNC-002 FUNC-003 FUNC-004 FUNC-005 FUNC-006 FUNC-007 FUNC-008 FUNC-009 FUNC-010 FUNC-011 FUNC-012"

xp_func_case_label() {
  echo "xpf-$(xp_case_slug "$1")"
}

xp_func_count_phase() {
  local app_label="$1"
  local phase="$2"
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "^${phase}$" || true
}

xp_func_expect_group_success() {
  local app_label="$1"
  local count="$2"
  local workload="$3"
  local core_limit="$4"
  local mem_ann="$5"
  local mem_env="$6"
  local oversub="$7"
  local timeout_sec="$8"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" "$count" "$workload" "$core_limit" "$mem_ann" "$mem_env" "$oversub"
  xp_wait_for_label_terminal "$app_label" "$timeout_sec"

  xp_collect_common_artifacts "$app_label"

  local succeeded
  succeeded=$(xp_func_count_phase "$app_label" "Succeeded")
  [ "$succeeded" -eq "$count" ]
}

xp_func_expect_group_failure() {
  local app_label="$1"
  local count="$2"
  local workload="$3"
  local core_limit="$4"
  local mem_ann="$5"
  local mem_env="$6"
  local oversub="$7"
  local timeout_sec="$8"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" "$count" "$workload" "$core_limit" "$mem_ann" "$mem_env" "$oversub"
  xp_wait_for_label_terminal "$app_label" "$timeout_sec" || true

  xp_collect_common_artifacts "$app_label"

  local failed succeeded
  failed=$(xp_func_count_phase "$app_label" "Failed")
  succeeded=$(xp_func_count_phase "$app_label" "Succeeded")

  if [ "$failed" -ge 1 ]; then
    return 0
  fi

  # fallback: consider OOM log as failure signal
  if grep -Erq "OutOfMemory|CUDA_ERROR_OUT_OF_MEMORY|Memory allocation rejected|OOM" "$XPUSHARE_CASE_LOG_DIR/pods"; then
    return 0
  fi

  # if all succeeded, this is unexpected for failure case
  [ "$succeeded" -lt "$count" ]
}

xp_case_FUNC_001() {
  local app_label
  app_label=$(xp_func_case_label "FUNC-001")
  xp_func_expect_group_success "$app_label" 1 w2 "" "" "" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"
}

xp_case_FUNC_002() {
  local app_label pod1 pod2
  app_label=$(xp_func_case_label "FUNC-002")

  xp_func_expect_group_success "$app_label" 2 w2 "" "" "" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"

  pod1="$app_label-1"
  pod2="$app_label-2"
  if xp_compare_two_pods_gpu "$pod1" "$pod2"; then
    xp_log_info "FUNC-002: pods landed on same GPU"
  else
    xp_log_warn "FUNC-002: pods did not land on same GPU (best-effort check)"
  fi

  return 0
}

xp_case_FUNC_003() {
  local app_label
  app_label=$(xp_func_case_label "FUNC-003")
  xp_func_expect_group_success "$app_label" 12 w2 "" "" "" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"
}

xp_case_FUNC_004() {
  local app_label
  app_label=$(xp_func_case_label "FUNC-004")
  xp_func_expect_group_failure "$app_label" 1 w4 "" "" "" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"
}

xp_case_FUNC_005() {
  local app_label
  app_label=$(xp_func_case_label "FUNC-005")

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 1 w4 "" "" "" 1
  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if grep -Erq "Memory allocations exceeded physical GPU memory capacity|PASS|OutOfMemory|CUDA_ERROR_OUT_OF_MEMORY" "$XPUSHARE_CASE_LOG_DIR/pods"; then
    # For oversub case we allow both success and pressure-related failure as long as system does not crash.
    if [ "$(xp_count_running_scheduler)" -ge 1 ]; then
      return 0
    fi
  fi
  return 1
}

xp_case_FUNC_006() {
  local app_label
  app_label=$(xp_func_case_label "FUNC-006")
  xp_func_expect_group_failure "$app_label" 1 w2 "" "" "1Gi" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"
}

xp_case_FUNC_007() {
  local app_label limit
  app_label=$(xp_func_case_label "FUNC-007")

  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    limit="8Gi"
  else
    limit="4Gi"
  fi

  xp_func_expect_group_success "$app_label" 1 w2 "" "" "$limit" 0 "$XP_DEFAULT_POD_TIMEOUT_SEC"
}

xp_case_FUNC_008() {
  local base q app_label runtime d25 d50 d75
  base=$(xp_func_case_label "FUNC-008")

  : > "$XPUSHARE_CASE_LOG_DIR/durations.txt"

  for q in 25 50 75; do
    app_label="${base}-q${q}"
    xp_cleanup_app "$app_label"
    xp_apply_workload_group "$app_label" 1 w2 "$q" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"
    xp_collect_common_artifacts "$app_label"

    runtime=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${app_label}-1.log")
    echo "quota=$q runtime=$runtime" >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"

    case "$q" in
      25) d25="$runtime" ;;
      50) d50="$runtime" ;;
      75) d75="$runtime" ;;
    esac
  done

  if [ -n "${d25:-}" ] && [ -n "${d50:-}" ] && [ -n "${d75:-}" ]; then
    awk -v a="$d25" -v b="$d50" -v c="$d75" 'BEGIN{exit !(a>b && b>c)}'
  else
    return 1
  fi
}

xp_case_FUNC_009() {
  local app_label p30 p60 d30 d60
  app_label=$(xp_func_case_label "FUNC-009")
  p30="${app_label}-30"
  p60="${app_label}-60"

  xp_cleanup_app "$app_label"

  xp_apply_workload_pod "$p30" "$app_label" w2 "30" "" "" 0
  xp_apply_workload_pod "$p60" "$app_label" w2 "60" "" "" 0

  xp_wait_for_pod_terminal "$p30" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null
  xp_wait_for_pod_terminal "$p60" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null
  xp_collect_common_artifacts "$app_label"

  d30=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p30}.log")
  d60=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p60}.log")
  echo "runtime_30=$d30 runtime_60=$d60" > "$XPUSHARE_CASE_LOG_DIR/runtime_compare.txt"

  if [ -n "$d30" ] && [ -n "$d60" ]; then
    awk -v a="$d30" -v b="$d60" 'BEGIN{exit !(a>b)}'
  else
    return 1
  fi
}

xp_case_FUNC_010() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-010")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "" "4Gi" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "8Gi"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Eq "Memory limit changed|Sending UPDATE_LIMIT|gpu-memory-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"
}

xp_case_FUNC_011() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-011")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "" "8Gi" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "2Gi"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Eq "Memory limit changed|Sending UPDATE_LIMIT|gpu-memory-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"
}

xp_case_FUNC_012() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-012")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "30" "" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "80"
  xp_safe_sleep 12
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "100"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Eq "Compute limit changed|UPDATE_CORE_LIMIT|gpu-core-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"
}

xp_run_functional_case() {
  local case_id="$1"
  local case_fn
  local summary="ok"
  case_fn="${case_id//-/_}"

  xp_case_begin "functional" "$case_id"

  if "xp_case_${case_fn}"; then
    xp_case_end "PASS" "$summary"
    return 0
  fi

  xp_case_end "FAIL" "case assertion failed"
  return 1
}

xp_run_functional_suite() {
  local filter="${1:-all}"
  local case_id fail_count
  fail_count=0

  for case_id in $XP_FUNCTIONAL_CASES; do
    if [ "$filter" != "all" ] && [ "$filter" != "$case_id" ]; then
      continue
    fi

    if xp_case_should_skip "functional" "$case_id"; then
      continue
    fi

    if ! xp_run_functional_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}
