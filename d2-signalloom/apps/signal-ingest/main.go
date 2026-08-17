// Signal-ingest: core ingest, correlation and query service for Signal Fusion.
//
// Receives signal observations across 5 layers, correlates them via CEL rules,
// and maintains provisional actors with evidence chains.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	// Use in-memory store for PoC. FrostDB is available in the store package
	// for durable Parquet writes, but the query path is not yet implemented.
	signalStore := store.NewMemoryStore()

	engine, err := correlation.NewEngine(signalStore)
	if err != nil {
		slog.Error("failed to create correlation engine", "error", err)
		os.Exit(1)
	}

	// Audit writer: use Postgres if DATABASE_URL is set, otherwise NopWriter.
	var auditWriter audit.AuditWriter
	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		pw, err := audit.NewPostgresWriter(dsn)
		if err != nil {
			slog.Warn("audit postgres connection failed, falling back to nop", "error", err)
			auditWriter = audit.NopWriter{}
		} else {
			auditWriter = pw
			defer pw.Close()
			slog.Info("audit writer connected to postgres")
		}
	} else {
		auditWriter = audit.NopWriter{}
		slog.Info("no DATABASE_URL set, audit writes disabled")
	}

	handlers := &api.Handlers{
		Store:  signalStore,
		Engine: engine,
		Audit:  auditWriter,
	}

	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		slog.Info("signal-ingest starting", "port", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown error", "error", err)
		os.Exit(1)
	}

	if err := signalStore.Close(); err != nil {
		slog.Error("store close error", "error", err)
	}

	slog.Info("stopped")
}
