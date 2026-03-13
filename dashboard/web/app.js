const state = {
  overview: null,
  cardMetrics: null,
  cardTimeline: null,
};

const summaryCards = document.getElementById("summaryCards");
const nodeTableBody = document.getElementById("nodeTableBody");
const podTableBody = document.getElementById("podTableBody");
const podSelector = document.getElementById("podSelector");
const metricsCards = document.getElementById("metricsCards");
const metricsStatus = document.getElementById("metricsStatus");
const lastUpdated = document.getElementById("lastUpdated");

const cardSelector = document.getElementById("cardSelector");
const cardRangeSelector = document.getElementById("cardRangeSelector");
const cardMetricsCards = document.getElementById("cardMetricsCards");
const cardStatus = document.getElementById("cardStatus");
const cardMemoryChart = document.getElementById("cardMemoryChart");
const cardQueueChart = document.getElementById("cardQueueChart");
const cardUtilChart = document.getElementById("cardUtilChart");
const memoryChartLegend = document.getElementById("memoryChartLegend");
const queueChartLegend = document.getElementById("queueChartLegend");
const utilChartLegend = document.getElementById("utilChartLegend");

const refreshButton = document.getElementById("refreshButton");
const queryMetricsButton = document.getElementById("queryMetricsButton");
const queryCardMetricsButton = document.getElementById("queryCardMetricsButton");

const MEMORY_SERIES = [
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

const QUEUE_SERIES = [
  {
    name: "running_clients",
    label: "运行队列",
    color: "#0b6cc4",
    fill: true,
    formatLatest: (value) => value.toFixed(0),
  },
  {
    name: "request_queue_clients",
    label: "请求队列",
    color: "#c05621",
    formatLatest: (value) => value.toFixed(0),
  },
  {
    name: "wait_queue_clients",
    label: "等待队列",
    color: "#be123c",
    formatLatest: (value) => value.toFixed(0),
  },
  {
    name: "memory_overloaded",
    label: "内存过载(0/1)",
    color: "#7c3aed",
    dash: [2, 3],
    formatLatest: (value) => value.toFixed(0),
  },
];

const UTIL_SERIES = [
  {
    name: "memory_usage_ratio",
    label: "显存占用率",
    color: "#0b6cc4",
    fill: true,
    formatLatest: (value) => `${(value * 100).toFixed(1)}%`,
  },
  {
    name: "gpu_utilization_ratio",
    label: "整卡算力利用率",
    color: "#0f766e",
    formatLatest: (value) => `${(value * 100).toFixed(1)}%`,
  },
  {
    name: "gpu_memory_utilization_ratio",
    label: "整卡显存利用率",
    color: "#dc2626",
    formatLatest: (value) => `${(value * 100).toFixed(1)}%`,
  },
];

refreshButton.addEventListener("click", () => loadOverview(true));
queryMetricsButton.addEventListener("click", () => loadPodMetrics(true));
queryCardMetricsButton.addEventListener("click", () => loadCardMetrics(true));
podSelector.addEventListener("change", () => loadPodMetrics(false));
cardSelector.addEventListener("change", async () => {
  renderSelectedCardMetrics();
  await loadCardTimeline(false);
});
cardRangeSelector.addEventListener("change", () => loadCardTimeline(true));
window.addEventListener("resize", debounce(() => renderCardTimelineCharts(), 150));

loadOverview(false);
setInterval(() => loadOverview(false), 15000);
setInterval(() => loadPodMetrics(false), 20000);
setInterval(() => loadCardTimeline(false), 30000);

async function fetchJSON(path, options = {}) {
  const response = await fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = payload.error || `${response.status} ${response.statusText}`;
    throw new Error(message);
  }
  return payload;
}

