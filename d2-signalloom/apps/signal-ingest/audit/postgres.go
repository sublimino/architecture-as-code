package audit

import (
	"context"
	"database/sql"
	"log/slog"

	_ "github.com/lib/pq" // Postgres driver
)

// PostgresWriter writes audit events to the signal_audit_trail table.
type PostgresWriter struct {
	db *sql.DB
}

// NewPostgresWriter opens a connection pool using the given DSN (DATABASE_URL).
func NewPostgresWriter(dsn string) (*PostgresWriter, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, err
	}
	// Validate connectivity eagerly.
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	return &PostgresWriter{db: db}, nil
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
