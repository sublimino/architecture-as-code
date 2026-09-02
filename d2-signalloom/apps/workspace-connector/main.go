package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
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
		Addr:    fmt.Sprintf(":%d", *port),
		Handler: mux,
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

func (s *Server) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ready"})
	})
	mux.HandleFunc("POST /api/v1/workspace/poll", s.handlePoll)
	mux.HandleFunc("POST /api/v1/workspace/stun", s.handleStun)
	mux.HandleFunc("GET /api/v1/workspace/status", s.handleStatus)
}

func (s *Server) handlePoll(w http.ResponseWriter, r *http.Request) {
	count, err := s.pollAndIngest(r.Context())
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"polled_and_ingested": count,
		"last_polled":         s.lastPolled,
	})
}

func (s *Server) handleStun(w http.ResponseWriter, r *http.Request) {
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

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"connector":   "google-workspace-reports",
		"status":      "active",
		"last_polled": s.lastPolled,
		"ingest_url":  s.ingestURL,
	})
}

func (s *Server) pollAndIngest(ctx context.Context) (int, error) {
	events, err := s.client.PollEvents(ctx, s.lastPolled)
	if err != nil {
		return 0, fmt.Errorf("failed to poll reports: %w", err)
	}

	s.lastPolled = time.Now().UTC()
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

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.ingestURL, bytes.NewReader(payload))
	if err != nil {
		return 0, fmt.Errorf("failed to create ingest request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// Log and tolerate connection errors if running standalone in test
		slog.Warn("failed to send to signal-ingest", "error", err)
		return len(obsList), nil
	}
	defer resp.Body.Close()

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