async function loadOverview(manual) {
  try {
    refreshButton.disabled = true;
    const overview = await fetchJSON("/api/v1/overview");
    state.overview = overview;
    renderOverview();
    await Promise.all([loadPodMetrics(false), loadCardMetrics(false)]);
    if (manual) {
      showMetricsStatus("数据刷新完成", false);
      showCardStatus("整卡监控刷新完成", false);
    }
  } catch (error) {
    showMetricsStatus(`刷新失败: ${error.message}`, true);
    showCardStatus(`刷新失败: ${error.message}`, true);
  } finally {
    refreshButton.disabled = false;
  }
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
    button.addEventListener("click", () => updatePodQuota(pod.namespace, pod.name, coreInput, memoryInput, button));
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
    showMetricsStatus("算力配额必须是 1-100 的整数", true);
    return;
  }

  const payload = {
    coreLimit,
    memoryLimit: memoryInput.value.trim(),
  };

  try {
    button.disabled = true;
    await fetchJSON(`/api/v1/pods/${encodeURIComponent(namespace)}/${encodeURIComponent(pod)}/quota`, {
      method: "PATCH",
      body: JSON.stringify(payload),
    });
    showMetricsStatus(`已更新 ${namespace}/${pod} 配额`, false);
    await loadOverview(false);
  } catch (error) {
    showMetricsStatus(`更新失败: ${error.message}`, true);
  } finally {
    button.disabled = false;
  }
}

