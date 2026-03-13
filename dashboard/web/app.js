const state = {
  overview: null,
};

const summaryCards = document.getElementById("summaryCards");
const nodeTableBody = document.getElementById("nodeTableBody");
const podTableBody = document.getElementById("podTableBody");
const podSelector = document.getElementById("podSelector");
const metricsCards = document.getElementById("metricsCards");
const metricsStatus = document.getElementById("metricsStatus");
const lastUpdated = document.getElementById("lastUpdated");

const refreshButton = document.getElementById("refreshButton");
const queryMetricsButton = document.getElementById("queryMetricsButton");

refreshButton.addEventListener("click", () => loadOverview(true));
queryMetricsButton.addEventListener("click", () => loadMetrics(true));
podSelector.addEventListener("change", () => loadMetrics(false));

loadOverview(false);
setInterval(() => loadOverview(false), 15000);
setInterval(() => loadMetrics(false), 20000);

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
    await loadMetrics(false);
    if (manual) {
      metricsStatus.textContent = "数据刷新完成";
      metricsStatus.className = "muted status-success";
    }
  } catch (error) {
    metricsStatus.textContent = `刷新失败: ${error.message}`;
    metricsStatus.className = "muted status-error";
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

async function loadMetrics(manual) {
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
