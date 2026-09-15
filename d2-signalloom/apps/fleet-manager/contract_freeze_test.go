package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// ── The contract-conformance test ────────────────────────────────────────────
//
// This file is the enforcement half of the SLER-P1-3 freeze. Everything else
// about the freeze is prose, and prose does not fail a build.
//
// It asserts three independent things, because a freeze that only checked one
// of them would be green while the contract was broken:
//
//  1. The Go SHAPE matches the frozen descriptor — every type, field, json tag,
//     Go type and omitempty flag. Catches rename, removal, addition, retype and
//     retag.
//  2. The JSON SCHEMA matches the Go shape. Catches the drift where somebody
//     updates the struct and the machine-readable artefact P6-3 validates
//     against silently describes the old contract.
//  3. The VERSION is pinned. Catches a field change smuggled in alongside a
//     version bump, or a version bump with no field change.
//
// The descriptor is written out by hand ON PURPOSE. Deriving it from the types
// it is meant to guard would make the test a tautology: it would compare the
// structs to themselves and pass on any change whatsoever. A hand-written
// expectation is the only form that can disagree with the code.
//
// The cost of a hand-written expectation is that it can be wrong, and the usual
// failure is that it silently guards NOTHING — an empty table comparing equal
// to an empty walk. TestFrozenDescriptorIsNotVacuous exists for exactly that.

// frozenField is one field of one frozen struct.
type frozenField struct {
	GoName    string
	JSONName  string
	GoType    string
	OmitEmpty bool
}

// frozenStruct is one frozen struct type.
type frozenStruct struct {
	Name   string
	Fields []frozenField
}

// frozenEnum is one frozen string-enum type and its complete member set.
type frozenEnum struct {
	Name    string
	Members []string
}

// frozenStructSpecimens returns one zero value per frozen struct type. This is
// the list the reflection walk iterates; adding a type to the contract means
// adding it here AND to frozenStructs below.
func frozenStructSpecimens() []any {
	return []any{
		PlaneResult{},
		TargetRef{},
		ContainmentReason{},
		ContainmentDecision{},
		MeshIsolationRequest{},
		MeshIsolationResponse{},
		BaoRevokeRequest{},
		BaoRevokeResponse{},
		SpireEvictionRequest{},
		SpireEvictionResponse{},
		AdmissionBlockRequest{},
		AdmissionBlockResponse{},
		FreezeRequest{},
		FreezeResponse{},
		ResumeTokenSignature{},
		ResumeToken{},
		ResumeRequest{},
		ResumeResponse{},
		StepResult{},
		TargetOutcome{},
		StateChangeEvent{},
		CascadeResult{},
		DegradedTarget{},
	}
}

// observeStruct walks one struct type into a frozenStruct descriptor.
func observeStruct(v any) frozenStruct {
	t := reflect.TypeOf(v)
	out := frozenStruct{Name: t.Name()}
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		tag := f.Tag.Get("json")
		parts := strings.Split(tag, ",")
		name := parts[0]
		if name == "" {
			name = f.Name
		}
		omit := false
		for _, p := range parts[1:] {
			if p == "omitempty" {
				omit = true
			}
		}
		out.Fields = append(out.Fields, frozenField{
			GoName:    f.Name,
			JSONName:  name,
			GoType:    f.Type.String(),
			OmitEmpty: omit,
		})
	}
	return out
}

// observeFrozenStructs walks every specimen.
func observeFrozenStructs() []frozenStruct {
	specimens := frozenStructSpecimens()
	out := make([]frozenStruct, 0, len(specimens))
	for _, s := range specimens {
		out = append(out, observeStruct(s))
	}
	return out
}

// renderStruct renders a descriptor as stable, diffable text.
func renderStruct(s frozenStruct) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", s.Name)
	for _, f := range s.Fields {
		fmt.Fprintf(&b, "  %s %s json:%q omitempty:%v\n", f.GoName, f.GoType, f.JSONName, f.OmitEmpty)
	}
	return b.String()
}

// TestDumpFrozenDescriptor prints the observed shape. It is a development aid
// for regenerating the frozen table after an APPROVED bump, never a substitute
// for the table. Skipped unless SLER_DUMP_DESCRIPTOR=1.
func TestDumpFrozenDescriptor(t *testing.T) {
	if os.Getenv("SLER_DUMP_DESCRIPTOR") != "1" {
		t.Skip("set SLER_DUMP_DESCRIPTOR=1 to dump the observed contract shape")
	}
	for _, s := range observeFrozenStructs() {
		fmt.Print(renderStruct(s))
	}
}

