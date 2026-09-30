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
	if !h.admit(w, r) {
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

// admit rejects anything but GET (405) and any request while the collector
// has no recent successful scrape (503): old numbers are not current numbers.
func (h *TelemetryHandler) admit(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Method is not allowed")
		return false
	}
	if !h.collector.Healthy() {
		detail := "no successful cAdvisor scrape yet"
		if err := h.collector.LastError(); err != nil {
			detail = err.Error()
		}
		writeError(w, http.StatusServiceUnavailable, "telemetry_unavailable", "Agent telemetry is unavailable: "+detail)
		return false
	}
	return true
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]map[string]string{"error": {"code": code, "message": message}})
}

func (h *TelemetryHandler) handleJSON(w http.ResponseWriter, r *http.Request, pod string) {
	ns := r.URL.Query().Get("namespace")
	var matches []AgentTelemetry
	for _, t := range h.collector.FindTelemetry(pod) {
		if ns == "" || t.Namespace == ns {
			matches = append(matches, t)
		}
	}
	switch len(matches) {
	case 0:
		writeError(w, http.StatusNotFound, "telemetry_not_found", "No telemetry for this agent pod")
		return
	case 1:
	default:
		writeError(w, http.StatusConflict, "telemetry_ambiguous_pod", "Pod name exists in several namespaces; pass ?namespace=")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(matches[0])
}

func (h *TelemetryHandler) handleList(w http.ResponseWriter, r *http.Request) {
	if !h.admit(w, r) {
		return
	}
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
			if ns := r.URL.Query().Get("namespace"); ns != "" && data.Namespace != ns {
				continue
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
