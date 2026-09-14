// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import (
	"context"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/model"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

// testSegmentRootKey is 32 bytes of fixed, non-secret material for deterministic tests.
const testSegmentRootKeyHex = "303132333435363738396162636465663031323334353637383961626364656601"

// TestMain supplies segment pseudonymisation key material for the whole package.
//
// The store constructors fail closed without it — that is the point of SLDP-P3-1 and it is asserted
// directly by TestSegmentPseudonymiser_FailsClosedWithoutKey, which unsets the variable for the
// duration of its own run. Setting it here rather than threading an option through every existing
// construction site keeps the blast radius of the change to the seam that actually moved.
func TestMain(m *testing.M) {
	if os.Getenv(SegmentPseudonymKeyEnv) == "" {
		_ = os.Setenv(SegmentPseudonymKeyEnv, testSegmentRootKeyHex)
	}
	os.Exit(m.Run())
}

func testPseudonymiser(t *testing.T) *SegmentPseudonymiser {
	t.Helper()
	root, err := hex.DecodeString(testSegmentRootKeyHex)
	if err != nil {
		t.Fatalf("decode test key: %v", err)
	}
	p, err := NewSegmentPseudonymiser(root, DefaultSegmentTenantScope, 0)
	if err != nil {
		t.Fatalf("NewSegmentPseudonymiser: %v", err)
	}
	return p
}

// mustBuildFilter is the test-side adapter for buildFilter's two-value signature.
func mustBuildFilter(t *testing.T, q Query) interface{ String() string } {
	t.Helper()
	expr, err := buildFilter(q, testPseudonymiser(t))
	if err != nil {
		t.Fatalf("buildFilter(%+v): %v", q, err)
	}
	if expr == nil {
		return nil
	}
	return expr
}

// ---------------------------------------------------------------------------
// A — schema v2 definition
// ---------------------------------------------------------------------------

func TestSegmentSchemaV2_ColumnSetIsExactlyDeclared(t *testing.T) {
	got := make([]string, 0, len(schemaDef().Columns))
	for _, c := range schemaDef().Columns {
		got = append(got, c.Name)
	}
	want := V2Columns()

	sortedGot := append([]string(nil), got...)
	sortedWant := append([]string(nil), want...)
	sort.Strings(sortedGot)
	sort.Strings(sortedWant)

	if len(sortedGot) != len(sortedWant) {
		t.Fatalf("schemaDef has %d columns, V2Columns declares %d\n got: %v\nwant: %v",
			len(sortedGot), len(sortedWant), sortedGot, sortedWant)
	}
	for i := range sortedGot {
		if sortedGot[i] != sortedWant[i] {
			t.Fatalf("column set diverges at %d: schemaDef=%q V2Columns=%q\n got: %v\nwant: %v",
				i, sortedGot[i], sortedWant[i], sortedGot, sortedWant)
		}
	}
}

// TestSegmentSchemaV2_NoCleartextIdentifierColumns is the card's central claim, stated as a probe.
func TestSegmentSchemaV2_NoCleartextIdentifierColumns(t *testing.T) {
	present := map[string]bool{}
	for _, c := range schemaDef().Columns {
		present[c.Name] = true
	}
	for _, removed := range V1RemovedColumns() {
		if present[removed] {
			t.Errorf("cleartext identifier column %q is still declared in the v2 segment schema", removed)
		}
	}
	for _, required := range []string{
		ColHMACActorHint, ColHMACActorID, ColHMACPrincipalID,
		ColHMACSessionID, ColHMACImpersonatedUser, ColEvidenceRefDigest,
		SegmentSchemaVersionColumn,
	} {
		if !present[required] {
			t.Errorf("pseudonym column %q is missing from the v2 segment schema", required)
		}
	}
}

