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
	"strings"
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
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy/tombstone"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/retention"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/subjectkey"
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

// RetentionTenantsEnvVar names the comma-separated tenants the retention reaper sweeps.
//
// There is no "all tenants" value and no default. A reaper with an empty tenant list sweeps nothing and
// reports no error — the shape of failure this whole card exists to remove — so the absence of this
// variable is a refusal to start the reaper, logged, rather than a reaper that runs over zero tenants
// and renders a reassuring zero.
const RetentionTenantsEnvVar = "SIGNAL_RETENTION_TENANTS"

// RetentionClockSyncEnvVar names an RFC3339 upstream time reading used to seed the trusted clock.
//
// UNOWNED BOUNDARY, recorded rather than assumed away: a real deployment needs an NTP or Roughtime
// client feeding TrustedClock.Sync on an interval. This card owns the trust DECISION (freshness window,
// drift tolerance, fail-closed refusal), not the transport. Until a card owns the transport, an operator
// seeds the clock once at boot from this variable, and the freshness window then expires it after an
// hour — which stops the sweep rather than letting it run on a stale reading. That is the correct
// direction for a placeholder.
const RetentionClockSyncEnvVar = "SIGNAL_RETENTION_CLOCK_SYNC"

// retentionTenants parses the tenant list the reaper sweeps.
func retentionTenants() []string {
	raw := strings.TrimSpace(os.Getenv(RetentionTenantsEnvVar))
	if raw == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// buildRetentionController assembles the SLDP-P6-1 retention controller.
//
// It returns an error rather than a degraded controller in every case it cannot assemble a complete one.
// There is deliberately no branch that yields a controller with fewer sinks, a local clock, or a
// discarding ledger: a retention control that runs with any of those reports deletion it did not perform.
func buildRetentionController(
	metrics *retention.Metrics,
	signalStore store.SignalStore,
	identityStore identity.ResolverStore,
	auditWriter audit.AuditWriter,
	engine *correlation.Engine,
) (*retention.Controller, error) {
	tenants := retentionTenants()
	if len(tenants) == 0 {
		return nil, fmt.Errorf("no tenants configured: set %s; a reaper with no tenants sweeps nothing and reports no error", RetentionTenantsEnvVar)
	}

	pw, ok := auditWriter.(*audit.PostgresWriter)
	if !ok || pw == nil {
		return nil, fmt.Errorf("retention requires a PostgreSQL ledger: set DATABASE_URL. An in-memory receipt ledger loses every proof of deletion on restart")
	}
	ledger, err := retention.NewPostgresLedger(pw.DB())
	if err != nil {
		return nil, fmt.Errorf("retention ledger: %w", err)
	}

	// The hold evaluator is privacy.Retention, which is the single implementation of "a legal hold beats
	// retention expiry" and which fails closed on an undetermined lookup.
	var sources []privacy.IncidentSource
	pgSource, err := privacy.NewPostgresIncidentSource(pw.DB())
	if err != nil {
		return nil, fmt.Errorf("retention hold source: %w", err)
	}
	sources = append(sources, pgSource)
	if engine != nil {
		qSource, err := privacy.NewQuarantineIncidentSource(engine, tenants[0])
		if err != nil {
			return nil, fmt.Errorf("retention quarantine hold source: %w", err)
		}
		sources = append(sources, qSource)
	}
	incidents, err := privacy.NewCompositeIncidentSource(sources...)
	if err != nil {
		return nil, fmt.Errorf("retention composite hold source: %w", err)
	}

	clock := retention.NewTrustedClock(retention.TrustedClockConfig{})
	if raw := strings.TrimSpace(os.Getenv(RetentionClockSyncEnvVar)); raw != "" {
		upstream, parseErr := time.Parse(time.RFC3339, raw)
		if parseErr != nil {
			return nil, fmt.Errorf("%s is not RFC3339: %w", RetentionClockSyncEnvVar, parseErr)
		}
		clock.Sync(upstream)
	} else {
		return nil, fmt.Errorf("no trusted clock reading: set %s. A retention boundary computed from an unattested local clock expires data early or late with no signal", RetentionClockSyncEnvVar)
	}

	evaluator, err := privacy.NewRetention(incidents, func() time.Time {
		// The evaluator shares the controller's clock rather than reading time.Now, so "is it due?" and
		// "what is the boundary?" cannot be answered from two different clocks. On an untrusted clock this
		// returns the zero time, which makes every record NOT due — the fail-closed direction, and the
		// controller aborts the sweep before this is reached anyway.
		now, clockErr := clock.Now()
		if clockErr != nil {
			return time.Time{}
		}
		return now
	})
	if err != nil {
		return nil, fmt.Errorf("retention evaluator: %w", err)
	}

	sinks, err := buildRetentionSinks(signalStore, identityStore, ledger)
	if err != nil {
		return nil, err
	}

	return retention.NewController(retention.Config{
		Clock:     clock,
		Ledger:    ledger,
		Evaluator: evaluator,
		Audit:     auditWriter,
		Metrics:   metrics,
		Policies:  retention.DefaultPolicySet(tenants[0]),
		Sinks:     sinks,
		Logger:    slog.Default(),
	})
}

// buildRetentionSinks constructs one adapter per inventory entry.
//
// Every entry in retention.AllSinkSpecs gets an adapter — there is no path that silently omits one,
// because the sink set is the denominator of every coverage figure and a missing sink raises apparent
// coverage instead of showing up as a hole.
//
// UNOWNED BOUNDARY, recorded rather than papered over: the in-process row purgers below are wired only
// for the copies this card can reach without adding repository methods that belong to other cards. Any
// spec whose purger is not yet implemented is registered as an EXTERNAL-ATTESTATION sink, so it stays
// outstanding, goes overdue, and is counted — rather than being quietly dropped from the inventory. That
// is a visible, dated gap for P6-GOV instead of an invisible one.
func buildRetentionSinks(signalStore store.SignalStore, identityStore identity.ResolverStore, ledger retention.Ledger) ([]retention.Sink, error) {
	purgers := map[string]retention.RowPurger{}
	if identityStore != nil {
		// Placeholder wiring is deliberately absent. Adding a purger that returns (0, nil) here would
		// make every identity sink report already_absent and the gauge read clean — a passthrough
		// control, which the architectural constitution forbids.
		_ = identityStore
	}

	sinks := make([]retention.Sink, 0, len(retention.AllSinkSpecs()))
	for _, spec := range retention.AllSinkSpecs() {
		switch {
		case spec.ID == "frostdb_observations" && signalStore != nil:
			sink, err := retention.NewPartitionSink(spec, signalStore, nil)
			if err != nil {
				return nil, fmt.Errorf("retention sink %s: %w", spec.ID, err)
			}
			sinks = append(sinks, sink)

		case spec.Reach == retention.ReachContinuityBearing:
			sink, err := retention.NewContinuitySink(spec, retention.LinkageSinksFor(spec.ID), retention.LinkageLookup(ledger))
			if err != nil {
				return nil, fmt.Errorf("retention sink %s: %w", spec.ID, err)
			}
			sinks = append(sinks, sink)

		default:
			if purger, ok := purgers[spec.ID]; ok {
				sink, err := retention.NewRowSink(spec, purger)
				if err != nil {
					return nil, fmt.Errorf("retention sink %s: %w", spec.ID, err)
				}
				sinks = append(sinks, sink)
				continue
			}
			// No in-process purger: declare it externally attested rather than omitting it.
			sinks = append(sinks, retention.NewExternalSink(spec))
		}
	}
	if len(sinks) != len(retention.AllSinkSpecs()) {
		return nil, fmt.Errorf("built %d sinks for %d inventory entries; the inventory must be covered exactly", len(sinks), len(retention.AllSinkSpecs()))
	}
	return sinks, nil
}

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

	destroyer, err := buildKeyDestroyer(auditWriter, encryptor)
	if err != nil {
		return nil, err
	}

	var publisher privacy.TombstonePublisher
	if keyPath := os.Getenv(tombstone.TombstoneKeyEnvVar); keyPath != "" {
		signer, err := tombstone.NewTombstoneSigner(keyPath)
		if err != nil {
			slog.Warn("tombstone signing key configured but failed to load; using unattested publisher", "path", keyPath, "error", err)
			publisher = tombstone.NewPublisher(nil)
		} else {
			publisher = tombstone.NewPublisher(signer)
		}
	} else {
		publisher = tombstone.NewPublisher(nil)
	}

	return privacy.NewService(privacy.Config{
		Incidents:     incidents,
		Destroyer:     destroyer,
		Audit:         auditWriter,
		Operators:     registry,
		Pseudonymiser: encryptor,
		Tombstones:    publisher,
	})
}

