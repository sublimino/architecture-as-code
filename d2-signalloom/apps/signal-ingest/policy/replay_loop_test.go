package policy

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Replay must never feed stage-1 output back into stage 1. With a match-all rule, a
// store holding one raw observation plus one stored finding and one stored decision
// yields exactly one finding, and no output line derives from the stored finding or
// decision. This pins the invariant whose mutation (removing replay's own-output
// filter) survived in W5's run because the sink's source guard masked it.
func TestReplayNeverDerivesFindingsFromStoredFindingsOrDecisions(t *testing.T) {
	dir := t.TempDir()
	bundle := `id: match-all
tenant_id: kusari
version: 1.0.0
mode: shadow
rules:
  - id: everything
    name: match everything
    severity: low
    expression: "true"
`
	if err := os.WriteFile(filepath.Join(dir, "match-all.yaml"), []byte(bundle), 0o644); err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 10, 2, 10, 0, 0, 0, time.UTC)
	st := store.NewMemoryStore()
	rows := []model.Observation{
		{ID: "raw-1", Timestamp: ts, Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong, Source: "aws:iam", Confidence: 0.9, ActorHint: "arn:aws:iam::1:user/a", RawEvidenceRef: "testdata/x#0", Description: "raw", Labels: map[string]string{TenantLabel: "kusari"}},
		{ID: "stored-finding-1", Timestamp: ts.Add(time.Second), Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong, Source: obscel.SourceFinding, Confidence: 1, ActorHint: "arn:aws:iam::1:user/a", RawEvidenceRef: "raw-0", Description: "finding", Labels: map[string]string{TenantLabel: "kusari", "rule_id": "everything", "bundle_id": "match-all", "bundle_version": "1.0.0", "severity": "low"}},
		{ID: "stored-decision-1", Timestamp: ts.Add(2 * time.Second), Layer: model.LayerCloudControlPlane, Fidelity: model.FidelityStrong, Source: obscel.SourceDecision, Confidence: 1, ActorHint: "arn:aws:iam::1:user/a", RawEvidenceRef: "stored-finding-1", Description: "decision", Labels: map[string]string{TenantLabel: "kusari", "rule_id": "everything", "window_id": "w", "mode": "shadow"}},
	}
	if err := st.Append(context.Background(), rows); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	findings, decisions, err := Replay(context.Background(), st, ReplayOptions{
		BundlesDir: dir, From: ts.Add(-time.Minute), To: ts.Add(time.Minute), Tenant: "kusari", Out: &out, Log: testLogger(t),
	})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if findings != 1 || decisions != 0 {
		t.Fatalf("got %d findings / %d decisions, want 1 / 0: stage-1 output must not be replayed as input\n%s", findings, decisions, out.String())
	}
	text := out.String()
	for _, forbidden := range []string{"stored-finding-1", "stored-decision-1"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("replay output derives from %s:\n%s", forbidden, text)
		}
	}
	if !strings.Contains(text, "raw-1") {
		t.Fatalf("replay output should derive from raw-1:\n%s", text)
	}
}
