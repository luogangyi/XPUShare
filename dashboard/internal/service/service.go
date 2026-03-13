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

type PodMetricsTimeline struct {
	Namespace     string            `json:"namespace"`
	Pod           string            `json:"pod"`
	WindowMinutes int               `json:"windowMinutes"`
	StepSeconds   int               `json:"stepSeconds"`
	QueriedAt     time.Time         `json:"queriedAt"`
	Series        []TimelineSeries  `json:"series"`
	Errors        map[string]string `json:"errors,omitempty"`
}

type CardMetrics struct {
	QueriedAt time.Time          `json:"queriedAt"`
	Items     []CardMetricsItem  `json:"items"`
	Summary   map[string]float64 `json:"summary,omitempty"`
	Errors    map[string]string  `json:"errors,omitempty"`
}

type CardMetricsItem struct {
	GPUUUID  string             `json:"gpuUUID"`
	GPUIndex string             `json:"gpuIndex"`
	Values   map[string]float64 `json:"values"`
}

type CardMetricsTimeline struct {
	GPUUUID       string            `json:"gpuUUID"`
	GPUIndex      string            `json:"gpuIndex"`
	WindowMinutes int               `json:"windowMinutes"`
	StepSeconds   int               `json:"stepSeconds"`
	QueriedAt     time.Time         `json:"queriedAt"`
	Series        []TimelineSeries  `json:"series"`
	Errors        map[string]string `json:"errors,omitempty"`
}

type TimelineSeries struct {
	Name   string          `json:"name"`
	Unit   string          `json:"unit,omitempty"`
	Points []TimelinePoint `json:"points"`
}

