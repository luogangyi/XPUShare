#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_STABILITY_CASES="STAB-001 STAB-002 STAB-003 STAB-004 LEAK-001 LEAK-002 LEAK-003 LEAK-004 LEAK-005 FAIL-001 FAIL-002 FAIL-003 FAIL-004"
XP_CASE_SUMMARY="ok"

XP_STAB_ITERATION_TIMEOUT_SEC="${XP_STAB_ITERATION_TIMEOUT_SEC:-3600}"
XP_STAB_MIX_SMALL_PODS="${XP_STAB_MIX_SMALL_PODS:-}"
XP_STAB_MIX_LARGE_PODS="${XP_STAB_MIX_LARGE_PODS:-}"
XP_STAB_MIX_SMALL_PODS_C1="${XP_STAB_MIX_SMALL_PODS_C1:-16}"
XP_STAB_MIX_LARGE_PODS_C1="${XP_STAB_MIX_LARGE_PODS_C1:-32}"
XP_STAB_MIX_SMALL_PODS_C2="${XP_STAB_MIX_SMALL_PODS_C2:-64}"
XP_STAB_MIX_LARGE_PODS_C2="${XP_STAB_MIX_LARGE_PODS_C2:-128}"
XP_LEAK_ROUNDS="${XP_LEAK_ROUNDS:-20}"
XP_LEAK_RSS_GROWTH_MAX_KB="${XP_LEAK_RSS_GROWTH_MAX_KB:-131072}"
XP_LEAK_FD_GROWTH_MAX="${XP_LEAK_FD_GROWTH_MAX:-200}"
XP_LEAK_GPU_RECOVER_TOLERANCE_BYTES="${XP_LEAK_GPU_RECOVER_TOLERANCE_BYTES:-1073741824}"
XP_LEAK_SERIES_GROWTH_MAX="${XP_LEAK_SERIES_GROWTH_MAX:-200}"
XP_LEAK_GHOST_CLIENT_MAX="${XP_LEAK_GHOST_CLIENT_MAX:-0}"

XP_FAIL_RESTART_TIMEOUT_SEC="${XP_FAIL_RESTART_TIMEOUT_SEC:-240}"
XP_C1_DRAIN_NODE="${XP_C1_DRAIN_NODE:-}"
XP_C2_STRESS_NODE="${XP_C2_STRESS_NODE:-}"

xp_stab_case_label() {
  echo "xps-$(xp_case_slug "$1")"
}

xp_stab_skip() {
  local reason="$1"
  XP_CASE_SUMMARY="SKIP: $reason"
  xp_case_note "$XP_CASE_SUMMARY"
  return 0
}

xp_stab_mix_small_pods() {
  if [ -n "$XP_STAB_MIX_SMALL_PODS" ]; then
    echo "$XP_STAB_MIX_SMALL_PODS"
    return 0
  fi
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    echo "$XP_STAB_MIX_SMALL_PODS_C2"
    return 0
  fi
  echo "$XP_STAB_MIX_SMALL_PODS_C1"
  return 0
}

xp_stab_mix_large_pods() {
  if [ -n "$XP_STAB_MIX_LARGE_PODS" ]; then
    echo "$XP_STAB_MIX_LARGE_PODS"
    return 0
  fi
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    echo "$XP_STAB_MIX_LARGE_PODS_C2"
    return 0
  fi
  echo "$XP_STAB_MIX_LARGE_PODS_C1"
  return 0
}

xp_stab_require_disruptive() {
  if [ "$XP_ENABLE_DISRUPTIVE" != "1" ]; then
    xp_stab_skip "set XP_ENABLE_DISRUPTIVE=1 to enable disruptive failover cases"
    return 1
  fi
  return 0
}

xp_stab_scheduler_rss_kb() {
  local pod
  pod=$(xp_scheduler_pod)
  if [ -z "$pod" ]; then
    echo 0
    return
  fi
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" exec "$pod" -- sh -c "awk '/VmRSS/{print \$2}' /proc/1/status" 2>/dev/null | tail -n 1
}

