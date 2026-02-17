#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_PERFORMANCE_CASES="PERF-001 PERF-002 PERF-003 PERF-004 PERF-005 PERF-006 PERF-007 PERF-008"
XP_CASE_SUMMARY="ok"

XP_PERF_METRICS_OVERHEAD_MAX_PCT="${XP_PERF_METRICS_OVERHEAD_MAX_PCT:-5}"
XP_PERF_MIX_RATIO_MIN="${XP_PERF_MIX_RATIO_MIN:-1.15}"
XP_PERF_SCALE_SET="${XP_PERF_SCALE_SET:-}"

xp_perf_case_label() {
  echo "xpp-$(xp_case_slug "$1")"
}

xp_perf_skip() {
  local reason="$1"
  XP_CASE_SUMMARY="SKIP: $reason"
  xp_case_note "$XP_CASE_SUMMARY"
  return 0
}

xp_perf_scale_set_resolved() {
  if [ -n "$XP_PERF_SCALE_SET" ]; then
    echo "$XP_PERF_SCALE_SET"
    return 0
  fi

  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    if [ -n "$XP_PERF_SCALE_SET_C2" ]; then
      echo "$XP_PERF_SCALE_SET_C2"
    else
      echo "8 16 32 64 96 128 $XP_CLUSTER_C2_TOTAL_VGPU"
    fi
    return 0
  fi

  if [ -n "$XP_PERF_SCALE_SET_C1" ]; then
    echo "$XP_PERF_SCALE_SET_C1"
  else
    echo "2 4 8 16 24 32 $XP_CLUSTER_C1_TOTAL_VGPU"
  fi
  return 0
}

xp_perf_runtime_for_pod() {
  local pod_name="$1"
  xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${pod_name}.log"
}

xp_perf_case_run_single_pod() {
  local app_label="$1"
  local workload="$2"
  local core="$3"
  local mem_ann="$4"
  local mem_env="$5"
  local oversub="$6"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2
  xp_apply_workload_group "$app_label" 1 "$workload" "$core" "$mem_ann" "$mem_env" "$oversub"
  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"
}

xp_case_PERF_001() {
  local app_label pod runtime phase

  app_label=$(xp_perf_case_label "PERF-001")
  pod="${app_label}-1"

  xp_perf_case_run_single_pod "$app_label" w2 "" "" "" 0

  phase=$(xp_pod_phase "$pod")
  runtime=$(xp_perf_runtime_for_pod "$pod")
  xp_case_kv "baseline_phase" "$phase"
  xp_case_kv "baseline_runtime_sec" "$runtime"

  if [ "$phase" != "Succeeded" ]; then
    XP_CASE_SUMMARY="baseline pod did not succeed"
    return 1
  fi
  if [ -z "$runtime" ]; then
    XP_CASE_SUMMARY="baseline runtime not found in pod log"
    return 1
  fi

  XP_CASE_SUMMARY="baseline runtime captured"
  return 0
}

xp_case_PERF_002() {
  local off_label on_label off_pod on_pod off_runtime on_runtime delta
  local scrape_pid=""

  off_label="$(xp_perf_case_label "PERF-002")-off"
  on_label="$(xp_perf_case_label "PERF-002")-on"
  off_pod="${off_label}-1"
  on_pod="${on_label}-1"

  xp_perf_case_run_single_pod "$off_label" w2 "" "" "" 0
  off_runtime=$(xp_perf_runtime_for_pod "$off_pod")
  xp_case_kv "runtime_metrics_off" "$off_runtime"

  xp_cleanup_app "$on_label"
  xp_safe_sleep 2
  xp_capture_metrics_repeated "$XPUSHARE_CASE_LOG_DIR/metrics_stress.txt" "$XP_METRICS_STRESS_DURATION_SEC" "$XP_METRICS_SCRAPE_INTERVAL_SEC" &
  scrape_pid=$!

  xp_apply_workload_group "$on_label" 1 w2 "" "" "" 0
  xp_wait_for_label_terminal "$on_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true

  if [ -n "$scrape_pid" ]; then
    kill "$scrape_pid" >/dev/null 2>&1 || true
    wait "$scrape_pid" 2>/dev/null || true
  fi

  xp_collect_common_artifacts "$on_label"
  on_runtime=$(xp_perf_runtime_for_pod "$on_pod")
  xp_case_kv "runtime_metrics_on" "$on_runtime"

  if [ -z "$off_runtime" ] || [ -z "$on_runtime" ]; then
    XP_CASE_SUMMARY="missing runtime for metrics overhead case"
    return 1
  fi

  delta=$(awk -v off="$off_runtime" -v on="$on_runtime" 'BEGIN{if (off<=0){print 999}else{printf "%.3f", ((on-off)/off)*100}}')
  xp_case_kv "metrics_overhead_pct" "$delta"

  if awk -v d="$delta" -v m="$XP_PERF_METRICS_OVERHEAD_MAX_PCT" 'BEGIN{exit !(d<=m)}'; then
    XP_CASE_SUMMARY="metrics scrape overhead within threshold"
    return 0
  fi

  XP_CASE_SUMMARY="metrics scrape overhead exceeds threshold"
  return 1
}