func TestSegmentSchemaV2_RetainsNonIdentifierColumns(t *testing.T) {
	present := map[string]bool{}
	for _, c := range schemaDef().Columns {
		present[c.Name] = true
	}
	for _, keep := range []string{
		"id", "timestamp", "layer", "fidelity", "source",
		"confidence", "description", "delegation_depth", "labels",
	} {
		if !present[keep] {
			t.Errorf("non-identifier column %q was dropped from the v2 schema", keep)
		}
	}
}

func TestSegmentSchemaV2_LabelsRemainDynamic(t *testing.T) {
	for _, c := range schemaDef().Columns {
		if c.Name == "labels" {
			if !c.Dynamic {
				t.Fatal("labels column lost Dynamic: true; every label would need a static column")
			}
			return
		}
	}
	t.Fatal("labels column absent")
}

// TestSegmentSchema_IsNotTheAttestationSchema guards the card's first hard blocker.
func TestSegmentSchema_IsNotTheAttestationSchema(t *testing.T) {
	if SegmentSchemaV2 == "signalloom.segment/v1" {
		t.Fatal("the segment COLUMN schema must never equal the DSSE attestation schema; " +
			"bumping the latter invalidates every signed segment already on disk")
	}
	if SegmentSchemaV1 == SegmentSchemaV2 {
		t.Fatal("v1 and v2 column schema identifiers are equal; generations would be indistinguishable")
	}
}

// ---------------------------------------------------------------------------
// B — pseudonymiser
// ---------------------------------------------------------------------------

func TestSegmentPseudonymiser_FailsClosed(t *testing.T) {
	root, _ := hex.DecodeString(testSegmentRootKeyHex)

	if _, err := NewSegmentPseudonymiser(root, "", 0); !errors.Is(err, ErrSegmentPseudonymTenantRequired) {
		t.Errorf("empty tenant: got %v, want ErrSegmentPseudonymTenantRequired", err)
	}
	if _, err := NewSegmentPseudonymiser([]byte("short"), DefaultSegmentTenantScope, 0); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Errorf("short key: got %v, want ErrSegmentPseudonymKeyRequired", err)
	}
	if _, err := NewSegmentPseudonymiser(nil, DefaultSegmentTenantScope, 0); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Errorf("nil key: got %v, want ErrSegmentPseudonymKeyRequired", err)
	}
	p, err := NewSegmentPseudonymiser(root, DefaultSegmentTenantScope, 0)
	if err != nil || p == nil {
		t.Fatalf("valid construction failed: %v", err)
	}
}

// TestSegmentPseudonymiser_FailsClosedWithoutKey proves the absent-key path is a refusal, not a
// passthrough. This is the exact defect SLDP-P2-1 removed from the secret scrubber.
func TestSegmentPseudonymiser_FailsClosedWithoutKey(t *testing.T) {
	t.Setenv(SegmentPseudonymKeyEnv, "")

	if _, err := NewSegmentPseudonymiserFromEnv(); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Fatalf("absent key: got %v, want ErrSegmentPseudonymKeyRequired", err)
	}
	if _, err := NewFrostDBStore(); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Fatalf("store construction with no key must refuse, got %v", err)
	}
	if _, err := NewFrostDBStoreWithBucket(t.TempDir()); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Fatalf("bucket store construction with no key must refuse, got %v", err)
	}

	t.Setenv(SegmentPseudonymKeyEnv, "303132")
	if _, err := NewSegmentPseudonymiserFromEnv(); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Fatalf("short key: got %v, want ErrSegmentPseudonymKeyRequired", err)
	}

	t.Setenv(SegmentPseudonymKeyEnv, "not-hex")
	if _, err := NewSegmentPseudonymiserFromEnv(); err == nil {
		t.Fatal("non-hex key material must be an error")
	}
}

func TestSegmentPseudonymiser_ErrorNamesTheVariable(t *testing.T) {
	if !strings.Contains(ErrSegmentPseudonymKeyRequired.Error(), SegmentPseudonymKeyEnv) {
		t.Fatalf("refusal message must name %s so an operator can act on it: %q",
			SegmentPseudonymKeyEnv, ErrSegmentPseudonymKeyRequired.Error())
	}
}