xp_stab_scheduler_fd_count() {
  local pod
  pod=$(xp_scheduler_pod)
  if [ -z "$pod" ]; then
    echo 0
    return
  fi
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" exec "$pod" -- sh -c 'ls /proc/1/fd | wc -l' 2>/dev/null | tail -n 1
}

xp_stab_sample_scheduler_state() {
  local outfile="$1"
  local rss fd now

  now=$(date +%s)
  rss=$(xp_stab_scheduler_rss_kb)
  fd=$(xp_stab_scheduler_fd_count)
  echo "ts=$now rss_kb=${rss:-0} fd=${fd:-0}" >> "$outfile"
}

xp_stab_metric_series_count() {
  local metric_file="$1"
  grep '^nvshare_client_' "$metric_file" | sed 's/[[:space:]].*$//' | sort -u | wc -l | awk '{print $1}'
}

xp_stab_apply_pod_on_node() {
  local pod_name="$1"
  local app_label="$2"
  local workload="$3"
  local core_limit="$4"
  local memory_limit_annotation="$5"
  local memory_limit_env="$6"
  local oversub="$7"
  local node_name="$8"

  local image command_block
  image=$(xp_workload_image "$workload")
  command_block=$(xp_workload_command_block "$workload")

  {
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod_name
  labels:
    app: $app_label
YAML

    if [ -n "$core_limit" ] || [ -n "$memory_limit_annotation" ]; then
      echo "  annotations:"
      if [ -n "$core_limit" ]; then
        echo "    nvshare.com/gpu-core-limit: \"$core_limit\""
      fi
      if [ -n "$memory_limit_annotation" ]; then
        echo "    nvshare.com/gpu-memory-limit: \"$memory_limit_annotation\""
      fi
    fi

    cat <<YAML
spec:
  restartPolicy: Never
  nodeName: $node_name
  containers:
  - name: test
    image: $image
YAML

    if [ -n "$command_block" ]; then
      echo "$command_block"
    fi

    cat <<YAML
    env:
    - name: NVSHARE_DEBUG
      value: "1"
YAML

    if [ "$oversub" = "1" ]; then
      cat <<YAML
    - name: NVSHARE_ENABLE_SINGLE_OVERSUB
      value: "1"
YAML
    fi

    if [ -n "$memory_limit_env" ]; then
      cat <<YAML
    - name: NVSHARE_GPU_MEMORY_LIMIT
      value: "$memory_limit_env"
YAML
    fi

    cat <<YAML
    resources:
      limits:
        nvshare.com/gpu: 1
YAML
  } | kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" apply -f -

  xp_wait_for_pod_exists "$pod_name" 60
}

xp_case_STAB_001() {
  local app_label iter end_ts

  if [ "$XPUSHARE_CLUSTER" != "c1" ]; then
    xp_stab_skip "STAB-001 targets cluster1"
    return 0
  fi

  app_label=$(xp_stab_case_label "STAB-001")
  end_ts=$(( $(date +%s) + XP_STAB_SHORT_SEC ))
  iter=0

  : > "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"
  xp_stab_sample_scheduler_state "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"

  while [ "$(date +%s)" -lt "$end_ts" ]; do
    iter=$((iter + 1))
    xp_cleanup_app "$app_label"
    xp_safe_sleep 2

    xp_apply_workload_group "$app_label" 4 w2 "50" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_STAB_ITERATION_TIMEOUT_SEC" || true
    xp_stab_sample_scheduler_state "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"

    if [ "$(xp_count_running_scheduler)" -lt 1 ]; then
      XP_CASE_SUMMARY="scheduler not running during STAB-001"
      xp_collect_common_artifacts "$app_label"
      return 1
    fi
  done

  xp_collect_common_artifacts "$app_label"
  xp_case_kv "iterations" "$iter"
  XP_CASE_SUMMARY="stable fixed-load rotation completed on cluster1"
  return 0
}

