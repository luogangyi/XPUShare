package service

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/grgalex/xpushare/dashboard/internal/k8s"
	"github.com/grgalex/xpushare/dashboard/internal/prom"
)

const (
	AnnotationCoreLimit   = "xpushare.com/gpu-core-limit"
	AnnotationMemoryLimit = "xpushare.com/gpu-memory-limit"
)

var memoryLimitPattern = regexp.MustCompile(`(?i)^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|B)?$`)

type Service struct {
	k8s  *k8s.Client
	prom *prom.Client
}

type NodeSummary struct {
	Name                    string `json:"name"`
	Runtime                 string `json:"runtime"`
	PhysicalResource        string `json:"physicalResource"`
	PhysicalDevicesTotal    int    `json:"physicalDevicesTotal"`
	VirtualDevicesTotal     int    `json:"virtualDevicesTotal"`
	VirtualDevicesAllocated int    `json:"virtualDevicesAllocated"`
	VirtualDevicesFree      int    `json:"virtualDevicesFree"`
}

type PodQuota struct {
	Namespace     string `json:"namespace"`
	Name          string `json:"name"`
	NodeName      string `json:"nodeName"`
	Phase         string `json:"phase"`
	RequestedVGPU int    `json:"requestedVGPU"`
	CoreLimit     string `json:"coreLimit"`
	MemoryLimit   string `json:"memoryLimit"`
}

type ClusterSummary struct {
	XPushareNodeCount       int `json:"xpushareNodeCount"`
	PhysicalDevicesTotal    int `json:"physicalDevicesTotal"`
	VirtualDevicesTotal     int `json:"virtualDevicesTotal"`
	VirtualDevicesAllocated int `json:"virtualDevicesAllocated"`
	VirtualDevicesFree      int `json:"virtualDevicesFree"`
	XPusharePodCount        int `json:"xpusharePodCount"`
	NamespaceCount          int `json:"namespaceCount"`
}

type Overview struct {
	GeneratedAt time.Time      `json:"generatedAt"`
	Summary     ClusterSummary `json:"summary"`
	Nodes       []NodeSummary  `json:"nodes"`
	Pods        []PodQuota     `json:"pods"`
}

type PodMetrics struct {
	Namespace string             `json:"namespace"`
	Pod       string             `json:"pod"`
	QueriedAt time.Time          `json:"queriedAt"`
	Values    map[string]float64 `json:"values"`
	Errors    map[string]string  `json:"errors,omitempty"`
}

func New(k8sClient *k8s.Client, promClient *prom.Client) *Service {
	return &Service{k8s: k8sClient, prom: promClient}
}

func (s *Service) GetOverview(ctx context.Context) (Overview, error) {
	nodes, pods, err := s.loadClusterData(ctx)
	if err != nil {
		return Overview{}, err
	}

	nodeSummaries := buildNodeSummaries(nodes, pods)
	podQuotas := buildPodQuotas(pods)

	summary := ClusterSummary{}
	namespaces := make(map[string]struct{})
	for _, node := range nodeSummaries {
		summary.XPushareNodeCount++
		summary.PhysicalDevicesTotal += node.PhysicalDevicesTotal
		summary.VirtualDevicesTotal += node.VirtualDevicesTotal
		summary.VirtualDevicesAllocated += node.VirtualDevicesAllocated
		summary.VirtualDevicesFree += node.VirtualDevicesFree
	}
	for _, pod := range podQuotas {
		summary.XPusharePodCount++
		namespaces[pod.Namespace] = struct{}{}
	}
	summary.NamespaceCount = len(namespaces)

	return Overview{
		GeneratedAt: time.Now().UTC(),
		Summary:     summary,
		Nodes:       nodeSummaries,
		Pods:        podQuotas,
	}, nil
}

func (s *Service) GetNodeSummaries(ctx context.Context) ([]NodeSummary, error) {
	nodes, pods, err := s.loadClusterData(ctx)
	if err != nil {
		return nil, err
	}
	return buildNodeSummaries(nodes, pods), nil
}

func (s *Service) GetPodQuotas(ctx context.Context) ([]PodQuota, error) {
	_, pods, err := s.loadClusterData(ctx)
	if err != nil {
		return nil, err
	}
	return buildPodQuotas(pods), nil
}

