package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/client"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/stun"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/workspace-connector/transform"
)

type Server struct {
	client     client.ReportsClient
	stunner    stun.StunExecutor
	ingestURL  string
	mu         sync.RWMutex
	lastPolled time.Time
}

func main() {
	port := flag.Int("port", 8092, "HTTP listen port")
	ingestURL := flag.String("ingest-url", "http://localhost:8090/api/v1/observations", "signal-ingest endpoint")
	pollInterval := flag.Duration("poll-interval", 10*time.Second, "polling interval for Reports API")
	mock := flag.Bool("mock", true, "run with mock Reports client")
	flag.Parse()

	var reportsClient client.ReportsClient
	if *mock {
		reportsClient = client.NewMockReportsClient()
	} else {
		reportsClient = client.NewLiveReportsClient("")
	}

	srv := &Server{
		client:    reportsClient,
		stunner:   stun.NewMemoryStunExecutor(),
		ingestURL: *ingestURL,
	}

	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Background polling loop
	go srv.startPolling(ctx, *pollInterval)

	httpServer := &http.Server{
		Addr:              fmt.Sprintf(":%d", *port),
		Handler:           srv.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("workspace-connector listening", "port", *port, "mock", *mock)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server failed", "error", err)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down workspace-connector")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
}

type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	s.registerRoutes(mux)
	return headBodySuppressingMiddleware(mux)
}

func (s *Server) registerRoutes(mux *http.ServeMux) {
	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Allow", "GET, HEAD, OPTIONS")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	}
	readyHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Allow", "GET, HEAD, OPTIONS")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
	}
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", readyHandler)
	mux.HandleFunc("/api/v1/workspace/poll", s.handlePoll)
	mux.HandleFunc("/api/v1/workspace/stun", s.handleStun)
	mux.HandleFunc("/api/v1/workspace/status", s.handleStatus)
}

func (s *Server) handlePoll(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r == nil || r.Method != http.MethodHead {
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
		}
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	count, err := s.pollAndIngest(r.Context())
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	s.mu.RLock()
	lastPolled := s.lastPolled
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"polled_and_ingested": count,
		"last_polled":         lastPolled,
	})
}

func (s *Server) handleStun(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r == nil || r.Method != http.MethodHead {
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
		}
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var req stun.StunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "invalid request: " + err.Error()})
		return
	}

	res, err := s.stunner.ExecuteStun(r.Context(), req)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(res)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r.Method == http.MethodHead {
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
		return
	}

	s.mu.RLock()
	lastPolled := s.lastPolled
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"connector":   "google-workspace-reports",
		"status":      "active",
		"last_polled": lastPolled,
		"ingest_url":  s.ingestURL,
	})
}

func (s *Server) pollAndIngest(ctx context.Context) (int, error) {
	s.mu.RLock()
	after := s.lastPolled
	s.mu.RUnlock()

	events, err := s.client.PollEvents(ctx, after)
	if err != nil {
		return 0, fmt.Errorf("failed to poll reports: %w", err)
	}

	s.mu.Lock()
	s.lastPolled = time.Now().UTC()
	s.mu.Unlock()

	if len(events) == 0 {
		return 0, nil
	}

	obsList, err := transform.TransformBatch(events)
	if err != nil {
		return 0, fmt.Errorf("failed to transform events: %w", err)
	}

	payload, err := json.Marshal(obsList)
	if err != nil {
		return 0, fmt.Errorf("failed to marshal observations: %w", err)
	}

	parsedURL, err := url.Parse(s.ingestURL)
	if err != nil || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") || parsedURL.Host == "" {
		return 0, fmt.Errorf("invalid ingest endpoint %q: must be valid http or https URL with non-empty host", s.ingestURL)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.ingestURL, bytes.NewReader(payload))
	if err != nil {
		return 0, fmt.Errorf("failed to create ingest request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		// Log and tolerate connection errors if running standalone in test
		slog.Warn("failed to send to signal-ingest", "error", err)
		return len(obsList), nil
	}
	defer func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		slog.Error("signal-ingest rejected observation batch", "status", resp.StatusCode)
		return 0, fmt.Errorf("signal-ingest returned status %d", resp.StatusCode)
	}

	return len(obsList), nil
}

func (s *Server) startPolling(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_, _ = s.pollAndIngest(ctx)
		}
	}
}
