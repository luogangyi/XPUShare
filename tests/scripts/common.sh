#!/bin/bash
# 通用测试工具函数

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 从 YAML 文件中提取 Pod 名称
# 参数: yaml_file
get_pod_name() {
    local yaml_file=$1
    grep "^  name:" "$yaml_file" | head -1 | sed 's/.*name: //'
}

# 获取镜像 URL
# 参数: yaml_file
get_image_url() {
    local manifest=$1
    grep "image:" "$manifest" | head -1 | sed 's/.*image: //' | tr -d ' '
}

# 并行等待所有 Pod 完成（轮询检查）
# 参数: timeout pod_name1 pod_name2 ...
wait_all_pods_complete() {
    local timeout=$1
    shift
    local pods=("$@")
    local total=${#pods[@]}
    local elapsed=0
    local interval=10
    
    echo "等待 $total 个 Pod 完成（超时: ${timeout}s）..."
    
    printf "%-30s | %-8s | %-12s | %-12s | %-12s\n" "Pod Name" "Status" "Duration" "Avg Speed" "MaxKernelWin"
    echo "--------------------------------------------------------------------------------------------"
    
    while [ $elapsed -lt $timeout ]; do
        local completed=0
        local failed=0
        local running=0
        local pending=0
        
        for pod in "${pods[@]}"; do
            local status=$(kubectl get pod $pod -o jsonpath='{.status.phase}' 2>/dev/null)
            
            if [ "$status" = "Succeeded" ]; then
                ((completed++))
            elif kubectl logs $pod 2>/dev/null | grep -q "PASS"; then
                ((completed++))
            elif [ "$status" = "Failed" ]; then
                ((failed++))
            elif [ "$status" = "Running" ]; then
                ((running++))
            else
                ((pending++))
            fi
        done
        
        echo "  [$elapsed/${timeout}s] 完成=$completed 运行中=$running 等待=$pending 失败=$failed"
        
        if [ $((completed + failed)) -eq $total ]; then
            echo ""
            echo "所有 Pod 已结束"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    echo -e "${YELLOW}⚠${NC} 超时，部分 Pod 未完成"
    return 1
}

# 解析时间字符串 (MM:SS 或 HH:MM:SS) 为秒
parse_time_to_seconds() {
    local t=$1
    if [[ $t =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        echo $((${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]}))
    elif [[ $t =~ ^([0-9]+):([0-9]+)$ ]]; then
        echo $((${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]}))
    else
        echo 0
    fi
}

# 统计分析测试结果
# 参数: pod_name1 pod_name2 ...
check_results() {
    local pods=("$@")
    local total_pods=${#pods[@]}
    local pass_count=0
    local fail_count=0
    
    # 统计数据数组
    local durations=()
    local speeds=()
    
    echo ""
    echo "=========================================================================================="
    for pod in "${pods[@]}"; do
        local logs=$(kubectl logs $pod 2>/dev/null)
        local status_phase=$(kubectl get pod $pod -o jsonpath='{.status.phase}' 2>/dev/null)
        local result_status="FAIL"
        
        # 判定结果
        if echo "$logs" | grep -q "PASS"; then
            result_status="PASS"
            ((pass_count++))
        elif [ "$status_phase" = "Succeeded" ]; then
             # 有些应用可能没有打印 PASS 但成功退出了
            result_status="PASS"
            ((pass_count++))
        else
            result_status="FAIL ($status_phase)"
            ((fail_count++))
        fi
        
        # 获取 K8s 记录的精确运行时间 (Running -> Completed)
        local start_ts=$(kubectl get pod $pod -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
        if [ -z "$start_ts" ]; then
             # 如果是 Completed 状态，Running 状态信息可能在 state.terminated 里找不到 running 字段?
             # Kubernetes 保留 terminated 状态的 startedAt 和 finishedAt
             start_ts=$(kubectl get pod $pod -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}' 2>/dev/null)
        fi
        
        local end_ts=$(kubectl get pod $pod -o jsonpath='{.status.containerStatuses[0].state.terminated.finishedAt}' 2>/dev/null)
        
        local duration_str="N/A"
        local duration_sec=0
        
        # 提取 last_tqdm 用于速度计算 fallback
        local last_tqdm=$(echo "$logs" | grep -o "[0-9]*%|.*\[.*<.*\]" | tail -1)

        if [ -n "$start_ts" ] && [ -n "$end_ts" ]; then
            # 使用纯 Python 标准库处理 ISO8601 时间 (YYYY-MM-DDTHH:MM:SSZ)
            duration_sec=$(python3 -c "from datetime import datetime
import sys
try:
    s = '$start_ts'
    e = '$end_ts'
    # 移除 Z 和 微秒 (只保留秒级精度)
    s = s.split('Z')[0].split('.')[0]
    e = e.split('Z')[0].split('.')[0]
    fmt = '%Y-%m-%dT%H:%M:%S'
    t1 = datetime.strptime(s, fmt)
    t2 = datetime.strptime(e, fmt)
    diff = int((t2 - t1).total_seconds())
    print(diff)
except Exception as err:
    print(0)
")
            if [ "$duration_sec" -gt 0 ]; then
                duration_str="${duration_sec}s"
                durations+=($duration_sec)
            fi
        else
            # Fallback: 尝试从 tqdm 解析 (保持兼容性)
            local regex_duration='\[([0-9:]+)<'
            if [[ $last_tqdm =~ $regex_duration ]]; then
                duration_str="${BASH_REMATCH[1]} (est)"
                durations+=($(parse_time_to_seconds ${BASH_REMATCH[1]}))
            fi
        fi
        
        local regex_speed=',[ ]*([0-9.]+)it/s'
        if [[ $last_tqdm =~ $regex_speed ]]; then
            speed_str="${BASH_REMATCH[1]}"
            speeds+=($speed_str)
        fi
        
        # 解析 Kernel Window 日志，寻找最大窗口值
        local max_window=$(echo "$logs" | grep "Pending Kernel Window is" | sort -V | tail -1 | grep -o "Window is [0-9]*" | awk '{print $3}')
        if [ -z "$max_window" ]; then max_window="-"; fi
        
        # 颜色输出
        local color=$RED
        if [ "$result_status" = "PASS" ]; then color=$GREEN; fi
        
        printf "${color}%-30s${NC} | ${color}%-8s${NC} | %-12s | %-12s | %-12s\n" \
            "$pod" "$result_status" "$duration_str" "${speed_str} it/s" "$max_window"
            
    done
    echo "=========================================================================================="
    
    # 计算统计信息
    echo ""
    echo "📊 统计分析:"
    echo "  Total: $total_pods, Pass: $pass_count, Fail: $fail_count"
    
    if [ ${#durations[@]} -gt 0 ]; then
        # 使用 awk 计算 Min/Max/Avg
        local stats=$(echo "${durations[@]}" | tr ' ' '\n' | awk '
            BEGIN {min=999999; max=0; sum=0} 
            {if ($1<min) min=$1; if ($1>max) max=$1; sum+=$1} 
            END {printf "Min=%ds, Max=%ds, Avg=%.1fs", min, max, sum/NR}')
        echo "  Duration: $stats"
    fi
    
    if [ ${#speeds[@]} -gt 0 ]; then
        local speed_stats=$(echo "${speeds[@]}" | tr ' ' '\n' | awk '
            BEGIN {min=999999; max=0; sum=0} 
            {if ($1<min) min=$1; if ($1>max) max=$1; sum+=$1} 
            END {printf "Min=%.2f, Max=%.2f, Avg=%.2f (it/s)", min, max, sum/NR}')
        echo "  Speed   : $speed_stats"
    fi
    echo ""
    
    if [ $fail_count -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# 清理指定标签的 Pod
cleanup_pods_by_label() {
    local label=$1
    echo "清理 Pod (label: $label)..."
    kubectl delete pod -l $label --ignore-not-found=true --wait=false 2>/dev/null
}

# 打印分隔线
print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}
