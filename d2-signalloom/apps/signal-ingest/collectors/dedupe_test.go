// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package collectors

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store"
)

type countingSink struct {
	got  []model.Observation
	fail error
}

func (c *countingSink) IngestObservation(_ context.Context, obs *model.Observation) error {
	if c.fail != nil {
		return c.fail
	}
	c.got = append(c.got, *obs)
	return nil
}

func obsWithID(id string, ts time.Time) model.Observation {
	return model.Observation{ID: id, Timestamp: ts, Layer: model.LayerCloudControlPlane}
}

func TestDedupeSink_DropsARepeatedID(t *testing.T) {
	rec := &countingSink{}
	s := NewDedupeSink(rec, NewDeduper(16))
	o := obsWithID("a", time.Now())

	for i := 0; i < 3; i++ {
		if err := s.IngestObservation(context.Background(), &o); err != nil {
			t.Fatalf("pass %d: %v", i, err)
		}
	}
	if len(rec.got) != 1 {
		t.Fatalf("want 1 forwarded observation, got %d", len(rec.got))
	}
}

func TestDedupeSink_AdmitsDistinctIDs(t *testing.T) {
	rec := &countingSink{}
	d := NewDeduper(16)
	s := NewDedupeSink(rec, d)

	now := time.Now()
	for _, id := range []string{"a", "b", "c"} {
		o := obsWithID(id, now)
		if err := s.IngestObservation(context.Background(), &o); err != nil {
			t.Fatal(err)
		}
	}
	if len(rec.got) != 3 {
		t.Fatalf("want 3 forwarded, got %d", len(rec.got))
	}
	if d.Dropped() != 0 {
		t.Fatalf("want 0 dropped, got %d", d.Dropped())
	}
}

// An observation with no ID cannot be keyed, so it must be admitted rather than
// collapsed onto every other unidentified observation.
func TestDedupeSink_AdmitsEveryUnidentifiedObservation(t *testing.T) {
	rec := &countingSink{}
	s := NewDedupeSink(rec, NewDeduper(16))
	now := time.Now()
	for i := 0; i < 3; i++ {
		o := obsWithID("", now)
		if err := s.IngestObservation(context.Background(), &o); err != nil {
			t.Fatal(err)
		}
	}
	if len(rec.got) != 3 {
		t.Fatalf("want 3 forwarded, got %d", len(rec.got))
	}
}

// A write the inner sink refused must stay replayable: claiming the ID and then
// losing the row would turn a transient store fault into permanent data loss.
func TestDedupeSink_ARefusedWriteIsNotClaimed(t *testing.T) {
	boom := errors.New("store down")
	rec := &countingSink{fail: boom}
	d := NewDeduper(16)
	s := NewDedupeSink(rec, d)
	o := obsWithID("a", time.Now())

	if err := s.IngestObservation(context.Background(), &o); !errors.Is(err, boom) {
		t.Fatalf("want the inner error, got %v", err)
	}
	if d.Tracked() != 0 {
		t.Fatalf("a refused write left %d claimed IDs", d.Tracked())
	}
	rec.fail = nil
	if err := s.IngestObservation(context.Background(), &o); err != nil {
		t.Fatal(err)
	}
	if len(rec.got) != 1 {
		t.Fatalf("retry after a refused write was swallowed: %d forwarded", len(rec.got))
	}
}

func TestDeduper_HonoursCapacity(t *testing.T) {
	d := NewDeduper(2)
	if !d.Accept("a") || !d.Accept("b") || !d.Accept("c") {
		t.Fatal("distinct IDs must all be accepted")
	}
	if got := d.Tracked(); got != 2 {
		t.Fatalf("capacity 2 tracked %d IDs", got)
	}
	// "a" was evicted as least-recently-accepted, so it is admitted again.
	if !d.Accept("a") {
		t.Fatal("an evicted ID must be admitted again; a bounded set cannot promise forever")
	}
	// "c" is still resident.
	if d.Accept("c") {
		t.Fatal("a resident ID must still be dropped")
	}
	if d.Evicted() == 0 {
		t.Fatal("eviction happened and was not counted")
	}
}

func TestDeduper_RecencyDecidesEviction(t *testing.T) {
	d := NewDeduper(2)
	d.Accept("a")
	d.Accept("b")
	// Touching "a" (a replay) must refresh it, so "b" is the eviction victim.
	if d.Accept("a") {
		t.Fatal("a resident ID must be dropped")
	}
	d.Accept("c")
	if d.Accept("a") {
		t.Fatal("the refreshed ID was evicted; recency is not being tracked")
	}
}

