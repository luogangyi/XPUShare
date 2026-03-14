#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <image[:tag]> [prometheus_base_url]"
  exit 1
fi

IMAGE=$1
NAMESPACE=${NAMESPACE:-xpushare-system}
NODE_PORT=${NODE_PORT:-32050}
APP_NAME=${APP_NAME:-xpushare-dashboard}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}

read -r -a KUBECTL_CMD <<< "${KUBECTL_BIN}"
kctl() {
  "${KUBECTL_CMD[@]}" "$@"
}

if ! command -v "${KUBECTL_CMD[0]}" >/dev/null 2>&1; then
  echo "${KUBECTL_CMD[0]} not found"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DASHBOARD_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
METRICS_MANIFEST="${DASHBOARD_DIR}/deploy/xpushare-scheduler-metrics.yaml"

if [[ $# -ge 2 ]]; then
  PROM_BASE_URL=$2
elif [[ -n "${PROM_BASE_URL:-}" ]]; then
  PROM_BASE_URL=${PROM_BASE_URL}
elif kctl -n kube-system get svc cmss-kcs-prometheus-system >/dev/null 2>&1; then
  PROM_BASE_URL="http://cmss-kcs-prometheus-system.kube-system.svc:9090"
elif kctl -n monitoring get svc prometheus-k8s >/dev/null 2>&1; then
  PROM_BASE_URL="http://prometheus-k8s.monitoring.svc:9090"
else
  PROM_BASE_URL="http://prometheus-k8s.monitoring.svc:9090"
fi

echo "[install] namespace=${NAMESPACE} image=${IMAGE} nodePort=${NODE_PORT}"
echo "[install] prometheus=${PROM_BASE_URL}"

tmp_manifest=$(mktemp)
cat >"${tmp_manifest}" <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${APP_NAME}
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${APP_NAME}
subjects:
  - kind: ServiceAccount
    name: ${APP_NAME}
    namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${APP_NAME}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
  namespace: ${NAMESPACE}
data:
  config.yaml: |
    server:
      listenAddr: ":8080"
    kubernetes:
      mode: "incluster"
    prometheus:
      baseURL: "${PROM_BASE_URL}"
      timeoutSec: 10
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      serviceAccountName: ${APP_NAME}
      containers:
        - name: ${APP_NAME}
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - "-config"
            - "/etc/xpushare-dashboard/config.yaml"
          ports:
            - containerPort: 8080
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/xpushare-dashboard
              readOnly: true
          readinessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /api/v1/healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: ${APP_NAME}-config
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: ${APP_NAME}
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: ${NODE_PORT}
YAML

kctl get ns "${NAMESPACE}" >/dev/null 2>&1 || kctl create ns "${NAMESPACE}"
kctl apply -f "${tmp_manifest}"
rm -f "${tmp_manifest}"

if [[ -f "${METRICS_MANIFEST}" ]]; then
  if kctl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    kctl apply -f "${METRICS_MANIFEST}"
    echo "[install] applied ${METRICS_MANIFEST}"
  else
    echo "[install] ServiceMonitor CRD not found, skip ${METRICS_MANIFEST}"
  fi
fi

kctl -n "${NAMESPACE}" rollout status deployment/${APP_NAME} --timeout=180s

kctl -n "${NAMESPACE}" get deployment/${APP_NAME}
kctl -n "${NAMESPACE}" get svc/${APP_NAME} -o wide

echo "[done] Dashboard installed"