// ── Assertions ───────────────────────────────────────────────────────────────

// TestFrozenSchemaVersionIsPinned catches a version bump that was not routed
// through P1-GOV, and a field change smuggled in beside one.
func TestFrozenSchemaVersionIsPinned(t *testing.T) {
	const want = "sler.signalloom.io/v1alpha1"
	if FrozenSchemaVersion != want {
		t.Errorf("FrozenSchemaVersion = %q, want %q\n%s", FrozenSchemaVersion, want, FrozenContractBumpProcedure)
	}
	if CurrentSchemaVersion != FrozenSchemaVersion {
		t.Errorf("CurrentSchemaVersion = %q but FrozenSchemaVersion = %q; the version the code emits and the version the contract froze must be the same string\n%s",
			CurrentSchemaVersion, FrozenSchemaVersion, FrozenContractBumpProcedure)
	}
	if SchemaVersionV1Alpha1 != FrozenSchemaVersion {
		t.Errorf("SchemaVersionV1Alpha1 = %q, want %q", SchemaVersionV1Alpha1, FrozenSchemaVersion)
	}
	if err := assertFrozenSchemaVersion(FrozenSchemaVersion); err != nil {
		t.Errorf("assertFrozenSchemaVersion rejected the frozen version: %v", err)
	}
	if err := assertFrozenSchemaVersion("sler.signalloom.io/v1alpha2"); err == nil {
		t.Error("assertFrozenSchemaVersion accepted a version this build does not speak; an unknown schema_version must be refused, not best-effort decoded")
	}
}

// TestFrozenDescriptorIsNotVacuous is the guard against the guard.
//
// A descriptor table that is empty, or that lost entries in an edit, compares
// equal to nothing and passes on every change. This is the specific way a
// hand-written expectation fails silently, so it is checked explicitly rather
// than assumed.
func TestFrozenDescriptorIsNotVacuous(t *testing.T) {
	if got, want := len(frozenStructs), len(frozenStructSpecimens()); got != want {
		t.Fatalf("frozenStructs has %d entries but %d specimens are walked; every specimen needs a frozen entry and vice versa", got, want)
	}
	if len(frozenStructs) < 20 {
		t.Fatalf("frozenStructs has only %d entries; the SLER wire contract has 23 struct types and 2 enums", len(frozenStructs))
	}
	totalFields := 0
	for _, s := range frozenStructs {
		if len(s.Fields) == 0 {
			t.Errorf("frozen struct %s declares no fields; an empty expectation guards nothing", s.Name)
		}
		totalFields += len(s.Fields)
	}
	if totalFields < 100 {
		t.Errorf("frozen descriptor covers only %d fields; expected well over 100 across the enforcement contract", totalFields)
	}
	if len(frozenEnums) != 2 {
		t.Errorf("frozenEnums has %d entries, want 2 (PlaneOutcome, EnforcementPlane)", len(frozenEnums))
	}
}

// TestFrozenGoShapeMatchesDescriptor is the field-level freeze. A rename, a
// removal, an addition, a retype or a retag all land here, named.
func TestFrozenGoShapeMatchesDescriptor(t *testing.T) {
	want := make(map[string]frozenStruct, len(frozenStructs))
	for _, s := range frozenStructs {
		want[s.Name] = s
	}
	seen := make(map[string]bool, len(want))

	for _, got := range observeFrozenStructs() {
		seen[got.Name] = true
		exp, ok := want[got.Name]
		if !ok {
			t.Errorf("type %s is walked as part of the wire contract but has no frozen descriptor entry\n%s", got.Name, FrozenContractBumpProcedure)
			continue
		}
		expByGo := make(map[string]frozenField, len(exp.Fields))
		for _, f := range exp.Fields {
			expByGo[f.GoName] = f
		}
		gotByGo := make(map[string]frozenField, len(got.Fields))
		for _, f := range got.Fields {
			gotByGo[f.GoName] = f
		}
		for _, f := range exp.Fields {
			g, ok := gotByGo[f.GoName]
			if !ok {
				t.Errorf("FROZEN FIELD REMOVED OR RENAMED: %s.%s (json:%q) is in the frozen contract but not in the Go type\n%s",
					exp.Name, f.GoName, f.JSONName, FrozenContractBumpProcedure)
				continue
			}
			if g.JSONName != f.JSONName {
				t.Errorf("FROZEN FIELD RETAGGED: %s.%s json tag is %q, frozen contract says %q\n%s",
					exp.Name, f.GoName, g.JSONName, f.JSONName, FrozenContractBumpProcedure)
			}
			if g.GoType != f.GoType {
				t.Errorf("FROZEN FIELD RETYPED: %s.%s is %s, frozen contract says %s\n%s",
					exp.Name, f.GoName, g.GoType, f.GoType, FrozenContractBumpProcedure)
			}
			if g.OmitEmpty != f.OmitEmpty {
				t.Errorf("FROZEN FIELD OPTIONALITY CHANGED: %s.%s omitempty=%v, frozen contract says %v\n%s",
					exp.Name, f.GoName, g.OmitEmpty, f.OmitEmpty, FrozenContractBumpProcedure)
			}
		}
		for _, g := range got.Fields {
			if _, ok := expByGo[g.GoName]; !ok {
				t.Errorf("FIELD ADDED WITHOUT A VERSION BUMP: %s.%s (json:%q) is in the Go type but not in the frozen contract\n%s",
					exp.Name, g.GoName, g.JSONName, FrozenContractBumpProcedure)
			}
		}
	}
	for name := range want {
		if !seen[name] {
			t.Errorf("FROZEN TYPE MISSING: %s has a frozen descriptor entry but is not walked; was it deleted or renamed?\n%s", name, FrozenContractBumpProcedure)
		}
	}
}

