#!/bin/bash
# 运行所有测试场景

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$SCRIPT_DIR/common.sh"

print_header "nvshare GPU 共享测试套件"

# 检查 nvshare 组件状态
echo "检查 nvshare 组件状态..."
if ! kubectl get pods -n nvshare-system 2>/dev/null | grep -q "Running"; then
    echo -e "${RED}✗${NC} 错误：nvshare 组件未正常运行"
    echo "请先部署 nvshare 组件："
    echo "  kubectl apply -f .tests/manifests/"
    exit 1
fi
echo -e "${GREEN}✓${NC} nvshare 组件正常运行"
echo ""

# 更新测试清单
echo "更新测试清单中的镜像 URL..."
"$SCRIPT_DIR/../workloads/update-manifests.sh" 2>/dev/null || true
echo ""

# 测试选择
echo "请选择要运行的测试："
echo "1. 基础 GPU 共享验证（2 Pod）"
echo "2. 多 Pod GPU 共享（4 Pod）"
echo "3. 跨 GPU 负载分布（12 Pod，超过单 GPU 10 vGPU）"
echo "4. 显存边界测试（启用 NVSHARE_ENABLE_SINGLE_OVERSUB）"
echo "5. 混合框架测试（PyTorch + TensorFlow）"
echo "6. 高并发压力测试（15 Pod）"
echo "7. 运行所有测试（顺序执行）"
echo "0. 退出"
echo ""

read -p "请输入选项 [0-7]: " choice

case $choice in
    1)
        "$SCRIPT_DIR/test-basic-sharing.sh"
        ;;
    2)
        "$SCRIPT_DIR/test-multi-pod-sharing.sh"
        ;;
    3)
        read -p "请输入 Pod 数量 [默认 12]: " pod_count
        pod_count=${pod_count:-12}
        "$SCRIPT_DIR/test-cross-gpu.sh" $pod_count
        ;;
    4)
        "$SCRIPT_DIR/test-memory-boundary.sh"
        ;;
    5)
        "$SCRIPT_DIR/test-mixed-frameworks.sh"
        ;;
    6)
        read -p "请输入 Pod 数量 [默认 15]: " pod_count
        pod_count=${pod_count:-15}
        "$SCRIPT_DIR/test-high-concurrency.sh" $pod_count
        ;;
    7)
        echo ""
        echo "运行所有测试..."
        echo ""
        
        # 清理所有测试 Pod
        "$SCRIPT_DIR/cleanup.sh"
        sleep 5
        
        echo ">>> 测试 1: 基础 GPU 共享"
        "$SCRIPT_DIR/test-basic-sharing.sh" || true
        echo ""
        read -p "按 Enter 继续下一个测试..."
        "$SCRIPT_DIR/cleanup.sh"
        sleep 3
        
        echo ">>> 测试 2: 多 Pod GPU 共享"
        "$SCRIPT_DIR/test-multi-pod-sharing.sh" || true
        echo ""
        read -p "按 Enter 继续下一个测试..."
        "$SCRIPT_DIR/cleanup.sh"
        sleep 3
        
        echo ">>> 测试 3: 跨 GPU 负载分布"
        "$SCRIPT_DIR/test-cross-gpu.sh" 12 || true
        echo ""
        read -p "按 Enter 继续下一个测试..."
        "$SCRIPT_DIR/cleanup.sh"
        sleep 3
        
        echo ">>> 测试 4: 显存边界测试"
        "$SCRIPT_DIR/test-memory-boundary.sh" || true
        echo ""
        read -p "按 Enter 继续下一个测试..."
        "$SCRIPT_DIR/cleanup.sh"
        sleep 3
        
        echo ">>> 测试 5: 混合框架测试"
        "$SCRIPT_DIR/test-mixed-frameworks.sh" || true
        echo ""
        read -p "按 Enter 继续下一个测试..."
        "$SCRIPT_DIR/cleanup.sh"
        sleep 3
        
        echo ">>> 测试 6: 高并发压力测试"
        "$SCRIPT_DIR/test-high-concurrency.sh" 15 || true
        
        print_header "所有测试完成"
        ;;
    0)
        echo "退出"
        exit 0
        ;;
    *)
        echo "无效选项"
        exit 1
        ;;
esac