func TestSegmentPseudonymiser_ShapeAndDeterminism(t *testing.T) {
	p := testPseudonymiser(t)

	empty, err := p.Pseudonym("")
	if err != nil || empty != "" {
		t.Fatalf("empty input: got (%q, %v), want (\"\", nil) — a constant digest on every "+
			"identity-free row would be a join key linking all of them", empty, err)
	}

	a1, err := p.Pseudonym("system:serviceaccount:prod:payments")
	if err != nil {
		t.Fatalf("Pseudonym: %v", err)
	}
	if len(a1) != pseudonym.HexLen || !pseudonym.IsPseudonym(a1) {
		t.Fatalf("pseudonym %q is not %d lowercase hex characters", a1, pseudonym.HexLen)
	}

	a2, _ := p.Pseudonym("system:serviceaccount:prod:payments")
	if a1 != a2 {
		t.Fatal("pseudonym is not deterministic; equality pushdown would be meaningless")
	}

	b, _ := p.Pseudonym("system:serviceaccount:prod:ledger")
	if a1 == b {
		t.Fatal("distinct identifiers collided")
	}
}

func TestSegmentPseudonymiser_ScopeSeparation(t *testing.T) {
	root, _ := hex.DecodeString(testSegmentRootKeyHex)
	const val = "alice@corp.internal"

	base, _ := NewSegmentPseudonymiser(root, "tenant-a", 0)
	otherTenant, _ := NewSegmentPseudonymiser(root, "tenant-b", 0)
	otherEpoch, _ := NewSegmentPseudonymiser(root, "tenant-a", 1)

	v0, _ := base.Pseudonym(val)
	vT, _ := otherTenant.Pseudonym(val)
	vE, _ := otherEpoch.Pseudonym(val)

	if v0 == vT {
		t.Error("two tenants produced the same pseudonym; cross-tenant correlation channel")
	}
	if v0 == vE {
		t.Error("two epochs produced the same pseudonym; rotation would be a no-op")
	}
	if base.Epoch() != 0 || otherEpoch.Epoch() != 1 {
		t.Error("Epoch() does not report the configured epoch")
	}
	if base.Tenant() != "tenant-a" {
		t.Error("Tenant() does not report the configured scope")
	}
}

func TestSegmentPseudonymiser_EvidenceRefIsDomainSeparated(t *testing.T) {
	p := testPseudonymiser(t)
	const same = "https://audit.internal/records/42"

	asIdentity, _ := p.Pseudonym(same)
	asEvidence, err := p.EvidenceRefDigest(same)
	if err != nil {
		t.Fatalf("EvidenceRefDigest: %v", err)
	}
	if asEvidence == asIdentity {
		t.Fatal("evidence-ref digest equals the identity pseudonym for the same input; " +
			"one string appearing in both columns would be linkable across them")
	}
	if !pseudonym.IsPseudonym(asEvidence) {
		t.Fatalf("evidence digest %q is not a well-formed pseudonym", asEvidence)
	}
	if got, _ := p.EvidenceRefDigest(""); got != "" {
		t.Fatalf("empty evidence ref: got %q, want \"\"", got)
	}
}

// ---------------------------------------------------------------------------
// C — write path
// ---------------------------------------------------------------------------

func identityBearingObservation() model.Observation {
	return model.Observation{
		ID:               "obs-identity-1",
		Timestamp:        time.Unix(1_700_000_000, 0).UTC(),
		Layer:            model.LayerIdentityAuth,
		Fidelity:         model.FidelityStrong,
		Source:           "k8s-audit",
		Confidence:       0.9,
		ActorHint:        "system:serviceaccount:prod:payments",
		ActorID:          "actor-1",
		PrincipalID:      "principal-1",
		SessionID:        "session-1",
		ImpersonatedUser: "alice@corp.internal",
		RawEvidenceRef:   "https://audit.internal/records/42",
		Description:      "impersonated request",
		DelegationDepth:  2,
		Labels:           map[string]string{"namespace": "prod", "verb": "create"},
	}
}

