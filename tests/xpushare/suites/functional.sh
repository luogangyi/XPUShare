#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_FUNCTIONAL_CASES="FUNC-001 FUNC-002 FUNC-003 FUNC-004 FUNC-005 FUNC-006 FUNC-007 FUNC-008 FUNC-009 FUNC-010 FUNC-011 FUNC-012"
XP_FUNC_QUOTA_REPEATS_NPU="${XP_FUNC_QUOTA_REPEATS_NPU:-1}"
XP_FUNC_NPU_QUOTA_WORKLOAD="${XP_FUNC_NPU_QUOTA_WORKLOAD:-w7}"
XP_FUNC_CUDA_QUOTA_WORKLOAD="${XP_FUNC_CUDA_QUOTA_WORKLOAD:-w2}"
XP_FUNC_NPU_QUOTA_MIN_RATIO_25="${XP_FUNC_NPU_QUOTA_MIN_RATIO_25:-3.5}"
XP_FUNC_NPU_QUOTA_MIN_RATIO_50="${XP_FUNC_NPU_QUOTA_MIN_RATIO_50:-1.7}"
XP_FUNC_NPU_QUOTA_MIN_RATIO_75="${XP_FUNC_NPU_QUOTA_MIN_RATIO_75:-1.2}"
XP_FUNC_NPU_MIX_MIN_RATIO_30="${XP_FUNC_NPU_MIX_MIN_RATIO_30:-2.8}"
XP_FUNC_NPU_MIX_MIN_RATIO_60="${XP_FUNC_NPU_MIX_MIN_RATIO_60:-1.5}"
XP_FUNC_NPU_MIX_MIN_30_OVER_60="${XP_FUNC_NPU_MIX_MIN_30_OVER_60:-1.5}"

xp_func_case_label() {
  echo "xpf-$(xp_case_slug "$1")"
}