// SubjectKeyMasterEnvVar names the master root key encryption key for the per-subject key hierarchy.
//
// It is deliberately SEPARATE from IDENTITY_ENCRYPTION_KEY. Sharing one root would mean the key that
// decrypts every alias also derives every subject KEK, so a single compromise would both read the
// graph and re-wrap a "destroyed" subject's data key -- and the whole point of SLDP-P4-1 is that a
// destroyed key cannot be reconstructed from surviving material.
const SubjectKeyMasterEnvVar = "SUBJECT_KEY_MASTER_KEK"

// buildKeyDestroyer assembles the SLDP-P4-1 erasure saga, or returns the refusing destroyer.
//
// The fallback is UnimplementedKeyDestroyer, NOT a recording or passthrough one. When the master KEK
// is absent there is no per-subject hierarchy, so an authorised erasure must fail loudly rather than
// report a destruction that did not happen: a false "erased" is a misstatement to a data subject and
// a regulator, whereas a loud refusal is an unconfigured deployment. See privacy/destroyer.go.
//
// It also refuses to run without a database. The in-memory store loses every wrapped key on restart,
// which would silently convert "this subject's key was destroyed" into "this subject never had one".
func buildKeyDestroyer(auditWriter audit.AuditWriter, encryptor identity.Encryptor) (privacy.KeyDestroyer, error) {
	master := os.Getenv(SubjectKeyMasterEnvVar)
	pw, hasDB := auditWriter.(*audit.PostgresWriter)
	if master == "" || !hasDB || pw == nil {
		slog.Error("per-subject key hierarchy is not configured; authorised erasures will be REFUSED",
			"master_kek_set", master != "",
			"database_configured", hasDB && pw != nil,
			"required_env", SubjectKeyMasterEnvVar,
			"card", "SLDP-P4-1")
		return privacy.UnimplementedKeyDestroyer{}, nil
	}

	hierarchy, err := subjectkey.NewHierarchy([]byte(master))
	if err != nil {
		return nil, fmt.Errorf("subject key hierarchy: %w", err)
	}
	store, err := subjectkey.NewPostgresStore(pw.DB())
	if err != nil {
		return nil, fmt.Errorf("subject key store: %w", err)
	}
	saga, err := subjectkey.NewSaga(subjectkey.SagaConfig{
		Hierarchy:     hierarchy,
		Store:         store,
		Cache:         subjectkey.NewPlaintextDEKCache(),
		Pseudonymiser: encryptor,
		// PostgreSQL is the store, so MVCC dead tuples, WAL and physical backups retain the prior
		// wrapped key until VACUUM and backup expiry. The receipt states this rather than implying
		// bit-level erasure.
		StorageResidual: subjectkey.StorageResidualMVCCAndBackup,
	})
	if err != nil {
		return nil, fmt.Errorf("erasure saga: %w", err)
	}
	slog.Info("per-subject key hierarchy and erasure saga are active",
		"store", "postgres", "max_key_versions_per_subject", subjectkey.MaxKeyVersionsPerSubject)
	return saga, nil
}

