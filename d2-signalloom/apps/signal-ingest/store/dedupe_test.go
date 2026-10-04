// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package store

import (
	"reflect"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

func row(id, desc string) model.Observation {
	return model.Observation{
		ID:          id,
		Timestamp:   time.Unix(1700000000, 0).UTC(),
		Layer:       model.LayerCloudControlPlane,
		Description: desc,
	}
}

func ids(rows []model.Observation) []string {
	out := make([]string, 0, len(rows))
	for i := range rows {
		out = append(out, rows[i].ID)
	}
	return out
}

func TestDedupeByID_CollapsesDuplicatesAndKeepsOrder(t *testing.T) {
	in := []model.Observation{row("a", "1"), row("b", "1"), row("a", "2"), row("c", "1"), row("b", "2")}
	got := ids(DedupeByID(in))
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("want %v, got %v", want, got)
	}
}

// The surviving row is the first occurrence, not the last: the replay command
// and Weave must agree on which copy they are looking at.
func TestDedupeByID_KeepsTheFirstOccurrence(t *testing.T) {
	in := []model.Observation{row("a", "first"), row("a", "second")}
	out := DedupeByID(in)
	if len(out) != 1 || out[0].Description != "first" {
		t.Fatalf("want the first copy, got %+v", out)
	}
}

func TestDedupeByID_PassesThroughUnidentifiedRows(t *testing.T) {
	in := []model.Observation{row("", "x"), row("", "y"), row("a", "1"), row("a", "2")}
	out := DedupeByID(in)
	if len(out) != 3 {
		t.Fatalf("want 3 rows (two unkeyable, one deduped), got %d: %v", len(out), ids(out))
	}
}

func TestDedupeByID_LeavesACleanResultUntouched(t *testing.T) {
	in := []model.Observation{row("a", "1"), row("b", "1")}
	out := DedupeByID(in)
	if len(out) != 2 {
		t.Fatalf("want 2, got %d", len(out))
	}
	if &out[0] != &in[0] {
		t.Fatal("a result with no duplicates must be returned without copying")
	}
}

func TestDedupeByID_HandlesEmptyAndSingle(t *testing.T) {
	if out := DedupeByID(nil); out != nil {
		t.Fatalf("nil in, want nil out, got %v", out)
	}
	one := []model.Observation{row("a", "1")}
	if out := DedupeByID(one); len(out) != 1 {
		t.Fatalf("want 1, got %d", len(out))
	}
}

// A store seeded with the duplicate rows the defect produced must read back as
// one row per ID once the read side collapses them.
func TestDedupeByID_RepairsAStoreWrittenBeforeTheFix(t *testing.T) {
	corpus := []model.Observation{row("a", "1"), row("b", "1"), row("c", "1")}
	st := NewMemoryStore()
	for pass := 0; pass < 2; pass++ {
		if err := st.Append(nil, corpus); err != nil { //nolint:staticcheck // MemoryStore ignores ctx
			t.Fatal(err)
		}
	}
	raw, err := st.QueryRange(nil, Query{}) //nolint:staticcheck // MemoryStore ignores ctx
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 6 {
		t.Fatalf("precondition: want the 6 duplicated rows the defect produced, got %d", len(raw))
	}
	if got := len(DedupeByID(raw)); got != 3 {
		t.Fatalf("read-side dedupe returned %d rows for 3 distinct IDs", got)
	}
}