func TestFrostDBStore_V2_WriteDropsCleartextIdentity(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	in := identityBearingObservation()
	if err := s.Append(context.Background(), []model.Observation{in}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	out, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("got %d rows, want 1", len(out))
	}
	got := out[0]

	for name, value := range map[string]string{
		"ActorHint":        got.ActorHint,
		"ActorID":          got.ActorID,
		"PrincipalID":      got.PrincipalID,
		"SessionID":        got.SessionID,
		"ImpersonatedUser": got.ImpersonatedUser,
		"RawEvidenceRef":   got.RawEvidenceRef,
	} {
		if value != "" {
			t.Errorf("%s round-tripped as %q; the v2 segment must not carry it", name, value)
		}
	}

	p := s.Pseudonymiser()
	wantActorHint, _ := p.Pseudonym(in.ActorHint)
	if got.HMACActorHint != wantActorHint {
		t.Errorf("HMACActorHint = %q, want %q", got.HMACActorHint, wantActorHint)
	}
	wantImpersonated, _ := p.Pseudonym(in.ImpersonatedUser)
	if got.HMACImpersonatedUser != wantImpersonated {
		t.Errorf("HMACImpersonatedUser = %q, want %q", got.HMACImpersonatedUser, wantImpersonated)
	}
	wantEvidence, _ := p.EvidenceRefDigest(in.RawEvidenceRef)
	if got.EvidenceRefDigest != wantEvidence {
		t.Errorf("EvidenceRefDigest = %q, want %q", got.EvidenceRefDigest, wantEvidence)
	}
	if got.SchemaVersion != SegmentSchemaV2 {
		t.Errorf("SchemaVersion = %q, want %q", got.SchemaVersion, SegmentSchemaV2)
	}
	if got.Description != in.Description || got.Labels["namespace"] != "prod" {
		t.Error("non-identifier payload did not survive the round trip")
	}
}

// TestFrostDBStore_V2_AbsentIdentifierStaysAbsent guards against hashing "" into a constant.
func TestFrostDBStore_V2_AbsentIdentifierStaysAbsent(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	obs := model.Observation{
		ID: "obs-anon", Timestamp: time.Unix(1_700_000_100, 0).UTC(),
		Layer: model.LayerNetworkEgress, Fidelity: model.FidelitySuggestive, Source: "netflow",
	}
	if err := s.Append(context.Background(), []model.Observation{obs}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	out, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("got %d rows, want 1", len(out))
	}
	if out[0].HMACActorHint != "" {
		t.Fatalf("an observation with no actor_hint got pseudonym %q; a constant digest on every "+
			"identity-free row is a join key linking all of them", out[0].HMACActorHint)
	}
}

