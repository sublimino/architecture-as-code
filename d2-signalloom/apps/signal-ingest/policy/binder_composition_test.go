package policy

import (
	"context"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// Production composes collectors.BindTenant OUTSIDE the policy sink: the collector's
// configured tenant is stamped first, then stage 1 resolves bundles from that label
// (SLAWS D7 then D2). An unstamped observation therefore still produces a finding for
// the collector's tenant. This is the only assertion that catches the two being
// composed the other way round, where an unstamped record would match no bundle.
func TestBinderOutsideThePolicySinkStampsBeforeStageOne(t *testing.T) {
	bundles, err := LoadBundles(repoBundlesDir(t), testLogger(t))
	if err != nil {
		t.Fatalf("LoadBundles: %v", err)
	}
	evaluator, err := obscel.NewEvaluator()
	if err != nil {
		t.Fatalf("obscel.NewEvaluator: %v", err)
	}
	st := store.NewMemoryStore()
	policySink := NewSink(collectors.NewStoreSink(st), st, evaluator, StaticBundles(bundles), Options{
		Windows: NewWindowsWithLogger(bundles, testLogger(t)),
		Logger:  testLogger(t),
	})
	bound := collectors.BindTenant(policySink, e2eTenant)

	unstamped := &model.Observation{
		ID:             "binder-composition-attachuserpolicy",
		Timestamp:      time.Date(2026, 10, 2, 9, 30, 0, 0, time.UTC),
		Layer:          model.LayerCloudControlPlane,
		Fidelity:       model.FidelityStrong,
		Source:         "aws:iam",
		Confidence:     0.9,
		ActorHint:      "arn:aws:iam::123456789012:user/kusari-agent",
		RawEvidenceRef: "testdata/binder#0",
		Description:    "IAM privilege change",
		Labels:         map[string]string{"event_source": "iam.amazonaws.com", "event_name": "AttachUserPolicy"},
	}
	if err := bound.IngestObservation(context.Background(), unstamped); err != nil {
		t.Fatalf("IngestObservation: %v", err)
	}
	findings := storedBySource(t, st, obscel.SourceFinding)
	if len(findings) != 1 {
		t.Fatalf("got %d findings, want 1: the binder must stamp before stage 1 resolves the tenant", len(findings))
	}
	if findings[0].Labels[TenantLabel] != e2eTenant {
		t.Fatalf("finding tenant_id = %q, want %q", findings[0].Labels[TenantLabel], e2eTenant)
	}
	srcRows := storedBySource(t, st, "aws:iam")
	if len(srcRows) != 1 || srcRows[0].Labels[TenantLabel] != e2eTenant {
		t.Fatalf("source observation not stamped by the binder: %+v", srcRows)
	}
}