xp_case_STAB_002() {
  local app_label iter end_ts n small_n large_n

  if [ "$XPUSHARE_CLUSTER" != "c2" ]; then
    xp_stab_skip "STAB-002 targets cluster2"
    return 0
  fi

  app_label=$(xp_stab_case_label "STAB-002")
  end_ts=$(( $(date +%s) + XP_STAB_LONG_SEC ))
  iter=0
  small_n=$(xp_stab_mix_small_pods)
  large_n=$(xp_stab_mix_large_pods)

  : > "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"
  xp_stab_sample_scheduler_state "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"

  while [ "$(date +%s)" -lt "$end_ts" ]; do
    iter=$((iter + 1))
    if [ $((iter % 2)) -eq 0 ]; then
      n="$small_n"
    else
      n="$large_n"
    fi

    xp_cleanup_app "$app_label"
    xp_safe_sleep 2

    xp_apply_workload_group "$app_label" "$n" w2 "" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_STAB_ITERATION_TIMEOUT_SEC" || true
    xp_stab_sample_scheduler_state "$XPUSHARE_CASE_LOG_DIR/scheduler_series.txt"

    if [ "$(xp_count_running_scheduler)" -lt 1 ]; then
      XP_CASE_SUMMARY="scheduler not running during STAB-002"
      xp_collect_common_artifacts "$app_label"
      return 1
    fi
  done

  xp_collect_common_artifacts "$app_label"
  xp_case_kv "iterations" "$iter"
  XP_CASE_SUMMARY="cluster2 long mixed-load stability run completed"
  return 0
}

xp_case_STAB_003() {
  local app_label end_ts idx pod core

  app_label=$(xp_stab_case_label "STAB-003")
  end_ts=$(( $(date +%s) + XP_STAB_SHORT_SEC ))
  idx=0

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  for pod in 1 2 3 4; do
    xp_apply_workload_pod "${app_label}-${pod}" "$app_label" w5 "30" "" "" 0
  done

  xp_safe_sleep 20
  : > "$XPUSHARE_CASE_LOG_DIR/update_timeline.txt"

  while [ "$(date +%s)" -lt "$end_ts" ]; do
    idx=$((idx + 1))
    case $((idx % 3)) in
      0) core=30 ;;
      1) core=60 ;;
      2) core=90 ;;
    esac

    for pod in 1 2 3 4; do
      xp_update_annotation "${app_label}-${pod}" "nvshare.com/gpu-core-limit" "$core"
    done

    echo "ts=$(date +%s) core=$core" >> "$XPUSHARE_CASE_LOG_DIR/update_timeline.txt"
    xp_capture_metrics_snapshot_with_suffix "stab3_${idx}" || true
    sleep "$XP_STAB_UPDATE_INTERVAL_SEC"
  done

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if ! grep -Eq "Compute limit changed|UPDATE_CORE_LIMIT|gpu-core-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"; then
    XP_CASE_SUMMARY="compute dynamic updates not observed in STAB-003"
    return 1
  fi

  XP_CASE_SUMMARY="dynamic compute updates remained stable over soak window"
  return 0
}

