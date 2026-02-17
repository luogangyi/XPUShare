#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_METRICS_CASES="MET-001 MET-002 MET-003 MET-004 MET-005 MET-006 MET-007 MET-008"
XP_CASE_SUMMARY="ok"

XP_METRIC_HIGH_MEM_ALERT_RATIO="${XP_METRIC_HIGH_MEM_ALERT_RATIO:-0.80}"
XP_METRIC_UTIL_MIN_RATIO="${XP_METRIC_UTIL_MIN_RATIO:-0.10}"

xp_met_case_label() {
  echo "xpm-$(xp_case_slug "$1")"
}

xp_met_skip() {
  local reason="$1"
  XP_CASE_SUMMARY="SKIP: $reason"
  xp_case_note "$XP_CASE_SUMMARY"
  return 0
}

xp_met_metric_value_for_pod() {
  local metric_name="$1"
  local pod_name="$2"
  local metric_file="$3"

  awk -v metric="$metric_name" -v pod="$pod_name" '
    $0 ~ ("^" metric "\\{") && $0 ~ ("pod=\"" pod "\"") {print $NF; exit}
  ' "$metric_file"
}

xp_met_metric_max_in_file() {
  local metric_name="$1"
  local metric_file="$2"

  awk -v metric="$metric_name" '
    $0 ~ ("^" metric "([ {].*)?$") {
      v=$NF+0
      if (v>max) max=v
    }
    END {printf "%.6f\n", max+0}
  ' "$metric_file"
}

xp_case_MET_001() {
  local health_code

  xp_capture_metrics_health "$XPUSHARE_CASE_LOG_DIR/metrics_health.txt"
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics.txt"
  health_code=$(xp_http_code_from_file "$XPUSHARE_CASE_LOG_DIR/metrics_health.txt")

  if [ "$health_code" != "200" ]; then
    XP_CASE_SUMMARY="/healthz is not HTTP 200 (code=${health_code:-NA})"
    return 1
  fi

  if ! grep -q '^nvshare_' "$XPUSHARE_CASE_LOG_DIR/metrics.txt"; then
    XP_CASE_SUMMARY="/metrics has no nvshare metrics"
    return 1
  fi

  XP_CASE_SUMMARY="/healthz and /metrics are available"
  return 0
}

xp_case_MET_002() {
  local app_label pod metric missing
  local required_metrics

  required_metrics="\
    nvshare_gpu_info\
    nvshare_gpu_memory_total_bytes\
    nvshare_gpu_memory_used_bytes\
    nvshare_gpu_utilization_ratio\
    nvshare_client_info\
    nvshare_client_managed_allocated_bytes\
    nvshare_client_nvml_used_bytes\
    nvshare_client_memory_quota_bytes\
    nvshare_client_core_quota_config_percent\
    nvshare_client_core_quota_effective_percent\
    nvshare_client_core_window_usage_ms\
    nvshare_client_core_window_limit_ms\
    nvshare_client_throttled\
    nvshare_scheduler_running_clients\
    nvshare_scheduler_wait_queue_clients\
    nvshare_scheduler_messages_total"

  app_label=$(xp_met_case_label "MET-002")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w2 "50" "" "" 0
  if ! xp_wait_for_pod_phase "$pod" "Running" 120; then
    xp_collect_common_artifacts "$app_label"
    xp_cleanup_app "$app_label"
    XP_CASE_SUMMARY="probe pod did not reach Running, cannot verify client metrics"
    return 1
  fi
  xp_safe_sleep 8

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics.txt"

  : > "$XPUSHARE_CASE_LOG_DIR/missing_metrics.txt"
  for metric in $required_metrics; do
    if ! xp_metric_exists_in_file "$metric" "$XPUSHARE_CASE_LOG_DIR/metrics.txt"; then
      echo "$metric" >> "$XPUSHARE_CASE_LOG_DIR/missing_metrics.txt"
    fi
  done

  missing=$(wc -l "$XPUSHARE_CASE_LOG_DIR/missing_metrics.txt" | awk '{print $1}')
  xp_case_kv "missing_metric_count" "$missing"
  xp_collect_common_artifacts "$app_label"
  xp_cleanup_app "$app_label"

  if [ "$missing" -eq 0 ]; then
    XP_CASE_SUMMARY="all required metrics are present"
    return 0
  fi

  XP_CASE_SUMMARY="missing required metrics (see missing_metrics.txt)"
  return 1
}