// TestFrozenEnumsAreComplete pins both enum member sets.
//
// The five-plane set is checked against AllEnforcementPlanes() as well as
// against the frozen list, because a plane that exists as a constant but is
// absent from the dispatch list is a plane the cascade will never call — a
// containment that silently skips a whole enforcement surface.
func TestFrozenEnumsAreComplete(t *testing.T) {
	byName := map[string]frozenEnum{}
	for _, e := range frozenEnums {
		byName[e.Name] = e
	}

	gotOutcomes := []string{string(OutcomeContained), string(OutcomePartial), string(OutcomeUnavailable), string(OutcomeNotFound)}
	assertEnum(t, "PlaneOutcome", byName["PlaneOutcome"].Members, gotOutcomes)
	for _, m := range byName["PlaneOutcome"].Members {
		if !PlaneOutcome(m).IsValid() {
			t.Errorf("frozen PlaneOutcome member %q fails IsValid()", m)
		}
	}
	if PlaneOutcome("definitely-not-a-member").IsValid() {
		t.Error("PlaneOutcome.IsValid() accepted an unrecognised value; unknown outcomes must never read as valid")
	}

	var gotPlanes []string
	for _, p := range AllEnforcementPlanes() {
		gotPlanes = append(gotPlanes, string(p))
		if !p.IsValid() {
			t.Errorf("AllEnforcementPlanes() member %q fails IsValid()", p)
		}
	}
	assertEnum(t, "EnforcementPlane", byName["EnforcementPlane"].Members, gotPlanes)
	if n := len(AllEnforcementPlanes()); n != 5 {
		t.Errorf("AllEnforcementPlanes() has %d members, want 5 (mesh, bao, spire, admission, freeze)", n)
	}
	if EnforcementPlane("definitely-not-a-plane").IsValid() {
		t.Error("EnforcementPlane.IsValid() accepted an unrecognised value")
	}
}

func assertEnum(t *testing.T, name string, want, got []string) {
	t.Helper()
	w := append([]string(nil), want...)
	g := append([]string(nil), got...)
	sort.Strings(w)
	sort.Strings(g)
	if !reflect.DeepEqual(w, g) {
		t.Errorf("FROZEN ENUM CHANGED: %s is %v, frozen contract says %v\n%s", name, g, w, FrozenContractBumpProcedure)
	}
}

// ── JSON Schema cross-check ──────────────────────────────────────────────────

// jsonSchemaDoc is the minimal shape this test needs out of the schema file.
type jsonSchemaDoc struct {
	Schema string                  `json:"$schema"`
	ID     string                  `json:"$id"`
	Title  string                  `json:"title"`
	Defs   map[string]jsonSchemaDef `json:"$defs"`
}

type jsonSchemaDef struct {
	Type       string                     `json:"type"`
	Enum       []string                   `json:"enum"`
	Required   []string                   `json:"required"`
	Properties map[string]json.RawMessage `json:"properties"`
}

// repoRootFromPackage walks up from the package directory to the repository
// root. The test lives in d2-signalloom/apps/fleet-manager.
func repoRootFromPackage(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Clean(filepath.Join(wd, "..", "..", ".."))
}