xp_case_STAB_004() {
  local app_label end_ts idx pod mem
  local base_mem

  app_label=$(xp_stab_case_label "STAB-004")
  end_ts=$(( $(date +%s) + XP_STAB_SHORT_SEC ))
  idx=0

  base_mem="4Gi"
  if [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    base_mem="8Gi"
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  for pod in 1 2 3 4; do
    xp_apply_workload_pod "${app_label}-${pod}" "$app_label" w5 "" "$base_mem" "" 0
  done

  xp_safe_sleep 20
  : > "$XPUSHARE_CASE_LOG_DIR/update_timeline.txt"

  while [ "$(date +%s)" -lt "$end_ts" ]; do
    idx=$((idx + 1))
    case $((idx % 3)) in
      0) mem="$base_mem" ;;
      1) mem="2Gi" ;;
      2) mem="6Gi" ;;
    esac

    for pod in 1 2 3 4; do
      xp_update_annotation "${app_label}-${pod}" "nvshare.com/gpu-memory-limit" "$mem"
    done

    echo "ts=$(date +%s) mem=$mem" >> "$XPUSHARE_CASE_LOG_DIR/update_timeline.txt"
    xp_capture_metrics_snapshot_with_suffix "stab4_${idx}" || true
    sleep "$XP_STAB_UPDATE_INTERVAL_SEC"
  done

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if ! grep -Eq "Memory limit changed|Sending UPDATE_LIMIT|gpu-memory-limit" "$XPUSHARE_CASE_LOG_DIR/scheduler.log"; then
    XP_CASE_SUMMARY="memory dynamic updates not observed in STAB-004"
    return 1
  fi

  XP_CASE_SUMMARY="dynamic memory updates remained stable over soak window"
  return 0
}

xp_case_LEAK_001() {
  local app_label i rss_start rss_end rss_growth

  app_label=$(xp_stab_case_label "LEAK-001")
  : > "$XPUSHARE_CASE_LOG_DIR/rss_series.txt"

  rss_start=$(xp_stab_scheduler_rss_kb)
  echo "round=0 rss_kb=${rss_start:-0}" >> "$XPUSHARE_CASE_LOG_DIR/rss_series.txt"

  for i in $(seq 1 "$XP_LEAK_ROUNDS"); do
    xp_cleanup_app "$app_label"
    xp_safe_sleep 1
    xp_apply_workload_group "$app_label" 2 w4 "" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true

    echo "round=$i rss_kb=$(xp_stab_scheduler_rss_kb)" >> "$XPUSHARE_CASE_LOG_DIR/rss_series.txt"
  done

  rss_end=$(xp_stab_scheduler_rss_kb)
  rss_growth=$((rss_end - rss_start))
  xp_case_kv "rss_start_kb" "$rss_start"
  xp_case_kv "rss_end_kb" "$rss_end"
  xp_case_kv "rss_growth_kb" "$rss_growth"

  xp_collect_common_artifacts "$app_label"

  if [ "$rss_growth" -le "$XP_LEAK_RSS_GROWTH_MAX_KB" ]; then
    XP_CASE_SUMMARY="scheduler RSS growth within leak threshold"
    return 0
  fi

  XP_CASE_SUMMARY="scheduler RSS growth exceeds leak threshold"
  return 1
}

xp_case_LEAK_002() {
  local app_label i fd_start fd_end fd_growth

  app_label=$(xp_stab_case_label "LEAK-002")
  : > "$XPUSHARE_CASE_LOG_DIR/fd_series.txt"

  fd_start=$(xp_stab_scheduler_fd_count)
  echo "round=0 fd=${fd_start:-0}" >> "$XPUSHARE_CASE_LOG_DIR/fd_series.txt"

  for i in $(seq 1 "$XP_LEAK_ROUNDS"); do
    xp_cleanup_app "$app_label"
    xp_safe_sleep 1
    xp_apply_workload_group "$app_label" 2 w4 "" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true

    echo "round=$i fd=$(xp_stab_scheduler_fd_count)" >> "$XPUSHARE_CASE_LOG_DIR/fd_series.txt"
  done

  fd_end=$(xp_stab_scheduler_fd_count)
  fd_growth=$((fd_end - fd_start))
  xp_case_kv "fd_start" "$fd_start"
  xp_case_kv "fd_end" "$fd_end"
  xp_case_kv "fd_growth" "$fd_growth"

  xp_collect_common_artifacts "$app_label"

  if [ "$fd_growth" -le "$XP_LEAK_FD_GROWTH_MAX" ]; then
    XP_CASE_SUMMARY="scheduler FD growth within threshold"
    return 0
  fi

  XP_CASE_SUMMARY="scheduler FD growth exceeds threshold"
  return 1
}