async function loadPodMetrics(manual) {
  const selected = podSelector.value;
  if (!selected || !selected.includes("/")) {
    metricsCards.innerHTML = "";
    return;
  }

  const [namespace, pod] = selected.split("/");
  try {
    const metrics = await fetchJSON(
      `/api/v1/metrics/pod?namespace=${encodeURIComponent(namespace)}&pod=${encodeURIComponent(pod)}`,
    );
    renderMetrics(metrics.values || {});

    const errorCount = metrics.errors ? Object.keys(metrics.errors).length : 0;
    if (errorCount > 0) {
      showMetricsStatus(`指标部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showMetricsStatus("指标查询完成", false);
    } else {
      showMetricsStatus(`自动刷新 ${selected}`, false);
    }
  } catch (error) {
    metricsCards.innerHTML = "";
    showMetricsStatus(`指标查询失败: ${error.message}`, true);
  }
}

function renderMetrics(values) {
  metricsCards.innerHTML = "";

  const entries = Object.entries(values);
  if (!entries.length) {
    metricsCards.appendChild(createMetricCard("无数据", "-"));
    return;
  }

  entries.sort(([a], [b]) => a.localeCompare(b));
  for (const [name, value] of entries) {
    metricsCards.appendChild(createMetricCard(name, formatMetricValue(name, value)));
  }
}

async function loadCardMetrics(manual) {
  try {
    queryCardMetricsButton.disabled = true;
    const payload = await fetchJSON("/api/v1/metrics/cards");
    state.cardMetrics = payload;
    renderCardSelector(payload.items || []);
    renderSelectedCardMetrics();
    await loadCardTimeline(false);

    const errorCount = payload.errors ? Object.keys(payload.errors).length : 0;
    if (errorCount > 0) {
      showCardStatus(`整卡实时指标部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showCardStatus("整卡实时指标已刷新", false);
    }
  } catch (error) {
    state.cardMetrics = null;
    cardMetricsCards.innerHTML = "";
    showCardStatus(`整卡指标查询失败: ${error.message}`, true);
    clearTimelineCharts("整卡时序暂不可用");
  } finally {
    queryCardMetricsButton.disabled = false;
  }
}

function renderCardSelector(items) {
  const previous = cardSelector.value;
  cardSelector.innerHTML = "";

  if (!items.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "暂无整卡数据";
    cardSelector.appendChild(option);
    return;
  }

  for (const item of items) {
    const option = document.createElement("option");
    option.value = encodeCardValue(item.gpuUUID, item.gpuIndex);
    option.textContent = `GPU ${item.gpuIndex || "-"} · ${shortText(item.gpuUUID || "-", 18)}`;
    cardSelector.appendChild(option);
  }

  if (previous && items.some((item) => encodeCardValue(item.gpuUUID, item.gpuIndex) === previous)) {
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
  ];

  for (const [name, value] of cards) {
    cardMetricsCards.appendChild(createMetricCard(name, value));
  }
}

async function loadCardTimeline(manual) {
  const selected = getSelectedCard();
  if (!selected) {
    state.cardTimeline = null;
    clearTimelineCharts("暂无整卡时序数据");
    return;
  }

  const windowMinutes = Number.parseInt(cardRangeSelector.value, 10) || 60;
  const stepSeconds = suggestStepSeconds(windowMinutes);
  const query = new URLSearchParams();
  if (selected.gpuUUID && selected.gpuUUID !== "-") {
    query.set("gpuUUID", selected.gpuUUID);
  }
  if (selected.gpuIndex && selected.gpuIndex !== "-") {
    query.set("gpuIndex", selected.gpuIndex);
  }
  query.set("minutes", String(windowMinutes));
  query.set("stepSeconds", String(stepSeconds));

  try {
    const payload = await fetchJSON(`/api/v1/metrics/card/timeseries?${query.toString()}`);
    state.cardTimeline = payload;
    renderCardTimelineCharts();

    const errorCount = payload.errors ? Object.keys(payload.errors).length : 0;
    if (errorCount > 0) {
      showCardStatus(`整卡时序部分可用，${errorCount} 项查询失败`, true);
    } else if (manual) {
      showCardStatus("整卡时序查询完成", false);
    } else {
      const cardText = selected.gpuUUID !== "-" ? selected.gpuUUID : `index=${selected.gpuIndex}`;
      showCardStatus(`自动刷新整卡 ${shortText(cardText, 18)}`, false);
    }
  } catch (error) {
    state.cardTimeline = null;
    clearTimelineCharts("整卡时序查询失败");
    showCardStatus(`整卡时序查询失败: ${error.message}`, true);
  }
}

function renderCardTimelineCharts() {
  const timeline = state.cardTimeline;
  if (!timeline || !Array.isArray(timeline.series)) {
    clearTimelineCharts("暂无整卡时序数据");
    return;
  }

  const seriesMap = new Map();
  for (const series of timeline.series) {
    seriesMap.set(series.name, series.points || []);
  }

  const memoryDatasets = buildDatasets(seriesMap, MEMORY_SERIES);
  const queueDatasets = buildDatasets(seriesMap, QUEUE_SERIES);
  const utilDatasets = buildDatasets(seriesMap, UTIL_SERIES);

  renderLineChart(cardMemoryChart, memoryDatasets, {
    transform: (value) => value / (1024 * 1024 * 1024),
    axisTickFormatter: (value) => `${value.toFixed(value >= 100 ? 0 : 1)} GiB`,
    emptyMessage: "暂无显存时序数据",
  });
  renderLegend(memoryChartLegend, memoryDatasets);

  renderLineChart(cardQueueChart, queueDatasets, {
    transform: (value) => value,
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
}

function clearTimelineCharts(message) {
  drawEmptyChart(cardMemoryChart, message);
  drawEmptyChart(cardQueueChart, message);
  drawEmptyChart(cardUtilChart, message);
  memoryChartLegend.innerHTML = "";
  queueChartLegend.innerHTML = "";
  utilChartLegend.innerHTML = "";
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
  const margin = { top: 18, right: 18, bottom: 30, left: 64 };
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  if (plotWidth <= 0 || plotHeight <= 0) {
    return;
  }

  const xValues = [];
  const yValues = [];
  for (const dataset of normalized) {
    for (const point of dataset.points) {
      xValues.push(point.x);
      yValues.push(point.y);
    }
  }

  let xMin = Math.min(...xValues);
  let xMax = Math.max(...xValues);
  if (!Number.isFinite(xMin) || !Number.isFinite(xMax)) {
    drawEmptyChart(canvas, options.emptyMessage || "暂无数据");
    return;
  }
  if (xMax <= xMin) {
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
  if (yMax <= yMin) {
    yMax = yMin + 1;
  }

  const background = ctx.createLinearGradient(0, margin.top, 0, height - margin.bottom);
  background.addColorStop(0, "#ffffff");
  background.addColorStop(1, "#f2f7ff");
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, width, height);

  const gridLines = 4;
  ctx.strokeStyle = "#dbe7f4";
  ctx.lineWidth = 1;
  ctx.font = "12px 'Helvetica Neue', 'PingFang SC', sans-serif";
  ctx.fillStyle = "#5f7288";

  for (let i = 0; i <= gridLines; i += 1) {
    const ratio = i / gridLines;
    const y = margin.top + plotHeight * ratio;
    ctx.beginPath();
    ctx.moveTo(margin.left, y);
    ctx.lineTo(width - margin.right, y);
    ctx.stroke();

    const value = yMax - (yMax - yMin) * ratio;
    ctx.fillText(options.axisTickFormatter(value), 10, y + 4);
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
    ctx.fillText(label, x - 18, height - 10);
  }

  const toCanvasX = (value) => margin.left + ((value - xMin) / (xMax - xMin)) * plotWidth;
  const toCanvasY = (value) => margin.top + (1 - (value - yMin) / (yMax - yMin)) * plotHeight;

  ctx.save();
  ctx.beginPath();
  ctx.rect(margin.left, margin.top, plotWidth, plotHeight);
  ctx.clip();

  for (const dataset of normalized) {
    const points = dataset.points.map((point) => ({
      x: toCanvasX(point.x),
      y: toCanvasY(point.y),
    }));
    if (points.length === 0) {
      continue;
    }

    ctx.lineWidth = 2.2;
    ctx.strokeStyle = dataset.color;
    ctx.setLineDash(dataset.dash || []);
    drawSmoothLine(ctx, points);

    if (dataset.fill && points.length > 1) {
      const area = ctx.createLinearGradient(0, margin.top, 0, height - margin.bottom);
      area.addColorStop(0, `${hexToRgba(dataset.color, 0.25)}`);
      area.addColorStop(1, `${hexToRgba(dataset.color, 0.02)}`);

      ctx.beginPath();
      ctx.moveTo(points[0].x, height - margin.bottom);
      for (const point of points) {
        ctx.lineTo(point.x, point.y);
      }
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
  if (!datasets.length) {
    return;
  }

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
  const width = Math.max(320, Math.floor(canvas.clientWidth || 320));
  const height = Math.max(180, Math.floor(canvas.clientHeight || 180));
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
  ctx.font = "13px 'Helvetica Neue', 'PingFang SC', sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(message, width / 2, height / 2);
  ctx.textAlign = "left";
}

function drawSmoothLine(ctx, points) {
  if (points.length === 0) {
    return;
  }
  if (points.length === 1) {
    ctx.beginPath();
    ctx.arc(points[0].x, points[0].y, 2.5, 0, Math.PI * 2);
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

function buildDatasets(seriesMap, definitions) {
  const result = [];
  for (const definition of definitions) {
    const points = seriesMap.get(definition.name) || [];
    result.push({ ...definition, points });
  }
  return result;
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
    return `${(value * 100).toFixed(1)}%`;
  }
  if (name.endsWith("_percent")) {
    return `${value.toFixed(2)}%`;
  }
  if (name.endsWith("_ms")) {
    return `${value.toFixed(0)} ms`;
  }
  if (name.endsWith("_clients") || name.endsWith("_overloaded")) {
    return value.toFixed(0);
  }
  return value.toFixed(4);
}

function formatBytes(bytes) {
  if (bytes <= 0) {
    return "0 B";
  }
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  return `${value.toFixed(value >= 100 ? 0 : 2)} ${units[i]}`;
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

function showMetricsStatus(message, isError) {
  metricsStatus.textContent = message;
  metricsStatus.className = isError ? "muted status-error" : "muted status-success";
}

function showCardStatus(message, isError) {
  cardStatus.textContent = message;
  cardStatus.className = isError ? "muted status-error" : "muted status-success";
}

function encodeCardValue(gpuUUID, gpuIndex) {
  return `${gpuUUID || "-"}::${gpuIndex || "-"}`;
}

function getSelectedCard() {
  const raw = cardSelector.value;
  if (!raw || !raw.includes("::")) {
    return null;
  }
  const [gpuUUID, gpuIndex] = raw.split("::");
  return { gpuUUID, gpuIndex };
}

function sameCard(item, selected) {
  return (item.gpuUUID || "-") === selected.gpuUUID && (item.gpuIndex || "-") === selected.gpuIndex;
}

function shortText(value, maxLen) {
  if (!value || value.length <= maxLen) {
    return value;
  }
  return `${value.slice(0, maxLen - 3)}...`;
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

function debounce(fn, wait) {
  let timer = null;
  return (...args) => {
    if (timer) {
      clearTimeout(timer);
    }
    timer = setTimeout(() => fn(...args), wait);
  };
}
