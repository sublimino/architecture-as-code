package api

import "net/http"

// NewProbeHandler serves the kubelet's probes, and nothing else, for a listener separate from the
// API port.
//
// ProtectedRouter authenticates every request before routing, /healthz and /readyz included, and
// the kubelet sends no credential: probing the API port is a 401, so a pod with auth on never
// becomes Ready. Rather than open an anonymous path through the gate, the probe answers move to a
// second port that the Service does not publish and the ingress NetworkPolicy does not admit. It
// carries liveness and the readiness verdict only: no data route, no posture detail (/health stays
// behind the gate), no metrics.
func NewProbeHandler(h *Handlers) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("HEAD /healthz", handleHealthz)
	mux.HandleFunc("GET /readyz", h.handleReadyz)
	mux.HandleFunc("HEAD /readyz", h.handleReadyz)
	return mux
}