type TimelinePoint struct {
	Timestamp int64   `json:"timestamp"`
	Value     float64 `json:"value"`
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

func (s *Service) GetPodMetricsTimeline(ctx context.Context, namespace, pod string, windowMinutes, stepSeconds int) (PodMetricsTimeline, error) {
	namespace = strings.TrimSpace(namespace)
	pod = strings.TrimSpace(pod)
	if namespace == "" || pod == "" {
		return PodMetricsTimeline{}, fmt.Errorf("namespace and pod are required")
	}

	windowMinutes, stepSeconds = normalizeTimelineOptions(windowMinutes, stepSeconds)
	timeline := PodMetricsTimeline{
		Namespace:     namespace,
		Pod:           pod,
		WindowMinutes: windowMinutes,
		StepSeconds:   stepSeconds,
		QueriedAt:     time.Now().UTC(),
		Series:        []TimelineSeries{},
		Errors:        map[string]string{},
	}

	if s.prom == nil || !s.prom.Enabled() {
		return timeline, fmt.Errorf("prometheus is not configured")
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

	now := time.Now().UTC()
	start := now.Add(-time.Duration(windowMinutes) * time.Minute)
	step := time.Duration(stepSeconds) * time.Second

	queries := []struct {
		name  string
		unit  string
		query string
	}{
		{name: "managed_allocated_bytes", unit: "bytes", query: withDualSelector("sum", "xpushare_client_managed_allocated_bytes")},
		{name: "nvml_used_bytes", unit: "bytes", query: withDualSelector("sum", "xpushare_client_nvml_used_bytes")},
		{name: "memory_quota_bytes", unit: "bytes", query: withDualSelector("max", "xpushare_client_memory_quota_bytes")},
		{name: "memory_quota_exceeded", unit: "count", query: withDualSelector("max", "xpushare_client_memory_quota_exceeded")},
		{name: "core_quota_effective_percent", unit: "percent", query: withDualSelector("max", "xpushare_client_core_quota_effective_percent")},
		{name: "core_usage_ratio", unit: "ratio", query: withDualSelector("max", "xpushare_client_core_usage_ratio")},
		{name: "throttled", unit: "count", query: withDualSelector("max", "xpushare_client_throttled")},
		{name: "pending_drop", unit: "count", query: withDualSelector("max", "xpushare_client_pending_drop")},
		{name: "quota_debt_ms", unit: "ms", query: withDualSelector("sum", "xpushare_client_quota_debt_ms")},
		{name: "gpu_utilization_ratio", unit: "ratio", query: fmt.Sprintf("avg(xpushare_gpu_utilization_ratio and on(gpu_uuid) %s)", clientInfoByGPU)},
		{name: "gpu_memory_utilization_ratio", unit: "ratio", query: fmt.Sprintf("avg(xpushare_gpu_memory_utilization_ratio and on(gpu_uuid) %s)", clientInfoByGPU)},
	}

	for _, item := range queries {
		rangeSamples, err := s.prom.QueryRange(ctx, item.query, start, now, step)
		if err != nil {
			timeline.Errors[item.name] = err.Error()
			continue
		}
		timeline.Series = append(timeline.Series, TimelineSeries{
			Name:   item.name,
			Unit:   item.unit,
			Points: mergeRangeSamples(rangeSamples),
		})
	}

	if len(timeline.Errors) == 0 {
		timeline.Errors = nil
	}
	return timeline, nil
}

func (s *Service) GetCardMetrics(ctx context.Context) (CardMetrics, error) {
	metrics := CardMetrics{
		QueriedAt: time.Now().UTC(),
		Items:     []CardMetricsItem{},
		Summary:   map[string]float64{},
		Errors:    map[string]string{},
	}

	if s.prom == nil || !s.prom.Enabled() {
		return metrics, fmt.Errorf("prometheus is not configured")
	}

	queries := []struct {
		name  string
		query string
	}{
		{name: "running_memory_bytes", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_running_memory_bytes)"},
		{name: "peak_running_memory_bytes", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_peak_running_memory_bytes)"},
		{name: "memory_safe_limit_bytes", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_memory_safe_limit_bytes)"},
		{name: "running_clients", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_running_clients)"},
		{name: "request_queue_clients", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_request_queue_clients)"},
		{name: "wait_queue_clients", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_wait_queue_clients)"},
		{name: "memory_overloaded", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_memory_overloaded)"},
		{name: "memory_usage_ratio", query: "max by (gpu_uuid, gpu_index) (xpushare_scheduler_running_memory_bytes / clamp_min(xpushare_scheduler_memory_safe_limit_bytes, 1))"},
		{name: "gpu_utilization_ratio", query: "max by (gpu_uuid, gpu_index) (xpushare_gpu_utilization_ratio)"},
		{name: "gpu_memory_utilization_ratio", query: "max by (gpu_uuid, gpu_index) (xpushare_gpu_memory_utilization_ratio)"},
	}

	itemsByCard := make(map[string]*CardMetricsItem)
	for _, item := range queries {
		samples, err := s.prom.Query(ctx, item.query)
		if err != nil {
			metrics.Errors[item.name] = err.Error()
			continue
		}

		for _, sample := range samples {
			key, gpuUUID, gpuIndex := extractCardIdentity(sample.Metric)
			if key == "" {
				continue
			}
			existing := itemsByCard[key]
			if existing == nil {
				existing = &CardMetricsItem{
					GPUUUID:  gpuUUID,
					GPUIndex: gpuIndex,
					Values:   map[string]float64{},
				}
				itemsByCard[key] = existing
			}
			existing.Values[item.name] = sample.Value
		}
	}

	cards := make([]CardMetricsItem, 0, len(itemsByCard))
	for _, item := range itemsByCard {
		cards = append(cards, *item)
	}
	sort.Slice(cards, func(i, j int) bool {
		left, right := cards[i], cards[j]
		leftIndex, leftErr := strconv.Atoi(left.GPUIndex)
		rightIndex, rightErr := strconv.Atoi(right.GPUIndex)
		switch {
		case leftErr == nil && rightErr == nil && leftIndex != rightIndex:
			return leftIndex < rightIndex
		case leftErr == nil && rightErr != nil:
			return true
		case leftErr != nil && rightErr == nil:
			return false
		case left.GPUUUID != right.GPUUUID:
			return left.GPUUUID < right.GPUUUID
		default:
			return left.GPUIndex < right.GPUIndex
		}
	})

	metrics.Items = cards

	summaryQueries := map[string]string{
		"gpu_sampler_up":            "max(xpushare_gpu_sampler_up)",
		"nvml_up":                   "max(xpushare_nvml_up)",
		"drop_lock_total":           "sum(xpushare_scheduler_drop_lock_total)",
		"client_disconnect_total":   "sum(xpushare_scheduler_client_disconnect_total)",
		"wait_for_mem_total":        "sum(xpushare_scheduler_wait_for_mem_total)",
		"mem_available_total":       "sum(xpushare_scheduler_mem_available_total)",
		"scheduler_running_clients": "sum(xpushare_scheduler_running_clients)",
	}
	for name, query := range summaryQueries {
		value, err := s.prom.QuerySum(ctx, query)
		if err != nil {
			metrics.Errors["summary_"+name] = err.Error()
			continue
		}
		metrics.Summary[name] = value
	}

	if len(metrics.Summary) == 0 {
		metrics.Summary = nil
	}
	if len(metrics.Errors) == 0 {
		metrics.Errors = nil
	}
	return metrics, nil
}

func (s *Service) GetCardMetricsTimeline(ctx context.Context, gpuUUID, gpuIndex string, windowMinutes, stepSeconds int) (CardMetricsTimeline, error) {
	windowMinutes, stepSeconds = normalizeTimelineOptions(windowMinutes, stepSeconds)

	timeline := CardMetricsTimeline{
		GPUUUID:       strings.TrimSpace(gpuUUID),
		GPUIndex:      strings.TrimSpace(gpuIndex),
		WindowMinutes: windowMinutes,
		StepSeconds:   stepSeconds,
		QueriedAt:     time.Now().UTC(),
		Series:        []TimelineSeries{},
		Errors:        map[string]string{},
	}

	if s.prom == nil || !s.prom.Enabled() {
		return timeline, fmt.Errorf("prometheus is not configured")
	}

	if timeline.GPUUUID == "" && timeline.GPUIndex == "" {
		return timeline, fmt.Errorf("gpuUUID or gpuIndex is required")
	}

	selector := buildCardSelector(timeline.GPUUUID, timeline.GPUIndex)
	now := time.Now().UTC()
	start := now.Add(-time.Duration(windowMinutes) * time.Minute)
	step := time.Duration(stepSeconds) * time.Second

	queries := []struct {
		name  string
		unit  string
		query string
	}{
		{name: "running_memory_bytes", unit: "bytes", query: fmt.Sprintf("max(xpushare_scheduler_running_memory_bytes{%s})", selector)},
		{name: "peak_running_memory_bytes", unit: "bytes", query: fmt.Sprintf("max(xpushare_scheduler_peak_running_memory_bytes{%s})", selector)},
		{name: "memory_safe_limit_bytes", unit: "bytes", query: fmt.Sprintf("max(xpushare_scheduler_memory_safe_limit_bytes{%s})", selector)},
		{name: "memory_usage_ratio", unit: "ratio", query: fmt.Sprintf("max(xpushare_scheduler_running_memory_bytes{%s} / clamp_min(xpushare_scheduler_memory_safe_limit_bytes{%s}, 1))", selector, selector)},
		{name: "running_clients", unit: "count", query: fmt.Sprintf("max(xpushare_scheduler_running_clients{%s})", selector)},
		{name: "request_queue_clients", unit: "count", query: fmt.Sprintf("max(xpushare_scheduler_request_queue_clients{%s})", selector)},
		{name: "wait_queue_clients", unit: "count", query: fmt.Sprintf("max(xpushare_scheduler_wait_queue_clients{%s})", selector)},
		{name: "memory_overloaded", unit: "count", query: fmt.Sprintf("max(xpushare_scheduler_memory_overloaded{%s})", selector)},
		{name: "gpu_utilization_ratio", unit: "ratio", query: fmt.Sprintf("max(xpushare_gpu_utilization_ratio{%s})", selector)},
		{name: "gpu_memory_utilization_ratio", unit: "ratio", query: fmt.Sprintf("max(xpushare_gpu_memory_utilization_ratio{%s})", selector)},
		{name: "wait_for_mem_rate", unit: "rate", query: "rate(xpushare_scheduler_wait_for_mem_total[5m])"},
		{name: "mem_available_rate", unit: "rate", query: "rate(xpushare_scheduler_mem_available_total[5m])"},
		{name: "drop_lock_rate", unit: "rate", query: "rate(xpushare_scheduler_drop_lock_total[5m])"},
		{name: "disconnect_rate", unit: "rate", query: "rate(xpushare_scheduler_client_disconnect_total[5m])"},
		{name: "gpu_sampler_up", unit: "count", query: "max(xpushare_gpu_sampler_up)"},
		{name: "nvml_up", unit: "count", query: "max(xpushare_nvml_up)"},
	}

	for _, item := range queries {
		rangeSamples, err := s.prom.QueryRange(ctx, item.query, start, now, step)
		if err != nil {
			timeline.Errors[item.name] = err.Error()
			continue
		}
		timeline.Series = append(timeline.Series, TimelineSeries{
			Name:   item.name,
			Unit:   item.unit,
			Points: mergeRangeSamples(rangeSamples),
		})
	}

	if len(timeline.Errors) == 0 {
		timeline.Errors = nil
	}
	return timeline, nil
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

func extractCardIdentity(labels map[string]string) (key string, gpuUUID string, gpuIndex string) {
	gpuUUID = strings.TrimSpace(labels["gpu_uuid"])
	gpuIndex = strings.TrimSpace(labels["gpu_index"])
	if gpuUUID == "" {
		gpuUUID = strings.TrimSpace(labels["gpu"])
	}
	if gpuIndex == "" {
		gpuIndex = strings.TrimSpace(labels["gpuIndex"])
	}

	if gpuUUID == "" && gpuIndex == "" {
		return "", "", ""
	}

	switch {
	case gpuUUID != "":
		key = "uuid:" + gpuUUID
	case gpuIndex != "":
		key = "index:" + gpuIndex
	}

	if gpuUUID == "" {
		gpuUUID = "-"
	}
	if gpuIndex == "" {
		gpuIndex = "-"
	}
	return key, gpuUUID, gpuIndex
}

func buildCardSelector(gpuUUID, gpuIndex string) string {
	parts := make([]string, 0, 2)
	if gpuUUID != "" {
		parts = append(parts, fmt.Sprintf("gpu_uuid=%q", gpuUUID))
	}
	if gpuIndex != "" {
		parts = append(parts, fmt.Sprintf("gpu_index=%q", gpuIndex))
	}
	return strings.Join(parts, ",")
}

func mergeRangeSamples(samples []prom.RangeSample) []TimelinePoint {
	if len(samples) == 0 {
		return nil
	}

	merged := make(map[int64]float64)
	for _, series := range samples {
		for _, point := range series.Values {
			timestamp := int64(point.Timestamp)
			merged[timestamp] += point.Value
		}
	}

	if len(merged) == 0 {
		return nil
	}

	timestamps := make([]int64, 0, len(merged))
	for ts := range merged {
		timestamps = append(timestamps, ts)
	}
	sort.Slice(timestamps, func(i, j int) bool { return timestamps[i] < timestamps[j] })

	points := make([]TimelinePoint, 0, len(timestamps))
	for _, ts := range timestamps {
		points = append(points, TimelinePoint{
			Timestamp: ts,
			Value:     merged[ts],
		})
	}
	return points
}

func normalizeTimelineOptions(windowMinutes, stepSeconds int) (int, int) {
	if windowMinutes <= 0 {
		windowMinutes = 60
	}
	if windowMinutes < 5 {
		windowMinutes = 5
	}
	if windowMinutes > 24*60 {
		windowMinutes = 24 * 60
	}
	if stepSeconds <= 0 {
		stepSeconds = 30
	}
	if stepSeconds < 5 {
		stepSeconds = 5
	}
	if stepSeconds > 300 {
		stepSeconds = 300
	}
	return windowMinutes, stepSeconds
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