xp_case_MET_003() {
  local app_label pod nvml_sum need_sum gpu_used_sum managed_sum running_clients
  local has_need_estimated

  app_label=$(xp_met_case_label "MET-003")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 1 w2 "" "" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120
  xp_safe_sleep 10

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"

  nvml_sum=$(xp_metric_sum_in_file "nvshare_client_nvml_used_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  managed_sum=$(xp_metric_sum_in_file "nvshare_client_managed_allocated_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  gpu_used_sum=$(xp_metric_sum_in_file "nvshare_gpu_memory_used_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  running_clients=$(xp_metric_sum_in_file "nvshare_scheduler_running_clients" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  has_need_estimated=0
  need_sum=0
  if xp_metric_exists_in_file "nvshare_client_memory_need_estimated_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"; then
    has_need_estimated=1
    need_sum=$(xp_metric_sum_in_file "nvshare_client_memory_need_estimated_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  fi

  xp_case_kv "sum_client_nvml_used_bytes" "$nvml_sum"
  xp_case_kv "sum_client_managed_allocated_bytes" "$managed_sum"
  xp_case_kv "sum_client_memory_need_estimated_bytes" "$need_sum"
  xp_case_kv "sum_gpu_memory_used_bytes" "$gpu_used_sum"
  xp_case_kv "has_memory_need_estimated_metric" "$has_need_estimated"
  xp_case_kv "scheduler_running_clients" "$running_clients"

  xp_collect_common_artifacts "$app_label"
  xp_cleanup_app "$app_label"

  if ! awk -v c="$running_clients" 'BEGIN{exit !(c>=1)}'; then
    XP_CASE_SUMMARY="snapshot captured no running clients"
    return 1
  fi

  if ! awk -v a="$nvml_sum" -v b="$managed_sum" 'BEGIN{exit !(a>0 || b>0)}'; then
    XP_CASE_SUMMARY="both nvml_used and managed_allocated are zero during workload"
    return 1
  fi

  if ! awk -v c="$gpu_used_sum" 'BEGIN{exit !(c>0)}'; then
    XP_CASE_SUMMARY="gpu_memory_used_bytes is not positive during workload"
    return 1
  fi

  if [ "$has_need_estimated" = "1" ] && ! awk -v b="$need_sum" 'BEGIN{exit !(b>0)}'; then
    XP_CASE_SUMMARY="memory_need_estimated metric exists but value is not positive"
    return 1
  fi

  XP_CASE_SUMMARY="memory metrics exposed and consistent in trend"
  return 0
}

xp_case_MET_004() {
  local app_label pod mem_limit mem_quota core_quota

  app_label=$(xp_met_case_label "MET-004")
  pod="${app_label}-1"

  mem_limit="4Gi"
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    mem_limit="8Gi"
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "35" "$mem_limit" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120
  xp_safe_sleep 6

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt"
  mem_quota=$(xp_met_metric_value_for_pod "nvshare_client_memory_quota_bytes" "$pod" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")
  core_quota=$(xp_met_metric_value_for_pod "nvshare_client_core_quota_config_percent" "$pod" "$XPUSHARE_CASE_LOG_DIR/metrics_mid.txt")

  xp_case_kv "metric_memory_quota_bytes" "$mem_quota"
  xp_case_kv "metric_core_quota_percent" "$core_quota"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ -z "$mem_quota" ] || [ -z "$core_quota" ]; then
    XP_CASE_SUMMARY="quota metrics for target pod missing"
    return 1
  fi

  if ! awk -v m="$mem_quota" -v c="$core_quota" 'BEGIN{exit !(m>0 && c>=35)}'; then
    XP_CASE_SUMMARY="quota metric value mismatch"
    return 1
  fi

  XP_CASE_SUMMARY="quota metrics align with pod configuration"
  return 0
}

xp_case_MET_005() {
  local app_label pod old_mem observed_ts update_ts latency_sec
  local tmp_metrics core_now mem_now
  local start_mem update_mem

  app_label=$(xp_met_case_label "MET-005")
  pod="${app_label}-1"
  tmp_metrics="$XPUSHARE_CASE_LOG_DIR/metrics_probe.txt"
  start_mem="4Gi"
  update_mem="6Gi"
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    start_mem="8Gi"
    update_mem="12Gi"
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_pod "$pod" "$app_label" w5 "30" "$start_mem" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120
  xp_safe_sleep 5

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt"
  old_mem=$(xp_met_metric_value_for_pod "nvshare_client_memory_quota_bytes" "$pod" "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt")
  if [ -z "$old_mem" ]; then
    old_mem=0
  fi

  update_ts=$(date +%s)
  xp_update_annotation "$pod" "nvshare.com/gpu-memory-limit" "$update_mem"
  xp_update_annotation "$pod" "nvshare.com/gpu-core-limit" "80"

  observed_ts=0
  while true; do
    xp_capture_metrics_snapshot "$tmp_metrics" || true
    core_now=$(xp_met_metric_value_for_pod "nvshare_client_core_quota_config_percent" "$pod" "$tmp_metrics")
    mem_now=$(xp_met_metric_value_for_pod "nvshare_client_memory_quota_bytes" "$pod" "$tmp_metrics")

    if [ -n "$core_now" ] && [ -n "$mem_now" ]; then
      if awk -v c="$core_now" -v m="$mem_now" -v o="$old_mem" 'BEGIN{exit !(c>=80 && m>o)}'; then
        observed_ts=$(date +%s)
        break
      fi
    fi

    if [ "$(date +%s)" -ge $((update_ts + XP_DYNAMIC_UPDATE_OBSERVE_TIMEOUT_SEC)) ]; then
      break
    fi
    sleep 2
  done

  xp_case_kv "dynamic_memory_before_bytes" "$old_mem"
  xp_case_kv "dynamic_memory_target_annotation" "$update_mem"
  xp_collect_common_artifacts "$app_label"
  xp_cleanup_app "$app_label"

  if [ "$observed_ts" -eq 0 ]; then
    XP_CASE_SUMMARY="dynamic quota changes not reflected in metrics within ${XP_DYNAMIC_UPDATE_OBSERVE_TIMEOUT_SEC}s"
    return 1
  fi

  latency_sec=$((observed_ts - update_ts))
  xp_case_kv "dynamic_quota_metric_latency_sec" "$latency_sec"

  if [ "$latency_sec" -le "$XP_DYNAMIC_UPDATE_EXPECT_SEC" ]; then
    XP_CASE_SUMMARY="dynamic quota reflected in metrics within target latency"
    return 0
  fi

  XP_CASE_SUMMARY="dynamic quota metric latency exceeded target"
  return 1
}

xp_case_MET_006() {
  local app_label pod max_util

  app_label=$(xp_met_case_label "MET-006")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 1 w2 "" "" "" 0
  xp_wait_for_pod_phase "$pod" "Running" 120

  xp_capture_metrics_repeated "$XPUSHARE_CASE_LOG_DIR/metrics_series.txt" 30 2
  max_util=$(xp_met_metric_max_in_file "nvshare_gpu_utilization_ratio" "$XPUSHARE_CASE_LOG_DIR/metrics_series.txt")
  xp_case_kv "max_gpu_util_ratio" "$max_util"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if awk -v v="$max_util" -v m="$XP_METRIC_UTIL_MIN_RATIO" 'BEGIN{exit !(v>=m)}'; then
    XP_CASE_SUMMARY="gpu utilization metric rises during active workload"
    return 0
  fi

  XP_CASE_SUMMARY="gpu utilization metric did not rise as expected"
  return 1
}

xp_case_MET_007() {
  local sample_count health_code

  xp_capture_metrics_repeated "$XPUSHARE_CASE_LOG_DIR/metrics_stress.txt" "$XP_METRICS_STRESS_DURATION_SEC" "$XP_METRICS_SCRAPE_INTERVAL_SEC"
  sample_count=$(grep -c '^# sample=' "$XPUSHARE_CASE_LOG_DIR/metrics_stress.txt" || true)
  xp_case_kv "metrics_stress_sample_count" "$sample_count"

  xp_capture_metrics_health "$XPUSHARE_CASE_LOG_DIR/metrics_health_after_stress.txt"
  health_code=$(xp_http_code_from_file "$XPUSHARE_CASE_LOG_DIR/metrics_health_after_stress.txt")

  if [ "$health_code" != "200" ]; then
    XP_CASE_SUMMARY="metrics endpoint unhealthy after high-frequency scrape (code=${health_code:-NA})"
    return 1
  fi

  if [ "$sample_count" -lt 5 ]; then
    XP_CASE_SUMMARY="too few samples captured in scrape stress test"
    return 1
  fi

  XP_CASE_SUMMARY="high-frequency metrics scrape remained stable"
  return 0
}

xp_case_MET_008() {
  local app_label pod peak_ratio

  app_label=$(xp_met_case_label "MET-008")
  pod="${app_label}-1"

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 1 w1 "" "" "" 1
  xp_wait_for_pod_phase "$pod" "Running" 120 || true

  xp_capture_metrics_repeated "$XPUSHARE_CASE_LOG_DIR/metrics_alert_probe.txt" 40 2

  peak_ratio=$(awk '
    /^nvshare_gpu_memory_used_bytes([ {].*)?$/ {used+=$NF}
    /^nvshare_gpu_memory_total_bytes([ {].*)?$/ {tot+=$NF}
    /^$/ {
      if (tot>0) {
        r=used/tot
        if (r>maxr) maxr=r
      }
      used=0
      tot=0
    }
    END {printf "%.6f\n", maxr+0}
  ' "$XPUSHARE_CASE_LOG_DIR/metrics_alert_probe.txt")
  xp_case_kv "peak_gpu_memory_used_ratio" "$peak_ratio"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if awk -v p="$peak_ratio" -v t="$XP_METRIC_HIGH_MEM_ALERT_RATIO" 'BEGIN{exit !(p>=t)}'; then
    XP_CASE_SUMMARY="high-memory alert drill threshold reached"
    return 0
  fi

  XP_CASE_SUMMARY="high-memory alert drill did not reach threshold"
  return 1
}

xp_run_metrics_case() {
  local case_id="$1"
  local case_fn
  case_fn="${case_id//-/_}"

  XP_CASE_SUMMARY="ok"
  xp_case_begin "metrics" "$case_id"

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

xp_run_metrics_suite() {
  local filter="${1:-all}"
  local case_id fail_count
  fail_count=0

  for case_id in $XP_METRICS_CASES; do
    if [ "$filter" != "all" ] && [ "$filter" != "$case_id" ]; then
      continue
    fi

    if xp_case_should_skip "metrics" "$case_id"; then
      continue
    fi

    if ! xp_run_metrics_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}
