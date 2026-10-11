package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"testing"
)

// The refusal shape, and its parity with the policy engine's.
//
// Four routes in this estate withhold the same class of figure: the Go engine's
// POST /api/v1/compliance/scan-fleet, fe-signalloom's GET /compliance/policy/summary and
// GET /compliance/policy/frameworks, and this service's GET /api/v1/fleet/topology. Until
// the shape converged they said so three different ways — omitted fields, null, and
// (on older paths) 0. An API that signals one condition three ways invites the reader to
// ask whether any of it is deliberate.
//
// fleet-manager declares the shape locally rather than importing it: policy-engine is a
// separate Go module and a separate deployable, and a require+replace would couple two
// services for five small types while being invisible to anyone reading either one alone.
// These tests are what make that duplication safe. They pin this side of the shape AND its
// agreement with the Go engine, by reading the engine's own declaration out of its source.
// Neither service can change the shape alone without one of the two suites failing — which
// is the only way a cross-service contract asserted in two codebases stays true.
//
// The same pattern, for the same reason, across the Go/Python boundary:
// apps/fe-signalloom/src/tests/test_refusal_shape_parity.py.

// enginePackageDir is policy-engine's compliance package, relative to this module root.
// A path and not an import: see the note above.
var enginePackageDir = filepath.Join("..", "policy-engine", "pkg", "compliance")

func engineRefusalTestPath() string {
	return filepath.Join(enginePackageDir, "fleet_scan_refusal_test.go")
}

func engineSourcePath() string {
	return filepath.Join(enginePackageDir, "fleet_scan.go")
}

// engineRefusalShapeKeys returns the key set the engine's own test declares, parsed from
// its source. Resolved from the engine rather than from a literal copied into this file: a
// copy would drift, and a drifted copy of a contract reads as a contract right up to the
// moment it matters.
func engineRefusalShapeKeys(t *testing.T) []string {
	t.Helper()

	src, err := os.ReadFile(engineRefusalTestPath())
	if err != nil {
		t.Fatalf("read engine declaration: %v", err)
	}

	block := regexp.MustCompile(`(?s)var refusalShapeKeys = \[\]string\{(.*?)\}`).FindSubmatch(src)
	if block == nil {
		t.Fatalf("refusalShapeKeys not found in %s. If the engine's declaration moved, this "+
			"test must FOLLOW it — not be deleted, which would silently un-pin the "+
			"cross-service shape.", engineRefusalTestPath())
	}

	var keys []string
	for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllSubmatch(block[1], -1) {
		keys = append(keys, string(m[1]))
	}
	sort.Strings(keys)
	return keys
}

// localRefusalShapeKeys returns the key set THIS service actually puts on the wire. Taken
// from a marshalled value rather than from reflection over the struct tags, because what a
// client sees is the JSON, and omitempty on a refusal field would make the two disagree in
// a way a tag-level comparison could not see.
func localRefusalShapeKeys(t *testing.T) []string {
	t.Helper()

	b, err := json.Marshal(newAuthoredNotComputedPricing("x", []string{"ale"}))
	if err != nil {
		t.Fatalf("marshal local refusal: %v", err)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(b, &obj); err != nil {
		t.Fatalf("unmarshal local refusal: %v", err)
	}

	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// TestEngineDeclarationIsReadable is a guard on the parse itself.
//
// A regex that silently matched nothing would make every parity assertion below vacuously
// true — comparing an empty set against an empty set and passing. The failure mode of a
// cross-service contract test is almost always that it stopped reading the other side, not
// that the other side changed, so the parse is asserted before anything is compared
// against it.
func TestEngineDeclarationIsReadable(t *testing.T) {
	for _, p := range []string{engineRefusalTestPath(), engineSourcePath()} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("%s is not readable: %v", p, err)
		}
	}

	keys := engineRefusalShapeKeys(t)
	if len(keys) < 5 {
		t.Fatalf("parsed only %v from the engine's declaration; the parse is broken", keys)
	}
}

// TestRefusalShapeParityWithPolicyEngine is the assertion the duplication rests on: the two
// services emit the same keys, or this fails.
func TestRefusalShapeParityWithPolicyEngine(t *testing.T) {
	want := engineRefusalShapeKeys(t)
	got := localRefusalShapeKeys(t)

	if len(got) != len(want) {
		t.Fatalf("refusal shape has diverged: fleet-manager emits %v, policy-engine declares %v. "+
			"The whole point of the shape is that a client has ONE object to deserialise across "+
			"every refusing route.", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("refusal shape has diverged at key %d: fleet-manager %q, policy-engine %q",
				i, got[i], want[i])
		}
	}
}