// TestFrostDBStore_V2_ActorPushdownStillMatches proves the query seam survived the column move.
func TestFrostDBStore_V2_ActorPushdownStillMatches(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	in := identityBearingObservation()
	if err := s.Append(context.Background(), []model.Observation{in}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	hit, err := s.QueryRange(context.Background(), Query{ActorID: in.ActorHint})
	if err != nil {
		t.Fatalf("QueryRange(match): %v", err)
	}
	if len(hit) != 1 {
		t.Fatalf("filtering by the cleartext actor must still match its own row: got %d rows", len(hit))
	}

	miss, err := s.QueryRange(context.Background(), Query{ActorID: "system:serviceaccount:prod:other"})
	if err != nil {
		t.Fatalf("QueryRange(miss): %v", err)
	}
	if len(miss) != 0 {
		t.Fatalf("non-matching actor returned %d rows", len(miss))
	}
}

// TestBuildFilter_UsesPseudonymAndFailsClosed checks the predicate literal is never cleartext.
func TestBuildFilter_UsesPseudonymAndFailsClosed(t *testing.T) {
	p := testPseudonymiser(t)
	const actor = "system:serviceaccount:prod:payments"

	expr, err := buildFilter(Query{ActorID: actor}, p)
	if err != nil {
		t.Fatalf("buildFilter: %v", err)
	}
	rendered := expr.String()
	if strings.Contains(rendered, actor) {
		t.Fatalf("filter expression leaks the cleartext identifier: %s", rendered)
	}
	want, _ := p.Pseudonym(actor)
	if !strings.Contains(rendered, want) {
		t.Fatalf("filter expression does not carry the pseudonym %q: %s", want, rendered)
	}
	if !strings.Contains(rendered, ColHMACActorHint) {
		t.Fatalf("filter must target %s: %s", ColHMACActorHint, rendered)
	}

	if _, err := buildFilter(Query{ActorID: actor}, nil); !errors.Is(err, ErrSegmentPseudonymKeyRequired) {
		t.Fatalf("filtering by actor with no pseudonymiser must refuse, got %v", err)
	}
	// A query with no actor predicate needs no key.
	if _, err := buildFilter(Query{After: time.Unix(1, 0)}, nil); err != nil {
		t.Fatalf("non-actor filter must not require a pseudonymiser: %v", err)
	}
}

func TestValidateFilterColumns_RequiresPseudonymColumn(t *testing.T) {
	if err := validateFilterColumns(schemaDef()); err != nil {
		t.Fatalf("v2 schema must satisfy the pushdown column contract: %v", err)
	}
	if colActorHint != ColHMACActorHint {
		t.Fatalf("pushdown column is %q, want %q — filtering on the removed cleartext column "+
			"would match nothing in a v2 segment", colActorHint, ColHMACActorHint)
	}
}

// ---------------------------------------------------------------------------
// D — label allow-list
// ---------------------------------------------------------------------------

func TestLabelAllowList_RefusesIdentifierKeys(t *testing.T) {
	forbidden := []string{
		"user", "username", "email", "sub", "subject", "caller", "ip",
		"src_ip", "actor", "principal", "client_id", "upn", "mail", "phone",
	}
	for _, k := range forbidden {
		if IsAllowedLabelKey(k) {
			t.Errorf("label key %q is allowed; it can carry a direct identifier into an immutable segment", k)
		}
	}
	for _, k := range DefaultLabelAllowListKeys() {
		if !IsAllowedLabelKey(k) {
			t.Errorf("declared allow-list key %q is not allowed by IsAllowedLabelKey", k)
		}
	}
	if len(DefaultLabelAllowListKeys()) == 0 {
		t.Fatal("allow-list is empty; the label key space would be unbounded")
	}
}

// TestLabelAllowList_RefusalPrecedesAnySegmentWrite is the deliverable's real claim: a rejected
// label must never reach a segment, not merely be filtered out of a query result.
func TestLabelAllowList_RefusalPrecedesAnySegmentWrite(t *testing.T) {
	dir := t.TempDir()
	s, err := NewFrostDBStoreWithBucket(dir, WithManualFlush())
	if err != nil {
		t.Fatalf("NewFrostDBStoreWithBucket: %v", err)
	}
	defer s.Close()

	bad := identityBearingObservation()
	bad.Labels = map[string]string{"namespace": "prod", "email": "alice@corp.internal"}

	err = s.Append(context.Background(), []model.Observation{bad})
	if err == nil {
		t.Fatal("Append accepted a disallowed label key")
	}
	var dErr *DisallowedLabelKeyError
	if !errors.As(err, &dErr) {
		t.Fatalf("got %T (%v), want *DisallowedLabelKeyError", err, err)
	}
	if dErr.Key != "email" {
		t.Errorf("error names key %q, want \"email\"", dErr.Key)
	}
	if !strings.Contains(err.Error(), "email") {
		t.Errorf("error message must name the offending key: %q", err.Error())
	}

	rows, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("a refused batch left %d rows in the table", len(rows))
	}

	// Nothing reached the bucket either.
	var parquet []string
	_ = filepath.Walk(dir, func(path string, info os.FileInfo, _ error) error {
		if info != nil && !info.IsDir() && strings.HasSuffix(path, ".parquet") {
			parquet = append(parquet, path)
		}
		return nil
	})
	if len(parquet) != 0 {
		t.Fatalf("a refused batch produced Parquet files: %v", parquet)
	}
}

