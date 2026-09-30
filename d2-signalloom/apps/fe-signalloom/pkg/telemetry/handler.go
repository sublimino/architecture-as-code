package telemetry

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// TelemetryHandler handles HTTP REST and SSE streaming requests for agent telemetry.
type TelemetryHandler struct {
	collector *CadvisorCollector
}

// NewTelemetryHandler creates a new TelemetryHandler instance.
func NewTelemetryHandler(collector *CadvisorCollector) *TelemetryHandler {
	return &TelemetryHandler{
		collector: collector,
	}
}

// RegisterRoutes registers telemetry endpoints onto an http.ServeMux.
func (h *TelemetryHandler) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/telemetry/agents/", h.ServeHTTP)
	mux.HandleFunc("/api/v1/telemetry/agents/", h.ServeHTTP)
	mux.HandleFunc("/api/telemetry/agents", h.handleList)
	mux.HandleFunc("/api/v1/telemetry/agents", h.handleList)
}

// ServeHTTP handles /api/telemetry/agents/{pod} and /api/v1/telemetry/agents/{pod}.
func (h *TelemetryHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	pod := extractPodName(r.URL.Path)
	if pod == "" {
		h.handleList(w, r)
		return
	}

	// Check if client requests Server-Sent Events (SSE)
	accept := r.Header.Get("Accept")
	isSSE := strings.Contains(accept, "text/event-stream") || r.URL.Query().Get("stream") == "true" || r.URL.Query().Get("sse") == "true"

	if isSSE {
		h.handleSSE(w, r, pod)
		return
	}

	h.handleJSON(w, r, pod)
}

func (h *TelemetryHandler) handleJSON(w http.ResponseWriter, r *http.Request, pod string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	telemetry, ok := h.collector.GetLatestTelemetry(pod)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]string{
			"error": fmt.Sprintf("no telemetry found for agent pod: %s", pod),
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(telemetry)
}

func (h *TelemetryHandler) handleList(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	all := h.collector.GetAllTelemetry()
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(all)
}

func (h *TelemetryHandler) handleSSE(w http.ResponseWriter, r *http.Request, pod string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	ch, unsubscribe := h.collector.Subscribe(pod)
	defer unsubscribe()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			// Client disconnected, exit cleanly to prevent goroutine leak
			return
		case data, ok := <-ch:
			if !ok {
				return
			}
			payload, err := json.Marshal(data)
			if err != nil {
				continue
			}
			_, writeErr := fmt.Fprintf(w, "data: %s\n\n", payload)
			if writeErr != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func extractPodName(path string) string {
	path = strings.TrimPrefix(path, "/api/v1/telemetry/agents/")
	path = strings.TrimPrefix(path, "/api/telemetry/agents/")
	path = strings.TrimPrefix(path, "/")
	return strings.TrimSuffix(path, "/")
}
