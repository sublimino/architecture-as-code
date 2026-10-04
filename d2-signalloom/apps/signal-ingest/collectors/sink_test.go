package collectors

import (
	"context"
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/tenancy"
)

type recordingSink struct{ got []model.Observation }

func (r *recordingSink) IngestObservation(_ context.Context, o *model.Observation) error {
	r.got = append(r.got, *o)
	return nil
}

func TestBindTenantStampsAbsentLabel(t *testing.T) {
	rec := &recordingSink{}
	s := BindTenant(rec, "kusari")
	in := &model.Observation{ID: "a", Labels: map[string]string{"k": "v"}}
	if err := s.IngestObservation(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if len(rec.got) != 1 || rec.got[0].Labels[tenancy.Label] != "kusari" || rec.got[0].Labels["k"] != "v" {
		t.Fatalf("forwarded observation not bound: %+v", rec.got)
	}
	if _, mutated := in.Labels[tenancy.Label]; mutated {
		t.Fatal("caller's observation must not be mutated")
	}
}

func TestBindTenantPassesMatchingLabel(t *testing.T) {
	rec := &recordingSink{}
	s := BindTenant(rec, "kusari")
	if err := s.IngestObservation(context.Background(), &model.Observation{ID: "a", Labels: map[string]string{tenancy.Label: "kusari"}}); err != nil {
		t.Fatal(err)
	}
	if len(rec.got) != 1 {
		t.Fatal("matching tenant must be forwarded")
	}
}

func TestBindTenantRefusesMismatchAndDoesNotForward(t *testing.T) {
	rec := &recordingSink{}
	s := BindTenant(rec, "kusari")
	err := s.IngestObservation(context.Background(), &model.Observation{ID: "a", Labels: map[string]string{tenancy.Label: "other"}})
	if !errors.Is(err, tenancy.ErrTenantMismatch) {
		t.Fatalf("want the shared tenancy.ErrTenantMismatch, got %v", err)
	}
	if len(rec.got) != 0 {
		t.Fatal("a mismatched observation must never reach the store")
	}
}

func TestBindTenantNilObservationIsNoop(t *testing.T) {
	rec := &recordingSink{}
	if err := BindTenant(rec, "kusari").IngestObservation(context.Background(), nil); err != nil || len(rec.got) != 0 {
		t.Fatalf("nil must be a no-op: err=%v got=%d", err, len(rec.got))
	}
}