func TestLabelAllowList_RejectsWholeBatch(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	good := identityBearingObservation()
	good.ID = "obs-good"
	bad := identityBearingObservation()
	bad.ID = "obs-bad"
	bad.Labels = map[string]string{"caller": "bob@corp.internal"}

	if err := s.Append(context.Background(), []model.Observation{good, bad}); err == nil {
		t.Fatal("a batch containing one disallowed key must be refused whole")
	}
	rows, _ := s.QueryRange(context.Background(), Query{})
	if len(rows) != 0 {
		t.Fatalf("partial batch landed: %d rows", len(rows))
	}
}

func TestLabelAllowList_EmptySetIsRefusalNotPermitAll(t *testing.T) {
	if _, err := NewFrostDBStore(WithLabelAllowList(nil)); !errors.Is(err, ErrLabelAllowListEmpty) {
		t.Errorf("nil allow-list: got %v, want ErrLabelAllowListEmpty", err)
	}
	if _, err := NewFrostDBStore(WithLabelAllowList(map[string]struct{}{})); !errors.Is(err, ErrLabelAllowListEmpty) {
		t.Errorf("empty allow-list: got %v, want ErrLabelAllowListEmpty", err)
	}
}

func TestLabelAllowList_OperatorSuppliedSetIsHonoured(t *testing.T) {
	s, err := NewFrostDBStore(WithLabelAllowList(map[string]struct{}{"only_this": {}}))
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	obs := identityBearingObservation()
	obs.Labels = map[string]string{"only_this": "yes"}
	if err := s.Append(context.Background(), []model.Observation{obs}); err != nil {
		t.Fatalf("allowed key refused: %v", err)
	}
	obs.Labels = map[string]string{"namespace": "prod"} // in the default set, not in this one
	if err := s.Append(context.Background(), []model.Observation{obs}); err == nil {
		t.Fatal("operator-supplied allow-list did not replace the default set")
	}
}

// ---------------------------------------------------------------------------
// E — mixed corpus readback
// ---------------------------------------------------------------------------

// buildV1Record synthesises a record in the pre-SLDP-P3-1 column layout.
//
// A v1 segment cannot be produced by this build any more — the writer only emits v2 — so the
// historical shape is reconstructed here directly. That is the point: after this card the bucket
// holds both generations forever, because a signed segment can never be rewritten.
func buildV1Record(t *testing.T, o model.Observation) arrow.Record {
	t.Helper()
	schema := arrow.NewSchema([]arrow.Field{
		{Name: "actor_hint", Type: arrow.BinaryTypes.String},
		{Name: "actor_id", Type: arrow.BinaryTypes.String},
		{Name: "description", Type: arrow.BinaryTypes.String},
		{Name: "id", Type: arrow.BinaryTypes.String},
		{Name: "impersonated_user", Type: arrow.BinaryTypes.String},
		{Name: "layer", Type: arrow.BinaryTypes.String},
		{Name: "principal_id", Type: arrow.BinaryTypes.String},
		{Name: "raw_evidence_ref", Type: arrow.BinaryTypes.String},
		{Name: "session_id", Type: arrow.BinaryTypes.String},
		{Name: "timestamp", Type: arrow.PrimitiveTypes.Int64},
	}, nil)
	b := array.NewRecordBuilder(memory.NewGoAllocator(), schema)
	defer b.Release()
	b.Field(0).(*array.StringBuilder).Append(o.ActorHint)
	b.Field(1).(*array.StringBuilder).Append(o.ActorID)
	b.Field(2).(*array.StringBuilder).Append(o.Description)
	b.Field(3).(*array.StringBuilder).Append(o.ID)
	b.Field(4).(*array.StringBuilder).Append(o.ImpersonatedUser)
	b.Field(5).(*array.StringBuilder).Append(string(o.Layer))
	b.Field(6).(*array.StringBuilder).Append(o.PrincipalID)
	b.Field(7).(*array.StringBuilder).Append(o.RawEvidenceRef)
	b.Field(8).(*array.StringBuilder).Append(o.SessionID)
	b.Field(9).(*array.Int64Builder).Append(o.Timestamp.UnixNano())
	return b.NewRecord()
}

