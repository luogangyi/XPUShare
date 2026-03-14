const state = {
  activePage: "overview",
  overview: null,
  podMetrics: null,
  podTimeline: null,
  cardMetrics: null,
  cardTimeline: null,
};

const PAGE_META = {
  overview: { title: "集群总览", subtitle: "节点、资源池与整体运行状态" },
  pod: { title: "POD 监控", subtitle: "POD 配额调整与 GPU/显存时序观测" },
  card: { title: "整卡/节点监控", subtitle: "整卡显存、队列、利用率与调度事件分析" },
};

const POD_METRIC_LABELS = {
  managed_allocated_bytes: "Managed 显存",
  nvml_used_bytes: "NVML 显存",
  memory_quota_bytes: "显存配额",
  memory_quota_exceeded: "显存超限",
  core_quota_config_percent: "配置算力配额",
  core_quota_effective_percent: "生效算力配额",
  core_usage_ratio: "算力使用率",
  throttled: "限流状态",
  pending_drop: "待释放状态",
  quota_debt_ms: "算力债务",
  gpu_utilization_ratio: "GPU 利用率",
  gpu_memory_utilization_ratio: "GPU 显存利用率",
};

const CARD_METRIC_LABELS = {
  running_memory_bytes: "运行显存",
  peak_running_memory_bytes: "峰值显存",
  memory_safe_limit_bytes: "安全上限",
  memory_usage_ratio: "显存占用率",
  running_clients: "运行队列",
  request_queue_clients: "请求队列",
  wait_queue_clients: "等待队列",
  memory_overloaded: "内存过载",
  gpu_utilization_ratio: "整卡算力利用率",
  gpu_memory_utilization_ratio: "整卡显存利用率",
};

const CARD_SUMMARY_LABELS = {
  gpu_sampler_up: "GPU 采样器状态",
  nvml_up: "NVML 状态",
  drop_lock_total: "累计 DROP_LOCK",
  client_disconnect_total: "累计客户端断连",
  wait_for_mem_total: "累计 WAIT_FOR_MEM",
  mem_available_total: "累计 MEM_AVAILABLE",
  scheduler_running_clients: "全局运行队列",
};

const POD_USAGE_SERIES = [
  { name: "core_usage_ratio", label: "算力使用率", color: "#0b6cc4", fill: true, formatLatest: formatPercent },
  { name: "gpu_utilization_ratio", label: "GPU 利用率", color: "#0f766e", formatLatest: formatPercent },
  { name: "gpu_memory_utilization_ratio", label: "GPU 显存利用率", color: "#dc2626", formatLatest: formatPercent },
];

const POD_MEMORY_SERIES = [
  {
    name: "managed_allocated_bytes",
    label: "Managed 显存",
    color: "#0b6cc4",
    fill: true,
    formatLatest: (value) => formatBytes(value),
  },
  {
    name: "nvml_used_bytes",
    label: "NVML 显存",
    color: "#16a085",
    formatLatest: (value) => formatBytes(value),
  },
  {
    name: "memory_quota_bytes",
    label: "显存配额",
    color: "#e67e22",
    dash: [6, 4],
    formatLatest: (value) => formatBytes(value),
  },
];

const POD_STATE_SERIES = [
  { name: "throttled", label: "限流", color: "#b91c1c", formatLatest: formatCount },
  { name: "pending_drop", label: "待释放", color: "#7c3aed", formatLatest: formatCount },
  { name: "memory_quota_exceeded", label: "显存超限", color: "#c2410c", formatLatest: formatCount },
];

const CARD_MEMORY_SERIES = [
  {
    name: "running_memory_bytes",
    label: "运行显存",
    color: "#0b6cc4",
    fill: true,
    formatLatest: (value) => formatBytes(value),
  },
  {
    name: "memory_safe_limit_bytes",
    label: "安全上限",
    color: "#16a085",
    dash: [6, 4],
    formatLatest: (value) => formatBytes(value),
  },
  {
    name: "peak_running_memory_bytes",
    label: "历史峰值",
    color: "#e67e22",
    dash: [3, 3],
    formatLatest: (value) => formatBytes(value),
  },
];

const CARD_QUEUE_SERIES = [
  { name: "running_clients", label: "运行队列", color: "#0b6cc4", fill: true, formatLatest: formatCount },
  { name: "request_queue_clients", label: "请求队列", color: "#c05621", formatLatest: formatCount },
  { name: "wait_queue_clients", label: "等待队列", color: "#be123c", formatLatest: formatCount },
  { name: "memory_overloaded", label: "内存过载", color: "#7c3aed", dash: [2, 3], formatLatest: formatCount },
];

const CARD_UTIL_SERIES = [
  { name: "memory_usage_ratio", label: "显存占用率", color: "#0b6cc4", fill: true, formatLatest: formatPercent },
  { name: "gpu_utilization_ratio", label: "整卡算力利用率", color: "#0f766e", formatLatest: formatPercent },
  { name: "gpu_memory_utilization_ratio", label: "整卡显存利用率", color: "#dc2626", formatLatest: formatPercent },
];

const CARD_EVENT_SERIES = [
  { name: "wait_for_mem_rate", label: "WAIT_FOR_MEM", color: "#b91c1c", formatLatest: formatRate },
  { name: "mem_available_rate", label: "MEM_AVAILABLE", color: "#15803d", formatLatest: formatRate },
  { name: "drop_lock_rate", label: "DROP_LOCK", color: "#7c3aed", formatLatest: formatRate },
  { name: "disconnect_rate", label: "DISCONNECT", color: "#d97706", formatLatest: formatRate },
];