// TestRefusalKeysAreAlwaysPresent covers the direction a key-set comparison alone would
// miss. Parity is necessary but not sufficient: a refusal whose keys vanish when empty
// satisfies "same key set" on a populated example and still breaks a client on an empty
// one. Every key must be present even when there is nothing to put in it.
func TestRefusalKeysAreAlwaysPresent(t *testing.T) {
	b, err := json.Marshal(newAuthoredNotComputedPricing("", nil))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(b, &obj); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	for _, key := range engineRefusalShapeKeys(t) {
		if _, present := obj[key]; !present {
			t.Errorf("key %q disappeared from an empty refusal; every key is always present", key)
		}
	}

	// nil slices must marshal as [] and not null, or a client must branch on the type of
	// a key the shape promises is a list.
	for _, key := range []string{"unpricedFields", "unmappedChecks"} {
		if string(obj[key]) != "[]" {
			t.Errorf("%s = %s on an empty refusal, want []", key, obj[key])
		}
	}
}

// TestStatusVocabularyIsSharedWithTheEngine asserts the enum VALUES, not just the key
// names. Matching keys with different status strings would be worse than no shape at all:
// a client would deserialise both and branch on neither.
//
// The assertion is containment rather than equality, deliberately. fleet-manager adds a
// third cause the engine has no use for (see PricingStatusAuthoredNotComputed), so the
// vocabularies are not identical — but every value the engine declares must exist here
// with the same spelling, and any value this service adds beyond that must be declared in
// localOnlyStatuses below. That makes a silent fourth status impossible while still
// allowing a service to describe a cause the others cannot have.
func TestStatusVocabularyIsSharedWithTheEngine(t *testing.T) {
	src, err := os.ReadFile(engineSourcePath())
	if err != nil {
		t.Fatalf("read engine source: %v", err)
	}

	engineValues := map[string]bool{}
	for _, m := range regexp.MustCompile(`PricingStatus\s*=\s*"([A-Z_]+)"`).FindAllSubmatch(src, -1) {
		engineValues[string(m[1])] = true
	}
	if len(engineValues) == 0 {
		t.Fatalf("no PricingStatus constants parsed from %s; the parse is broken", engineSourcePath())
	}

	local := map[string]bool{
		string(PricingStatusPriced):                  true,
		string(PricingStatusNoDeclaredLossFrequency): true,
		string(PricingStatusNoRiskDataPlane):         true,
		string(PricingStatusAuthoredNotComputed):     true,
	}

	// Every engine value must exist here, spelled identically.
	for v := range engineValues {
		if !local[v] {
			t.Errorf("policy-engine declares status %q and fleet-manager does not; a client "+
				"cannot branch on a vocabulary the two services do not share", v)
		}
	}

	// Anything extra must be explicitly declared as local-only.
	localOnlyStatuses := map[string]bool{
		string(PricingStatusAuthoredNotComputed): true,
	}
	for v := range local {
		if !engineValues[v] && !localOnlyStatuses[v] {
			t.Errorf("fleet-manager declares status %q which the engine does not have and which "+
				"is not in localOnlyStatuses; add it there with a comment saying why this "+
				"service needs a cause the others cannot express", v)
		}
	}
}

// TestLocalOnlyStatusIsNotOneOfTheEnginesCauses stops the third status being a respelling
// of a cause that already has a name. The three demand different operator actions, and one
// label over several facts reads as authoritative precisely because it is uniform.
func TestLocalOnlyStatusIsNotOneOfTheEnginesCauses(t *testing.T) {
	src, err := os.ReadFile(engineSourcePath())
	if err != nil {
		t.Fatalf("read engine source: %v", err)
	}

	for _, m := range regexp.MustCompile(`PricingStatus\s*=\s*"([A-Z_]+)"`).FindAllSubmatch(src, -1) {
		if string(m[1]) == string(PricingStatusAuthoredNotComputed) {
			t.Errorf("AUTHORED_NOT_COMPUTED already exists in the engine; it is not a third cause")
		}
	}

	if PricingStatusAuthoredNotComputed == PricingStatusPriced {
		t.Errorf("a refusal is equal to PRICED")
	}
	if PricingStatusAuthoredNotComputed.Available() {
		t.Errorf("%q reports a figure as available", PricingStatusAuthoredNotComputed)
	}
}

// TestRefusalIsNotReadableAsAFigure is the property that separates an explicit refusal from
// an omission or a zero: the status must not coerce to a number.
func TestRefusalIsNotReadableAsAFigure(t *testing.T) {
	var parsed float64
	if err := json.Unmarshal([]byte(`"`+string(PricingStatusAuthoredNotComputed)+`"`), &parsed); err == nil {
		t.Errorf("the status parsed as the number %v", parsed)
	}
}