func buildV2Record(t *testing.T, o model.Observation, p *SegmentPseudonymiser) arrow.Record {
	t.Helper()
	schema := arrow.NewSchema([]arrow.Field{
		{Name: "description", Type: arrow.BinaryTypes.String},
		{Name: ColEvidenceRefDigest, Type: arrow.BinaryTypes.String},
		{Name: ColHMACActorHint, Type: arrow.BinaryTypes.String},
		{Name: ColHMACImpersonatedUser, Type: arrow.BinaryTypes.String},
		{Name: "id", Type: arrow.BinaryTypes.String},
		{Name: "layer", Type: arrow.BinaryTypes.String},
		{Name: SegmentSchemaVersionColumn, Type: arrow.BinaryTypes.String},
		{Name: "timestamp", Type: arrow.PrimitiveTypes.Int64},
	}, nil)
	b := array.NewRecordBuilder(memory.NewGoAllocator(), schema)
	defer b.Release()
	ah, _ := p.Pseudonym(o.ActorHint)
	iu, _ := p.Pseudonym(o.ImpersonatedUser)
	er, _ := p.EvidenceRefDigest(o.RawEvidenceRef)
	b.Field(0).(*array.StringBuilder).Append(o.Description)
	b.Field(1).(*array.StringBuilder).Append(er)
	b.Field(2).(*array.StringBuilder).Append(ah)
	b.Field(3).(*array.StringBuilder).Append(iu)
	b.Field(4).(*array.StringBuilder).Append(o.ID)
	b.Field(5).(*array.StringBuilder).Append(string(o.Layer))
	b.Field(6).(*array.StringBuilder).Append(SegmentSchemaV2)
	b.Field(7).(*array.Int64Builder).Append(o.Timestamp.UnixNano())
	return b.NewRecord()
}

func TestMixedCorpus_BothGenerationsDecode(t *testing.T) {
	p := testPseudonymiser(t)

	legacy := identityBearingObservation()
	legacy.ID = "obs-v1"
	modern := identityBearingObservation()
	modern.ID = "obs-v2"

	v1 := buildV1Record(t, legacy)
	defer v1.Release()
	v2 := buildV2Record(t, modern, p)
	defer v2.Release()

	if got := SegmentSchemaOf(v1); got != SegmentSchemaV1 {
		t.Errorf("SegmentSchemaOf(v1 record) = %q, want %q", got, SegmentSchemaV1)
	}
	if got := SegmentSchemaOf(v2); got != SegmentSchemaV2 {
		t.Errorf("SegmentSchemaOf(v2 record) = %q, want %q", got, SegmentSchemaV2)
	}

	// One corpus, both generations — the steady state after this card.
	var corpus []model.Observation
	corpus = append(corpus, recordToObservations(v1)...)
	corpus = append(corpus, recordToObservations(v2)...)

	if len(corpus) != 2 {
		t.Fatalf("mixed corpus decoded %d rows, want 2", len(corpus))
	}

	old, recent := corpus[0], corpus[1]

	if old.SchemaVersion != SegmentSchemaV1 {
		t.Errorf("v1 row SchemaVersion = %q, want %q", old.SchemaVersion, SegmentSchemaV1)
	}
	if old.ActorHint != legacy.ActorHint {
		t.Errorf("historical segment must remain queryable: ActorHint = %q, want %q", old.ActorHint, legacy.ActorHint)
	}
	if old.RawEvidenceRef != legacy.RawEvidenceRef || old.ImpersonatedUser != legacy.ImpersonatedUser {
		t.Error("v1 row lost cleartext fields the historical segment actually contains")
	}
	if old.HMACActorHint != "" {
		t.Errorf("v1 row invented a pseudonym: %q", old.HMACActorHint)
	}

	if recent.SchemaVersion != SegmentSchemaV2 {
		t.Errorf("v2 row SchemaVersion = %q, want %q", recent.SchemaVersion, SegmentSchemaV2)
	}
	if recent.ActorHint != "" || recent.ImpersonatedUser != "" || recent.RawEvidenceRef != "" {
		t.Error("v2 row carried cleartext identity out of a segment that does not contain it")
	}
	wantAH, _ := p.Pseudonym(modern.ActorHint)
	if recent.HMACActorHint != wantAH {
		t.Errorf("v2 row HMACActorHint = %q, want %q", recent.HMACActorHint, wantAH)
	}
}