const navItems = Array.from(document.querySelectorAll(".nav-item"));
const pages = {
  overview: document.getElementById("page-overview"),
  pod: document.getElementById("page-pod"),
  card: document.getElementById("page-card"),
};

const pageTitle = document.getElementById("pageTitle");
const pageSubtitle = document.getElementById("pageSubtitle");
const refreshButton = document.getElementById("refreshButton");
const lastUpdated = document.getElementById("lastUpdated");

const summaryCards = document.getElementById("summaryCards");
const nodeTableBody = document.getElementById("nodeTableBody");

const podTableBody = document.getElementById("podTableBody");
const podSelector = document.getElementById("podSelector");
const podRangeSelector = document.getElementById("podRangeSelector");
const queryMetricsButton = document.getElementById("queryMetricsButton");
const queryPodTrendButton = document.getElementById("queryPodTrendButton");
const metricsCards = document.getElementById("metricsCards");
const metricsStatus = document.getElementById("metricsStatus");
const podUsageChart = document.getElementById("podUsageChart");
const podUsageLegend = document.getElementById("podUsageLegend");
const podMemoryChart = document.getElementById("podMemoryChart");
const podMemoryLegend = document.getElementById("podMemoryLegend");
const podStateChart = document.getElementById("podStateChart");
const podStateLegend = document.getElementById("podStateLegend");

const cardSelector = document.getElementById("cardSelector");
const cardNodeSelector = document.getElementById("cardNodeSelector");
const cardRangeSelector = document.getElementById("cardRangeSelector");
const queryCardMetricsButton = document.getElementById("queryCardMetricsButton");
const cardStatus = document.getElementById("cardStatus");
const cardSummaryCards = document.getElementById("cardSummaryCards");
const cardMetricsCards = document.getElementById("cardMetricsCards");
const cardMemoryChart = document.getElementById("cardMemoryChart");
const memoryChartLegend = document.getElementById("memoryChartLegend");
const cardQueueChart = document.getElementById("cardQueueChart");
const queueChartLegend = document.getElementById("queueChartLegend");
const cardUtilChart = document.getElementById("cardUtilChart");
const utilChartLegend = document.getElementById("utilChartLegend");
const cardEventChart = document.getElementById("cardEventChart");
const eventChartLegend = document.getElementById("eventChartLegend");

navItems.forEach((item) => {
  item.addEventListener("click", () => {
    const page = item.dataset.page;
    if (!page || !PAGE_META[page]) {
      return;
    }
    setRoute(page);
  });
});

window.addEventListener("hashchange", () => applyRoute(readRouteFromHash(), true));
window.addEventListener("resize", debounce(() => {
  renderPodTimelineCharts();
  renderCardTimelineCharts();
}, 150));

refreshButton.addEventListener("click", () => refreshActivePage(true));
queryMetricsButton.addEventListener("click", () => loadPodMetrics(true));
queryPodTrendButton.addEventListener("click", () => loadPodTimeline(true));
podSelector.addEventListener("change", async () => {
  await loadPodMetrics(false);
  await loadPodTimeline(false);
});
podRangeSelector.addEventListener("change", () => loadPodTimeline(true));

queryCardMetricsButton.addEventListener("click", () => loadCardMetrics(true));
cardNodeSelector.addEventListener("change", async () => {
  renderCardSelector(state.cardMetrics?.items || []);
  renderSelectedCardMetrics();
  await loadCardTimeline(false);
});
cardSelector.addEventListener("change", async () => {
  renderSelectedCardMetrics();
  await loadCardTimeline(false);
});
cardRangeSelector.addEventListener("change", () => loadCardTimeline(true));

init().catch((error) => {
  showPodStatus(`初始化失败: ${error.message}`, true);
  showCardStatus(`初始化失败: ${error.message}`, true);
});

async function init() {
  applyRoute(readRouteFromHash(), false);
  await loadOverview();
  await refreshActivePage(false);

  setInterval(() => {
    loadOverview().catch(() => {});
  }, 45000);
  setInterval(() => {
    if (state.activePage === "pod") {
      loadPodMetrics(false).catch(() => {});
      loadPodTimeline(false).catch(() => {});
    }
    if (state.activePage === "card") {
      loadCardMetrics(false).catch(() => {});
      loadCardTimeline(false).catch(() => {});
    }
  }, 30000);
}

