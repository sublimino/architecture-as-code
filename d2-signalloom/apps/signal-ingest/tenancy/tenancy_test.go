package tenancy

import (
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func TestBindStampsAbsentTenant(t *testing.T) {
	obs := []model.Observation{{ID: "a"}, {ID: "b", Labels: map[string]string{"k": "v"}}}
	if err := BindObservations("kusari", false, obs); err != nil {
		t.Fatal(err)
	}
	for _, o := range obs {
		if o.Labels[Label] != "kusari" {
			t.Fatalf("%s not stamped: %v", o.ID, o.Labels)
		}
	}
	if obs[1].Labels["k"] != "v" {
		t.Fatal("existing labels must be preserved")
	}
}

func TestBindKeepsMatchingTenant(t *testing.T) {
	obs := []model.Observation{{ID: "a", Labels: map[string]string{Label: "kusari"}}}
	if err := BindObservations("kusari", false, obs); err != nil {
		t.Fatal(err)
	}
}

func TestBindRefusesMismatchBeforeMutating(t *testing.T) {
	obs := []model.Observation{{ID: "a"}, {ID: "b", Labels: map[string]string{Label: "other"}}}
	err := BindObservations("kusari", false, obs)
	if !errors.Is(err, ErrTenantMismatch) {
		t.Fatalf("want ErrTenantMismatch, got %v", err)
	}
	if _, stamped := obs[0].Labels[Label]; stamped {
		t.Fatal("batch must be refused whole: first observation was stamped")
	}
}

func TestBindRefusesEmptyTenant(t *testing.T) {
	if err := BindObservations("", false, []model.Observation{{ID: "a"}}); !errors.Is(err, ErrTenantMismatch) {
		t.Fatalf("want ErrTenantMismatch, got %v", err)
	}
}

func TestCrossTenantGrantLeavesBatchAsSent(t *testing.T) {
	obs := []model.Observation{{ID: "a", Labels: map[string]string{Label: "other"}}}
	if err := BindObservations("kusari", true, obs); err != nil {
		t.Fatal(err)
	}
	if obs[0].Labels[Label] != "other" {
		t.Fatal("cross-tenant writer's tenant must be kept as sent")
	}
}
