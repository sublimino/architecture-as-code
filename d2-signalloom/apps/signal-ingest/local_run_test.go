package main

import (
	"path/filepath"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// A local run (no DATABASE_URL) audits to SIGNAL_AUDIT_FILE: a sink the router accepts as healthy.
// Without it the sink is the discarding NopWriter, which the router refuses.
func TestLocalAuditWriterIsAFileSinkWhenConfigured(t *testing.T) {
	t.Setenv(AuditFileEnvVar, filepath.Join(t.TempDir(), "audit.jsonl"))
	w, err := localAuditWriter()
	if err != nil {
		t.Fatal(err)
	}
	if p := audit.GetAuditPosture(w); !p.Healthy || p.Backend != "file" {
		t.Fatalf("posture %+v, want a healthy file backend", p)
	}
	t.Setenv(AuditFileEnvVar, "")
	w, _ = localAuditWriter()
	if audit.GetAuditPosture(w).Healthy {
		t.Fatal("with no audit file the local sink must not report healthy")
	}
	t.Setenv(AuditFileEnvVar, filepath.Join(t.TempDir(), "absent-dir", "audit.jsonl"))
	if _, err := localAuditWriter(); err == nil {
		t.Fatal("an unopenable audit file must refuse startup")
	}
}