func TestMatchesQuery_IsGenerationAware(t *testing.T) {
	p := testPseudonymiser(t)
	const actor = "system:serviceaccount:prod:payments"
	pseu, _ := p.Pseudonym(actor)

	v1Row := model.Observation{SchemaVersion: SegmentSchemaV1, ActorHint: actor}
	v2Row := model.Observation{SchemaVersion: SegmentSchemaV2, HMACActorHint: pseu}
	other := model.Observation{SchemaVersion: SegmentSchemaV2, HMACActorHint: "deadbeef"}

	q := Query{ActorID: actor}
	if !matchesQuery(v1Row, q, p) {
		t.Error("oracle missed a v1 row that the cleartext column matches")
	}
	if !matchesQuery(v2Row, q, p) {
		t.Error("oracle missed a v2 row that the pseudonym column matches")
	}
	if matchesQuery(other, q, p) {
		t.Error("oracle matched an unrelated v2 row")
	}
}

// mustPseudonym is the test-side shorthand for the keyed pseudonym of a cleartext identifier.
func mustPseudonym(t *testing.T, value string) string {
	t.Helper()
	out, err := testPseudonymiser(t).Pseudonym(value)
	if err != nil {
		t.Fatalf("Pseudonym(%q): %v", value, err)
	}
	return out
}

// TestFrostDBStore_V2_DescriptionIsRedactedAtTheChokepoint asserts the PAYLOAD, not the schema.
//
// Every other test in this file inspects column names, and all of them passed while
// `POST /api/v1/observations` could still put an attacker-supplied email address and source IP into
// a signed, unerasable segment through the free-text description. A schema-level assertion is
// structurally blind to that. This one writes a hostile description through the store — not through
// any collector — and reads the persisted row back.
func TestFrostDBStore_V2_DescriptionIsRedactedAtTheChokepoint(t *testing.T) {
	s, err := NewFrostDBStore()
	if err != nil {
		t.Fatalf("NewFrostDBStore: %v", err)
	}
	defer s.Close()

	obs := model.Observation{
		ID: "obs-hostile", Timestamp: time.Unix(1_700_000_200, 0).UTC(),
		Layer: model.LayerIdentityAuth, Fidelity: model.FidelityStrong, Source: "http-api",
		Description: "denied for alice@corp.internal from 10.0.0.5 acting as " +
			"system:serviceaccount:prod:payments",
	}
	if err := s.Append(context.Background(), []model.Observation{obs}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	out, err := s.QueryRange(context.Background(), Query{})
	if err != nil {
		t.Fatalf("QueryRange: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("got %d rows, want 1", len(out))
	}

	got := out[0].Description
	for _, leaked := range []string{
		"alice@corp.internal",
		"10.0.0.5",
		"system:serviceaccount:prod:payments",
	} {
		if strings.Contains(got, leaked) {
			t.Errorf("identifier %q reached an immutable segment through description: %q", leaked, got)
		}
	}
	if !strings.Contains(got, "denied for") {
		t.Errorf("redaction destroyed the non-identifier context: %q", got)
	}
}
