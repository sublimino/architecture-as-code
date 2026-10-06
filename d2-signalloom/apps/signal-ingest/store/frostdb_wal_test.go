//go:build frostdb

package store

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
)

// TestFrostDB_UnrotatedRowsSurviveAbandonedProcess pins the durability that proposal D1 ("no
// loss for any source") promises: an Append that has been acknowledged is readable by a store
// opened later on the same directory even when the first process never flushed, closed, or
// rotated its block. That is the OOM-kill case observed on kind-osramp on 2026-10-06, where
// 145 acknowledged rows vanished with the active block.
//
// The first process is a real child process (this test binary re-executed with
// FROSTDB_WAL_CHILD set) that exits without Close, because two column stores on one directory
// inside a single process contend for the WAL and would make the test hang instead of
// answering the question.
func TestFrostDB_UnrotatedRowsSurviveAbandonedProcess(t *testing.T) {
	if dir := os.Getenv("FROSTDB_WAL_CHILD"); dir != "" {
		walChildAppendAndExit(t, dir)
		return
	}
	dir := t.TempDir()
	cmd := exec.Command(os.Args[0], "-test.run=^TestFrostDB_UnrotatedRowsSurviveAbandonedProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), "FROSTDB_WAL_CHILD="+dir)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("child process: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "WAL_CHILD_ACKED=3") {
		t.Fatalf("child did not acknowledge its rows:\n%s", out)
	}

	second, err := NewFrostDBStoreWithBucket(dir, WithManualFlush(), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err != nil {
		t.Fatalf("reopen on the same directory: %v", err)
	}
	defer second.Close()
	got, err := second.QueryRange(context.Background(), Query{After: walFixtureTime.Add(-time.Minute)})
	if err != nil {
		t.Fatalf("query after reopen: %v", err)
	}
	ids := map[string]bool{}
	for _, o := range got {
		ids[o.ID] = true
	}
	for _, want := range []string{"wal-1", "wal-2", "wal-3"} {
		if !ids[want] {
			t.Fatalf("row %s acknowledged by the abandoned process is missing after reopen (got %d rows)", want, len(got))
		}
	}
}

// walDurabilityLag is comfortably more than FrostDB's 50 ms WAL batch tick.
const walDurabilityLag = 500 * time.Millisecond

// walFixtureTime is fixed so parent and child agree on the query window.
var walFixtureTime = time.Date(2026, 10, 6, 7, 0, 0, 0, time.UTC)

// walChildAppendAndExit is the abandoned process: open, append, confirm the rows are visible,
// print the acknowledgement, and exit without Flush or Close.
func walChildAppendAndExit(t *testing.T, dir string) {
	first, err := NewFrostDBStoreWithBucket(dir, WithManualFlush(), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err != nil {
		t.Fatalf("child open: %v", err)
	}
	ts := walFixtureTime
	rows := []model.Observation{
		{ID: "wal-1", Timestamp: ts, Source: "test", Layer: model.LayerCloudControlPlane, Description: "one", Labels: map[string]string{"tenant_id": "t"}},
		{ID: "wal-2", Timestamp: ts.Add(time.Second), Source: "test", Layer: model.LayerCloudControlPlane, Description: "two", Labels: map[string]string{"tenant_id": "t"}},
		{ID: "wal-3", Timestamp: ts.Add(2 * time.Second), Source: "test", Layer: model.LayerCloudControlPlane, Description: "three", Labels: map[string]string{"tenant_id": "t"}},
	}
	if err := first.Append(context.Background(), rows); err != nil {
		t.Fatalf("child append: %v", err)
	}
	got, err := first.QueryRange(context.Background(), Query{After: ts.Add(-time.Minute)})
	if err != nil || len(got) != 3 {
		t.Fatalf("child should see its own rows: n=%d err=%v", len(got), err)
	}
	// FrostDB's WAL is written by a background goroutine on a 50 ms tick and offers no
	// synchronous flush, so an ack is durable only once that tick has run. The wait here is
	// that residual, stated rather than hidden: a kill inside the tick can still lose the rows
	// acked in it. Everything older than one tick must survive, and that is what is asserted.
	time.Sleep(walDurabilityLag)
	fmt.Printf("WAL_CHILD_ACKED=%d\n", len(got))
	os.Exit(0)
}

// TestFrostDB_ActiveMemoryFloor refuses a ceiling that would rotate on every row.
func TestFrostDB_ActiveMemoryFloor(t *testing.T) {
	_, err := NewFrostDBStoreWithBucket(t.TempDir(), WithActiveMemoryBytes(1024), WithSegmentPseudonymiser(testPseudonymiser(t)))
	if err == nil {
		t.Fatal("a 1 KiB active block must be refused")
	}
}