function readRouteFromHash() {
  const page = String(window.location.hash || "").replace(/^#/, "").trim();
  return PAGE_META[page] ? page : "overview";
}

function setRoute(page) {
  if (state.activePage === page && window.location.hash === `#${page}`) {
    return;
  }
  window.location.hash = page;
}

function applyRoute(page, shouldRefresh) {
  state.activePage = page;
  navItems.forEach((item) => {
    item.classList.toggle("active", item.dataset.page === page);
  });
  Object.entries(pages).forEach(([key, section]) => {
    section.classList.toggle("active", key === page);
  });

  const meta = PAGE_META[page];
  pageTitle.textContent = meta.title;
  pageSubtitle.textContent = meta.subtitle;
  if (shouldRefresh) {
    refreshActivePage(false).catch(() => {});
  }
}

async function refreshActivePage(manual) {
  refreshButton.disabled = true;
  try {
    if (!state.overview) {
      await loadOverview();
    }
    switch (state.activePage) {
      case "overview":
        await loadOverview();
        break;
      case "pod":
        await loadOverview();
        await loadPodMetrics(manual);
        await loadPodTimeline(manual);
        break;
      case "card":
        await loadCardMetrics(manual);
        await loadCardTimeline(manual);
        break;
      default:
        break;
    }
  } catch (error) {
    if (state.activePage === "pod") {
      showPodStatus(`刷新失败: ${error.message}`, true);
    } else if (state.activePage === "card") {
      showCardStatus(`刷新失败: ${error.message}`, true);
    }
  } finally {
    refreshButton.disabled = false;
  }
}

async function fetchJSON(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = payload.error || `${response.status} ${response.statusText}`;
    throw new Error(message);
  }
  return payload;
}

async function loadOverview() {
  const overview = await fetchJSON("/api/v1/overview");
  state.overview = overview;
  renderOverview();
}

function renderOverview() {
  if (!state.overview) {
    return;
  }
  const summary = state.overview.summary || {};
  const cards = [
    ["xpushare 节点", summary.xpushareNodeCount || 0],
    ["物理 GPU/NPU", summary.physicalDevicesTotal || 0],
    ["vGPU 总量", summary.virtualDevicesTotal || 0],
    ["vGPU 已分配", summary.virtualDevicesAllocated || 0],
    ["vGPU 空闲", summary.virtualDevicesFree || 0],
    ["xpushare Pod", summary.xpusharePodCount || 0],
    ["涉及 Namespace", summary.namespaceCount || 0],
  ];

  summaryCards.innerHTML = "";
  const template = document.getElementById("summaryCardTemplate");
  for (const [title, value] of cards) {
    const node = template.content.firstElementChild.cloneNode(true);
    node.querySelector(".summary-title").textContent = title;
    node.querySelector(".summary-value").textContent = value;
    summaryCards.appendChild(node);
  }

  renderNodeTable(state.overview.nodes || []);
  renderPodTable(state.overview.pods || []);
  renderPodSelector(state.overview.pods || []);

  const ts = state.overview.generatedAt ? new Date(state.overview.generatedAt) : new Date();
  lastUpdated.textContent = `最后更新: ${ts.toLocaleString()}`;
}

function renderNodeTable(nodes) {
  nodeTableBody.innerHTML = "";
  if (!nodes.length) {
    nodeTableBody.appendChild(emptyRow(7, "暂无 xpushare 节点数据"));
    return;
  }
  for (const node of nodes) {
    const tr = document.createElement("tr");
    appendCell(tr, node.name);
    appendCell(tr, node.runtime || "unknown");
    appendCell(tr, node.physicalResource || "-");
    appendCell(tr, String(node.physicalDevicesTotal || 0));
    appendCell(tr, String(node.virtualDevicesTotal || 0));
    appendCell(tr, String(node.virtualDevicesAllocated || 0));
    appendCell(tr, String(node.virtualDevicesFree || 0));
    nodeTableBody.appendChild(tr);
  }
}

function renderPodTable(pods) {
  podTableBody.innerHTML = "";
  if (!pods.length) {
    podTableBody.appendChild(emptyRow(10, "暂无 xpushare Pod 数据"));
    return;
  }

  for (const pod of pods) {
    const tr = document.createElement("tr");
    const key = `${pod.namespace}/${pod.name}`;
    appendCell(tr, pod.namespace);
    appendCell(tr, pod.name);
    appendCell(tr, pod.nodeName || "-");
    appendCell(tr, pod.phase || "Unknown");
    appendCell(tr, String(pod.requestedVGPU || 0));
    appendCell(tr, pod.coreLimit || "100");
    appendCell(tr, pod.memoryLimit || "-");

    const coreTd = document.createElement("td");
    const coreInput = document.createElement("input");
    coreInput.type = "number";
    coreInput.min = "1";
    coreInput.max = "100";
    coreInput.value = parseCoreLimit(pod.coreLimit);
    coreInput.id = `core-${cssSafeId(key)}`;
    coreTd.appendChild(coreInput);
    tr.appendChild(coreTd);

    const memoryTd = document.createElement("td");
    const memoryInput = document.createElement("input");
    memoryInput.type = "text";
    memoryInput.placeholder = "例如 4Gi，留空表示删除";
    memoryInput.value = pod.memoryLimit === "-" ? "" : (pod.memoryLimit || "");
    memoryInput.id = `memory-${cssSafeId(key)}`;
    memoryTd.appendChild(memoryInput);
    tr.appendChild(memoryTd);

    const actionTd = document.createElement("td");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "更新";
    button.addEventListener("click", () =>
      updatePodQuota(pod.namespace, pod.name, coreInput, memoryInput, button),
    );
    actionTd.appendChild(button);
    tr.appendChild(actionTd);
    podTableBody.appendChild(tr);
  }
}

function renderPodSelector(pods) {
  const previousValue = podSelector.value;
  podSelector.innerHTML = "";

  if (!pods.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "暂无可选 Pod";
    podSelector.appendChild(option);
    return;
  }

  for (const pod of pods) {
    const option = document.createElement("option");
    option.value = `${pod.namespace}/${pod.name}`;
    option.textContent = `${pod.namespace}/${pod.name}`;
    podSelector.appendChild(option);
  }

  if (previousValue && pods.some((pod) => `${pod.namespace}/${pod.name}` === previousValue)) {
    podSelector.value = previousValue;
  }
}