func loadJSONSchema(t *testing.T) jsonSchemaDoc {
	t.Helper()
	path := filepath.Join(repoRootFromPackage(t), FrozenContractJSONSchema)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the frozen contract's machine-readable schema is missing: %v\nSLER-P1-3 requires %s to exist so P6-3's acceptance suite can validate messages programmatically rather than by hand-written assertions", err, FrozenContractJSONSchema)
	}
	var doc jsonSchemaDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("%s is not valid JSON: %v", FrozenContractJSONSchema, err)
	}
	return doc
}

// TestJSONSchemaIsWellFormed checks the envelope of the machine-readable
// artefact before anything tries to use it.
func TestJSONSchemaIsWellFormed(t *testing.T) {
	doc := loadJSONSchema(t)
	if want := "https://json-schema.org/draft/2020-12/schema"; doc.Schema != want {
		t.Errorf("$schema = %q, want %q", doc.Schema, want)
	}
	if !strings.Contains(doc.ID, FrozenSchemaVersion) {
		t.Errorf("$id = %q does not carry the frozen schema version %q; the artefact must say which contract it describes", doc.ID, FrozenSchemaVersion)
	}
	if len(doc.Defs) == 0 {
		t.Fatal("$defs is empty; the schema describes nothing")
	}
}

// TestJSONSchemaMatchesGoShape is the cross-artefact guard.
//
// Two halves of one contract, maintained in two files, WILL drift — and the
// drift is invisible because each half is internally consistent and its own
// tests stay green. This diffs them against each other so the divergence has
// somewhere to fail.
func TestJSONSchemaMatchesGoShape(t *testing.T) {
	doc := loadJSONSchema(t)

	for _, got := range observeFrozenStructs() {
		def, ok := doc.Defs[got.Name]
		if !ok {
			t.Errorf("JSON SCHEMA MISSING TYPE: %s has no $defs entry in %s\n%s", got.Name, FrozenContractJSONSchema, FrozenContractBumpProcedure)
			continue
		}
		goProps := map[string]bool{}
		var wantRequired []string
		for _, f := range got.Fields {
			if f.JSONName == "-" {
				continue
			}
			goProps[f.JSONName] = true
			if !f.OmitEmpty {
				wantRequired = append(wantRequired, f.JSONName)
			}
		}
		for name := range goProps {
			if _, ok := def.Properties[name]; !ok {
				t.Errorf("JSON SCHEMA MISSING PROPERTY: %s.%s is in the Go type but not in $defs/%s/properties\n%s", got.Name, name, got.Name, FrozenContractBumpProcedure)
			}
		}
		for name := range def.Properties {
			if !goProps[name] {
				t.Errorf("JSON SCHEMA EXTRA PROPERTY: $defs/%s/properties/%s describes a field the Go type does not have\n%s", got.Name, name, FrozenContractBumpProcedure)
			}
		}
		gotRequired := append([]string(nil), def.Required...)
		sort.Strings(gotRequired)
		sort.Strings(wantRequired)
		if !reflect.DeepEqual(gotRequired, wantRequired) {
			t.Errorf("JSON SCHEMA REQUIRED MISMATCH for %s:\n  schema:   %v\n  go(!omitempty): %v\n%s", got.Name, gotRequired, wantRequired, FrozenContractBumpProcedure)
		}
	}

	for _, e := range frozenEnums {
		def, ok := doc.Defs[e.Name]
		if !ok {
			t.Errorf("JSON SCHEMA MISSING ENUM: %s has no $defs entry", e.Name)
			continue
		}
		assertEnum(t, "JSON schema enum "+e.Name, e.Members, def.Enum)
	}
}