xp_case_PERF_003() {
  local base q app_label pod runtime d25 d50 d75

  base=$(xp_perf_case_label "PERF-003")
  : > "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"

  for q in 25 50 75; do
    app_label="${base}-q${q}"
    pod="${app_label}-1"

    xp_perf_case_run_single_pod "$app_label" w2 "$q" "" "" 0
    runtime=$(xp_perf_runtime_for_pod "$pod")
    echo "quota=$q runtime=$runtime" >> "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"

    case "$q" in
      25) d25="$runtime" ;;
      50) d50="$runtime" ;;
      75) d75="$runtime" ;;
    esac
  done

  if [ -z "${d25:-}" ] || [ -z "${d50:-}" ] || [ -z "${d75:-}" ]; then
    XP_CASE_SUMMARY="missing one or more quota runtimes"
    return 1
  fi

  if awk -v a="$d25" -v b="$d50" -v c="$d75" 'BEGIN{exit !(a>b && b>c)}'; then
    XP_CASE_SUMMARY="single-task runtime monotonic with compute quota"
    return 0
  fi

  XP_CASE_SUMMARY="runtime monotonicity failed for 25/50/75 quota"
  return 1
}

xp_case_PERF_004() {
  local app_label p30 p60 d30 d60 ratio

  app_label=$(xp_perf_case_label "PERF-004")
  p30="${app_label}-30"
  p60="${app_label}-60"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$p30" "$app_label" w2 "30" "" "" 0
  xp_apply_workload_pod "$p60" "$app_label" w2 "60" "" "" 0

  xp_wait_for_pod_terminal "$p30" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "$p60" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_collect_common_artifacts "$app_label"

  if ! xp_compare_two_pods_gpu "$p30" "$p60"; then
    xp_perf_skip "pods not on same GPU, skip mixed-quota ratio assertion"
    return 0
  fi

  d30=$(xp_perf_runtime_for_pod "$p30")
  d60=$(xp_perf_runtime_for_pod "$p60")
  if [ -z "$d30" ] || [ -z "$d60" ]; then
    XP_CASE_SUMMARY="missing runtime data for mixed-quota case"
    return 1
  fi

  ratio=$(awk -v a="$d30" -v b="$d60" 'BEGIN{if (b<=0){print 999}else{printf "%.3f", a/b}}')
  xp_case_kv "runtime_ratio_30_over_60" "$ratio"

  if awk -v r="$ratio" -v min="$XP_PERF_MIX_RATIO_MIN" 'BEGIN{exit !(r>=min)}'; then
    XP_CASE_SUMMARY="mixed quota runtime ratio matches expectation"
    return 0
  fi

  XP_CASE_SUMMARY="mixed quota runtime ratio below expectation"
  return 1
}

xp_case_PERF_005() {
  local off_label on_label off_pod on_pod off_phase on_phase off_runtime on_runtime

  if [ "$XPUSHARE_CLUSTER" != "c1" ]; then
    xp_perf_skip "PERF-005 targets T4 cluster1"
    return 0
  fi

  off_label="$(xp_perf_case_label "PERF-005")-off"
  on_label="$(xp_perf_case_label "PERF-005")-on"
  off_pod="${off_label}-1"
  on_pod="${on_label}-1"

  xp_perf_case_run_single_pod "$off_label" w1 "" "" "" 0
  off_phase=$(xp_pod_phase "$off_pod")
  off_runtime=$(xp_perf_runtime_for_pod "$off_pod")

  xp_perf_case_run_single_pod "$on_label" w1 "" "" "" 1
  on_phase=$(xp_pod_phase "$on_pod")
  on_runtime=$(xp_perf_runtime_for_pod "$on_pod")

  xp_case_kv "oversub_off_phase" "$off_phase"
  xp_case_kv "oversub_on_phase" "$on_phase"
  xp_case_kv "oversub_off_runtime" "$off_runtime"
  xp_case_kv "oversub_on_runtime" "$on_runtime"

  if [ "$off_phase" = "Failed" ] && [ "$on_phase" = "Succeeded" ]; then
    XP_CASE_SUMMARY="oversub enabled run succeeded while disabled run failed"
    return 0
  fi

  if [ "$off_phase" = "Succeeded" ] && [ "$on_phase" = "Succeeded" ] && [ -n "$off_runtime" ] && [ -n "$on_runtime" ]; then
    XP_CASE_SUMMARY="both oversub modes succeeded; performance curve recorded"
    return 0
  fi

  XP_CASE_SUMMARY="unable to obtain stable oversub comparison"
  return 1
}