func (s *Service) UpdatePodQuota(ctx context.Context, namespace, pod string, coreLimit *int, memoryLimit *string) error {
	annotations := make(map[string]interface{})

	if coreLimit != nil {
		if *coreLimit < 1 || *coreLimit > 100 {
			return fmt.Errorf("coreLimit must be in range 1..100")
		}
		annotations[AnnotationCoreLimit] = strconv.Itoa(*coreLimit)
	}

	if memoryLimit != nil {
		trimmed := strings.TrimSpace(*memoryLimit)
		switch {
		case trimmed == "" || trimmed == "-":
			annotations[AnnotationMemoryLimit] = nil
		case !memoryLimitPattern.MatchString(trimmed):
			return fmt.Errorf("memoryLimit format is invalid, expected e.g. 4096, 4Gi, 512Mi")
		default:
			annotations[AnnotationMemoryLimit] = trimmed
		}
	}

	if len(annotations) == 0 {
		return fmt.Errorf("empty update payload")
	}

	return s.k8s.PatchPodAnnotations(ctx, namespace, pod, annotations)
}

func (s *Service) GetPodMetrics(ctx context.Context, namespace, pod string) (PodMetrics, error) {
	metrics := PodMetrics{
		Namespace: namespace,
		Pod:       pod,
		QueriedAt: time.Now().UTC(),
		Values:    map[string]float64{},
		Errors:    map[string]string{},
	}

	if s.prom == nil || !s.prom.Enabled() {
		return metrics, fmt.Errorf("prometheus is not configured")
	}

	selectorPrimary := fmt.Sprintf("namespace=%q,pod=%q", namespace, pod)
	selectorExported := fmt.Sprintf("exported_namespace=%q,exported_pod=%q", namespace, pod)

	withDualSelector := func(agg, metric string) string {
		return fmt.Sprintf("%s(%s{%s}) or %s(%s{%s})",
			agg, metric, selectorPrimary,
			agg, metric, selectorExported)
	}

	clientInfoByGPU := fmt.Sprintf("((max by (gpu_uuid) (xpushare_client_info{%s})) or (max by (gpu_uuid) (xpushare_client_info{%s})))",
		selectorPrimary, selectorExported)

	queries := map[string]string{
		"managed_allocated_bytes":      withDualSelector("sum", "xpushare_client_managed_allocated_bytes"),
		"nvml_used_bytes":              withDualSelector("sum", "xpushare_client_nvml_used_bytes"),
		"memory_quota_bytes":           withDualSelector("max", "xpushare_client_memory_quota_bytes"),
		"memory_quota_exceeded":        withDualSelector("max", "xpushare_client_memory_quota_exceeded"),
		"core_quota_config_percent":    withDualSelector("max", "xpushare_client_core_quota_config_percent"),
		"core_quota_effective_percent": withDualSelector("max", "xpushare_client_core_quota_effective_percent"),
		"core_usage_ratio":             withDualSelector("max", "xpushare_client_core_usage_ratio"),
		"throttled":                    withDualSelector("max", "xpushare_client_throttled"),
		"pending_drop":                 withDualSelector("max", "xpushare_client_pending_drop"),
		"quota_debt_ms":                withDualSelector("sum", "xpushare_client_quota_debt_ms"),
		"gpu_utilization_ratio":        fmt.Sprintf("avg(xpushare_gpu_utilization_ratio and on(gpu_uuid) %s)", clientInfoByGPU),
		"gpu_memory_utilization_ratio": fmt.Sprintf("avg(xpushare_gpu_memory_utilization_ratio and on(gpu_uuid) %s)", clientInfoByGPU),
	}

	keys := make([]string, 0, len(queries))
	for key := range queries {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		value, err := s.prom.QuerySum(ctx, queries[key])
		if err != nil {
			metrics.Errors[key] = err.Error()
			continue
		}
		metrics.Values[key] = value
	}

	if len(metrics.Errors) == 0 {
		metrics.Errors = nil
	}
	return metrics, nil
}

func (s *Service) loadClusterData(ctx context.Context) ([]k8s.Node, []k8s.Pod, error) {
	nodes, err := s.k8s.GetNodes(ctx)
	if err != nil {
		return nil, nil, err
	}
	pods, err := s.k8s.ListPods(ctx)
	if err != nil {
		return nil, nil, err
	}
	return nodes, pods, nil
}

