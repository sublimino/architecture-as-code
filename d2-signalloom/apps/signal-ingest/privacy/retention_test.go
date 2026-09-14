package privacy

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestRetentionPrecedenceTruthTable asserts all four cells of the hold-versus-expiry matrix.
//
// All four are required, not just the interesting one. Asserting only "held and expired is not
// deletable" would pass for an implementation that never deletes anything, and asserting only
// "expired and unheld is deletable" would pass for one that always deletes. The discriminating
// evidence is the pair.
func TestRetentionPrecedenceTruthTable(t *testing.T) {
	const subject = "actor-x"
	elapsed := testNow.Add(-24 * time.Hour) // retention period ended yesterday
	upcoming := testNow.Add(24 * time.Hour) // retention period still running

	cases := []struct {
		name          string
		holds         []Hold
		retentionEnds time.Time
		wantDue       bool
		wantDeletable bool
	}{
		{"within retention, no hold", nil, upcoming, false, false},
		{"within retention, active hold", []Hold{containmentHold(subject)}, upcoming, false, false},
		{"past retention, no hold", nil, elapsed, true, true},
		{"past retention, active hold", []Hold{containmentHold(subject)}, elapsed, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, err := NewRetention(availableSource(&sequenceRecorder{}, tc.holds...), fixedClock(testNow))
			if err != nil {
				t.Fatalf("construct retention: %v", err)
			}
			d, err := r.Evaluate(context.Background(), "tenant-a", subject, tc.retentionEnds)
			if err != nil {
				t.Fatalf("evaluate: %v", err)
			}
			if d.Due != tc.wantDue {
				t.Errorf("Due = %v, want %v", d.Due, tc.wantDue)
			}
			if d.Deletable != tc.wantDeletable {
				t.Errorf("Deletable = %v, want %v", d.Deletable, tc.wantDeletable)
			}
			// The interesting cell must SAY that precedence is why, or an operator staring at a
			// record six weeks past its retention date has no idea what is holding it.
			if tc.wantDue && !tc.wantDeletable {
				if !strings.Contains(d.Reason, "precedence") {
					t.Errorf("a hold blocking an elapsed retention period does not explain precedence: %q", d.Reason)
				}
				if len(d.HoldIDs) == 0 {
					t.Error("the blocking hold is not named")
				}
			}
		})
	}
}

// TestRetentionPrecedenceDueIsIndependentOfHoldState keeps the two questions separate.
//
// Collapsing Due into Deletable is how a retention sweeper ends up destroying evidence on a timer:
// it asks "is it due?", gets a hold-aware false, and concludes the schedule has not elapsed. The
// operator then cannot see that anything is overdue at all.
func TestRetentionPrecedenceDueIsIndependentOfHoldState(t *testing.T) {
	const subject = "actor-x"
	r, err := NewRetention(availableSource(&sequenceRecorder{}, containmentHold(subject)), fixedClock(testNow))
	if err != nil {
		t.Fatalf("construct retention: %v", err)
	}
	d, err := r.Evaluate(context.Background(), "tenant-a", subject, testNow.Add(-24*time.Hour))
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if !d.Due {
		t.Fatal("an elapsed retention period reports not-due because a hold is active; " +
			"the schedule and the hold have been collapsed into one answer")
	}
	if d.Deletable {
		t.Fatal("a held record reports deletable")
	}
}

func TestRetentionPrecedenceFailsClosed(t *testing.T) {
	t.Run("incident source unavailable", func(t *testing.T) {
		r, err := NewRetention(unavailableSource(&sequenceRecorder{}), fixedClock(testNow))
		if err != nil {
			t.Fatalf("construct retention: %v", err)
		}
		d, err := r.Evaluate(context.Background(), "tenant-a", "actor-x", testNow.Add(-24*time.Hour))
		if err == nil {
			t.Fatal("retention evaluation succeeded while incident state was unavailable")
		}
		if !errors.Is(err, ErrIncidentStateUnavailable) {
			t.Errorf("want ErrIncidentStateUnavailable, got %v", err)
		}
		if d.Deletable {
			t.Fatal("a record was reported deletable although holds could not be read")
		}
	})

	t.Run("no jurisdiction", func(t *testing.T) {
		declining := &fakeIncidentSource{jurisdiction: false, seq: &sequenceRecorder{}}
		r, err := NewRetention(declining, fixedClock(testNow))
		if err != nil {
			t.Fatalf("construct retention: %v", err)
		}
		d, err := r.Evaluate(context.Background(), "tenant-b", "actor-x", testNow.Add(-24*time.Hour))
		if err == nil {
			t.Fatal("retention evaluation succeeded although no source had jurisdiction")
		}
		if d.Deletable {
			t.Fatal("a record was reported deletable although nobody looked for holds")
		}
	})

	t.Run("nil incident source is refused at construction", func(t *testing.T) {
		if _, err := NewRetention(nil, fixedClock(testNow)); err == nil {
			t.Fatal("NewRetention accepted a nil incident source; a sweeper that cannot see holds deletes through them")
		}
	})
}