xp_case_PERF_006() {
  local off_label on_label off_pod on_pod off_phase on_phase off_runtime on_runtime

  if [ "$XPUSHARE_CLUSTER" != "c2" ]; then
    xp_perf_skip "PERF-006 targets A800 cluster2"
    return 0
  fi

  off_label="$(xp_perf_case_label "PERF-006")-off"
  on_label="$(xp_perf_case_label "PERF-006")-on"
  off_pod="${off_label}-1"
  on_pod="${on_label}-1"

  xp_perf_case_run_single_pod "$off_label" w1 "" "" "" 0
  off_phase=$(xp_pod_phase "$off_pod")
  off_runtime=$(xp_perf_runtime_for_pod "$off_pod")

  xp_perf_case_run_single_pod "$on_label" w1 "" "" "" 1
  on_phase=$(xp_pod_phase "$on_pod")
  on_runtime=$(xp_perf_runtime_for_pod "$on_pod")

  xp_case_kv "a800_oversub_off_phase" "$off_phase"
  xp_case_kv "a800_oversub_on_phase" "$on_phase"
  xp_case_kv "a800_oversub_off_runtime" "$off_runtime"
  xp_case_kv "a800_oversub_on_runtime" "$on_runtime"

  if [ "$on_phase" != "Succeeded" ]; then
    XP_CASE_SUMMARY="oversub enabled run failed unexpectedly on A800"
    return 1
  fi

  XP_CASE_SUMMARY="A800 oversub comparison recorded"
  return 0
}

xp_case_PERF_007() {
  local app_label pod update_ts observed_ts latency_sec tmp_metrics

  app_label=$(xp_perf_case_label "PERF-007")
  pod="${app_label}-1"
  tmp_metrics="$XPUSHARE_CASE_LOG_DIR/metrics_probe.txt"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "25" "" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120

  update_ts=$(date +%s)
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "75"

  observed_ts=0
  while true; do
    xp_capture_metrics_snapshot "$tmp_metrics" || true
    if grep -Eq "^nvshare_client_core_quota_config_percent\{[^}]*pod=\"$pod\"[^}]*\}[[:space:]]+75(\\.0+)?$" "$tmp_metrics"; then
      observed_ts=$(date +%s)
      break
    fi

    if [ "$(date +%s)" -ge $((update_ts + 60)) ]; then
      break
    fi
    sleep 2
  done

  xp_wait_for_pod_terminal "$pod" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_collect_common_artifacts "$app_label"

  if [ "$observed_ts" -eq 0 ]; then
    XP_CASE_SUMMARY="dynamic compute quota not observed in metrics within 60s"
    return 1
  fi

  latency_sec=$((observed_ts - update_ts))
  xp_case_kv "dynamic_compute_metric_latency_sec" "$latency_sec"

  if [ "$latency_sec" -le "$XP_DYNAMIC_UPDATE_EXPECT_SEC" ]; then
    XP_CASE_SUMMARY="dynamic compute update latency within target"
    return 0
  fi

  XP_CASE_SUMMARY="dynamic compute update latency too high"
  return 1
}

xp_case_PERF_008() {
  local base n app_label start_ts end_ts elapsed succ scale_set

  base=$(xp_perf_case_label "PERF-008")
  scale_set=$(xp_perf_scale_set_resolved)
  xp_case_kv "scale_set" "$scale_set"
  : > "$XPUSHARE_CASE_LOG_DIR/scale_results.txt"

  for n in $scale_set; do
    app_label="${base}-n${n}"

    xp_cleanup_app "$app_label"
    xp_safe_sleep 2

    start_ts=$(date +%s)
    xp_apply_workload_group "$app_label" "$n" w2 "50" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
    end_ts=$(date +%s)

    elapsed=$((end_ts - start_ts))
    succ=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Succeeded$' || true)
    echo "pods=$n elapsed_sec=$elapsed success=$succ" >> "$XPUSHARE_CASE_LOG_DIR/scale_results.txt"

    xp_collect_common_artifacts "$app_label"

    if [ "$succ" -lt 1 ]; then
      XP_CASE_SUMMARY="scale $n produced zero succeeded pods"
      return 1
    fi
  done

  XP_CASE_SUMMARY="scale ladder completed and recorded"
  return 0
}

xp_run_performance_case() {
  local case_id="$1"
  local case_fn
  case_fn="${case_id//-/_}"

  XP_CASE_SUMMARY="ok"
  xp_case_begin "performance" "$case_id"

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

xp_run_performance_suite() {
  local filter="${1:-all}"
  local case_id fail_count
  fail_count=0

  for case_id in $XP_PERFORMANCE_CASES; do
    if [ "$filter" != "all" ] && [ "$filter" != "$case_id" ]; then
      continue
    fi

    if xp_case_should_skip "performance" "$case_id"; then
      continue
    fi

    if ! xp_run_performance_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}