xp_func_quota_workload() {
  if [ "$(xp_cluster_backend "$XPUSHARE_CLUSTER")" = "npu" ]; then
    echo "$XP_FUNC_NPU_QUOTA_WORKLOAD"
    return 0
  fi
  echo "$XP_FUNC_CUDA_QUOTA_WORKLOAD"
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
  local effective_count

  effective_count=$(xp_effective_group_count "$count")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" "$count" "$workload" "$core_limit" "$mem_ann" "$mem_env" "$oversub"
  xp_wait_for_label_terminal "$app_label" "$timeout_sec"

  xp_collect_common_artifacts "$app_label"

  local succeeded
  succeeded=$(xp_func_count_phase "$app_label" "Succeeded")
  [ "$succeeded" -eq "$effective_count" ]
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
  local effective_count

  effective_count=$(xp_effective_group_count "$count")
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
  [ "$succeeded" -lt "$effective_count" ]
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

  # Fallback: in rare API races pod logs may not be captured into case dir.
  if [ ! -f "$XPUSHARE_CASE_LOG_DIR/pods/${app_label}-1.log" ]; then
    mkdir -p "$XPUSHARE_CASE_LOG_DIR/pods"
    kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" logs "${app_label}-1" \
      > "$XPUSHARE_CASE_LOG_DIR/pods/${app_label}-1.log" 2>&1 || true
  fi

  if grep -Erq "Memory allocations exceeded physical GPU memory capacity|PASS|OutOfMemory|NPU out of memory|CUDA_ERROR_OUT_OF_MEMORY|AclrtSynchronizeDeviceWithTimeout|aicore execution is abnormal|error code is 507015" "$XPUSHARE_CASE_LOG_DIR/pods"; then
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
  local base q app_label runtime d25 d50 d75 d100
  local r25 r50 r75
  local backend repeats rep runtimes agg_runtime
  local workload
  base=$(xp_func_case_label "FUNC-008")
  backend=$(xp_cluster_backend "$XPUSHARE_CLUSTER")
  workload=$(xp_func_quota_workload)
  repeats=1
  if [ "$backend" = "npu" ]; then
    repeats="$XP_FUNC_QUOTA_REPEATS_NPU"
  fi

  : > "$XPUSHARE_CASE_LOG_DIR/durations.txt"

  runtimes=""
  for rep in $(seq 1 "$repeats"); do
    if [ "$repeats" -gt 1 ]; then
      app_label="${base}-q100-r${rep}"
    else
      app_label="${base}-q100"
    fi
    xp_cleanup_app "$app_label"
    xp_apply_workload_group "$app_label" 1 "$workload" "100" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"
    xp_collect_common_artifacts "$app_label"

    runtime=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${app_label}-1.log")
    echo "quota=100 repeat=$rep runtime=$runtime workload=$workload" >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"
    if [ -n "$runtime" ]; then
      runtimes="$runtimes $runtime"
    fi
  done
  d100=$(printf '%s\n' $runtimes | sort -n | awk '
    NF>0 {a[++n]=$1}
    END {
      if (n==0) exit 1
      if (n%2==1) {
        print a[(n+1)/2]
      } else {
        print (a[n/2] + a[n/2+1]) / 2
      }
    }')
  echo "quota=100 median_runtime=$d100 repeats=$repeats workload=$workload" >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"

  for q in 25 50 75; do
    runtimes=""
    for rep in $(seq 1 "$repeats"); do
      if [ "$repeats" -gt 1 ]; then
        app_label="${base}-q${q}-r${rep}"
      else
        app_label="${base}-q${q}"
      fi
      xp_cleanup_app "$app_label"
      xp_apply_workload_group "$app_label" 1 "$workload" "$q" "" "" 0
      xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC"
      xp_collect_common_artifacts "$app_label"

      runtime=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${app_label}-1.log")
      echo "quota=$q repeat=$rep runtime=$runtime workload=$workload" >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"
      if [ -n "$runtime" ]; then
        runtimes="$runtimes $runtime"
      fi
    done

    agg_runtime=$(printf '%s\n' $runtimes | sort -n | awk '
      NF>0 {a[++n]=$1}
      END {
        if (n==0) exit 1
        if (n%2==1) {
          print a[(n+1)/2]
        } else {
          print (a[n/2] + a[n/2+1]) / 2
        }
      }')
    runtime="$agg_runtime"
    echo "quota=$q median_runtime=$runtime repeats=$repeats" >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"

    case "$q" in
      25) d25="$runtime" ;;
      50) d50="$runtime" ;;
      75) d75="$runtime" ;;
    esac
  done

  if [ -z "${d100:-}" ] || [ -z "${d25:-}" ] || [ -z "${d50:-}" ] || [ -z "${d75:-}" ]; then
    return 1
  fi

  r25=$(awk -v a="$d25" -v b="$d100" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  r50=$(awk -v a="$d50" -v b="$d100" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  r75=$(awk -v a="$d75" -v b="$d100" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  echo "ratio25_vs_base=$r25 ratio50_vs_base=$r50 ratio75_vs_base=$r75 base_runtime=$d100 workload=$workload" \
    >> "$XPUSHARE_CASE_LOG_DIR/durations.txt"
  xp_case_kv "func_quota_base_runtime_sec" "$d100"
  xp_case_kv "func_quota_ratio25_vs_base" "$r25"
  xp_case_kv "func_quota_ratio50_vs_base" "$r50"
  xp_case_kv "func_quota_ratio75_vs_base" "$r75"
  xp_case_kv "func_quota_workload" "$workload"

  if [ "$backend" = "npu" ]; then
    awk -v d25="$d25" -v d50="$d50" -v d75="$d75" \
      -v r25="$r25" -v r50="$r50" -v r75="$r75" \
      -v min25="$XP_FUNC_NPU_QUOTA_MIN_RATIO_25" \
      -v min50="$XP_FUNC_NPU_QUOTA_MIN_RATIO_50" \
      -v min75="$XP_FUNC_NPU_QUOTA_MIN_RATIO_75" '
      BEGIN {
        cond_order=(d25 > d50 && d50 > d75)
        cond_ratio=(r25 >= min25 && r50 >= min50 && r75 >= min75)
        exit !(cond_order && cond_ratio)
      }'
    return $?
  fi

  awk -v a="$d25" -v b="$d50" -v c="$d75" 'BEGIN{exit !(a>b && b>c)}'
}

xp_case_FUNC_009() {
  local app_label p30 p60 base_app base_runtime d30 d60 r30 r60 r30_60 workload backend
  app_label=$(xp_func_case_label "FUNC-009")
  backend=$(xp_cluster_backend "$XPUSHARE_CLUSTER")
  workload=$(xp_func_quota_workload)
  p30="${app_label}-30"
  p60="${app_label}-60"
  base_app="${app_label}-q100"

  xp_cleanup_app "$base_app"
  xp_apply_workload_group "$base_app" 1 "$workload" "100" "" "" 0
  xp_wait_for_label_terminal "$base_app" "$XP_DEFAULT_POD_TIMEOUT_SEC"
  xp_collect_common_artifacts "$base_app"
  base_runtime=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${base_app}-1.log")

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$p30" "$app_label" "$workload" "30" "" "" 0
  xp_apply_workload_pod "$p60" "$app_label" "$workload" "60" "" "" 0

  xp_wait_for_pod_terminal "$p30" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null
  xp_wait_for_pod_terminal "$p60" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null
  xp_collect_common_artifacts "$app_label"

  d30=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p30}.log")
  d60=$(xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${p60}.log")
  r30=$(awk -v a="$d30" -v b="$base_runtime" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  r60=$(awk -v a="$d60" -v b="$base_runtime" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  r30_60=$(awk -v a="$d30" -v b="$d60" 'BEGIN{if (b<=0){print 999}else{printf "%.4f", a/b}}')
  echo "workload=$workload baseline_100=$base_runtime runtime_30=$d30 runtime_60=$d60 ratio30_vs_base=$r30 ratio60_vs_base=$r60 ratio30_over_60=$r30_60" \
    > "$XPUSHARE_CASE_LOG_DIR/runtime_compare.txt"
  xp_case_kv "func_mix_base_runtime_sec" "$base_runtime"
  xp_case_kv "func_mix_ratio30_vs_base" "$r30"
  xp_case_kv "func_mix_ratio60_vs_base" "$r60"
  xp_case_kv "func_mix_ratio30_over_60" "$r30_60"
  xp_case_kv "func_mix_workload" "$workload"

  if [ -z "$base_runtime" ] || [ -z "$d30" ] || [ -z "$d60" ]; then
    return 1
  fi

  if [ "$backend" = "npu" ]; then
    awk -v d30="$d30" -v d60="$d60" \
      -v r30="$r30" -v r60="$r60" -v r3060="$r30_60" \
      -v min30="$XP_FUNC_NPU_MIX_MIN_RATIO_30" \
      -v min60="$XP_FUNC_NPU_MIX_MIN_RATIO_60" \
      -v min3060="$XP_FUNC_NPU_MIX_MIN_30_OVER_60" \
      'BEGIN{exit !(d30 > d60 && r30 >= min30 && r60 >= min60 && r3060 >= min3060)}'
    return $?
  fi

  awk -v a="$d30" -v b="$d60" 'BEGIN{exit !(a>b)}'
}

xp_case_FUNC_010() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-010")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "" "4Gi" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_memory_limit_annotation "$pod" "8Gi"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Erq "Received UPDATE_LIMIT: new limit = 8589934592|Memory limit updated: .*8\\.00 GiB" "$XPUSHARE_CASE_LOG_DIR/pods"
}

xp_case_FUNC_011() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-011")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "" "8Gi" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_memory_limit_annotation "$pod" "2Gi"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Erq "Received UPDATE_LIMIT: new limit = 2147483648|Memory limit updated: .*2\\.00 GiB" "$XPUSHARE_CASE_LOG_DIR/pods"
}

xp_case_FUNC_012() {
  local app_label pod
  app_label=$(xp_func_case_label "FUNC-012")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_apply_workload_pod "$pod" "$app_label" w5 "30" "" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 90

  xp_update_core_limit_annotation "$pod" "80"
  xp_safe_sleep 12
  xp_update_core_limit_annotation "$pod" "100"
  xp_safe_sleep 12

  xp_collect_common_artifacts "$app_label"
  grep -Erq "Received UPDATE_CORE_LIMIT: new core limit = 100%|Core limit updated dynamically to 100%" "$XPUSHARE_CASE_LOG_DIR/pods"
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