func TestDeduper_WarmsFromStore(t *testing.T) {
	st := store.NewMemoryStore()
	now := time.Now()
	seed := []model.Observation{obsWithID("a", now), obsWithID("b", now)}
	if err := st.Append(context.Background(), seed); err != nil {
		t.Fatal(err)
	}
	// Outside the warm window: must NOT be warmed, so it is still ingestable.
	if err := st.Append(context.Background(), []model.Observation{obsWithID("old", now.Add(-72*time.Hour))}); err != nil {
		t.Fatal(err)
	}

	d := NewDeduper(16)
	if err := d.Warm(context.Background(), st, 24*time.Hour, now, nil); err != nil {
		t.Fatal(err)
	}
	if d.WarmedIDs() != 2 {
		t.Fatalf("want 2 warmed IDs, got %d", d.WarmedIDs())
	}

	rec := &countingSink{}
	s := NewDedupeSink(rec, d)
	for _, id := range []string{"a", "b", "old"} {
		o := obsWithID(id, now)
		if err := s.IngestObservation(context.Background(), &o); err != nil {
			t.Fatal(err)
		}
	}
	if len(rec.got) != 1 || rec.got[0].ID != "old" {
		t.Fatalf("warm-up did not block the already-durable IDs: forwarded %+v", rec.got)
	}
}

func TestDeduper_WarmIsBoundedByCapacity(t *testing.T) {
	st := store.NewMemoryStore()
	now := time.Now()
	var seed []model.Observation
	for i := 0; i < 50; i++ {
		seed = append(seed, obsWithID("id-"+strconv.Itoa(i), now))
	}
	if err := st.Append(context.Background(), seed); err != nil {
		t.Fatal(err)
	}
	d := NewDeduper(10)
	if err := d.Warm(context.Background(), st, time.Hour, now, nil); err != nil {
		t.Fatal(err)
	}
	if got := d.Tracked(); got > 10 {
		t.Fatalf("warm-up overran its capacity: tracked %d", got)
	}
}

func TestDeduper_FilterObservationsCollapsesWithinABatch(t *testing.T) {
	d := NewDeduper(16)
	now := time.Now()
	batch := []model.Observation{obsWithID("a", now), obsWithID("b", now), obsWithID("a", now)}
	out := d.FilterObservations(batch)
	if len(out) != 2 || out[0].ID != "a" || out[1].ID != "b" {
		t.Fatalf("want [a b], got %+v", out)
	}
	if d.Dropped() != 1 {
		t.Fatalf("want 1 dropped, got %d", d.Dropped())
	}
	// A second pass of the same batch is entirely a replay.
	if out := d.FilterObservations(batch); len(out) != 0 {
		t.Fatalf("second pass admitted %d observations", len(out))
	}
}

func TestDeduper_ReleaseRestoresAFailedBatch(t *testing.T) {
	d := NewDeduper(16)
	now := time.Now()
	batch := []model.Observation{obsWithID("a", now)}
	out := d.FilterObservations(batch)
	d.Release(out)
	if got := d.FilterObservations(batch); len(got) != 1 {
		t.Fatalf("a released batch was not re-admitted: %d", len(got))
	}
}

func TestDeduper_RenderNamesBothCounters(t *testing.T) {
	d := NewDeduper(4)
	d.Accept("a")
	d.Accept("a")
	out := d.Render()
	for _, want := range []string{
		"signalloom_ingest_dedupe_dropped_total 1",
		"signalloom_ingest_dedupe_warmed_ids 0",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("Render() is missing %q:\n%s", want, out)
		}
	}
}

func TestDeduperFromEnv_ReadsCapacityAndWindow(t *testing.T) {
	t.Setenv(DedupeCapacityEnv, "7")
	t.Setenv(DedupeWarmWindowEnv, "90m")
	d := NewDeduperFromEnv(nil)
	if d.Capacity() != 7 {
		t.Fatalf("capacity %d", d.Capacity())
	}
	if d.WarmWindow() != 90*time.Minute {
		t.Fatalf("warm window %s", d.WarmWindow())
	}
}

func TestDeduperFromEnv_DefaultsWhenUnsetOrInvalid(t *testing.T) {
	t.Setenv(DedupeCapacityEnv, "not-a-number")
	t.Setenv(DedupeWarmWindowEnv, "")
	d := NewDeduperFromEnv(nil)
	if d.Capacity() != DefaultDedupeCapacity {
		t.Fatalf("capacity %d", d.Capacity())
	}
	if d.WarmWindow() != DefaultDedupeWarmWindow {
		t.Fatalf("warm window %s", d.WarmWindow())
	}
}

// A nil Deduper is a working passthrough, so a caller that has not configured
// one is not a nil dereference on the ingest path.
func TestDedupeSink_NilDeduperIsAPassthrough(t *testing.T) {
	rec := &countingSink{}
	s := NewDedupeSink(rec, nil)
	o := obsWithID("a", time.Now())
	_ = s.IngestObservation(context.Background(), &o)
	_ = s.IngestObservation(context.Background(), &o)
	if len(rec.got) != 2 {
		t.Fatalf("want passthrough of both, got %d", len(rec.got))
	}
}
