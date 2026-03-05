#!/bin/bash

set -euo pipefail

# shellcheck source=/dev/null
if ! declare -F xp_now >/dev/null 2>&1; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

XP_PERFORMANCE_CASES="PERF-001 PERF-002 PERF-003 PERF-004 PERF-005 PERF-006 PERF-007 PERF-008 PERF-009 PERF-010"
XP_CASE_SUMMARY="ok"

XP_PERF_METRICS_OVERHEAD_MAX_PCT="${XP_PERF_METRICS_OVERHEAD_MAX_PCT:-5}"
XP_PERF_MIX_RATIO_MIN="${XP_PERF_MIX_RATIO_MIN:-1.15}"
XP_PERF_SCALE_SET="${XP_PERF_SCALE_SET:-}"
XP_PERF_BASELINE_WORKLOAD="${XP_PERF_BASELINE_WORKLOAD:-w6}"
XP_PERF_BASELINE_MIN_SEC="${XP_PERF_BASELINE_MIN_SEC:-240}"
XP_PERF_QUOTA_LINEAR_TOL_PCT="${XP_PERF_QUOTA_LINEAR_TOL_PCT:-40}"
XP_PERF_PARALLEL_LINEAR_MIN_FACTOR="${XP_PERF_PARALLEL_LINEAR_MIN_FACTOR:-0.60}"
XP_PERF_PARALLEL_LINEAR_MAX_FACTOR="${XP_PERF_PARALLEL_LINEAR_MAX_FACTOR:-1.90}"
XP_PERF_SINGLE_CARD_PODS="${XP_PERF_SINGLE_CARD_PODS:-4}"
XP_PERF_MULTI_CARD_PODS="${XP_PERF_MULTI_CARD_PODS:-8}"
XP_PERF_SAME_GPU_RETRIES="${XP_PERF_SAME_GPU_RETRIES:-8}"
XP_PERF_STAGGER_SLEEP_SEC="${XP_PERF_STAGGER_SLEEP_SEC:-15}"
XP_PERF_DUAL_STATUS_STRICT="${XP_PERF_DUAL_STATUS_STRICT:-1}"

xp_perf_case_label() {
  echo "xpp-$(xp_case_slug "$1")"
}

xp_perf_skip() {
  local reason="$1"
  XP_CASE_SUMMARY="SKIP: $reason"
  xp_case_note "$XP_CASE_SUMMARY"
  return 0
}

xp_perf_dual_finalize() {
  local tag="$1"
  local placement_status="$2"
  local quota_status="$3"
  local reason="$4"

  xp_case_kv "${tag}_placement_status" "$placement_status"
  xp_case_kv "${tag}_quota_effect_status" "$quota_status"
  xp_case_kv "${tag}_dual_reason" "$reason"

  if [ "$placement_status" = "PASS" ] && [ "$quota_status" = "PASS" ]; then
    XP_CASE_SUMMARY="placement=PASS, quota_effect=PASS, reason=${reason}"
    return 0
  fi

  XP_CASE_SUMMARY="placement=${placement_status}, quota_effect=${quota_status}, reason=${reason}"
  if [ "$XP_PERF_DUAL_STATUS_STRICT" = "0" ]; then
    return 0
  fi
  return 1
}

xp_perf_scale_set_resolved() {
  local raw scale_set safe_max v out

  if [ -n "$XP_PERF_SCALE_SET" ]; then
    raw="$XP_PERF_SCALE_SET"
  elif [ "$XPUSHARE_CLUSTER" = "c2" ]; then
    if [ -n "$XP_PERF_SCALE_SET_C2" ]; then
      raw="$XP_PERF_SCALE_SET_C2"
    else
      raw="8 16 32 64 $XP_CLUSTER_C2_TOTAL_VGPU"
    fi
  else
    if [ -n "$XP_PERF_SCALE_SET_C1" ]; then
      raw="$XP_PERF_SCALE_SET_C1"
    else
      raw="2 4 8 16 24 32 $XP_CLUSTER_C1_TOTAL_VGPU"
    fi
  fi

  safe_max=$(xp_cluster_safe_max_pods "$XPUSHARE_CLUSTER")
  out=""
  for v in $raw; do
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -le 0 ]; then
      continue
    fi
    if [[ "$safe_max" =~ ^[0-9]+$ ]] && [ "$safe_max" -gt 0 ] && [ "$v" -gt "$safe_max" ]; then
      continue
    fi
    if ! echo " $out " | grep -q " $v "; then
      out="$out $v"
    fi
  done

  scale_set=$(echo "$out" | xargs)
  if [ -n "$scale_set" ]; then
    echo "$scale_set"
    return 0
  fi

  echo "1"
  return 0
}

