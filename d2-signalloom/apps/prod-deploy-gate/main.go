// prod-deploy-gate: HITL policy enforcement boundary.
//
// Intercepts deployment commands, generates cryptographic 30m approval tokens,
// dispatches interactive approval cards to Slack/Zulip, and resumes execution
// only upon valid HMAC signature.
//
// Endpoints:
//   POST /gate/request  — initiate approval flow, returns token
//   POST /gate/approve  — validate signed token, resume deployment
//   GET  /healthz       — liveness probe
//   GET  /readyz        — readiness probe
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

// GateRequest is the payload for POST /gate/request.
type GateRequest struct {
	Description string `json:"description"`
	Requester   string `json:"requester"`
	Environment string `json:"environment"`
}

// GateResponse is returned from POST /gate/request.
type GateResponse struct {
	RequestID string `json:"request_id"`
	Status    string `json:"status"`
	ExpiresAt string `json:"expires_at"`
}

// ApproveRequest is the payload for POST /gate/approve.
type ApproveRequest struct {
	Token    string `json:"token"`
	Approver string `json:"approver"`
}

// ApproveResponse is returned from POST /gate/approve.
type ApproveResponse struct {
	RequestID string `json:"request_id"`
	Status    string `json:"status"`
	Approver  string `json:"approver"`
}

// pendingGate tracks a gate request awaiting approval.
type pendingGate struct {
	RequestID   string
	Description string
	Requester   string
	Token       string
	ExpiresAt   time.Time
	Done        chan struct{}
	Approved    bool
	Approver    string
}

// Server holds the gate state.
type Server struct {
	hmacSecret []byte
	webhookURL string
	gateTTL    time.Duration
	mu         sync.Mutex
	pending    map[string]*pendingGate
	nextID     int
}

func NewServer(hmacSecret []byte, webhookURL string, gateTTL time.Duration) *Server {
	return &Server{
		hmacSecret: hmacSecret,
		webhookURL: webhookURL,
		gateTTL:    gateTTL,
		pending:    make(map[string]*pendingGate),
	}
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}


// headResponseWriter suppresses response bodies for HTTP HEAD requests (RFC 9110 Section 6.4.1).
type headResponseWriter struct {
	http.ResponseWriter
}

func (w *headResponseWriter) Write(p []byte) (int, error) {
	return len(p), nil
}

// headBodySuppressingMiddleware wraps an http.Handler and suppresses the response body
// when the request method is HEAD, in compliance with RFC 9110 Section 6.4.1.
func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/gate/request", s.handleGateRequest)
	mux.HandleFunc("/gate/approve", s.handleGateApprove)
	mux.HandleFunc("/gate/", s.handleGetGate)
	mux.HandleFunc("/health", handleHealthz)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
}

func newMux(srv *Server) http.Handler {
	mux := http.NewServeMux()
	srv.registerRoutes(mux)
	return headBodySuppressingMiddleware(mux)
}

func (s *Server) PruneExpired(now time.Time) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	pruned := 0
	for id, gate := range s.pending {
		if now.After(gate.ExpiresAt) {
			delete(s.pending, id)
			pruned++
		}
	}
	return pruned
}

func (s *Server) startJanitor(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.PruneExpired(time.Now())
		}
	}
}