async function updatePodQuota(namespace, pod, coreInput, memoryInput, button) {
  const coreLimit = Number.parseInt(coreInput.value, 10);
  if (!Number.isInteger(coreLimit) || coreLimit < 1 || coreLimit > 100) {
    showPodStatus("算力配额必须是 1-100 的整数", true);
    return;
  }

  const payload = { coreLimit, memoryLimit: memoryInput.value.trim() };
  button.disabled = true;
  try {
    await fetchJSON(`/api/v1/pods/${encodeURIComponent(namespace)}/${encodeURIComponent(pod)}/quota`, {
      method: "PATCH",
      body: JSON.stringify(payload),
    });
    showPodStatus(`已更新 ${namespace}/${pod} 配额`, false);
    await loadOverview();
    await loadPodMetrics(false);
    await loadPodTimeline(false);
  } catch (error) {
    showPodStatus(`更新失败: ${error.message}`, true);
  } finally {
    button.disabled = false;
  }
}

async function loadPodMetrics(manual) {
  const selected = getSelectedPod();
  if (!selected) {
    metricsCards.innerHTML = "";
    return;
  }
  try {
    const payload = await fetchJSON(
      `/api/v1/metrics/pod?namespace=${encodeURIComponent(selected.namespace)}&pod=${encodeURIComponent(selected.pod)}`,
    );
    state.podMetrics = payload;
    renderMetricCards(metricsCards, payload.values || {}, POD_METRIC_LABELS);
    const errorCount = payload.errors ? Object.keys(payload.errors).length : 0;
    if (errorCount > 0) {
      showPodStatus(`POD 实时指标部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showPodStatus("POD 实时指标已刷新", false);
    }
  } catch (error) {
    state.podMetrics = null;
    metricsCards.innerHTML = "";
    showPodStatus(`POD 指标查询失败: ${error.message}`, true);
  }
}

async function loadPodTimeline(manual) {
  const selected = getSelectedPod();
  if (!selected) {
    state.podTimeline = null;
    clearPodTimelineCharts("暂无 POD 时序数据");
    return;
  }
  const minutes = Number.parseInt(podRangeSelector.value, 10) || 60;
  const stepSeconds = suggestStepSeconds(minutes);
  const query = new URLSearchParams({
    namespace: selected.namespace,
    pod: selected.pod,
    minutes: String(minutes),
    stepSeconds: String(stepSeconds),
  });

  try {
    const payload = await fetchJSON(`/api/v1/metrics/pod/timeseries?${query.toString()}`);
    state.podTimeline = payload;
    renderPodTimelineCharts();
    const errorCount = payload.errors ? Object.keys(payload.errors).length : 0;
    if (errorCount > 0) {
      showPodStatus(`POD 时序部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showPodStatus("POD 时序曲线已刷新", false);
    }
  } catch (error) {
    state.podTimeline = null;
    clearPodTimelineCharts("POD 时序查询失败");
    showPodStatus(`POD 时序查询失败: ${error.message}`, true);
  }
}

function renderPodTimelineCharts() {
  const timeline = state.podTimeline;
  if (!timeline || !Array.isArray(timeline.series)) {
    clearPodTimelineCharts("暂无 POD 时序数据");
    return;
  }
  const seriesMap = buildSeriesMap(timeline.series);
  const usageDatasets = buildDatasets(seriesMap, POD_USAGE_SERIES);
  const memoryDatasets = buildDatasets(seriesMap, POD_MEMORY_SERIES);
  const stateDatasets = buildDatasets(seriesMap, POD_STATE_SERIES);

  renderLineChart(podUsageChart, usageDatasets, {
    transform: (value) => value * 100,
    minY: 0,
    axisTickFormatter: (value) => `${value.toFixed(0)}%`,
    emptyMessage: "暂无利用率数据",
  });
  renderLegend(podUsageLegend, usageDatasets);

  renderLineChart(podMemoryChart, memoryDatasets, {
    transform: (value) => value / (1024 * 1024 * 1024),
    axisTickFormatter: (value) => `${value.toFixed(value >= 100 ? 0 : 1)} GiB`,
    emptyMessage: "暂无显存数据",
  });
  renderLegend(podMemoryLegend, memoryDatasets);

  renderLineChart(podStateChart, stateDatasets, {
    transform: (value) => value,
    minY: 0,
    axisTickFormatter: (value) => value.toFixed(value >= 10 ? 0 : 1),
    emptyMessage: "暂无状态数据",
  });
  renderLegend(podStateLegend, stateDatasets);
}

function clearPodTimelineCharts(message) {
  drawEmptyChart(podUsageChart, message);
  drawEmptyChart(podMemoryChart, message);
  drawEmptyChart(podStateChart, message);
  podUsageLegend.innerHTML = "";
  podMemoryLegend.innerHTML = "";
  podStateLegend.innerHTML = "";
}

async function loadCardMetrics(manual) {
  queryCardMetricsButton.disabled = true;
  try {
    const payload = await fetchJSON("/api/v1/metrics/cards");
    state.cardMetrics = payload;
    renderCardNodeSelector(payload.items || []);
    renderCardSelector(payload.items || []);
    renderCardSummary(payload.summary || {});
    renderSelectedCardMetrics();
    if (manual) {
      showCardStatus("整卡实时指标已刷新", false);
    }
  } catch (error) {
    state.cardMetrics = null;
    cardNodeSelector.innerHTML = "";
    const option = document.createElement("option");
    option.value = "__all__";
    option.textContent = "全部节点";
    cardNodeSelector.appendChild(option);
    cardSummaryCards.innerHTML = "";
    cardMetricsCards.innerHTML = "";
    showCardStatus(`整卡指标查询失败: ${error.message}`, true);
    clearCardTimelineCharts("整卡时序暂不可用");
  } finally {
    queryCardMetricsButton.disabled = false;
  }
}

function renderCardSummary(values) {
  renderMetricCards(cardSummaryCards, values, CARD_SUMMARY_LABELS);
}

function renderCardNodeSelector(items) {
  const previous = cardNodeSelector.value;
  const nodes = getCardNodeNames(items);
  cardNodeSelector.innerHTML = "";

  const allOption = document.createElement("option");
  allOption.value = "__all__";
  allOption.textContent = "全部节点";
  cardNodeSelector.appendChild(allOption);

  for (const nodeName of nodes) {
    const option = document.createElement("option");
    option.value = nodeName;
    option.textContent = nodeName;
    cardNodeSelector.appendChild(option);
  }

  if (previous && (previous === "__all__" || nodes.includes(previous))) {
    cardNodeSelector.value = previous;
  } else {
    cardNodeSelector.value = "__all__";
  }
}

function renderCardSelector(items) {
  const previous = cardSelector.value;
  const selectedNode = getSelectedCardNode();
  const filteredItems = (items || []).filter((item) => selectedNode === "__all__" || (item.nodeName || "") === selectedNode);
  cardSelector.innerHTML = "";
  if (!filteredItems.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = selectedNode === "__all__" ? "暂无整卡数据" : "该节点暂无整卡数据";
    cardSelector.appendChild(option);
    return;
  }
  for (const item of filteredItems) {
    const option = document.createElement("option");
    option.value = encodeCardValue(item.gpuUUID, item.gpuIndex, item.schedulerPod);
    const nodeLabel = item.nodeName ? `${item.nodeName} · ` : "";
    option.textContent = `${nodeLabel}GPU ${item.gpuIndex || "-"} · ${shortText(item.gpuUUID || "-", 18)}`;
    cardSelector.appendChild(option);
  }
  if (
    previous &&
    filteredItems.some((item) => encodeCardValue(item.gpuUUID, item.gpuIndex, item.schedulerPod) === previous)
  ) {
    cardSelector.value = previous;
  }
}

function renderSelectedCardMetrics() {
  cardMetricsCards.innerHTML = "";
  const selected = getSelectedCard();
  if (!selected) {
    cardMetricsCards.appendChild(createMetricCard("整卡状态", "暂无整卡数据"));
    return;
  }

  const items = state.cardMetrics?.items || [];
  const card = items.find((item) => sameCard(item, selected));
  if (!card) {
    cardMetricsCards.appendChild(createMetricCard("整卡状态", "未找到选中整卡"));
    return;
  }
  const values = card.values || {};
  const cards = [
    ["节点", card.nodeName || "-"],
    ["调度器 Pod", card.schedulerPod || "-"],
    ["GPU UUID", card.gpuUUID || "-"],
    ["GPU Index", card.gpuIndex || "-"],
    ["运行显存", formatMetricValue("running_memory_bytes", values.running_memory_bytes || 0)],
    ["安全上限", formatMetricValue("memory_safe_limit_bytes", values.memory_safe_limit_bytes || 0)],
    ["历史峰值", formatMetricValue("peak_running_memory_bytes", values.peak_running_memory_bytes || 0)],
    ["显存占用率", formatMetricValue("memory_usage_ratio", values.memory_usage_ratio || 0)],
    ["运行队列", formatMetricValue("running_clients", values.running_clients || 0)],
    ["请求队列", formatMetricValue("request_queue_clients", values.request_queue_clients || 0)],
    ["等待队列", formatMetricValue("wait_queue_clients", values.wait_queue_clients || 0)],
    ["内存过载", formatMetricValue("memory_overloaded", values.memory_overloaded || 0)],
    ["整卡算力利用率", formatMetricValue("gpu_utilization_ratio", values.gpu_utilization_ratio || 0)],
    ["整卡显存利用率", formatMetricValue("gpu_memory_utilization_ratio", values.gpu_memory_utilization_ratio || 0)],
  ];
  for (const [name, value] of cards) {
    cardMetricsCards.appendChild(createMetricCard(name, value));
  }
}

async function loadCardTimeline(manual) {
  const selected = getSelectedCard();
  if (!selected) {
    state.cardTimeline = null;
    clearCardTimelineCharts("暂无整卡时序数据");
    return;
  }

  const minutes = Number.parseInt(cardRangeSelector.value, 10) || 60;
  const stepSeconds = suggestStepSeconds(minutes);
  const query = new URLSearchParams({ minutes: String(minutes), stepSeconds: String(stepSeconds) });
  if (selected.gpuUUID && selected.gpuUUID !== "-") {
    query.set("gpuUUID", selected.gpuUUID);
  }
  if (selected.gpuIndex && selected.gpuIndex !== "-") {
    query.set("gpuIndex", selected.gpuIndex);
  }
  if (selected.schedulerPod && selected.schedulerPod !== "-") {
    query.set("schedulerPod", selected.schedulerPod);
  }

  try {
    const payload = await fetchJSON(`/api/v1/metrics/card/timeseries?${query.toString()}`);
    state.cardTimeline = payload;
    renderCardTimelineCharts();
    const errorCount = payload.errors ? Object.keys(payload.errors).length : 0;
    if (errorCount > 0) {
      showCardStatus(`整卡时序部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showCardStatus("整卡时序曲线已刷新", false);
    }
  } catch (error) {
    state.cardTimeline = null;
    clearCardTimelineCharts("整卡时序查询失败");
    showCardStatus(`整卡时序查询失败: ${error.message}`, true);
  }
}

function renderCardTimelineCharts() {
  const timeline = state.cardTimeline;
  if (!timeline || !Array.isArray(timeline.series)) {
    clearCardTimelineCharts("暂无整卡时序数据");
    return;
  }

  const seriesMap = buildSeriesMap(timeline.series);
  const memoryDatasets = buildDatasets(seriesMap, CARD_MEMORY_SERIES);
  const queueDatasets = buildDatasets(seriesMap, CARD_QUEUE_SERIES);
  const utilDatasets = buildDatasets(seriesMap, CARD_UTIL_SERIES);
  const eventDatasets = buildDatasets(seriesMap, CARD_EVENT_SERIES);

  renderLineChart(cardMemoryChart, memoryDatasets, {
    transform: (value) => value / (1024 * 1024 * 1024),
    axisTickFormatter: (value) => `${value.toFixed(value >= 100 ? 0 : 1)} GiB`,
    emptyMessage: "暂无显存时序数据",
  });
  renderLegend(memoryChartLegend, memoryDatasets);

  renderLineChart(cardQueueChart, queueDatasets, {
    transform: (value) => value,
    minY: 0,
    axisTickFormatter: (value) => value.toFixed(value >= 10 ? 0 : 1),
    emptyMessage: "暂无队列时序数据",
  });
  renderLegend(queueChartLegend, queueDatasets);

  renderLineChart(cardUtilChart, utilDatasets, {
    transform: (value) => value * 100,
    minY: 0,
    axisTickFormatter: (value) => `${value.toFixed(0)}%`,
    emptyMessage: "暂无利用率时序数据",
  });
  renderLegend(utilChartLegend, utilDatasets);

  renderLineChart(cardEventChart, eventDatasets, {
    transform: (value) => value,
    minY: 0,
    axisTickFormatter: (value) => value.toFixed(2),
    emptyMessage: "暂无调度事件速率",
  });
  renderLegend(eventChartLegend, eventDatasets);
}

function clearCardTimelineCharts(message) {
  drawEmptyChart(cardMemoryChart, message);
  drawEmptyChart(cardQueueChart, message);
  drawEmptyChart(cardUtilChart, message);
  drawEmptyChart(cardEventChart, message);
  memoryChartLegend.innerHTML = "";
  queueChartLegend.innerHTML = "";
  utilChartLegend.innerHTML = "";
  eventChartLegend.innerHTML = "";
}

function renderMetricCards(container, values, labelMap = {}) {
  container.innerHTML = "";
  const entries = Object.entries(values || {});
  if (!entries.length) {
    container.appendChild(createMetricCard("无数据", "-"));
    return;
  }
  entries.sort(([a], [b]) => a.localeCompare(b));
  for (const [name, value] of entries) {
    container.appendChild(createMetricCard(labelMap[name] || name, formatMetricValue(name, value)));
  }
}

function renderLineChart(canvas, datasets, options) {
  const normalized = [];
  for (const dataset of datasets) {
    const points = [];
    for (const point of dataset.points) {
      const x = Number(point.timestamp);
      const y = options.transform(Number(point.value));
      if (Number.isFinite(x) && Number.isFinite(y)) {
        points.push({ x, y });
      }
    }
    if (points.length > 0) {
      normalized.push({ ...dataset, points });
    }
  }
  if (!normalized.length) {
    drawEmptyChart(canvas, options.emptyMessage || "暂无数据");
    return;
  }

  const { ctx, width, height } = beginCanvas(canvas);
  const margin = { top: 14, right: 14, bottom: 26, left: 56 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  if (plotWidth <= 0 || plotHeight <= 0) {
    return;
  }

  const xValues = normalized.flatMap((dataset) => dataset.points.map((point) => point.x));
  const yValues = normalized.flatMap((dataset) => dataset.points.map((point) => point.y));
  let xMin = Math.min(...xValues);
  let xMax = Math.max(...xValues);
  if (!Number.isFinite(xMin) || !Number.isFinite(xMax)) {
    drawEmptyChart(canvas, options.emptyMessage || "暂无数据");
    return;
  }
  if (xMin === xMax) {
    xMax = xMin + 1;
  }

  let yMin = Number.isFinite(options.minY) ? options.minY : Math.min(...yValues, 0);
  let yMax = Math.max(...yValues);
  if (!Number.isFinite(yMin)) {
    yMin = 0;
  }
  if (!Number.isFinite(yMax)) {
    yMax = 1;
  }
  if (yMin === yMax) {
    yMax = yMin + 1;
  }

  const background = ctx.createLinearGradient(0, margin.top, 0, height - margin.bottom);
  background.addColorStop(0, "#ffffff");
  background.addColorStop(1, "#f3f8ff");
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, width, height);

  ctx.font = "11px 'Helvetica Neue', 'PingFang SC', sans-serif";
  ctx.fillStyle = "#5f7288";
  ctx.strokeStyle = "#dbe7f4";
  ctx.lineWidth = 1;

  const gridLines = 4;
  for (let i = 0; i <= gridLines; i += 1) {
    const ratio = i / gridLines;
    const y = margin.top + plotHeight * ratio;
    ctx.beginPath();
    ctx.moveTo(margin.left, y);
    ctx.lineTo(width - margin.right, y);
    ctx.stroke();

    const value = yMax - (yMax - yMin) * ratio;
    ctx.fillText(options.axisTickFormatter(value), 8, y + 4);
  }

  const xTicks = 4;
  for (let i = 0; i <= xTicks; i += 1) {
    const ratio = i / xTicks;
    const x = margin.left + plotWidth * ratio;
    const ts = xMin + (xMax - xMin) * ratio;
    ctx.beginPath();
    ctx.moveTo(x, margin.top);
    ctx.lineTo(x, height - margin.bottom);
    ctx.stroke();
    const label = formatTimeTick(ts, xMax - xMin);
    ctx.fillText(label, x - 16, height - 8);
  }

  const toX = (value) => margin.left + ((value - xMin) / (xMax - xMin)) * plotWidth;
  const toY = (value) => margin.top + (1 - (value - yMin) / (yMax - yMin)) * plotHeight;

  ctx.save();
  ctx.beginPath();
  ctx.rect(margin.left, margin.top, plotWidth, plotHeight);
  ctx.clip();

  for (const dataset of normalized) {
    const points = dataset.points.map((point) => ({ x: toX(point.x), y: toY(point.y) }));
    if (points.length === 0) {
      continue;
    }

    ctx.strokeStyle = dataset.color;
    ctx.lineWidth = 2;
    ctx.setLineDash(dataset.dash || []);
    drawSmoothLine(ctx, points);

    if (dataset.fill && points.length > 1) {
      const area = ctx.createLinearGradient(0, margin.top, 0, height - margin.bottom);
      area.addColorStop(0, hexToRgba(dataset.color, 0.20));
      area.addColorStop(1, hexToRgba(dataset.color, 0.02));
      ctx.beginPath();
      ctx.moveTo(points[0].x, height - margin.bottom);
      points.forEach((point) => ctx.lineTo(point.x, point.y));
      ctx.lineTo(points[points.length - 1].x, height - margin.bottom);
      ctx.closePath();
      ctx.fillStyle = area;
      ctx.fill();
    }
  }
  ctx.restore();
  ctx.setLineDash([]);
}

function renderLegend(container, datasets) {
  container.innerHTML = "";
  for (const dataset of datasets) {
    if (!dataset.points.length) {
      continue;
    }
    const latest = dataset.points[dataset.points.length - 1].value;
    const item = document.createElement("span");
    item.className = "legend-item";
    const dot = document.createElement("span");
    dot.className = "legend-dot";
    dot.style.background = dataset.color;
    const text = document.createElement("span");
    text.textContent = `${dataset.label}: ${dataset.formatLatest(latest)}`;
    item.appendChild(dot);
    item.appendChild(text);
    container.appendChild(item);
  }
}

function beginCanvas(canvas) {
  const width = Math.max(300, Math.floor(canvas.clientWidth || 300));
  const baseHeight = Math.floor(canvas.clientHeight || canvas.height || 170);
  const height = Math.max(150, Math.min(220, baseHeight));
  const dpr = window.devicePixelRatio || 1;
  const realWidth = Math.floor(width * dpr);
  const realHeight = Math.floor(height * dpr);
  if (canvas.width !== realWidth || canvas.height !== realHeight) {
    canvas.width = realWidth;
    canvas.height = realHeight;
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, width, height);
  return { ctx, width, height };
}

function drawEmptyChart(canvas, message) {
  const { ctx, width, height } = beginCanvas(canvas);
  const gradient = ctx.createLinearGradient(0, 0, 0, height);
  gradient.addColorStop(0, "#ffffff");
  gradient.addColorStop(1, "#f6faff");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, width, height);
  ctx.fillStyle = "#6b7f94";
  ctx.font = "12px 'Helvetica Neue', 'PingFang SC', sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(message, width / 2, height / 2);
  ctx.textAlign = "left";
}

function drawSmoothLine(ctx, points) {
  if (points.length === 1) {
    ctx.beginPath();
    ctx.arc(points[0].x, points[0].y, 2, 0, Math.PI * 2);
    ctx.fillStyle = ctx.strokeStyle;
    ctx.fill();
    return;
  }

  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i += 1) {
    const cx = (points[i].x + points[i + 1].x) / 2;
    const cy = (points[i].y + points[i + 1].y) / 2;
    ctx.quadraticCurveTo(points[i].x, points[i].y, cx, cy);
  }
  const last = points.length - 1;
  ctx.quadraticCurveTo(points[last - 1].x, points[last - 1].y, points[last].x, points[last].y);
  ctx.stroke();
}

function buildSeriesMap(series) {
  const map = new Map();
  (series || []).forEach((item) => map.set(item.name, item.points || []));
  return map;
}

function buildDatasets(seriesMap, definitions) {
  return definitions.map((definition) => ({
    ...definition,
    points: seriesMap.get(definition.name) || [],
  }));
}

function createMetricCard(name, valueText) {
  const card = document.createElement("article");
  card.className = "metric-card";
  const title = document.createElement("div");
  title.className = "metric-name";
  title.textContent = name;
  const value = document.createElement("div");
  value.className = "metric-value";
  value.textContent = valueText;
  card.appendChild(title);
  card.appendChild(value);
  return card;
}

function formatMetricValue(name, value) {
  if (!Number.isFinite(value)) {
    return "-";
  }
  if (name.endsWith("_bytes")) {
    return formatBytes(value);
  }
  if (name.endsWith("_ratio")) {
    return formatPercent(value);
  }
  if (name.endsWith("_percent")) {
    return `${value.toFixed(1)}%`;
  }
  if (name.endsWith("_ms")) {
    return `${value.toFixed(0)} ms`;
  }
  if (name.endsWith("_rate")) {
    return formatRate(value);
  }
  if (name.endsWith("_clients") || name.endsWith("_total") || name.endsWith("_up") || name.endsWith("_drop")) {
    return formatCount(value);
  }
  return value.toFixed(4);
}

function formatBytes(bytes) {
  if (bytes <= 0) {
    return "0 B";
  }
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 100 ? 0 : 2)} ${units[index]}`;
}

function formatPercent(value) {
  return `${(value * 100).toFixed(1)}%`;
}

function formatCount(value) {
  return Number(value).toFixed(value >= 100 ? 0 : 1);
}

function formatRate(value) {
  return `${Number(value).toFixed(3)} /s`;
}

function appendCell(row, text) {
  const td = document.createElement("td");
  td.textContent = text;
  row.appendChild(td);
}

function emptyRow(span, message) {
  const tr = document.createElement("tr");
  const td = document.createElement("td");
  td.colSpan = span;
  td.textContent = message;
  td.className = "muted";
  tr.appendChild(td);
  return tr;
}

function parseCoreLimit(value) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 100) {
    return 100;
  }
  return parsed;
}

function cssSafeId(value) {
  return value.replace(/[^a-zA-Z0-9_-]/g, "_");
}

function getSelectedPod() {
  const selected = podSelector.value || "";
  if (!selected.includes("/")) {
    return null;
  }
  const [namespace, pod] = selected.split("/");
  return { namespace, pod };
}

function getCardNodeNames(items) {
  return Array.from(
    new Set(
      (items || [])
        .map((item) => (item.nodeName || "").trim())
        .filter((name) => Boolean(name)),
    ),
  ).sort((left, right) => left.localeCompare(right));
}

function getSelectedCardNode() {
  const selected = (cardNodeSelector.value || "").trim();
  if (!selected) {
    return "__all__";
  }
  return selected;
}

function encodeCardValue(gpuUUID, gpuIndex, schedulerPod) {
  return `${gpuUUID || "-"}::${gpuIndex || "-"}::${schedulerPod || "-"}`;
}

function getSelectedCard() {
  const raw = cardSelector.value || "";
  if (!raw) {
    return null;
  }
  const parts = raw.split("::");
  if (parts.length < 2) {
    return null;
  }
  const [gpuUUID, gpuIndex, schedulerPod = "-"] = parts;
  return { gpuUUID, gpuIndex, schedulerPod };
}

function sameCard(item, selected) {
  return (
    (item.gpuUUID || "-") === selected.gpuUUID &&
    (item.gpuIndex || "-") === selected.gpuIndex &&
    (item.schedulerPod || "-") === selected.schedulerPod
  );
}

function shortText(value, maxLen) {
  if (!value || value.length <= maxLen) {
    return value;
  }
  return `${value.slice(0, maxLen - 3)}...`;
}

function formatTimeTick(timestampSeconds, spanSeconds) {
  const date = new Date(timestampSeconds * 1000);
  const hour = String(date.getHours()).padStart(2, "0");
  const minute = String(date.getMinutes()).padStart(2, "0");
  if (spanSeconds >= 24 * 60 * 60) {
    const month = String(date.getMonth() + 1).padStart(2, "0");
    const day = String(date.getDate()).padStart(2, "0");
    return `${month}/${day} ${hour}:${minute}`;
  }
  return `${hour}:${minute}`;
}

function suggestStepSeconds(windowMinutes) {
  if (windowMinutes <= 30) {
    return 15;
  }
  if (windowMinutes <= 120) {
    return 30;
  }
  if (windowMinutes <= 360) {
    return 60;
  }
  return 120;
}

function hexToRgba(hex, alpha) {
  const normalized = hex.replace("#", "");
  const full = normalized.length === 3 ? normalized.split("").map((c) => c + c).join("") : normalized;
  const value = Number.parseInt(full, 16);
  const r = (value >> 16) & 255;
  const g = (value >> 8) & 255;
  const b = value & 255;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function showPodStatus(message, isError) {
  metricsStatus.textContent = message;
  metricsStatus.className = isError ? "muted status-error" : "muted status-success";
}

function showCardStatus(message, isError) {
  cardStatus.textContent = message;
  cardStatus.className = isError ? "muted status-error" : "muted status-success";
}

function debounce(fn, wait) {
  let timer = null;
  return (...args) => {
    if (timer) {
      clearTimeout(timer);
    }
    timer = setTimeout(() => fn(...args), wait);
  };
}