xp_case_LEAK_003() {
  local app_label used_before used_after

  app_label=$(xp_stab_case_label "LEAK-003")

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt"
  used_before=$(xp_metric_sum_in_file "nvshare_gpu_memory_used_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt")

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2
  xp_apply_workload_group "$app_label" 4 w2 "" "" "" 0
  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true

  xp_safe_sleep 20
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt"
  used_after=$(xp_metric_sum_in_file "nvshare_gpu_memory_used_bytes" "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt")

  xp_case_kv "gpu_used_before_bytes" "$used_before"
  xp_case_kv "gpu_used_after_bytes" "$used_after"
  xp_collect_common_artifacts "$app_label"

  if awk -v a="$used_after" -v b="$used_before" -v t="$XP_LEAK_GPU_RECOVER_TOLERANCE_BYTES" 'BEGIN{exit !(a <= b + t)}'; then
    XP_CASE_SUMMARY="GPU memory recovered close to baseline after load cleanup"
    return 0
  fi

  XP_CASE_SUMMARY="GPU memory did not recover to baseline range"
  return 1
}

xp_case_LEAK_004() {
  local app_label i client_count

  app_label=$(xp_stab_case_label "LEAK-004")

  for i in $(seq 1 "$XP_LEAK_ROUNDS"); do
    xp_cleanup_app "$app_label"
    xp_safe_sleep 1
    xp_apply_workload_group "$app_label" 2 w2 "" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  done

  xp_cleanup_app "$app_label"
  xp_safe_sleep 15
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt"
  client_count=$(grep -c '^nvshare_client_info{' "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt" || true)

  xp_case_kv "client_info_series_after_churn" "$client_count"
  xp_collect_common_artifacts "$app_label"

  if [ "$client_count" -le "$XP_LEAK_GHOST_CLIENT_MAX" ]; then
    XP_CASE_SUMMARY="no ghost client retained after churn"
    return 0
  fi

  XP_CASE_SUMMARY="ghost client series remains after churn"
  return 1
}

xp_case_LEAK_005() {
  local app_label i series_before series_after growth

  app_label=$(xp_stab_case_label "LEAK-005")

  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt"
  series_before=$(xp_stab_metric_series_count "$XPUSHARE_CASE_LOG_DIR/metrics_before.txt")

  for i in $(seq 1 "$XP_LEAK_ROUNDS"); do
    xp_cleanup_app "$app_label"
    xp_safe_sleep 1
    xp_apply_workload_group "$app_label" 2 w4 "" "" "" 0
    xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  done

  xp_cleanup_app "$app_label"
  xp_safe_sleep 20
  xp_capture_metrics_snapshot "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt"
  series_after=$(xp_stab_metric_series_count "$XPUSHARE_CASE_LOG_DIR/metrics_after.txt")
  growth=$((series_after - series_before))

  xp_case_kv "series_before" "$series_before"
  xp_case_kv "series_after" "$series_after"
  xp_case_kv "series_growth" "$growth"

  xp_collect_common_artifacts "$app_label"

  if [ "$growth" -le "$XP_LEAK_SERIES_GROWTH_MAX" ]; then
    XP_CASE_SUMMARY="metrics series growth is bounded after churn"
    return 0
  fi

  XP_CASE_SUMMARY="metrics series growth appears unbounded"
  return 1
}

xp_case_FAIL_001() {
  local app_label

  if ! xp_stab_require_disruptive; then
    return 0
  fi

  app_label=$(xp_stab_case_label "FAIL-001")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 4 w5 "" "" "" 0
  xp_safe_sleep 20

  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" rollout restart ds/nvshare-scheduler
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" rollout status ds/nvshare-scheduler --timeout="${XP_FAIL_RESTART_TIMEOUT_SEC}s"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ "$(xp_count_running_scheduler)" -lt 1 ]; then
    XP_CASE_SUMMARY="scheduler not healthy after restart"
    return 1
  fi

  XP_CASE_SUMMARY="scheduler restart during load recovered successfully"
  return 0
}

