package audit

import (
	"context"
	"database/sql"
	"log/slog"
	"time"

	"github.com/lib/pq" // Postgres driver
)

// DefaultConnectTimeout bounds the startup connectivity check.
//
// The number is chosen against the startupProbe in
// apps/signal-ingest/base/deployment.yaml -- periodSeconds 2 x
// failureThreshold 10, so the kubelet kills the container ~20s after start.
// Everything before the audit writer (store open, correlation engine) is
// sub-millisecond, so this bound is very nearly the whole of what boot spends
// before ListenAndServe.
//
// 5s leaves 15s -- seven further probe attempts -- for the listener to bind
// and answer, so a degraded start still becomes a Running pod on the next
// probe tick rather than a CrashLoopBackOff. Going much higher inverts that:
// a 15s bound binds at ~15s and has to win on attempt 8 of 10, which is not a
// margin. Going much lower is the opposite error -- an in-cluster Postgres
// answers in well under 100ms, but a cold cluster's first DNS + TCP + auth
// round trip can take seconds, and degrading the audit trail of a compliance
// product because DNS was slow costs more than the four seconds saved.
//
// TestDefaultConnectTimeout_FitsStartupProbeBudget asserts this arithmetic so
// that changing the probe or the bound in isolation fails the build rather
// than silently re-arming the defect.
const DefaultConnectTimeout = 5 * time.Second

// PostgresWriter writes audit events to the signal_audit_trail table.
type PostgresWriter struct {
	db *sql.DB
}

// OpenPostgresWriter prepares the connection pool WITHOUT contacting the
// server: it parses the DSN and builds a connector, nothing more. It returns
// in microseconds even when the database is unreachable, which is what keeps
// the boot path free of any external dependency.
//
// It deliberately does NOT use sql.Open("postgres", dsn), and that is the
// substantive half of this fix rather than a stylistic preference.
// sql.Open(name, dsn) wraps the driver in database/sql's own dsnConnector,
// whose Connect method has the signature
//
//	func (t dsnConnector) Connect(_ context.Context) (driver.Conn, error)
//
// -- it DISCARDS the context and calls driver.Open(dsn). pq therefore dials
// from context.Background() no matter what deadline the caller supplied, so
// db.PingContext(ctx) does not bound the dial at all. Measured against a
// blackholed address: PingContext with a 1.5s context was still blocked at
// 5.5s. Switching to pq.NewConnectorConfig + sql.OpenDB puts pq's own
// connector in the chain, and that one does thread ctx through to
// net.Dialer.DialContext. (pq's doc comment on Connector.Connect claims
// "Context is not used"; the comment is stale, conn.go's dial() passes it.)
//
// ConnectTimeout is set as a second, independent bound because the context
// only covers the DIAL. A server that completes the TCP handshake and then
// stalls mid-startup would otherwise reproduce the original silence one layer
// up. pq applies ConnectTimeout as a socket deadline across the whole
// establishment and clears it again once startup finishes (conn.go:302), so it
// bounds the handshake without leaking a deadline onto later queries. A
// connect_timeout already present in the DSN wins -- operator intent is not
// overridden.
//
// An error here means the DSN itself is unusable (bad scheme, unparseable).
// That is a configuration fault: it will not fix itself and no amount of
// retrying helps, which is why the caller treats it differently from a failed
// Ping.
func OpenPostgresWriter(dsn string) (*PostgresWriter, error) {
	cfg, err := pq.NewConfig(dsn)
	if err != nil {
		return nil, err
	}
	if cfg.ConnectTimeout <= 0 {
		cfg.ConnectTimeout = DefaultConnectTimeout
	}
	connector, err := pq.NewConnectorConfig(cfg)
	if err != nil {
		return nil, err
	}
	// sql.OpenDB never dials and never returns an error.
	return &PostgresWriter{db: sql.OpenDB(connector)}, nil
}

// Ping verifies the server is actually reachable, bounded by ctx.
//
// PingContext, not Ping. The distinction is the entire defect: db.Ping() has
// no deadline, and when a NetworkPolicy DROPS the SYN (rather than refusing
// it) there is no error to return and no timeout to hit -- the call simply
// never comes back. Bounding it converts that silence into a deadline error
// the caller can branch on. See OpenPostgresWriter for why the context only
// reaches the driver via pq's connector.
//
// Used twice: once at boot to classify the audit path, and again on every
// /readyz probe so the classification stays honest over the pod's life.
func (p *PostgresWriter) Ping(ctx context.Context) error {
	return p.db.PingContext(ctx)
}

// NewPostgresWriterContext opens the pool and verifies connectivity within
// ctx, returning nil and an error if the server cannot be reached. On failure
// the pool is closed, so an errored call leaks nothing.
func NewPostgresWriterContext(ctx context.Context, dsn string) (*PostgresWriter, error) {
	p, err := OpenPostgresWriter(dsn)
	if err != nil {
		return nil, err
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, err
	}
	return p, nil
}

// NewPostgresWriter opens and verifies a pool under DefaultConnectTimeout.
// Retained as the eager, one-argument constructor for callers that want
// connect-or-fail semantics; it differs from the version that shipped only in
// that it now has a deadline.
func NewPostgresWriter(dsn string) (*PostgresWriter, error) {
	ctx, cancel := context.WithTimeout(context.Background(), DefaultConnectTimeout)
	defer cancel()
	return NewPostgresWriterContext(ctx, dsn)
}

// WriteAuditEvent inserts a row into signal_audit_trail. On failure it logs
// the error and returns it — callers in this demo-grade service treat the
// error as non-fatal.
func (p *PostgresWriter) WriteAuditEvent(ctx context.Context, event Event) error {
	const q = `INSERT INTO signal_audit_trail
		(tenant_id, event_type, actor_id, detail)
		VALUES ($1, $2, $3, $4)`

	var actorID *string
	if event.ActorID != "" {
		actorID = &event.ActorID
	}

	detail := event.Detail
	if len(detail) == 0 {
		detail = []byte("{}")
	}

	_, err := p.db.ExecContext(ctx, q, event.TenantID, string(event.EventType), actorID, detail)
	if err != nil {
		slog.Error("audit write failed", "event_type", event.EventType, "error", err)
	}
	return err
}

// Close releases the connection pool.
func (p *PostgresWriter) Close() error {
	return p.db.Close()
}