// =============================================================================================
// HOLD MODEL AND SOURCES
// =============================================================================================

func TestHoldActiveSemantics(t *testing.T) {
	base := containmentHold("actor-x")
	cases := map[string]struct {
		released time.Time
		want     bool
	}{
		"never released (zero value) is indefinite": {time.Time{}, true},
		"released in the past":                      {testNow.Add(-time.Hour), false},
		"released in the future still blocks":       {testNow.Add(time.Hour), true},
		"released exactly now is released":          {testNow, false},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			h := base
			h.ReleasedAt = tc.released
			if got := h.Active(testNow); got != tc.want {
				t.Fatalf("Active() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestHoldKindValid(t *testing.T) {
	for _, k := range []HoldKind{HoldUnresolvedIncident, HoldActiveContainment, HoldOperatorPlaced} {
		if !k.Valid() {
			t.Errorf("enumerated kind %q reports invalid", k)
		}
	}
	for _, k := range []HoldKind{"", "quarantine", "incident"} {
		if k.Valid() {
			t.Errorf("unenumerated kind %q reports valid", k)
		}
	}
}

// fakeQuarantine is a controllable QuarantineLookup.
type fakeQuarantine struct {
	records map[string]*model.QuarantineRecord
}

func (f fakeQuarantine) IsActorQuarantined(actorID string) (*model.QuarantineRecord, bool) {
	r, ok := f.records[actorID]
	return r, ok
}

func TestHoldQuarantineSourceDerivesContainmentHolds(t *testing.T) {
	quarantinedAt := testNow.Add(-3 * time.Hour)
	lookup := fakeQuarantine{records: map[string]*model.QuarantineRecord{
		"actor-bad": {
			ActorID:         "actor-bad",
			ViolationReason: model.ViolationForgedClaim,
			QuarantinedAt:   quarantinedAt,
		},
	}}
	src, err := NewQuarantineIncidentSource(lookup, "tenant-a")
	if err != nil {
		t.Fatalf("construct quarantine source: %v", err)
	}

	t.Run("quarantined actor yields an active containment hold", func(t *testing.T) {
		res, err := src.ActiveHolds(context.Background(), "tenant-a", "actor-bad")
		if err != nil {
			t.Fatalf("ActiveHolds: %v", err)
		}
		if !res.Jurisdiction {
			t.Fatal("the source declined jurisdiction over its own tenant")
		}
		if len(res.Holds) != 1 {
			t.Fatalf("got %d holds, want 1", len(res.Holds))
		}
		h := res.Holds[0]
		if h.Kind != HoldActiveContainment {
			t.Errorf("kind = %q, want %q", h.Kind, HoldActiveContainment)
		}
		if !strings.Contains(h.IncidentRef, string(model.ViolationForgedClaim)) {
			t.Errorf("the violation reason did not reach the incident ref: %q", h.IncidentRef)
		}
		if !h.OpenedAt.Equal(quarantinedAt) {
			t.Errorf("OpenedAt = %v, want the quarantine timestamp %v", h.OpenedAt, quarantinedAt)
		}
		if h.SubjectID != "actor-bad" || h.TenantID != "tenant-a" {
			t.Errorf("hold is not scoped to the queried subject and tenant: %+v", h)
		}
	})

	t.Run("unquarantined actor yields jurisdiction with no holds", func(t *testing.T) {
		res, err := src.ActiveHolds(context.Background(), "tenant-a", "actor-good")
		if err != nil {
			t.Fatalf("ActiveHolds: %v", err)
		}
		if !res.Jurisdiction {
			t.Fatal("the source declined jurisdiction over its own tenant")
		}
		if len(res.Holds) != 0 {
			t.Fatalf("got %d holds for an unquarantined actor", len(res.Holds))
		}
	})

	// THE defect the HoldQueryResult type exists to prevent. Under a plain ([]Hold, error)
	// contract, this case and the one above would be byte-identical, and a tenant this source knows
	// nothing about would read as "determined: no holds".
	t.Run("other tenant declines rather than answering no-holds", func(t *testing.T) {
		res, err := src.ActiveHolds(context.Background(), "tenant-b", "actor-bad")
		if err != nil {
			t.Fatalf("ActiveHolds: %v", err)
		}
		if res.Jurisdiction {
			t.Fatal("the source claimed jurisdiction over a tenant it is not bound to")
		}
	})

	t.Run("nil lookup is refused at construction", func(t *testing.T) {
		if _, err := NewQuarantineIncidentSource(nil, "tenant-a"); err == nil {
			t.Fatal("a nil quarantine lookup was accepted")
		}
		if _, err := NewQuarantineIncidentSource(lookup, ""); err == nil {
			t.Fatal("an empty tenant was accepted; the source would then match every tenant")
		}
	})
}

func TestHoldCompositeSourceRefusesPartialViews(t *testing.T) {
	seq := &sequenceRecorder{}

	t.Run("unions holds from every authoritative source", func(t *testing.T) {
		a := availableSource(seq, Hold{ID: "hold-a", SubjectID: "s", TenantID: "tenant-a", Kind: HoldOperatorPlaced})
		b := availableSource(seq, Hold{ID: "hold-b", SubjectID: "s", TenantID: "tenant-a", Kind: HoldUnresolvedIncident})
		c, err := NewCompositeIncidentSource(a, b)
		if err != nil {
			t.Fatalf("construct composite: %v", err)
		}
		res, err := c.ActiveHolds(context.Background(), "tenant-a", "s")
		if err != nil {
			t.Fatalf("ActiveHolds: %v", err)
		}
		if len(res.Holds) != 2 {
			t.Fatalf("got %d holds, want the union of 2", len(res.Holds))
		}
	})

	// One failing constituent poisons the whole answer. The failing source is exactly the one that
	// might have been holding this subject.
	t.Run("any constituent error refuses", func(t *testing.T) {
		c, err := NewCompositeIncidentSource(availableSource(seq), unavailableSource(seq))
		if err != nil {
			t.Fatalf("construct composite: %v", err)
		}
		if _, err := c.ActiveHolds(context.Background(), "tenant-a", "s"); !errors.Is(err, ErrIncidentStateUnavailable) {
			t.Fatalf("a composite returned a partial view as a complete one: %v", err)
		}
	})

	t.Run("all constituents declining refuses", func(t *testing.T) {
		d1 := &fakeIncidentSource{jurisdiction: false, seq: seq}
		d2 := &fakeIncidentSource{jurisdiction: false, seq: seq}
		c, err := NewCompositeIncidentSource(d1, d2)
		if err != nil {
			t.Fatalf("construct composite: %v", err)
		}
		if _, err := c.ActiveHolds(context.Background(), "tenant-z", "s"); !errors.Is(err, ErrNoJurisdiction) {
			t.Fatalf("a composite whose every member declined answered 'no holds': %v", err)
		}
	})

	t.Run("one authoritative source among decliners is enough", func(t *testing.T) {
		c, err := NewCompositeIncidentSource(&fakeIncidentSource{jurisdiction: false, seq: seq}, availableSource(seq))
		if err != nil {
			t.Fatalf("construct composite: %v", err)
		}
		res, err := c.ActiveHolds(context.Background(), "tenant-a", "s")
		if err != nil {
			t.Fatalf("a composite with one authoritative source refused: %v", err)
		}
		if !res.Jurisdiction {
			t.Error("the composite declined although one source was authoritative")
		}
	})

	t.Run("empty and nil composites are refused at construction", func(t *testing.T) {
		if _, err := NewCompositeIncidentSource(); err == nil {
			t.Fatal("an empty composite was constructed; it would answer 'no holds' to every subject")
		}
		if _, err := NewCompositeIncidentSource(availableSource(seq), nil); err == nil {
			t.Fatal("a composite containing a nil source was constructed")
		}
	})
}

// TestHoldActiveFilteringIsDeterministic keeps refusal bodies and audit records byte-identical
// across repeated evaluations of the same state.
func TestHoldActiveFilteringIsDeterministic(t *testing.T) {
	holds := []Hold{
		{ID: "z-hold", SubjectID: "s"},
		{ID: "a-hold", SubjectID: "s"},
		{ID: "m-hold", SubjectID: "s", ReleasedAt: testNow.Add(-time.Hour)}, // released, must drop
	}
	first := holdIDs(activeHoldsAt(holds, testNow))
	if len(first) != 2 {
		t.Fatalf("got %d active holds, want 2 (one is released)", len(first))
	}
	if first[0] != "a-hold" || first[1] != "z-hold" {
		t.Fatalf("active holds are not sorted deterministically: %v", first)
	}
	second := holdIDs(activeHoldsAt(holds, testNow))
	for i := range first {
		if first[i] != second[i] {
			t.Fatalf("repeated evaluation produced a different order: %v then %v", first, second)
		}
	}
}
