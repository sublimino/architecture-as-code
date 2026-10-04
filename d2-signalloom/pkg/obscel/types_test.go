package obscel

import (
	"testing"
	"time"
)

func TestFindingIDIsDerivedAndStable(t *testing.T) {
	a := FindingID("kusari", "iam-priv-change", "1.0.0", "obs-1")
	b := FindingID("kusari", "iam-priv-change", "1.0.0", "obs-1")
	if a != b || len(a) != 64 {
		t.Fatalf("finding id must be a stable sha256 hex: %q vs %q", a, b)
	}
	if FindingID("kusari", "iam-priv-change", "1.0.1", "obs-1") == a {
		t.Fatal("bundle version must participate in the id")
	}
}

func TestDecisionIDIgnoresFindingOrder(t *testing.T) {
	x := DecisionID("kusari", "r", "k", []string{"a", "b", "c"})
	y := DecisionID("kusari", "r", "k", []string{"c", "a", "b"})
	if x != y {
		t.Fatal("decision id must not depend on finding order")
	}
}

func TestCanonicalFindingSortsLabels(t *testing.T) {
	ts := time.Date(2026, 10, 4, 8, 0, 0, 0, time.UTC)
	f := Finding{ID: "id", Timestamp: ts, TenantID: "t", RuleID: "r", BundleID: "b", BundleVersion: "1", Labels: map[string]string{"z": "1", "a": "2"}}
	got := CanonicalFinding(f)
	want := "id|2026-10-04T08:00:00Z|t||r|b@1||" + "|a=2|z=1"
	if got != want {
		t.Fatalf("canonical form drifted:\n got %q\nwant %q", got, want)
	}
}
