package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/grgalex/xpushare/dashboard/internal/service"
)

type Handler struct {
	service *service.Service
}

type quotaUpdateRequest struct {
	CoreLimit   *int    `json:"coreLimit"`
	MemoryLimit *string `json:"memoryLimit"`
}

func New(svc *service.Service) *Handler {
	return &Handler{service: svc}
}

func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("/api/v1/healthz", h.handleHealth)
	mux.HandleFunc("/api/v1/overview", h.handleOverview)
	mux.HandleFunc("/api/v1/nodes/xpushare", h.handleNodes)
	mux.HandleFunc("/api/v1/pods/xpushare", h.handlePods)
	mux.HandleFunc("/api/v1/metrics/pod", h.handlePodMetrics)
	mux.HandleFunc("/api/v1/metrics/pod/timeseries", h.handlePodMetricsTimeline)
	mux.HandleFunc("/api/v1/metrics/cards", h.handleCardMetrics)
	mux.HandleFunc("/api/v1/metrics/card/timeseries", h.handleCardMetricsTimeline)
	mux.HandleFunc("/api/v1/pods/", h.handlePodQuotaPatch)
}

func (h *Handler) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status": "ok",
		"time":   time.Now().UTC(),
	})
}

func (h *Handler) handleOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	overview, err := h.service.GetOverview(ctx)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, overview)
}

func (h *Handler) handleNodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	nodes, err := h.service.GetNodeSummaries(ctx)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"items": nodes,
	})
}

func (h *Handler) handlePods(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	pods, err := h.service.GetPodQuotas(ctx)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"items": pods,
	})
}

func (h *Handler) handlePodMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	namespace := strings.TrimSpace(r.URL.Query().Get("namespace"))
	pod := strings.TrimSpace(r.URL.Query().Get("pod"))
	if namespace == "" || pod == "" {
		writeError(w, http.StatusBadRequest, "namespace and pod query parameters are required")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	metrics, err := h.service.GetPodMetrics(ctx, namespace, pod)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, metrics)
}

func (h *Handler) handlePodMetricsTimeline(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	query := r.URL.Query()
	namespace := strings.TrimSpace(query.Get("namespace"))
	pod := strings.TrimSpace(query.Get("pod"))
	if namespace == "" || pod == "" {
		writeError(w, http.StatusBadRequest, "namespace and pod query parameters are required")
		return
	}

	windowMinutes, err := parseIntWithDefault(query.Get("minutes"), 60)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid minutes: %v", err))
		return
	}
	stepSeconds, err := parseIntWithDefault(query.Get("stepSeconds"), 30)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid stepSeconds: %v", err))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	metrics, err := h.service.GetPodMetricsTimeline(ctx, namespace, pod, windowMinutes, stepSeconds)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "required") {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, metrics)
}

func (h *Handler) handleCardMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	metrics, err := h.service.GetCardMetrics(ctx)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, metrics)
}

func (h *Handler) handleCardMetricsTimeline(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	query := r.URL.Query()
	gpuUUID := strings.TrimSpace(query.Get("gpuUUID"))
	gpuIndex := strings.TrimSpace(query.Get("gpuIndex"))

	windowMinutes, err := parseIntWithDefault(query.Get("minutes"), 60)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid minutes: %v", err))
		return
	}
	stepSeconds, err := parseIntWithDefault(query.Get("stepSeconds"), 30)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid stepSeconds: %v", err))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	metrics, err := h.service.GetCardMetricsTimeline(ctx, gpuUUID, gpuIndex, windowMinutes, stepSeconds)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "required") {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, metrics)
}

func (h *Handler) handlePodQuotaPatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPatch {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	namespace, pod, ok := extractPodPath(r.URL)
	if !ok {
		writeError(w, http.StatusNotFound, "invalid path, expected /api/v1/pods/{namespace}/{pod}/quota")
		return
	}

	var payload quotaUpdateRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid request payload: %v", err))
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid request payload: multiple JSON objects are not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	if err := h.service.UpdatePodQuota(ctx, namespace, pod, payload.CoreLimit, payload.MemoryLimit); err != nil {
		status := http.StatusBadRequest
		if strings.Contains(strings.ToLower(err.Error()), "kubernetes api") {
			status = http.StatusBadGateway
		}
		writeError(w, status, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":    "updated",
		"namespace": namespace,
		"pod":       pod,
	})
}

func extractPodPath(u *url.URL) (namespace string, pod string, ok bool) {
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) != 6 {
		return "", "", false
	}
	if parts[0] != "api" || parts[1] != "v1" || parts[2] != "pods" || parts[5] != "quota" {
		return "", "", false
	}
	ns, err := url.PathUnescape(parts[3])
	if err != nil || ns == "" {
		return "", "", false
	}
	name, err := url.PathUnescape(parts[4])
	if err != nil || name == "" {
		return "", "", false
	}
	return ns, name, true
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{
		"error": message,
	})
}

func parseIntWithDefault(raw string, defaultValue int) (int, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultValue, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, err
	}
	return value, nil
}