func buildNodeSummaries(nodes []k8s.Node, pods []k8s.Pod) []NodeSummary {
	allocatedByNode := make(map[string]int)
	for _, pod := range pods {
		if pod.Spec.NodeName == "" || isTerminalPhase(pod.Status.Phase) {
			continue
		}
		requested := podRequestedVGPU(pod)
		if requested > 0 {
			allocatedByNode[pod.Spec.NodeName] += requested
		}
	}

	summaries := make([]NodeSummary, 0)
	for _, node := range nodes {
		virtualTotal := parseResourceCount(node.Status.Allocatable[k8s.ResourceXPUShareGPU])
		if virtualTotal <= 0 {
			continue
		}

		runtime, resourceName, physicalCount := detectRuntime(node)
		allocated := allocatedByNode[node.Metadata.Name]
		free := virtualTotal - allocated
		if free < 0 {
			free = 0
		}

		summaries = append(summaries, NodeSummary{
			Name:                    node.Metadata.Name,
			Runtime:                 runtime,
			PhysicalResource:        resourceName,
			PhysicalDevicesTotal:    physicalCount,
			VirtualDevicesTotal:     virtualTotal,
			VirtualDevicesAllocated: allocated,
			VirtualDevicesFree:      free,
		})
	}

	sort.Slice(summaries, func(i, j int) bool {
		return summaries[i].Name < summaries[j].Name
	})
	return summaries
}

func buildPodQuotas(pods []k8s.Pod) []PodQuota {
	result := make([]PodQuota, 0)
	for _, pod := range pods {
		if isTerminalPhase(pod.Status.Phase) {
			continue
		}
		annotations := pod.Metadata.Annotations
		requested := podRequestedVGPU(pod)
		hasCore := annotations != nil && annotations[AnnotationCoreLimit] != ""
		hasMemory := annotations != nil && annotations[AnnotationMemoryLimit] != ""
		if requested <= 0 && !hasCore && !hasMemory {
			continue
		}

		coreLimit := "100"
		memoryLimit := "-"
		if hasCore {
			coreLimit = annotations[AnnotationCoreLimit]
		}
		if hasMemory {
			memoryLimit = annotations[AnnotationMemoryLimit]
		}

		result = append(result, PodQuota{
			Namespace:     pod.Metadata.Namespace,
			Name:          pod.Metadata.Name,
			NodeName:      pod.Spec.NodeName,
			Phase:         pod.Status.Phase,
			RequestedVGPU: requested,
			CoreLimit:     coreLimit,
			MemoryLimit:   memoryLimit,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].Namespace == result[j].Namespace {
			return result[i].Name < result[j].Name
		}
		return result[i].Namespace < result[j].Namespace
	})
	return result
}

func podRequestedVGPU(pod k8s.Pod) int {
	total := 0
	for _, container := range pod.Spec.Containers {
		if value, ok := container.Resources.Limits[k8s.ResourceXPUShareGPU]; ok {
			total += parseResourceCount(value)
			continue
		}
		if value, ok := container.Resources.Requests[k8s.ResourceXPUShareGPU]; ok {
			total += parseResourceCount(value)
		}
	}
	return total
}

func detectRuntime(node k8s.Node) (runtime string, resourceName string, count int) {
	if value := parseResourceCount(node.Status.Capacity["nvidia.com/gpu"]); value > 0 {
		return "cuda", "nvidia.com/gpu", value
	}
	if value := parseResourceCount(node.Status.Allocatable["nvidia.com/gpu"]); value > 0 {
		return "cuda", "nvidia.com/gpu", value
	}

	npuCandidates := []string{
		"huawei.com/Ascend910",
		"huawei.com/ascend910",
		"huawei.com/Ascend310",
		"huawei.com/ascend310",
		"ascend.com/NPU",
		"ascend.com/npu",
		"npu.huawei.com/NPU",
		"npu.huawei.com/npu",
	}
	for _, key := range npuCandidates {
		if value := parseResourceCount(node.Status.Capacity[key]); value > 0 {
			return "cann", key, value
		}
		if value := parseResourceCount(node.Status.Allocatable[key]); value > 0 {
			return "cann", key, value
		}
	}

	for key, raw := range node.Status.Capacity {
		lower := strings.ToLower(key)
		if strings.Contains(lower, "ascend") || strings.Contains(lower, "npu") {
			if value := parseResourceCount(raw); value > 0 {
				return "cann", key, value
			}
		}
	}

	return "unknown", "", 0
}

func parseResourceCount(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}

	end := 0
	for end < len(raw) {
		ch := raw[end]
		if ch < '0' || ch > '9' {
			break
		}
		end++
	}
	if end == 0 {
		if value, err := strconv.ParseFloat(raw, 64); err == nil {
			return int(value)
		}
		return 0
	}

	value, err := strconv.Atoi(raw[:end])
	if err != nil {
		return 0
	}
	return value
}

func isTerminalPhase(phase string) bool {
	switch phase {
	case "Succeeded", "Failed":
		return true
	default:
		return false
	}
}
