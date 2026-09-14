// Signal-ingest: core ingest, correlation and query service for Signal Fusion.
//
// Receives signal observations across 5 layers, correlates them via CEL rules,
// and maintains provisional actors with evidence chains.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api"
	apiaudit "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/agentnono"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/ebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/correlation"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

// ErasureTenantEnvVar names the tenant the process-global quarantine engine speaks for.
//
// The quarantine engine is not tenant-aware — it is a single in-process map keyed by actor ID — so
// binding it to one tenant is the only honest adaptation available. Any OTHER tenant's erasure is
// then evaluated without a containment source, and if no other source has jurisdiction the request
// is refused rather than permitted. That is the correct failure direction and it is why this is a
// declination rather than a silent "no holds": a tenant whose containment state cannot be read is a
// tenant whose subjects cannot be erased.
//
// UNOWNED BOUNDARY, recorded rather than assumed away: a tenant-aware quarantine index belongs to
// whichever card makes the correlation engine multi-tenant. Until then a multi-tenant deployment
// must configure the Postgres hold source, which is authoritative for every tenant.
const ErasureTenantEnvVar = "SIGNAL_ERASURE_TENANT"

// buildErasureGate assembles the Article 17(3) erasure gate from whatever incident sources this
// deployment actually has.
//
// It returns an error rather than a permissive fallback whenever it cannot assemble a complete
// gate. There is deliberately no branch that yields a Service with fewer checks.
func buildErasureGate(auditWriter audit.AuditWriter, encryptor identity.Encryptor, engine *correlation.Engine) (*privacy.Service, error) {
	registry, err := privacy.OperatorRegistryFromEnv()
	if err != nil {
		return nil, fmt.Errorf("operator registry: %w", err)
	}

	var sources []privacy.IncidentSource
	// The durable hold table is authoritative for every tenant, and row-level security scopes it.
	if pw, ok := auditWriter.(*audit.PostgresWriter); ok && pw != nil {
		pgSource, err := privacy.NewPostgresIncidentSource(pw.DB())
		if err != nil {
			return nil, fmt.Errorf("postgres incident source: %w", err)
		}
		sources = append(sources, pgSource)
	}
	// Live containment, for the one tenant this process's quarantine engine speaks for.
	if tenant := os.Getenv(ErasureTenantEnvVar); tenant != "" && engine != nil {
		qSource, err := privacy.NewQuarantineIncidentSource(engine, tenant)
		if err != nil {
			return nil, fmt.Errorf("quarantine incident source: %w", err)
		}
		sources = append(sources, qSource)
	}
	if len(sources) == 0 {
		return nil, fmt.Errorf("no incident source available: set DATABASE_URL for the durable hold table or %s for live containment", ErasureTenantEnvVar)
	}
	incidents, err := privacy.NewCompositeIncidentSource(sources...)
	if err != nil {
		return nil, fmt.Errorf("composite incident source: %w", err)
	}

	return privacy.NewService(privacy.Config{
		Incidents: incidents,
		// UnimplementedKeyDestroyer refuses. Until SLDP-P4-1 ships the per-subject key hierarchy,
		// an authorised erasure fails loudly rather than reporting a destruction that did not
		// happen. See privacy/destroyer.go for why a plausible-receipt stub was rejected.
		Destroyer:     privacy.UnimplementedKeyDestroyer{},
		Audit:         auditWriter,
		Operators:     registry,
		Pseudonymiser: encryptor,
	})
}

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
			auditWriter = audit.NewNopWriter(identity.DevOptInAllowed())
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
		auditWriter = audit.NewNopWriter(identity.DevOptInAllowed())
		slog.Info("no DATABASE_URL set, audit writes disabled", "allow_discard", identity.DevOptInAllowed())
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Collector sink adapter backed by signal store
	storeSink := collectors.NewStoreSink(signalStore)

	// Audit webhook receiver
	auditReceiver := apiaudit.NewWebhookReceiver(ctx, 0, 0, storeSink)

	// Collector registry: constructed and started at boot before HTTP server.
	// Collector registry: constructed and started at boot before HTTP server.
	// Registers gcpaudit, baoaudit, spirea, netebpf, k8saudit, kagent, workspacesaas, and fixtures collectors to storeSink.
	// Reuses the auditReceiver for k8saudit mounting.
	collectorRegistry := collectors.NewRegistryFromEnvWithReceiver(storeSink, auditReceiver)

	// --- Phase 2 Collector Registration Seam (SFDP-P2-PRE) ---
	// P2-1: gcpaudit
	// gcpaudit collector registered via NewRegistryFromEnv (COLLECTOR_GCPAUDIT_MODE)

	// P2-2: baoaudit (OpenBao audit device stream receiver)
	// Registers baoaudit.AuditReceiver with shared storeSink, Start() driven by
	// registry lifecycle, Stop() on shutdown, mode-gated live|fixture|off.
	_ = collectors.NewBaoAuditCollector(collectors.ResolveEnvMode("COLLECTOR_BAOAUDIT_MODE", "SIGNAL_COLLECTOR_BAOAUDIT", "BAOAUDIT_MODE"), storeSink)

	// P2-2: spirea (SPIRE SVID issuance collector)
	// Registers spirea.SPIREIssuanceCollector with shared storeSink, Start() driven by
	// registry lifecycle, Stop() on shutdown, mode-gated live|fixture|off.
	_ = collectors.NewSPIREACollector(collectors.ResolveEnvMode("COLLECTOR_SPIREA_MODE", "SIGNAL_COLLECTOR_SPIREA", "SPIREA_MODE"), storeSink)

	// P2-3: k8saudit (K8s audit receiver webhook mount)
	// Mounted via auditReceiver and registered in registry with live/fixture/off modes.

	// P2-5: kagent (KAgent tool-log resolver collector)
	// Registered via NewRegistryFromEnvWithReceiver (COLLECTOR_KAGENT_MODE) with live/fixture/off modes.

	// P2-6: workspacesaas (Workspace/M365 thin adapter collector)
	// Registered via NewRegistryFromEnvWithReceiver (COLLECTOR_WORKSPACESAAS_MODE) with live/fixture/off modes.

	// --- CRKC-P1-4: tetragon (audit-only runtime telemetry) ---
	// Registered HERE rather than inside collectors.NewRegistryFromEnv because
	// collectors/ebpf imports collectors for the shared Mode type; registering
	// it from the parent package would close an import cycle. Guarded by
	// TestAntiParentPackageDoesNotImportEbpf.
	//
	// Tetragon is a telemetry producer only — no LSM enforcement. Containment
	// belongs to stun-sentinel (Tier 0) and Flux (Tier 1).
	// See docs/signalloom/tetragon-telemetry-pipeline.md.
	tetragonCollector := ebpf.NewCollectorFromEnv(storeSink)
	collectorRegistry.Register(tetragonCollector)

	if err := collectorRegistry.Start(ctx); err != nil {
		slog.Warn("collector failed to start; serving degraded", "error", err)
	}

	// Identity graph repository & resolver store (SFDP-P3-2):
	// Reuses the audit connection pool (*sql.DB) when DATABASE_URL is set, avoiding a second pool.
	var identityStore identity.ResolverStore
	var activeEncryptor identity.Encryptor

	keyStr := os.Getenv("IDENTITY_ENCRYPTION_KEY")
	enc, err := identity.NewEncryptorFromKeyString(keyStr)
	if err != nil {
		slog.Error("failed to initialize identity encryptor (refusing to boot unencrypted outside development mode)", "error", err)
		os.Exit(1)
	}
	activeEncryptor = enc

	if pw, ok := auditWriter.(*audit.PostgresWriter); ok && pw != nil {
		identityRepo := identity.NewPostgresRepository(pw.DB(), activeEncryptor)
		identityStore = identity.NewGraphResolverStore(identityRepo)
		migCtx, cancelMig := context.WithTimeout(context.Background(), 5*time.Second)
		if err := identity.ApplyMigrations(migCtx, pw.DB()); err != nil {
			slog.Warn("identity migrations deferred or failed", "error", err)
		}
		cancelMig()
	} else {
		identityStore = identity.NewGraphResolverStore(identity.NewMemoryRepository(activeEncryptor))
	}

	eventBus := identity.NewInProcessEventBus()
	stunClient := identity.NewMockStunSentinelClient()
	stunListener := identity.NewStunEventListener(identityStore.Repository(), eventBus, stunClient)
	stunListener.SetOnRevoke(func(actorID string, timestamp time.Time) {
		for _, a := range engine.GetActors() {
			if a.ID == actorID || a.CanonicalID == actorID {
				a.Status = model.ActorRevoked
				a.UpdatedAt = timestamp
			}
		}
	})

	delegationReaper := identity.NewDelegationReaper(identityStore.Repository(), eventBus, identity.DefaultReaperInterval)
	delegationReaper.Start(ctx)
	defer delegationReaper.Stop()

	fairFixtureSource := fair.NewFixtureSource(fair.DefaultFixtureCount)
	fairService := fair.NewService(fairFixtureSource)

	// --- SLDP-P3-2: Article 17(3) erasure gate. -------------------------------------------------
	//
	// The gate is constructed here, not inside the handler, so that a deployment which cannot build
	// one ends up with a nil Privacy and a route that answers 503. That is the fail-closed
	// direction: with no gate configured no erasure may proceed, whereas a handler that built its
	// own gate lazily could build a permissive one.
	//
	// Startup is deliberately NOT refused when the gate cannot be built. Every existing deployment
	// predates this card and has no SIGNAL_ERASURE_OPERATORS set; exiting here would turn a new
	// optional route into a boot failure across the estate. The safe asymmetry is available: no
	// gate means no erasure, which costs a feature nobody is using yet.
	privacyService, privacyErr := buildErasureGate(auditWriter, activeEncryptor, engine)
	if privacyErr != nil {
		slog.Warn("Article 17 erasure gate not configured; the erasure route will refuse every request",
			"error", privacyErr)
	} else {
		slog.Info("Article 17 erasure gate configured", "route", "POST /api/v1/privacy/erasure/{id}")
	}

	handlers := &api.Handlers{
		Store:           signalStore,
		Engine:          engine,
		Audit:           auditWriter,
		AuditReady:      auditReady,
		AuditReceiver:   auditReceiver,
		CollectorHealth: collectorRegistry.Health,
		IdentityStore:   identityStore,
		FairService:     fairService,
		StunClient:      stunClient,
		EventBus:        eventBus,
		Encryptor:       activeEncryptor,
		Privacy:         privacyService,
	}

	// --- CRKC-P1-4: Prometheus metrics for the Tetragon telemetry lane & OpenFAIR risk ---
	// Registered through the protected router alongside every API route.
	// Renders even before the collector starts (zeroed counters), so a scrape
	// during rollout reports "0" rather than an empty body that would read as
	// "this collector does not exist".
	agentNonoMetrics := agentnono.NewMetrics()
	if c := collectorRegistry.GetCollector("agentnono"); c != nil {
		if anc, ok := c.(*collectors.AgentNonoCollector); ok && anc.RawCollector() != nil {
			agentNonoMetrics = anc.RawCollector().Metrics()
		}
	}

	metricsHandler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = io.WriteString(w, tetragonCollector.Metrics().Render())
		_, _ = io.WriteString(w, fairService.Metrics.Render())
		_, _ = io.WriteString(w, agentNonoMetrics.Render())
		_, _ = io.WriteString(w, correlation.DefaultQuarantineMetrics().Render())
	})

	// Every HTTP request enters through the Authorization JWT-SVID gate below.
	// NewProtectedRouter is the sole production route-registration boundary.
	authConfig, err := api.AuthConfigFromEnv()
	if err != nil {
		slog.Error("HTTP authentication configuration invalid; refusing startup", "error", err)
		os.Exit(1)
	}
	authenticator, err := api.NewJWTAuthenticator(authConfig)
	if err != nil {
		slog.Error("HTTP authenticator initialization failed; refusing startup", "error", err)
		os.Exit(1)
	}
	protectedRouter, err := api.NewProtectedRouter(handlers, authenticator, auditWriter, metricsHandler, api.RouterOptions{})
	if err != nil {
		slog.Error("protected HTTP router initialization failed", "error", err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      protectedRouter,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

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

	auditReceiver.Close()
	collectorRegistry.Stop()

	if err := signalStore.Close(); err != nil {
		slog.Error("store close error", "error", err)
	}

	slog.Info("stopped")
}