// TestWorkedExamplesDecodeUnderTheFrozenContract validates the published
// example payloads against the Go types with unknown fields REFUSED.
//
// DisallowUnknownFields is what makes this a real check. A tolerant decode
// would accept an example carrying a field the contract dropped, and the
// example is precisely the artefact a downstream engineer copies.
func TestWorkedExamplesDecodeUnderTheFrozenContract(t *testing.T) {
	root := repoRootFromPackage(t)

	t.Run("containment decision", func(t *testing.T) {
		raw := mustReadExample(t, filepath.Join(root, "docs/signalloom/sler-p1-3-example-containment-decision.json"))
		dec := json.NewDecoder(strings.NewReader(string(raw)))
		dec.DisallowUnknownFields()
		var decision ContainmentDecision
		if err := dec.Decode(&decision); err != nil {
			t.Fatalf("worked ContainmentDecision example does not decode under the frozen contract: %v", err)
		}
		if err := assertFrozenSchemaVersion(decision.SchemaVersion); err != nil {
			t.Errorf("worked example: %v", err)
		}
		if err := decision.ValidateDecision(); err != nil {
			t.Errorf("worked ContainmentDecision example fails ValidateDecision: %v", err)
		}
		// The example must exercise PARTIAL containment. An example in which
		// everything succeeded proves nothing about the property P1-5 exists to
		// preserve, and it is the example every downstream engineer copies.
		if decision.OverallOutcome != OutcomePartial {
			t.Errorf("worked example overall_outcome = %q, want %q: the published example must demonstrate that a partial containment is representable", decision.OverallOutcome, OutcomePartial)
		}
		if len(decision.PlaneResults) != len(AllEnforcementPlanes()) {
			t.Errorf("worked example carries %d plane_results, want one per plane (%d)", len(decision.PlaneResults), len(AllEnforcementPlanes()))
		}
		// Every outcome value must appear somewhere in the example. Fixtures
		// that carry only the values their author imagined are how an enum
		// member ships untested.
		present := map[PlaneOutcome]bool{}
		for _, pr := range decision.PlaneResults {
			present[pr.Outcome] = true
		}
		for _, o := range []PlaneOutcome{OutcomeContained, OutcomePartial, OutcomeUnavailable, OutcomeNotFound} {
			if !present[o] {
				t.Errorf("worked example never exercises plane outcome %q; the example must carry every enum member", o)
			}
		}
	})

	t.Run("resume token", func(t *testing.T) {
		raw := mustReadExample(t, filepath.Join(root, "docs/signalloom/sler-p1-3-example-resume-token.json"))
		dec := json.NewDecoder(strings.NewReader(string(raw)))
		dec.DisallowUnknownFields()
		var token ResumeToken
		if err := dec.Decode(&token); err != nil {
			t.Fatalf("worked ResumeToken example does not decode under the frozen contract: %v", err)
		}
		if err := assertFrozenSchemaVersion(token.SchemaVersion); err != nil {
			t.Errorf("worked example: %v", err)
		}
		if len(token.Signatures) < 2 {
			t.Errorf("worked ResumeToken example carries %d signatures; the published example must demonstrate dual-operator signing", len(token.Signatures))
		}
		if err := token.ValidateStructure(); err != nil {
			t.Errorf("worked ResumeToken example fails ValidateStructure: %v", err)
		}
	})
}

func mustReadExample(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("worked example payload missing: %v\nSLER-P1-3 publishes worked examples so a downstream engineer copies a payload that is known to validate", err)
	}
	return raw
}

// TestPartialContainmentRemainsRepresentable is the P1-5 invariant, re-asserted
// at the freeze boundary.
//
// Freezing a result type that cannot express a partial or failed containment
// would lock in the exact defect P1-5 removed. This is checked HERE, at the
// freeze, and not left to P1-5's own suite, because the freeze is the thing
// that makes it permanent.
func TestPartialContainmentRemainsRepresentable(t *testing.T) {
	mixed := []PlaneResult{
		{Plane: PlaneMesh, Outcome: OutcomeContained},
		{Plane: PlaneBao, Outcome: OutcomeUnavailable, Error: "openbao unreachable"},
	}
	if got := AggregateOutcome(mixed); got != OutcomePartial {
		t.Errorf("AggregateOutcome(contained+unavailable) = %q, want %q", got, OutcomePartial)
	}
	allBlind := []PlaneResult{
		{Plane: PlaneMesh, Outcome: OutcomeUnavailable},
		{Plane: PlaneBao, Outcome: OutcomeNotFound},
	}
	if got := AggregateOutcome(allBlind); got == OutcomeContained || got == OutcomePartial {
		t.Errorf("AggregateOutcome(unavailable+not_found) = %q; zero containment achieved must never read as contained or partial", got)
	}
	var pr PlaneResult
	rt := reflect.TypeOf(pr)
	for _, required := range []string{"Outcome", "Error", "Plane"} {
		if _, ok := rt.FieldByName(required); !ok {
			t.Errorf("PlaneResult has no %s field; a per-plane failure would be unrepresentable", required)
		}
	}
	var cd ContainmentDecision
	ct := reflect.TypeOf(cd)
	for _, required := range []string{"PlaneResults", "OverallOutcome"} {
		if _, ok := ct.FieldByName(required); !ok {
			t.Errorf("ContainmentDecision has no %s field; a partial containment would be unrepresentable", required)
		}
	}
}