func (s *Server) handleGateRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var req GateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	req.Requester = strings.TrimSpace(req.Requester)
	if req.Requester == "" {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "requester required for audit trail"})
		return
	}

	s.mu.Lock()
	s.nextID++
	requestID := fmt.Sprintf("gate-%06d", s.nextID)
	s.mu.Unlock()

	token, err := GenerateToken(s.hmacSecret, requestID, s.gateTTL)
	if err != nil {
		slog.Error("failed to generate token", "error", err)
		writeJSON(w, r, http.StatusInternalServerError, map[string]string{"error": "token generation failed"})
		return
	}

	expiresAt := time.Now().Add(s.gateTTL)
	gate := &pendingGate{
		RequestID:   requestID,
		Description: req.Description,
		Requester:   req.Requester,
		Token:       token,
		ExpiresAt:   expiresAt,
		Done:        make(chan struct{}),
	}

	s.mu.Lock()
	s.pending[requestID] = gate
	s.mu.Unlock()

	// Send approval card to webhook (non-blocking).
	if s.webhookURL != "" {
		go func() {
			card := ApprovalCard{
				RequestID:   requestID,
				Description: req.Description,
				Requester:   req.Requester,
				ApproveURL:  fmt.Sprintf("/gate/approve"),
				Token:       token,
				ExpiresAt:   expiresAt.Format(time.RFC3339),
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := SendApprovalCard(ctx, s.webhookURL, card); err != nil {
				slog.Error("failed to send approval card", "request_id", requestID, "error", err)
			}
		}()
	}

	slog.Info("gate request created", "request_id", requestID, "requester", req.Requester, "description", req.Description)

	writeJSON(w, r, http.StatusAccepted, GateResponse{
		RequestID: requestID,
		Status:    "pending",
		ExpiresAt: expiresAt.Format(time.RFC3339),
	})
}

func (s *Server) handleGetGate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	requestID := strings.TrimPrefix(r.URL.Path, "/gate/")
	if requestID == "" || requestID == r.URL.Path {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "request ID required"})
		return
	}

	s.mu.Lock()
	gate, ok := s.pending[requestID]
	if ok && time.Now().After(gate.ExpiresAt) {
		delete(s.pending, requestID)
		ok = false
	}
	var resp GateResponse
	if ok {
		resp = GateResponse{
			RequestID: gate.RequestID,
			Status:    "pending",
			ExpiresAt: gate.ExpiresAt.Format(time.RFC3339),
		}
	}
	s.mu.Unlock()

	if !ok {
		writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "gate request not found or expired"})
		return
	}

	writeJSON(w, r, http.StatusOK, resp)
}

func (s *Server) handleGateApprove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var req ApproveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Token == "" {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "token required"})
		return
	}

	if strings.TrimSpace(req.Approver) == "" {
		writeJSON(w, r, http.StatusBadRequest, map[string]string{"error": "approver required for HITL audit trail"})
		return
	}

	requestID, err := ValidateToken(s.hmacSecret, req.Token)
	if err != nil {
		slog.Warn("token validation failed", "error", err)
		writeJSON(w, r, http.StatusForbidden, map[string]string{"error": fmt.Sprintf("token validation failed: %v", err)})
		return
	}

	s.mu.Lock()
	gate, ok := s.pending[requestID]
	if ok {
		gate.Approved = true
		gate.Approver = req.Approver
		close(gate.Done)
		delete(s.pending, requestID)
	}
	s.mu.Unlock()

	if !ok {
		writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "gate request not found or already resolved"})
		return
	}

	slog.Info("gate approved", "request_id", requestID, "approver", req.Approver)

	writeJSON(w, r, http.StatusOK, ApproveResponse{
		RequestID: requestID,
		Status:    "approved",
		Approver:  req.Approver,
	})
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ready"})
}


func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	hmacSecret := os.Getenv("GATE_HMAC_SECRET")
	if hmacSecret == "" {
		slog.Error("GATE_HMAC_SECRET is required")
		os.Exit(1)
	}

	webhookURL := os.Getenv("GATE_WEBHOOK_URL")

	gateTTLStr := os.Getenv("GATE_TIMEOUT")
	gateTTL := 30 * time.Minute
	if gateTTLStr != "" {
		var err error
		gateTTL, err = time.ParseDuration(gateTTLStr)
		if err != nil {
			slog.Error("invalid GATE_TIMEOUT", "value", gateTTLStr, "error", err)
			os.Exit(1)
		}
	}

	srv := NewServer([]byte(hmacSecret), webhookURL, gateTTL)

	mux := newMux(srv)

	httpSrv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go srv.startJanitor(ctx, 1*time.Minute)

	go func() {
		slog.Info("prod-deploy-gate starting", "port", port)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "error", err)
		os.Exit(1)
	}

	slog.Info("stopped")
}
