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

	// Store selection: set SIGNAL_STORE=frostdb for Parquet-backed durability.
	// SIGNAL_STORE_DIR controls where Parquet files land (default /tmp/signal-store).
	// Requires the binary to be built with -tags frostdb.
	storeType := os.Getenv("SIGNAL_STORE")
	storeDir := os.Getenv("SIGNAL_STORE_DIR")
	signalStore, err := store.NewStoreFromEnv(storeType, storeDir)
	if err != nil {
		slog.Error("failed to create signal store", "type", storeType, "dir", storeDir, "error", err)
		os.Exit(1)
	}
	slog.Info("signal store initialized", "type", storeType, "dir", storeDir)

	engine, err := correlation.NewEngine(signalStore)
	if err != nil {
		slog.Error("failed to create correlation engine", "error", err)
		os.Exit(1)
	}

	// Audit writer: use Postgres if DATABASE_URL is set, otherwise NopWriter.
	//
	// Boot must not be able to block on the database. It previously did:
	// NewPostgresWriter called db.Ping() with no deadline, and because
	// fe-signalloom runs a default-deny NetworkPolicy, the packets to Postgres
	// were DROPPED rather than refused. A dropped SYN yields neither success
	// nor error, so the fallback below never ran, the listener was never
	// reached, and the startup probe killed the container ~19s in --
	// CrashLoopBackOff caused entirely by a resilience path that could not
	// execute. Every step here is now bounded.
	var auditWriter audit.AuditWriter
	// auditReady is handed to /readyz. nil means "nothing to check".
	var auditReady func(context.Context) error

	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		pw, err := audit.OpenPostgresWriter(dsn) // local work only, never dials
		if err != nil {
			// The DSN itself is unusable. No pool exists, so there is nothing
			// to retry and no reachability to regain: this is permanent until
			// the secret is corrected. NopWriter keeps the service running,
			// and readiness stays red for as long as the process lives so the
			// misconfiguration cannot pass for health.
			slog.Error("audit DATABASE_URL is unusable, audit writes disabled", "error", err)
			auditWriter = audit.NopWriter{}
			permanentErr := err
			auditReady = func(context.Context) error { return permanentErr }
		} else {
			auditWriter = pw
			defer pw.Close()
			// Boot-time classification, bounded. Its result changes what we
			// LOG, not which writer we install -- see below.
			pingCtx, cancelPing := context.WithTimeout(context.Background(), audit.DefaultConnectTimeout)
			pingErr := pw.Ping(pingCtx)
			cancelPing()
			if pingErr != nil {
				// Deliberately NOT falling back to NopWriter here, which is a
				// change from the behaviour this code documented. NopWriter
				// returns nil from every write: it reports success while
				// discarding the event. On a compliance product that is the
				// most expensive failure available -- an audit trail with
				// holes nobody is told about -- and it is also permanent,
				// since nothing would ever reconnect.
				//
				// Keeping the pool inverts both properties. database/sql
				// redials per query, so the audit path repairs itself the
				// moment Postgres is reachable; until then writes FAIL and
				// say so rather than silently succeeding. The cost is that
				// the degradation must be visible, which is what readiness
				// below is for.
				slog.Warn("audit postgres unreachable at startup; serving degraded",
					"error", pingErr,
					"timeout", audit.DefaultConnectTimeout,
					"consequence", "writes will error and retry; /readyz reports not_ready until the database answers")
			} else {
				slog.Info("audit writer connected to postgres")
			}
			auditReady = pw.Ping
		}
	} else {
		// No DSN: audit is deliberately off (local and fixture runs). This is
		// a configured state, not a degraded one, so readiness stays green.
		auditWriter = audit.NopWriter{}
		slog.Info("no DATABASE_URL set, audit writes disabled")
	}

	handlers := &api.Handlers{
		Store:      signalStore,
		Engine:     engine,
		Audit:      auditWriter,
		AuditReady: auditReady,
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