xp_case_FAIL_002() {
  local app_label

  if ! xp_stab_require_disruptive; then
    return 0
  fi

  app_label=$(xp_stab_case_label "FAIL-002")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 4 w5 "" "" "" 0
  xp_safe_sleep 20

  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" rollout restart ds/nvshare-device-plugin
  kubectl -n "$XPUSHARE_SYSTEM_NAMESPACE" rollout status ds/nvshare-device-plugin --timeout="${XP_FAIL_RESTART_TIMEOUT_SEC}s"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ "$(xp_count_running_scheduler)" -lt 1 ]; then
    XP_CASE_SUMMARY="scheduler unhealthy after device-plugin restart"
    return 1
  fi

  XP_CASE_SUMMARY="device-plugin restart during load recovered"
  return 0
}

xp_case_FAIL_003() {
  local app_label

  if [ "$XPUSHARE_CLUSTER" != "c1" ]; then
    xp_stab_skip "FAIL-003 targets cluster1"
    return 0
  fi

  if ! xp_stab_require_disruptive; then
    return 0
  fi

  if [ -z "$XP_C1_DRAIN_NODE" ]; then
    xp_stab_skip "set XP_C1_DRAIN_NODE to run drain case"
    return 0
  fi

  app_label=$(xp_stab_case_label "FAIL-003")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  xp_apply_workload_group "$app_label" 4 w2 "" "" "" 0
  xp_safe_sleep 20

  if ! kubectl drain "$XP_C1_DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=180s; then
    kubectl uncordon "$XP_C1_DRAIN_NODE" >/dev/null 2>&1 || true
    XP_CASE_SUMMARY="node drain failed"
    xp_collect_common_artifacts "$app_label"
    return 1
  fi

  kubectl uncordon "$XP_C1_DRAIN_NODE" >/dev/null 2>&1 || true

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  XP_CASE_SUMMARY="drain + recovery path executed"
  return 0
}

xp_case_FAIL_004() {
  local app_label i succ

  if [ "$XPUSHARE_CLUSTER" != "c2" ]; then
    xp_stab_skip "FAIL-004 targets cluster2"
    return 0
  fi

  if ! xp_stab_require_disruptive; then
    return 0
  fi

  if [ -z "$XP_C2_STRESS_NODE" ]; then
    xp_stab_skip "set XP_C2_STRESS_NODE to pin workload to one node"
    return 0
  fi

  app_label=$(xp_stab_case_label "FAIL-004")
  xp_cleanup_app "$app_label"
  xp_safe_sleep 2

  for i in $(seq 1 8); do
    xp_stab_apply_pod_on_node "${app_label}-${i}" "$app_label" w2 "" "" "" 0 "$XP_C2_STRESS_NODE"
  done

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  succ=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Succeeded$' || true)
  xp_case_kv "success_count" "$succ"

  xp_collect_common_artifacts "$app_label"

  if [ "$succ" -lt 1 ]; then
    XP_CASE_SUMMARY="single-node stress produced no successful tasks"
    return 1
  fi

  XP_CASE_SUMMARY="single-node stress and recovery path recorded"
  return 0
}

xp_run_stability_case() {
  local case_id="$1"
  local case_fn
  case_fn="${case_id//-/_}"

  XP_CASE_SUMMARY="ok"
  xp_case_begin "stability" "$case_id"

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

xp_run_stability_suite() {
  local filter="${1:-all}"
  local case_id fail_count
  fail_count=0

  for case_id in $XP_STABILITY_CASES; do
    if [ "$filter" != "all" ] && [ "$filter" != "$case_id" ]; then
      continue
    fi

    if xp_case_should_skip "stability" "$case_id"; then
      continue
    fi

    if ! xp_run_stability_case "$case_id"; then
      fail_count=$((fail_count + 1))
    fi
  done

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}
