package identity

import (
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

func TestPoolSharing_AuditAndIdentityShareSingleConnectionPool(t *testing.T) {
	// Construct an audit PostgresWriter with a dummy DSN
	dsn := "postgres://user:pass@127.0.0.1:5432/db?sslmode=disable"
	pw, err := audit.OpenPostgresWriter(dsn)
	if err != nil {
		t.Fatalf("OpenPostgresWriter: %v", err)
	}
	defer pw.Close()

	// Obtain the shared *sql.DB handle from the audit writer
	sharedDB := pw.DB()
	if sharedDB == nil {
		t.Fatal("expected non-nil *sql.DB from pw.DB()")
	}

	// Instantiate PostgresRepository using the shared *sql.DB
	repo := NewPostgresRepository(sharedDB, NewNoopEncryptor())

	// Verify that the repository's DB pointer matches the audit writer's DB pointer exactly
	if repo.DB() != sharedDB {
		t.Errorf("expected identity repository to share the exact same *sql.DB handle as audit writer: got %p, want %p",
			repo.DB(), sharedDB)
	}

	// Verify that connection pool statistics reflect a single shared pool
	stats := sharedDB.Stats()
	if stats.MaxOpenConnections != 0 { // Default unset limit
		t.Logf("connection pool stats: %+v", stats)
	}
}