// httpAuthenticator returns the authenticator the protected router should use.
//
// TEMPORARY — delete this function, its call in main, and api/static_bearer.go
// on or before api.StaticBearerSunset. It exists only to let the stun-sentinel
// correlator's static bearer token through while the correlator is moved onto
// the JWT-SVID it already has a binding for in deploy/jwt-auth-config.yaml.
//
// With no SIGNAL_AUTH_STATIC_BEARER_* variable set it returns jwt unchanged,
// so the shipped default is exactly the JWT-SVID gate. A half-configured
// credential is an error for the caller to refuse startup on, never a weaker
// gate.
func httpAuthenticator(jwt api.Authenticator) (api.Authenticator, error) {
	staticBearer, err := api.StaticBearerConfigFromEnv()
	if err != nil {
		return nil, err
	}
	if staticBearer == nil {
		return jwt, nil
	}
	return api.NewStaticBearerAuthenticator(*staticBearer, jwt)
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

	// --- SLDP-P6-1: retention controller and its overdue-object gauge. --------------------------
	//
	// Same fail-closed asymmetry as the erasure gate above, and the same reason: every deployment
	// predates this card, so refusing startup would turn a new control into an estate-wide boot
	// failure. What is NOT permitted is a controller that reports success it has not earned, so when
	// the controller cannot be built the metrics are still registered and render a zeroed series while
	// the log says the sweep is not running. A missing series would read as "this subsystem does not
	// exist", which is a much more comfortable claim than "it exists and is not sweeping".
	retentionMetrics := retention.NewMetrics()
	retentionController, retentionErr := buildRetentionController(retentionMetrics, signalStore, identityStore, auditWriter, engine)
	if retentionErr != nil {
		slog.Warn("retention controller not configured; no sink is being swept for expired personal data",
			"error", retentionErr,
			"consequence", "signalloom_retention_overdue_objects renders zero because nothing is evaluated, not because nothing is expired")
	} else {
		retentionReaper, reaperErr := retention.NewReaper(
			retentionController,
			func() []string { return retentionTenants() },
			retention.DefaultSweepInterval,
			slog.Default(),
		)
		if reaperErr != nil {
			slog.Warn("retention reaper not started", "error", reaperErr)
		} else {
			retentionReaper.Start(ctx)
			defer retentionReaper.Stop()
			slog.Info("retention controller started",
				"sinks", len(retention.AllSinkSpecs()),
				"interval", retention.DefaultSweepInterval.String(),
				"max_retention_period", retention.MaxRetentionPeriod.String(),
				"max_propagation_delay", retention.MaxPropagationDelay.String())
		}
	}

	metricsHandler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		_, _ = io.WriteString(w, tetragonCollector.Metrics().Render())
		_, _ = io.WriteString(w, fairService.Metrics.Render())
		_, _ = io.WriteString(w, agentNonoMetrics.Render())
		_, _ = io.WriteString(w, correlation.DefaultQuarantineMetrics().Render())
		_, _ = io.WriteString(w, retentionMetrics.Render())
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
	// SLDC-P2-2: re-read SIGNAL_AUTH_JWKS_FILE on its refresh interval (no-op for inline JWKS).
	authenticator.StartKeyRefresh(ctx)

	// TEMPORARY — delete this call, httpAuthenticator below, and
	// api/static_bearer.go, on or before api.StaticBearerSunset.
	gateway, err := httpAuthenticator(authenticator)
	if err != nil {
		slog.Error("static bearer configuration invalid; refusing startup", "error", err)
		os.Exit(1)
	}

	protectedRouter, err := api.NewProtectedRouter(handlers, gateway, auditWriter, metricsHandler, api.RouterOptions{})
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
