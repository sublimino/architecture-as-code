package audit

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// FileWriter is the audit sink for a local run without Postgres (the SLTM probe harness starts the
// real binary this way). It must be a real, fail-closed sink: every event persisted as one JSON
// line, and a write that cannot persist is an error, never a silent discard (NopWriter's defect).
func TestFileWriterPersistsEveryEventAsOneJSONLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "audit.jsonl")
	w, err := NewFileWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	for _, tenant := range []string{"tenant-a", "tenant-b"} {
		if err := w.WriteAuditEvent(context.Background(), Event{TenantID: tenant, EventType: EventActorUpdated, Detail: json.RawMessage(`{"k":1}`)}); err != nil {
			t.Fatal(err)
		}
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var got []Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e Event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatalf("line is not an event: %q", sc.Text())
		}
		got = append(got, e)
	}
	if len(got) != 2 || got[0].TenantID != "tenant-a" || got[1].TenantID != "tenant-b" || got[0].CreatedAt.IsZero() {
		t.Fatalf("persisted %+v", got)
	}
	if p := GetAuditPosture(w); !p.Healthy || p.Backend != "file" || p.Policy != "fail_closed" {
		t.Fatalf("posture %+v", p)
	}
}

func TestFileWriterFailsClosed(t *testing.T) {
	if _, err := NewFileWriter(filepath.Join(t.TempDir(), "missing-dir", "audit.jsonl")); err == nil {
		t.Fatal("a file writer over an unopenable path was built")
	}
	path := filepath.Join(t.TempDir(), "audit.jsonl")
	w, err := NewFileWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	w.Close() // every later write must now fail, not succeed into nothing
	if err := w.WriteAuditEvent(context.Background(), Event{TenantID: "t", EventType: EventActorUpdated}); err == nil {
		t.Fatal("a write that could not persist reported success")
	}
}