xp_perf_runtime_for_pod() {
  local pod_name="$1"
  xp_extract_runtime_seconds "$XPUSHARE_CASE_LOG_DIR/pods/${pod_name}.log"
}

xp_perf_baseline_runtime() {
  local baseline_file
  baseline_file="$XPUSHARE_LOG_ROOT/$XPUSHARE_CLUSTER_NAME/performance/PERF-001/metrics.env"
  if [ -f "$baseline_file" ]; then
    awk -F= '$1=="baseline_runtime_sec"{print $2}' "$baseline_file" | tail -n 1
    return 0
  fi
  echo ""
}

xp_perf_list_pods_by_app() {
  local app_label="$1"
  kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort
}

xp_perf_wait_for_label_live() {
  local app_label="$1"
  local expected="$2"
  local timeout_sec="$3"
  local start now rows total running
  start=$(date +%s)

  while true; do
    rows=$(kubectl -n "$XPUSHARE_DEFAULT_NAMESPACE" get pod -l "app=$app_label" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    total=$(echo "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
    running=$(echo "$rows" | awk -F'|' '$2=="Running"{c++} END{print c+0}')

    if [ "$total" -ge "$expected" ] && [ "$running" -ge 1 ]; then
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 2
  done
}

xp_perf_collect_gpu_map_from_metrics() {
  local app_label="$1"
  local outfile="$2"
  local tmp_metrics
  tmp_metrics="$XPUSHARE_CASE_LOG_DIR/metrics_gpu_map.txt"

  xp_capture_metrics_snapshot "$tmp_metrics" >/dev/null 2>&1 || true

  awk -v pfx="${app_label}-" '
    /^nvshare_client_info\{/ {
      pod=""; gpu="";
      if (match($0, /pod=\"[^\"]+\"/)) {
        pod=substr($0, RSTART+5, RLENGTH-6);
      }
      if (match($0, /gpu_uuid=\"[^\"]+\"/)) {
        gpu=substr($0, RSTART+10, RLENGTH-11);
      }
      if (pod != "" && gpu != "" && index(pod, pfx) == 1) {
        print pod " " gpu;
      }
    }
  ' "$tmp_metrics" >> "$outfile"
}

xp_perf_collect_pod_gpu_map() {
  local app_label="$1"
  local outfile="$2"
  local pod uuid

  : > "$outfile"
  for pod in $(xp_perf_list_pods_by_app "$app_label"); do
    uuid=$(xp_get_pod_gpu_uuid "$pod" | tr -d '\r' | tr -d '\n')
    if [ -n "$uuid" ]; then
      echo "$pod $uuid" >> "$outfile"
    fi
  done

  if [ ! -s "$outfile" ]; then
    xp_perf_collect_gpu_map_from_metrics "$app_label" "$outfile"
  fi

  if [ -s "$outfile" ]; then
    sort -u "$outfile" -o "$outfile"
  fi
}

xp_perf_launch_staggered_quota_group() {
  local app_label="$1"
  local workload="$2"
  local low_quota="$3"
  local high_quota="$4"
  local stagger_sec="$5"
  local p1 p2 p3 p4

  p1="${app_label}-1"
  p2="${app_label}-2"
  p3="${app_label}-3"
  p4="${app_label}-4"

  xp_apply_workload_pod "$p1" "$app_label" "$workload" "$low_quota" "" "" 0
  xp_apply_workload_pod "$p2" "$app_label" "$workload" "$low_quota" "" "" 0
  xp_wait_for_pod_phase "$p1" "Running" 180 >/dev/null 2>&1 || true
  xp_wait_for_pod_phase "$p2" "Running" 180 >/dev/null 2>&1 || true
  xp_safe_sleep "$stagger_sec"

  xp_apply_workload_pod "$p3" "$app_label" "$workload" "$high_quota" "" "" 0
  xp_apply_workload_pod "$p4" "$app_label" "$workload" "$high_quota" "" "" 0
  xp_wait_for_label_count "$app_label" 4 120 || true
  xp_wait_for_pod_phase "$p3" "Running" 180 >/dev/null 2>&1 || true
  xp_wait_for_pod_phase "$p4" "Running" 180 >/dev/null 2>&1 || true
}

xp_perf_collect_same_gpu_low_high_pairs() {
  local map_file="$1"
  local low_a="$2"
  local low_b="$3"
  local high_a="$4"
  local high_b="$5"
  local out_file="$6"

  awk -v la="$low_a" -v lb="$low_b" -v ha="$high_a" -v hb="$high_b" '
    {
      pod=$1; gpu=$2;
      if (pod==la || pod==lb) low[gpu]=pod;
      if (pod==ha || pod==hb) high[gpu]=pod;
    }
    END {
      for (g in low) {
        if (g in high) print g, low[g], high[g];
      }
    }
  ' "$map_file" > "$out_file"
}

xp_perf_assert_parallel_linearity() {
  local baseline="$1"
  local avg_runtime="$2"
  local concurrency="$3"
  local label="$4"
  local ratio expect_min expect_max key

  key=$(xp_case_slug "$label")
  ratio=$(awk -v a="$avg_runtime" -v b="$baseline" 'BEGIN{if (b<=0){print 999}else{printf "%.3f", a/b}}')
  expect_min=$(awk -v k="$concurrency" -v f="$XP_PERF_PARALLEL_LINEAR_MIN_FACTOR" 'BEGIN{printf "%.3f", k*f}')
  expect_max=$(awk -v k="$concurrency" -v f="$XP_PERF_PARALLEL_LINEAR_MAX_FACTOR" 'BEGIN{printf "%.3f", k*f}')
  xp_case_kv "${key}_runtime_ratio" "$ratio"
  xp_case_kv "${key}_expect_min" "$expect_min"
  xp_case_kv "${key}_expect_max" "$expect_max"

  awk -v r="$ratio" -v lo="$expect_min" -v hi="$expect_max" 'BEGIN{exit !(r>=lo && r<=hi)}'
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

  xp_perf_case_run_single_pod "$app_label" "$XP_PERF_BASELINE_WORKLOAD" "" "" "" 0

  phase=$(xp_pod_phase "$pod")
  runtime=$(xp_perf_runtime_for_pod "$pod")
  xp_case_kv "baseline_phase" "$phase"
  xp_case_kv "baseline_runtime_sec" "$runtime"
  xp_case_kv "baseline_workload" "$XP_PERF_BASELINE_WORKLOAD"

  if [ "$phase" != "Succeeded" ]; then
    XP_CASE_SUMMARY="baseline pod did not succeed"
    return 1
  fi
  if [ -z "$runtime" ]; then
    XP_CASE_SUMMARY="baseline runtime not found in pod log"
    return 1
  fi

  if ! awk -v r="$runtime" -v min="$XP_PERF_BASELINE_MIN_SEC" 'BEGIN{exit !(r>=min)}'; then
    XP_CASE_SUMMARY="baseline runtime too short ($runtime s < $XP_PERF_BASELINE_MIN_SEC s), increase w6 iters"
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
  local base baseline app_label map_file pair_file
  local p1 p2 p3 p4 attempt same_gpu max_attempt pair_count
  local sum_low sum_high low_rt high_rt pairs_used
  local avg25 avg75 ratio25 ratio75 expected25 expected75 lo25 hi25 lo75 hi75
  local placement_status quota_status reason

  base=$(xp_perf_case_label "PERF-003")
  : > "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"
  baseline=$(xp_perf_baseline_runtime)
  xp_case_kv "quota_baseline_runtime_sec" "$baseline"

  if [ -z "$baseline" ]; then
    XP_CASE_SUMMARY="missing baseline runtime for quota linearity check"
    return 1
  fi

  max_attempt="$XP_PERF_SAME_GPU_RETRIES"
  if ! [[ "$max_attempt" =~ ^[0-9]+$ ]] || [ "$max_attempt" -le 0 ]; then
    max_attempt=3
  fi

  same_gpu=0
  for attempt in $(seq 1 "$max_attempt"); do
    app_label="${base}-a${attempt}"
    p1="${app_label}-1"
    p2="${app_label}-2"
    p3="${app_label}-3"
    p4="${app_label}-4"
    map_file="$XPUSHARE_CASE_LOG_DIR/quota_gpu_map.attempt${attempt}.txt"
    pair_file="$XPUSHARE_CASE_LOG_DIR/quota_pairs.attempt${attempt}.txt"

    xp_cleanup_app "$app_label"
    xp_safe_sleep 2
    xp_perf_launch_staggered_quota_group "$app_label" "$XP_PERF_BASELINE_WORKLOAD" "25" "75" "$XP_PERF_STAGGER_SLEEP_SEC"
    xp_perf_collect_pod_gpu_map "$app_label" "$map_file"
    xp_perf_collect_same_gpu_low_high_pairs "$map_file" "$p1" "$p2" "$p3" "$p4" "$pair_file"
    pair_count=$(wc -l < "$pair_file" | tr -d ' ')
    xp_case_kv "quota_pair_count_attempt_${attempt}" "$pair_count"

    if [ "$pair_count" -ge 1 ]; then
      same_gpu=1
      xp_case_kv "quota_pair_same_gpu_attempt" "$attempt"
      cp -f "$map_file" "$XPUSHARE_CASE_LOG_DIR/quota_gpu_map.txt"
      cp -f "$pair_file" "$XPUSHARE_CASE_LOG_DIR/quota_pairs.txt"
      break
    fi

    xp_cleanup_app "$app_label"
    xp_safe_sleep 2
  done

  if [ "$same_gpu" -ne 1 ]; then
    placement_status="FAIL"
    quota_status="SKIP"
    reason="unable to place same-gpu low/high pair after ${max_attempt} retries"
    xp_perf_dual_finalize "perf003" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  xp_wait_for_pod_terminal "$p1" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "$p2" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "$p3" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "$p4" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_collect_common_artifacts "$app_label"

  sum_low=0
  sum_high=0
  pairs_used=0
  while read -r _gpu low_pod high_pod; do
    low_rt=$(xp_perf_runtime_for_pod "$low_pod")
    high_rt=$(xp_perf_runtime_for_pod "$high_pod")
    if [ -n "$low_rt" ] && [ -n "$high_rt" ]; then
      sum_low=$(awk -v s="$sum_low" -v v="$low_rt" 'BEGIN{printf "%.6f", s+v}')
      sum_high=$(awk -v s="$sum_high" -v v="$high_rt" 'BEGIN{printf "%.6f", s+v}')
      pairs_used=$((pairs_used + 1))
      echo "pair gpu=$_gpu low_pod=$low_pod low_rt=$low_rt high_pod=$high_pod high_rt=$high_rt" >> "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"
    fi
  done < "$XPUSHARE_CASE_LOG_DIR/quota_pairs.txt"

  xp_case_kv "quota_pairs_used" "$pairs_used"
  if [ "$pairs_used" -lt 1 ]; then
    placement_status="PASS"
    quota_status="FAIL"
    reason="missing runtime data for same-gpu low/high pairs"
    xp_perf_dual_finalize "perf003" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  avg25=$(awk -v s="$sum_low" -v c="$pairs_used" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
  avg75=$(awk -v s="$sum_high" -v c="$pairs_used" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
  ratio25=$(awk -v a="$avg25" -v b="$baseline" 'BEGIN{if (b<=0){print 999}else{printf "%.3f", a/b}}')
  ratio75=$(awk -v a="$avg75" -v b="$baseline" 'BEGIN{if (b<=0){print 999}else{printf "%.3f", a/b}}')
  expected25=$(awk 'BEGIN{printf "%.3f", (25+75)/25.0}')
  expected75=$(awk 'BEGIN{printf "%.3f", (25+75)/75.0}')
  lo25=$(awk -v e="$expected25" -v t="$XP_PERF_QUOTA_LINEAR_TOL_PCT" 'BEGIN{printf "%.3f", e*(1-t/100.0)}')
  hi25=$(awk -v e="$expected25" -v t="$XP_PERF_QUOTA_LINEAR_TOL_PCT" 'BEGIN{printf "%.3f", e*(1+t/100.0)}')
  lo75=$(awk -v e="$expected75" -v t="$XP_PERF_QUOTA_LINEAR_TOL_PCT" 'BEGIN{printf "%.3f", e*(1-t/100.0)}')
  hi75=$(awk -v e="$expected75" -v t="$XP_PERF_QUOTA_LINEAR_TOL_PCT" 'BEGIN{printf "%.3f", e*(1+t/100.0)}')

  xp_case_kv "quota_pair_avg25_runtime_sec" "$avg25"
  xp_case_kv "quota_pair_avg75_runtime_sec" "$avg75"
  xp_case_kv "quota_pair_ratio25_vs_base" "$ratio25"
  xp_case_kv "quota_pair_ratio75_vs_base" "$ratio75"
  echo "q25 avg_runtime=$avg25 ratio_vs_base=$ratio25 expected=$expected25 range=[$lo25,$hi25]" >> "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"
  echo "q75 avg_runtime=$avg75 ratio_vs_base=$ratio75 expected=$expected75 range=[$lo75,$hi75]" >> "$XPUSHARE_CASE_LOG_DIR/quota_runtime.txt"

  if awk -v r="$ratio25" -v lo="$lo25" -v hi="$hi25" 'BEGIN{exit !(r>=lo && r<=hi)}' && \
     awk -v r="$ratio75" -v lo="$lo75" -v hi="$hi75" 'BEGIN{exit !(r>=lo && r<=hi)}' && \
     awk -v a="$avg25" -v b="$avg75" 'BEGIN{exit !(a>b)}'; then
    placement_status="PASS"
    quota_status="PASS"
    reason="same-gpu low/high pairs match baseline linear expectation"
    xp_perf_dual_finalize "perf003" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  placement_status="PASS"
  quota_status="FAIL"
  reason="same-gpu low/high pairs deviate from baseline linearity"
  xp_perf_dual_finalize "perf003" "$placement_status" "$quota_status" "$reason"
  return $?
}

xp_case_PERF_004() {
  local app_label p1 p2 p3 p4 d30 d60 ratio same_gpu attempt max_attempt
  local map_file pair_file pair_count sum_low sum_high low_rt high_rt pairs_used
  local placement_status quota_status reason

  app_label=$(xp_perf_case_label "PERF-004")

  max_attempt="$XP_PERF_SAME_GPU_RETRIES"
  if ! [[ "$max_attempt" =~ ^[0-9]+$ ]] || [ "$max_attempt" -le 0 ]; then
    max_attempt=3
  fi

  same_gpu=0
  for attempt in $(seq 1 "$max_attempt"); do
    local try_label
    try_label="${app_label}-a${attempt}"
    p1="${try_label}-1"
    p2="${try_label}-2"
    p3="${try_label}-3"
    p4="${try_label}-4"
    map_file="$XPUSHARE_CASE_LOG_DIR/mixed_gpu_map.attempt${attempt}.txt"
    pair_file="$XPUSHARE_CASE_LOG_DIR/mixed_pairs.attempt${attempt}.txt"

    xp_cleanup_app "$try_label"
    xp_safe_sleep 2

    xp_perf_launch_staggered_quota_group "$try_label" "$XP_PERF_BASELINE_WORKLOAD" "30" "60" "$XP_PERF_STAGGER_SLEEP_SEC"
    xp_perf_collect_pod_gpu_map "$try_label" "$map_file"
    xp_perf_collect_same_gpu_low_high_pairs "$map_file" "$p1" "$p2" "$p3" "$p4" "$pair_file"
    pair_count=$(wc -l < "$pair_file" | tr -d ' ')
    xp_case_kv "mixed_pair_count_attempt_${attempt}" "$pair_count"

    if [ "$pair_count" -ge 1 ]; then
      same_gpu=1
      xp_case_kv "mixed_quota_same_gpu_attempt" "$attempt"
      app_label="$try_label"
      cp -f "$map_file" "$XPUSHARE_CASE_LOG_DIR/mixed_gpu_map.txt"
      cp -f "$pair_file" "$XPUSHARE_CASE_LOG_DIR/mixed_pairs.txt"
      break
    fi

    xp_cleanup_app "$try_label"
    xp_safe_sleep 2
  done

  xp_wait_for_pod_terminal "${app_label}-1" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "${app_label}-2" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "${app_label}-3" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_wait_for_pod_terminal "${app_label}-4" "$XP_DEFAULT_POD_TIMEOUT_SEC" >/dev/null || true
  xp_collect_common_artifacts "$app_label"

  if [ "$same_gpu" -ne 1 ]; then
    placement_status="FAIL"
    quota_status="SKIP"
    reason="unable to place same-gpu low/high pair after ${max_attempt} retries"
    xp_perf_dual_finalize "perf004" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  sum_low=0
  sum_high=0
  pairs_used=0
  while read -r _gpu low_pod high_pod; do
    low_rt=$(xp_perf_runtime_for_pod "$low_pod")
    high_rt=$(xp_perf_runtime_for_pod "$high_pod")
    if [ -n "$low_rt" ] && [ -n "$high_rt" ]; then
      sum_low=$(awk -v s="$sum_low" -v v="$low_rt" 'BEGIN{printf "%.6f", s+v}')
      sum_high=$(awk -v s="$sum_high" -v v="$high_rt" 'BEGIN{printf "%.6f", s+v}')
      pairs_used=$((pairs_used + 1))
    fi
  done < "$XPUSHARE_CASE_LOG_DIR/mixed_pairs.txt"

  xp_case_kv "mixed_pairs_used" "$pairs_used"
  if [ "$pairs_used" -lt 1 ]; then
    placement_status="PASS"
    quota_status="FAIL"
    reason="missing runtime data for same-gpu low/high pairs"
    xp_perf_dual_finalize "perf004" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  d30=$(awk -v s="$sum_low" -v c="$pairs_used" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
  d60=$(awk -v s="$sum_high" -v c="$pairs_used" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
  xp_case_kv "mixed_avg30_runtime_sec" "$d30"
  xp_case_kv "mixed_avg60_runtime_sec" "$d60"
  ratio=$(awk -v a="$d30" -v b="$d60" 'BEGIN{if (b<=0){print 999}else{printf "%.3f", a/b}}')
  xp_case_kv "runtime_ratio_30_over_60" "$ratio"

  if awk -v r="$ratio" -v min="$XP_PERF_MIX_RATIO_MIN" 'BEGIN{exit !(r>=min)}'; then
    placement_status="PASS"
    quota_status="PASS"
    reason="same-gpu low/high pairs match mixed-quota ratio expectation"
    xp_perf_dual_finalize "perf004" "$placement_status" "$quota_status" "$reason"
    return $?
  fi

  placement_status="PASS"
  quota_status="FAIL"
  reason="same-gpu low/high pairs ratio below expectation"
  xp_perf_dual_finalize "perf004" "$placement_status" "$quota_status" "$reason"
  return $?
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

xp_case_PERF_009() {
  local app_label baseline map_file target_uuid target_count avg_runtime pod uuid rt
  local sum count req_count eff_count

  app_label=$(xp_perf_case_label "PERF-009")
  baseline=$(xp_perf_baseline_runtime)
  if [ -z "$baseline" ]; then
    xp_perf_skip "baseline missing, run PERF-001 first"
    return 0
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2
  req_count="$XP_PERF_SINGLE_CARD_PODS"
  eff_count=$(xp_effective_group_count "$req_count")
  xp_case_kv "single_card_requested_pods" "$req_count"
  xp_case_kv "single_card_effective_pods" "$eff_count"
  xp_apply_workload_group "$app_label" "$req_count" "$XP_PERF_BASELINE_WORKLOAD" "100" "" "" 0
  xp_perf_wait_for_label_live "$app_label" "$eff_count" 180 || true

  map_file="$XPUSHARE_CASE_LOG_DIR/single_card_gpu_map.txt"
  xp_perf_collect_pod_gpu_map "$app_label" "$map_file"
  xp_case_kv "single_card_gpu_map_file" "$map_file"

  if [ ! -s "$map_file" ]; then
    xp_perf_skip "unable to capture pod->gpu mapping for single-card scenario"
    return 0
  fi

  target_uuid=$(awk '{c[$2]++} END{m=0;u="";for (k in c){if(c[k]>m){m=c[k];u=k}} print u}' "$map_file")
  target_count=$(awk -v u="$target_uuid" '$2==u{c++} END{print c+0}' "$map_file")
  xp_case_kv "single_card_target_gpu_uuid" "$target_uuid"
  xp_case_kv "single_card_target_concurrency" "$target_count"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ "$target_count" -lt 2 ]; then
    xp_perf_skip "no >=2 pods on same GPU, skip single-card linear assertion"
    return 0
  fi

  sum=0
  count=0
  while read -r pod uuid; do
    if [ "$uuid" != "$target_uuid" ]; then
      continue
    fi
    rt=$(xp_perf_runtime_for_pod "$pod")
    if [ -n "$rt" ]; then
      sum=$(awk -v s="$sum" -v v="$rt" 'BEGIN{printf "%.6f", s+v}')
      count=$((count + 1))
    fi
  done < "$map_file"

  if [ "$count" -lt 2 ]; then
    XP_CASE_SUMMARY="single-card subset runtime samples insufficient"
    return 1
  fi

  avg_runtime=$(awk -v s="$sum" -v c="$count" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
  xp_case_kv "single_card_avg_runtime_sec" "$avg_runtime"

  if xp_perf_assert_parallel_linearity "$baseline" "$avg_runtime" "$count" "single_card"; then
    XP_CASE_SUMMARY="single-card parallel linearity within tolerance"
    return 0
  fi

  XP_CASE_SUMMARY="single-card parallel runtime deviates from baseline linearity"
  return 1
}

xp_case_PERF_010() {
  local app_label baseline map_file distinct_gpu fail_count uuid cnt sum rt avg key
  local req_count eff_count

  app_label=$(xp_perf_case_label "PERF-010")
  baseline=$(xp_perf_baseline_runtime)
  if [ -z "$baseline" ]; then
    xp_perf_skip "baseline missing, run PERF-001 first"
    return 0
  fi

  xp_cleanup_app "$app_label"
  xp_safe_sleep 2
  req_count="$XP_PERF_MULTI_CARD_PODS"
  eff_count=$(xp_effective_group_count "$req_count")
  xp_case_kv "multi_card_requested_pods" "$req_count"
  xp_case_kv "multi_card_effective_pods" "$eff_count"
  xp_apply_workload_group "$app_label" "$req_count" "$XP_PERF_BASELINE_WORKLOAD" "100" "" "" 0
  xp_perf_wait_for_label_live "$app_label" "$eff_count" 180 || true

  map_file="$XPUSHARE_CASE_LOG_DIR/multi_card_gpu_map.txt"
  xp_perf_collect_pod_gpu_map "$app_label" "$map_file"
  xp_case_kv "multi_card_gpu_map_file" "$map_file"

  if [ ! -s "$map_file" ]; then
    XP_CASE_SUMMARY="unable to capture pod->gpu mapping for multi-card scenario"
    return 1
  fi

  distinct_gpu=$(awk '{print $2}' "$map_file" | sort -u | wc -l | tr -d ' ')
  xp_case_kv "multi_card_distinct_gpu_count" "$distinct_gpu"

  xp_wait_for_label_terminal "$app_label" "$XP_DEFAULT_POD_TIMEOUT_SEC" || true
  xp_collect_common_artifacts "$app_label"

  if [ "$distinct_gpu" -lt 2 ]; then
    xp_perf_skip "multi-card scenario did not span >=2 GPUs (or mapping not distinguishable)"
    return 0
  fi

  fail_count=0
  while read -r cnt uuid; do
    sum=0
    while read -r pod mapped_uuid; do
      if [ "$mapped_uuid" != "$uuid" ]; then
        continue
      fi
      rt=$(xp_perf_runtime_for_pod "$pod")
      if [ -n "$rt" ]; then
        sum=$(awk -v s="$sum" -v v="$rt" 'BEGIN{printf "%.6f", s+v}')
      fi
    done < "$map_file"

    avg=$(awk -v s="$sum" -v c="$cnt" 'BEGIN{if(c<=0){print 0}else{printf "%.6f", s/c}}')
    key=$(xp_case_slug "multi_card_${uuid}")
    xp_case_kv "${key}_count" "$cnt"
    xp_case_kv "${key}_avg_runtime_sec" "$avg"
    if ! xp_perf_assert_parallel_linearity "$baseline" "$avg" "$cnt" "multi_card_${uuid}"; then
      fail_count=$((fail_count + 1))
    fi
  done < <(awk '{c[$2]++} END{for (k in c) print c[k],k}' "$map_file" | sort -nr)

  if [ "$fail_count" -eq 0 ]; then
    XP_CASE_SUMMARY="multi-card parallel linearity within tolerance"
    return 0
  fi

  XP_CASE_SUMMARY="multi-card parallel runtime deviates from baseline linearity"
  return 1
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
