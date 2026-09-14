package tombstone

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// goodRequest is the canonical valid mint input. Tests mutate one field at a time from here, so a
// failure names exactly one variable.
func goodRequest() MintRequest {
	return MintRequest{
		TenantID:           "tenant-alpha",
		SubjectID:          "spiffe://cluster.local/ns/payments/sa/ledger-agent",
		RequestID:          "req-2026-09-14-0001",
		PolicyBasis:        BasisArticle17_1,
		ErasedAt:           time.Date(2026, 9, 14, 11, 22, 33, 123456789, time.UTC),
		KeyGenerationFirst: 41,
		KeyGenerationLast:  43,
		KeysDestroyed:      3,
		BucketPopulation:   64,
		OperationID:        "0f7c1b2a3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8",
		ReceiptSchema:      "signalloom.key-destruction-receipt/v1",
		ReceiptDigest:      "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b",
	}
}

func goodReceiptFor(req MintRequest, ts Tombstone) privacy.KeyDestructionReceipt {
	return privacy.KeyDestructionReceipt{
		SubjectID:     req.SubjectID,
		TenantID:      req.TenantID,
		KeysRemoved:   req.KeysDestroyed,
		DestroyedAt:   req.ErasedAt,
		OperationID:   req.OperationID,
		ReceiptSchema: req.ReceiptSchema,
		ReceiptDigest: req.ReceiptDigest,
		ReceiptNonce:  ts.ReceiptNonce,
	}
}

func mustMint(t *testing.T, req MintRequest) (Tombstone, ConfirmationKey) {
	t.Helper()
	ts, key, err := Mint(req)
	if err != nil {
		t.Fatalf("Mint: unexpected error: %v", err)
	}
	return ts, key
}

// ---------------------------------------------------------------------------------------------
// A. Schema shape
// ---------------------------------------------------------------------------------------------

// TestTombstoneAllowListMatchesStruct is the schema's closure gate. It fails in BOTH directions,
// so a field added to Tombstone without an AllowedFields entry fails, and an AllowedFields entry
// with no struct field fails too.
func TestTombstoneAllowListMatchesStruct(t *testing.T) {
	got := DocumentFields()
	if len(got) != len(AllowedFields) {
		t.Fatalf("Tombstone has %d json fields but AllowedFields has %d entries\n  struct: %v\n  allow:  %v",
			len(got), len(AllowedFields), got, AllowedFields)
	}
	inAllow := map[string]bool{}
	for _, f := range AllowedFields {
		inAllow[f] = true
	}
	for _, f := range got {
		if !inAllow[f] {
			t.Errorf("Tombstone field %q is not in AllowedFields: a new field must be justified against the three linkage mechanisms before it is added", f)
		}
	}
	inStruct := map[string]bool{}
	for _, f := range got {
		inStruct[f] = true
	}
	for _, f := range AllowedFields {
		if !inStruct[f] {
			t.Errorf("AllowedFields names %q but Tombstone has no such field", f)
		}
	}
}

// TestTombstoneStructHasNoForbiddenFieldNames runs the shared guard over the real struct.
func TestTombstoneStructHasNoForbiddenFieldNames(t *testing.T) {
	if bad := FieldNameViolations(DocumentFields()); len(bad) > 0 {
		t.Fatalf("Tombstone carries forbidden field names: %v", bad)
	}
	if bad := FieldNameViolations(AllowedFields); len(bad) > 0 {
		t.Fatalf("AllowedFields carries forbidden names: %v", bad)
	}
}

// TestTombstoneForbiddenFieldGuardActuallyFires is the positive control for the guard above.
//
// Without it, FieldNameViolations returning nothing is indistinguishable from FieldNameViolations
// doing nothing. Each case names a field the way a well-meaning future card would name it.
func TestTombstoneForbiddenFieldGuardActuallyFires(t *testing.T) {
	cases := []struct{ name, field string }{
		{"cleartext subject", "subject_id"},
		{"keyed pseudonym", "subject_pseudonym"},
		{"actor hint", "hmac_actor_hint"},
		{"request binding", "request_id"},
		{"approver names", "approver_ids"},
		{"operator names", "operator_id"},
		{"network address token", "src_ip"},
		{"workload identity", "spiffe_id"},
		{"contact", "data_subject_email"},
		{"host", "host"},
		{"generic identifier", "external_identifier"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if bad := FieldNameViolations([]string{c.field}); len(bad) == 0 {
				t.Fatalf("guard did not fire on %q — the guard is not doing anything", c.field)
			}
		})
	}
}

// TestTombstoneHasNoTimeField enforces the type-level defence against nanosecond timestamps.
func TestTombstoneHasNoTimeField(t *testing.T) {
	rt := reflect.TypeOf(Tombstone{})
	timeType := reflect.TypeOf(time.Time{})
	for i := 0; i < rt.NumField(); i++ {
		if rt.Field(i).Type == timeType {
			t.Fatalf("Tombstone.%s is a time.Time; it marshals to RFC3339Nano and is a join key against the erasure audit trail", rt.Field(i).Name)
		}
	}
}

// TestTombstoneValidateDocumentRejectsExtraField proves the runtime allow-list rejects a smuggled
// key even when the struct is clean — the case where a document arrives from another build.
func TestTombstoneValidateDocumentRejectsExtraField(t *testing.T) {
	ts, _ := mustMint(t, goodRequest())
	raw, err := json.Marshal(ts)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	doc["subject_pseudonym"] = json.RawMessage(`"deadbeef"`)
	tampered, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("remarshal: %v", err)
	}
	if err := ValidateDocument(tampered); !errors.Is(err, ErrForbiddenField) {
		t.Fatalf("ValidateDocument accepted a smuggled field, err=%v", err)
	}
}

// TestTombstoneValidateDocumentRejectsMissingField proves the other direction: dropping the
// confirmation commitment "to tidy up" is refused, because it would silently remove the only
// auditability the design has.
func TestTombstoneValidateDocumentRejectsMissingField(t *testing.T) {
	ts, _ := mustMint(t, goodRequest())
	raw, _ := json.Marshal(ts)
	var doc map[string]json.RawMessage
	_ = json.Unmarshal(raw, &doc)
	delete(doc, "confirmation_commitment")
	trimmed, _ := json.Marshal(doc)
	if err := ValidateDocument(trimmed); !errors.Is(err, ErrMissingField) {
		t.Fatalf("ValidateDocument accepted a document missing confirmation_commitment, err=%v", err)
	}
}

// TestTombstoneValidateDocumentAcceptsAGenuineDocument is the negative control for the two above.
func TestTombstoneValidateDocumentAcceptsAGenuineDocument(t *testing.T) {
	ts, _ := mustMint(t, goodRequest())
	raw, _ := json.Marshal(ts)
	if err := ValidateDocument(raw); err != nil {
		t.Fatalf("ValidateDocument rejected a genuine document: %v", err)
	}
}

// ---------------------------------------------------------------------------------------------
// B. Coarse timestamp and the population-size check
// ---------------------------------------------------------------------------------------------

func TestTombstoneCoarsenDay(t *testing.T) {
	shape := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

	base := time.Date(2026, 9, 14, 23, 59, 59, 999999998, time.UTC)
	if got := CoarsenDay(base); !shape.MatchString(got) {
		t.Fatalf("CoarsenDay produced %q, want YYYY-MM-DD", got)
	}
	// One nanosecond apart, same UTC day.
	if a, b := CoarsenDay(base), CoarsenDay(base.Add(time.Nanosecond)); a != b {
		t.Fatalf("two instants 1ns apart within a day coarsened differently: %q vs %q", a, b)
	}
	// One nanosecond apart, across UTC midnight.
	edge := time.Date(2026, 9, 14, 23, 59, 59, 999999999, time.UTC)
	if a, b := CoarsenDay(edge), CoarsenDay(edge.Add(time.Nanosecond)); a == b {
		t.Fatalf("instants either side of UTC midnight coarsened identically: %q", a)
	}
	// Non-UTC input is converted before truncation. 00:30 on the 15th in +05:00 is still the 14th
	// in UTC; coarsening in local time would put it in the wrong bucket.
	zone := time.FixedZone("plus5", 5*3600)
	local := time.Date(2026, 9, 15, 0, 30, 0, 0, zone)
	if got, want := CoarsenDay(local), "2026-09-14"; got != want {
		t.Fatalf("CoarsenDay(%s) = %q, want %q — the instant must be converted to UTC before truncation", local, got, want)
	}
}

// TestTombstonePopulationCheck is the k-anonymity gate, exercised across its whole boundary.
//
// The boundary cases are the point. A mutation that turns `<` into `<=` flips the
// BucketPopulation==MinAnonymitySet row; a mutation that deletes the zero check flips the first
// row. Neither survives.
func TestTombstonePopulationCheck(t *testing.T) {
	if MinAnonymitySet < 5 {
		t.Fatalf("MinAnonymitySet is %d; a floor below 5 is not a small-cell suppression threshold", MinAnonymitySet)
	}
	cases := []struct {
		name       string
		population int
		wantErr    error
	}{
		{"unset is refused, not defaulted", 0, ErrPopulationUnknown},
		{"negative is refused", -1, ErrInvalidRequest},
		{"one below the floor", MinAnonymitySet - 1, ErrAnonymitySetTooSmall},
		{"a singleton cohort identifies by elimination", 1, ErrAnonymitySetTooSmall},
		{"exactly at the floor is permitted", MinAnonymitySet, nil},
		{"comfortably above the floor", MinAnonymitySet * 20, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := goodRequest()
			req.BucketPopulation = c.population
			ts, _, err := Mint(req)
			switch {
			case c.wantErr == nil && err != nil:
				t.Fatalf("Mint(population=%d) refused: %v", c.population, err)
			case c.wantErr != nil && !errors.Is(err, c.wantErr):
				t.Fatalf("Mint(population=%d) err=%v, want %v", c.population, err, c.wantErr)
			}
			if c.wantErr != nil {
				if ts != (Tombstone{}) {
					t.Fatalf("a refused mint returned a non-zero tombstone; a caller ignoring the error would publish it")
				}
				if !strings.Contains(err.Error(), fmt.Sprintf("%d", c.population)) && c.population != 0 {
					t.Errorf("refusal does not name the observed population %d: %v", c.population, err)
				}
			}
		})
	}
}

// TestTombstonePublishesThresholdNotMeasurement guards the distinction that makes the field safe.
func TestTombstonePublishesThresholdNotMeasurement(t *testing.T) {
	req := goodRequest()
	req.BucketPopulation = 8123 // deliberately distinctive
	ts, _ := mustMint(t, req)
	if ts.AnonymitySetMin != MinAnonymitySet {
		t.Fatalf("AnonymitySetMin = %d, want the constant %d", ts.AnonymitySetMin, MinAnonymitySet)
	}
	raw, _ := json.Marshal(ts)
	if strings.Contains(string(raw), "8123") {
		t.Fatalf("the observed bucket population leaked into the document: %s", raw)
	}
}

// ---------------------------------------------------------------------------------------------
// C. Receipt commitment
// ---------------------------------------------------------------------------------------------

// TestTombstoneReceiptProjectionHasNoSubject asserts the projection type cannot acquire a subject
// field, by reflection over its names rather than by reading it.
func TestTombstoneReceiptProjectionHasNoSubject(t *testing.T) {
	rt := reflect.TypeOf(ReceiptProjection{})
	var names []string
	for i := 0; i < rt.NumField(); i++ {
		names = append(names, rt.Field(i).Name, rt.Field(i).Tag.Get("json"))
	}
	if bad := FieldNameViolations(names); len(bad) > 0 {
		t.Fatalf("ReceiptProjection carries identifying fields %v — the commitment domain must have no subject in it", bad)
	}
}

// TestTombstoneProjectReceiptDropsSubject drives the real privacy.KeyDestructionReceipt through
// the projection and asserts the subject does not survive. This is the compile-checked contract
// with SLDP-P4-1.
func TestTombstoneProjectReceiptDropsSubject(t *testing.T) {
	const subject = "spiffe://cluster.local/ns/payments/sa/ledger-agent"
	receipt := privacy.KeyDestructionReceipt{
		SubjectID:   subject,
		TenantID:    "tenant-alpha",
		KeysRemoved: 3,
		DestroyedAt: time.Date(2026, 9, 14, 11, 22, 33, 123456789, time.UTC),
	}
	p := ProjectReceipt(receipt, 41, 43)
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal projection: %v", err)
	}
	if strings.Contains(string(raw), subject) {
		t.Fatalf("projection carried the subject: %s", raw)
	}
	if strings.Contains(string(raw), "123456789") {
		t.Fatalf("projection carried nanosecond precision: %s", raw)
	}
	if p.KeysDestroyedBand != "2-5" {
		t.Fatalf("KeysDestroyedBand = %q, want the band for 3 keys", p.KeysDestroyedBand)
	}
	if p.KeyGenerationFirst != 1 || p.KeyGenerationLast != GenerationEpochSize {
		t.Fatalf("projection generation range [%d,%d] is not epoch-coarsened", p.KeyGenerationFirst, p.KeyGenerationLast)
	}
	if p.DestroyedDay != "2026-09-14" {
		t.Fatalf("DestroyedDay = %q, want the coarse day", p.DestroyedDay)
	}
}

// TestTombstoneProjectionIsASubsetOfPublishedFields enforces the property the receipt commitment
// actually depends on.
//
// The nonce is published, so the commitment is binding but not hiding: anyone can recompute
// SHA-256(nonce || candidate) and confirm a guess. That is harmless only while every projection
// field is already public. One unpublished low-entropy field would turn the published nonce into an
// enumeration oracle for it — a strictly weaker failure than a subject digest but the same shape,
// and "the projection contains no subject" does not rule it out.
func TestTombstoneProjectionIsASubsetOfPublishedFields(t *testing.T) {
	published := map[string]bool{}
	for _, f := range AllowedFields {
		published[f] = true
	}
	rt := reflect.TypeOf(ReceiptProjection{})
	for i := 0; i < rt.NumField(); i++ {
		tag, _, _ := strings.Cut(rt.Field(i).Tag.Get("json"), ",")
		if !published[tag] {
			t.Errorf("ReceiptProjection.%s marshals as %q, which is not a published tombstone field; the published nonce makes it enumerable",
				rt.Field(i).Name, tag)
		}
	}
	req := goodRequest()
	ts, _ := mustMint(t, req)
	if !VerifyReceiptCommitment(ts, goodReceiptFor(req, ts)) {
		t.Fatal("the commitment does not verify against matching receipt")
	}
}

// TestTombstoneKeysDestroyedIsBanded proves the exact count never reaches the document.
//
// k enforced over (tenant, day) is defeated by any unbucketed attribute that re-splits the bucket.
// A key count is precisely that, and retained segment rows let an adversary estimate it from
// activity volume.
func TestTombstoneKeysDestroyedIsBanded(t *testing.T) {
	cases := []struct {
		n    int
		want string
	}{
		{0, "0"}, {1, "1"}, {2, "2-5"}, {5, "2-5"}, {6, "6-20"}, {20, "6-20"}, {21, "21+"}, {4096, "21+"},
	}
	for _, c := range cases {
		if got := BandKeysDestroyed(c.n); got != c.want {
			t.Errorf("BandKeysDestroyed(%d) = %q, want %q", c.n, got, c.want)
		}
	}
	// Distinct counts inside one band must publish the same band, which is what makes it a
	// generalisation rather than a relabelling.
	req := goodRequest()
	req.KeysDestroyed = 3
	a, _ := mustMint(t, req)
	req.KeysDestroyed = 5
	b, _ := mustMint(t, req)
	if a.KeysDestroyedBand != b.KeysDestroyedBand {
		t.Fatalf("counts 3 and 5 published different bands: %q vs %q", a.KeysDestroyedBand, b.KeysDestroyedBand)
	}
	raw, _ := json.Marshal(a)
	if strings.Contains(string(raw), `"keys_destroyed"`) {
		t.Errorf("the exact-count field is still present: %s", raw)
	}
	if strings.Contains(string(raw), ":3,") || strings.Contains(string(raw), ":3}") {
		t.Errorf("the exact key count leaked into the document: %s", raw)
	}
}

// TestTombstoneGenerationRangeIsEpochCoarsened proves the published range carries no enrolment
// rank, no rotation cadence and no population estimate.
func TestTombstoneGenerationRangeIsEpochCoarsened(t *testing.T) {
	lo, hi := CoarsenGenerationRange(41, 43)
	if lo != 1 || hi != GenerationEpochSize {
		t.Fatalf("CoarsenGenerationRange(41,43) = [%d,%d], want [1,%d]", lo, hi, GenerationEpochSize)
	}
	if l, h := CoarsenGenerationRange(0, 5); l != 0 || h != 0 {
		t.Errorf("CoarsenGenerationRange(0,5) = [%d,%d], want the zero range", l, h)
	}
	if l, h := CoarsenGenerationRange(9, 2); l != 0 || h != 0 {
		t.Errorf("CoarsenGenerationRange(9,2) = [%d,%d], want the zero range", l, h)
	}
	if l, h := CoarsenGenerationRange(999, 1001); l != 1 || h != 2*GenerationEpochSize {
		t.Errorf("CoarsenGenerationRange(999,1001) = [%d,%d], want [1,%d]", l, h, 2*GenerationEpochSize)
	}
	// Rank erasure: two subjects enrolled at different generations inside one epoch must publish
	// identical ranges, so no ordering survives for a permutation-matching attack to exploit.
	req := goodRequest()
	req.KeyGenerationFirst, req.KeyGenerationLast = 7, 9
	a, _ := mustMint(t, req)
	req.KeyGenerationFirst, req.KeyGenerationLast = 812, 899
	b, _ := mustMint(t, req)
	if a.KeyGenerationFirst != b.KeyGenerationFirst || a.KeyGenerationLast != b.KeyGenerationLast {
		t.Fatalf("two in-epoch erasures published distinct ranges [%d,%d] vs [%d,%d]: enrolment rank survives",
			a.KeyGenerationFirst, a.KeyGenerationLast, b.KeyGenerationFirst, b.KeyGenerationLast)
	}
	// A hand-assembled, un-coarsened range must not validate.
	raw := a
	raw.KeyGenerationFirst, raw.KeyGenerationLast = 41, 43
	if err := raw.Validate(); !errors.Is(err, ErrInvalidGenerationRange) {
		t.Fatalf("Validate accepted an un-aligned range: %v", err)
	}
}

func TestTombstoneReceiptCommitmentRoundTrip(t *testing.T) {
	req := goodRequest()
	ts, _ := mustMint(t, req)
	receipt := goodReceiptFor(req, ts)
	if len(ts.ReceiptNonce) != 64 {
		t.Fatalf("ReceiptNonce is %d hex chars, want 64 (32 bytes)", len(ts.ReceiptNonce))
	}
	if !VerifyReceiptCommitment(ts, receipt) {
		t.Fatal("VerifyReceiptCommitment rejected a freshly minted tombstone")
	}

	mutated := ts
	mutated.KeysDestroyedBand = "21+"
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment survived a hand-edit of keys_destroyed_band")
	}
	mutated = ts
	mutated.KeyGenerationLast++
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment survived a hand-edit of key_generation_last")
	}
	mutated = ts
	mutated.ErasedDay = "2026-09-15"
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment survived a hand-edit of erased_day")
	}
	mutated = ts
	mutated.TenantID = "tenant-beta"
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment survived a hand-edit of tenant_id")
	}
	mutated = ts
	// Flip one nibble of the nonce.
	nonce := []byte(ts.ReceiptNonce)
	if nonce[0] == 'a' {
		nonce[0] = 'b'
	} else {
		nonce[0] = 'a'
	}
	mutated.ReceiptNonce = string(nonce)
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment survived a nonce mutation")
	}
	mutated = ts
	mutated.ReceiptNonce = "not-hex"
	if VerifyReceiptCommitment(mutated, receipt) {
		t.Error("commitment verified against an unparseable nonce")
	}

	// Mismatched receipt must also fail
	mismatchedReceipt := receipt
	mismatchedReceipt.ReceiptDigest = "0000000000000000000000000000000000000000000000000000000000000000"
	if VerifyReceiptCommitment(ts, mismatchedReceipt) {
		t.Error("commitment verified against mismatched receipt digest")
	}
}

// TestTombstoneCommitmentsAreFreshPerMint proves the randomness is real: identical input, distinct
// output. This is also what distinguishes a CSPRNG id from a derived one.
func TestTombstoneCommitmentsAreFreshPerMint(t *testing.T) {
	req := goodRequest()
	a, keyA := mustMint(t, req)
	b, keyB := mustMint(t, req)

	if a.TombstoneID == b.TombstoneID {
		t.Error("two mints from identical input share a tombstone_id — the id is derived, not random")
	}
	if a.ReceiptNonce == b.ReceiptNonce {
		t.Error("two mints share a receipt nonce")
	}
	if a.ReceiptCommitment == b.ReceiptCommitment {
		t.Error("two mints share a receipt commitment — equal commitments would cluster tombstones")
	}
	if a.ConfirmationCommitment == b.ConfirmationCommitment {
		t.Error("two mints for the same subject share a confirmation commitment — the field would be a subject selector")
	}
	if keyA == keyB {
		t.Error("two mints share a confirmation key")
	}
	if len(a.TombstoneID) != 32 {
		t.Errorf("tombstone_id is %d hex chars, want 32 (16 bytes)", len(a.TombstoneID))
	}
}

// TestTombstoneCanonicalProjectionIsDeterministic guards the commitment scheme's foundation.
func TestTombstoneCanonicalProjectionIsDeterministic(t *testing.T) {
	p := ReceiptProjection{TenantID: "t", KeysDestroyedBand: "2-5", KeyGenerationFirst: 1, KeyGenerationLast: 1000, DestroyedDay: "2026-09-14"}
	first := canonicalProjection(p, "digest-test")
	for i := 0; i < 100; i++ {
		if got := canonicalProjection(p, "digest-test"); string(got) != string(first) {
			t.Fatalf("canonicalProjection is not deterministic at iteration %d", i)
		}
	}
	// Length prefixing, not delimiter joining: ("ab","c") and ("a","bc") must differ.
	if string(canonical("d", "ab", "c")) == string(canonical("d", "a", "bc")) {
		t.Fatal("canonical() collides on a field-boundary shift; a colliding canonicalisation makes the commitment meaningless")
	}
	// Domain separation: the same inputs under two domains must not collide.
	if string(canonical(receiptCommitmentDomain, "x")) == string(canonical(confirmationDomain, "x")) {
		t.Fatal("the two commitment domains collide")
	}
}

// TestTombstoneReceiptCommitmentIsNotASubjectOracle is the direct refutation of the P4-PRE §6.2
// receipt_digest field.
//
// The adversary here is maximally advantaged: they hold the full candidate subject list, the
// tenant, every published field, and the nonce. They still cannot confirm a candidate, because the
// subject is not in the commitment's domain at all. Under the preflight's construction this test
// would pass trivially in reverse — see TestTombstoneLinkageProbeDetectsPlantedReceiptDigest.
func TestTombstoneReceiptCommitmentIsNotASubjectOracle(t *testing.T) {
	req := goodRequest()
	ts, _ := mustMint(t, req)
	nonce, err := hex.DecodeString(ts.ReceiptNonce)
	if err != nil {
		t.Fatalf("decode nonce: %v", err)
	}
	candidates := []string{req.SubjectID, "other-a", "other-b"}
	for _, candidate := range candidates {
		// Every plausible way an adversary might try to fold the candidate into the commitment.
		guesses := []string{
			ReceiptCommitment(nonce, ReceiptProjection{
				TenantID: candidate, KeysDestroyedBand: ts.KeysDestroyedBand,
				KeyGenerationFirst: ts.KeyGenerationFirst, KeyGenerationLast: ts.KeyGenerationLast,
				DestroyedDay: ts.ErasedDay,
			}, req.ReceiptDigest),
			hex.EncodeToString(sha256Sum(append(nonce, []byte(candidate)...))),
			hex.EncodeToString(sha256Sum([]byte(candidate))),
			hex.EncodeToString(sha256Sum([]byte(ts.TenantID + candidate))),
		}
		for _, g := range guesses {
			if g == ts.ReceiptCommitment {
				t.Fatalf("receipt commitment confirmed candidate %q — it is a subject oracle", candidate)
			}
		}
	}
}

func sha256Sum(b []byte) []byte {
	d := sha256.Sum256(b)
	return d[:]
}

// ---------------------------------------------------------------------------------------------
// D. Confirmation commitment — the auditability resolution
// ---------------------------------------------------------------------------------------------

// TestTombstoneConfirmSpecificErasure is the selective-disclosure truth table.
//
// One row true, four false. Each false row is a distinct way an adversary or a mistaken auditor
// could hold three of the four inputs.
func TestTombstoneConfirmSpecificErasure(t *testing.T) {
	req := goodRequest()
	ts, key := mustMint(t, req)

	_, otherKey := mustMint(t, req)

	cases := []struct {
		name                     string
		key                      ConfirmationKey
		tenant, subject, request string
		want                     bool
	}{
		{"the true triple under the true key", key, req.TenantID, req.SubjectID, req.RequestID, true},
		{"a different subject", key, req.TenantID, "someone-else", req.RequestID, false},
		{"the true subject under a different key", otherKey, req.TenantID, req.SubjectID, req.RequestID, false},
		{"a different tenant", key, "tenant-beta", req.SubjectID, req.RequestID, false},
		{"a different request id", key, req.TenantID, req.SubjectID, "req-other", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ConfirmSpecificErasure(ts, c.key, c.tenant, c.subject, c.request); got != c.want {
				t.Fatalf("ConfirmSpecificErasure = %v, want %v", got, c.want)
			}
		})
	}
}

// TestTombstoneConfirmationIsUselessWithoutTheKey is the non-linkability half of the same field.
//
// An adversary holding a thousand-strong candidate list and the full tombstone confirms nothing,
// because the commitment is a PRF output under a key the platform destroyed.
func TestTombstoneConfirmationIsUselessWithoutTheKey(t *testing.T) {
	req := goodRequest()
	ts, _ := mustMint(t, req)

	candidates := make([]string, 0, 1000)
	candidates = append(candidates, req.SubjectID) // the true subject IS in the list
	for i := 0; i < 999; i++ {
		candidates = append(candidates, fmt.Sprintf("spiffe://cluster.local/ns/payments/sa/agent-%04d", i))
	}
	var zero ConfirmationKey
	for _, c := range candidates {
		if ConfirmSpecificErasure(ts, zero, ts.TenantID, c, req.RequestID) {
			t.Fatalf("confirmed candidate %q under a zero key", c)
		}
	}
	// And the raw commitment must not equal any unkeyed digest of a candidate.
	for _, c := range candidates {
		if ts.ConfirmationCommitment == hex.EncodeToString(sha256Sum([]byte(c))) {
			t.Fatalf("confirmation commitment equals an unkeyed digest of %q", c)
		}
	}
}

// TestTombstoneConfirmationKeyIsNotSerialisable covers the three ways the key could reach storage.
func TestTombstoneConfirmationKeyIsNotSerialisable(t *testing.T) {
	ts, key := mustMint(t, goodRequest())

	disclosed := key.Disclose()
	if len(disclosed) != 64 {
		t.Fatalf("Disclose produced %d chars, want 64", len(disclosed))
	}
	raw, _ := json.Marshal(ts)
	if strings.Contains(string(raw), disclosed) {
		t.Fatal("the confirmation key appears in the marshalled tombstone")
	}
	if got := fmt.Sprintf("%v", key); strings.Contains(got, disclosed) {
		t.Fatalf("%%v on a ConfirmationKey leaked the key: %s", got)
	}
	if got := fmt.Sprintf("%s", key); strings.Contains(got, disclosed) {
		t.Fatalf("%%s on a ConfirmationKey leaked the key: %s", got)
	}
	if got := fmt.Sprintf("%#v", key); strings.Contains(got, disclosed) {
		t.Fatalf("%%#v on a ConfirmationKey leaked the key: %s", got)
	}
	if _, err := json.Marshal(key); !errors.Is(err, ErrConfirmationKeyNotSerialisable) {
		// json.Marshal wraps MarshalerError; errors.Is unwraps it.
		t.Fatalf("json.Marshal(ConfirmationKey) err = %v, want ErrConfirmationKeyNotSerialisable", err)
	}
	// Round trip through the deliberate escape hatch.
	back, err := ParseConfirmationKey(disclosed)
	if err != nil {
		t.Fatalf("ParseConfirmationKey: %v", err)
	}
	if back != key {
		t.Fatal("ParseConfirmationKey did not round-trip")
	}
	if _, err := ParseConfirmationKey("zz"); err == nil {
		t.Error("ParseConfirmationKey accepted non-hex")
	}
	if _, err := ParseConfirmationKey(hex.EncodeToString(make([]byte, 16))); err == nil {
		t.Error("ParseConfirmationKey accepted a short key")
	}
}

// ---------------------------------------------------------------------------------------------
// E. Request validation, generation range, CSPRNG failure
// ---------------------------------------------------------------------------------------------

func TestTombstoneMintRefusesInvalidRequests(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*MintRequest)
		wantErr error
	}{
		{"no tenant", func(r *MintRequest) { r.TenantID = "" }, ErrInvalidRequest},
		{"no subject", func(r *MintRequest) { r.SubjectID = "" }, ErrInvalidRequest},
		{"no request id", func(r *MintRequest) { r.RequestID = "" }, ErrInvalidRequest},
		{"empty basis", func(r *MintRequest) { r.PolicyBasis = "" }, ErrInvalidPolicyBasis},
		{"invented basis", func(r *MintRequest) { r.PolicyBasis = "article_6_1_f" }, ErrInvalidPolicyBasis},
		{"zero instant", func(r *MintRequest) { r.ErasedAt = time.Time{} }, ErrInvalidRequest},
		{"negative key count", func(r *MintRequest) { r.KeysDestroyed = -1 }, ErrInvalidRequest},
		{"unset first generation", func(r *MintRequest) { r.KeyGenerationFirst = 0 }, ErrInvalidGenerationRange},
		{"inverted range", func(r *MintRequest) { r.KeyGenerationFirst, r.KeyGenerationLast = 9, 2 }, ErrInvalidGenerationRange},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := goodRequest()
			c.mutate(&req)
			if _, _, err := Mint(req); !errors.Is(err, c.wantErr) {
				t.Fatalf("Mint err = %v, want %v", err, c.wantErr)
			}
		})
	}
}

func TestTombstoneMintAcceptsASingleGeneration(t *testing.T) {
	req := goodRequest()
	req.KeyGenerationFirst, req.KeyGenerationLast = 7, 7
	ts, _ := mustMint(t, req)
	if ts.KeyGenerationFirst != 1 || ts.KeyGenerationLast != GenerationEpochSize {
		t.Fatalf("single-generation range not coarsened to its epoch: %d..%d", ts.KeyGenerationFirst, ts.KeyGenerationLast)
	}
	if _, ok := any(ts.KeyGenerationFirst).(uint64); !ok {
		t.Fatal("KeyGenerationFirst is not uint64")
	}
}

// TestTombstoneMintFailsClosedOnCSPRNGFailure proves the mint refuses rather than falling back to
// a weak or zero value when randomness is unavailable.
func TestTombstoneMintFailsClosedOnCSPRNGFailure(t *testing.T) {
	original := randRead
	t.Cleanup(func() { randRead = original })

	sentinel := errors.New("entropy source unavailable")
	for failOn := 0; failOn < 3; failOn++ {
		calls := 0
		target := failOn
		randRead = func(b []byte) error {
			if calls == target {
				calls++
				return sentinel
			}
			calls++
			return original(b)
		}
		ts, key, err := Mint(goodRequest())
		if !errors.Is(err, sentinel) {
			t.Fatalf("draw %d: Mint err = %v, want the sentinel", failOn, err)
		}
		if ts != (Tombstone{}) {
			t.Fatalf("draw %d: refused mint returned a populated tombstone", failOn)
		}
		var zero ConfirmationKey
		if key != zero {
			t.Fatalf("draw %d: refused mint returned a populated key", failOn)
		}
	}
}

// TestTombstonePackageDocumentsTheGenerationInvariant asserts the cross-card invariant is stated
// in code, not only in a markdown file a future card might not read.
func TestTombstonePackageDocumentsTheGenerationInvariant(t *testing.T) {
	raw, err := readSource("tombstone.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	for _, needle := range []string{
		"INVARIANT FOR SLDP-P4-1",
		"tenant-scoped",
		"appear in retained evidence",
		"anchor.py:407",
		"never persisted",
	} {
		if !strings.Contains(raw, needle) {
			t.Errorf("tombstone.go does not state %q", needle)
		}
	}
}

// TestTombstoneSignerDocumentsTheForgeryLimit asserts the unanchored-signature limit is published
// in code.
func TestTombstoneSignerDocumentsTheForgeryLimit(t *testing.T) {
	raw, err := readSource("signer.go")
	if err != nil {
		t.Fatalf("read source: %v", err)
	}
	for _, needle := range []string{"anchor.py:407", "Archivista publication is optional", "backdate"} {
		if !strings.Contains(raw, needle) {
			t.Errorf("signer.go does not state %q", needle)
		}
	}
}

// ---------------------------------------------------------------------------------------------
// G. Signing authority
// ---------------------------------------------------------------------------------------------

func newTestSigner(t *testing.T) (*TombstoneSigner, ed25519.PublicKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	signer, err := NewTombstoneSignerFromPEM(block)
	if err != nil {
		t.Fatalf("NewTombstoneSignerFromPEM: %v", err)
	}
	return signer, pub
}

func TestTombstoneSignAndVerify(t *testing.T) {
	signer, pub := newTestSigner(t)
	ts, _ := mustMint(t, goodRequest())

	envelope, err := signer.Sign(ts)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	var env DSSEEnvelope
	if err := json.Unmarshal(envelope, &env); err != nil {
		t.Fatalf("parse envelope: %v", err)
	}
	if env.PayloadType != "application/vnd.in-toto+json" {
		t.Errorf("payloadType = %q", env.PayloadType)
	}
	if env.Signatures[0].KeyID != signer.KeyID() {
		t.Errorf("keyid = %q, want %q", env.Signatures[0].KeyID, signer.KeyID())
	}

	// keyID must be hex SHA-256 of the PKIX SPKI — the same rule store/segment_attestor.go uses.
	spki, _ := x509.MarshalPKIXPublicKey(pub)
	want := hex.EncodeToString(sha256Sum(spki))
	if signer.KeyID() != want {
		t.Errorf("KeyID = %q, want hex sha256 of SPKI %q", signer.KeyID(), want)
	}

	payload, _ := base64.StdEncoding.DecodeString(env.Payload)
	var statement map[string]any
	if err := json.Unmarshal(payload, &statement); err != nil {
		t.Fatalf("parse statement: %v", err)
	}
	if statement["_type"] != "https://in-toto.io/Statement/v1" {
		t.Errorf("_type = %v", statement["_type"])
	}
	if statement["predicateType"] != tombstonePredicate {
		t.Errorf("predicateType = %v", statement["predicateType"])
	}
	subjects, _ := statement["subject"].([]any)
	if len(subjects) != 1 {
		t.Fatalf("want exactly one in-toto subject, got %d", len(subjects))
	}
	name, _ := subjects[0].(map[string]any)["name"].(string)
	if !strings.Contains(name, ts.TombstoneID) {
		t.Errorf("in-toto subject name %q does not name the tombstone id", name)
	}
	if strings.Contains(name, goodRequest().SubjectID) {
		t.Fatal("the in-toto subject name carries the DATA subject — the two meanings of 'subject' have collided")
	}

	got, err := VerifyEnvelope(envelope, pub, signer.KeyID())
	if err != nil {
		t.Fatalf("VerifyEnvelope rejected a genuine envelope: %v", err)
	}
	if got != ts {
		t.Fatalf("round trip changed the tombstone:\n got %+v\nwant %+v", got, ts)
	}
}

func TestTombstoneVerifyEnvelopeRejections(t *testing.T) {
	signer, pub := newTestSigner(t)
	other, otherPub := newTestSigner(t)
	ts, _ := mustMint(t, goodRequest())
	envelope, err := signer.Sign(ts)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	t.Run("mutated payload", func(t *testing.T) {
		var env DSSEEnvelope
		_ = json.Unmarshal(envelope, &env)
		payload, _ := base64.StdEncoding.DecodeString(env.Payload)
		payload[len(payload)/2] ^= 0x01
		env.Payload = base64.StdEncoding.EncodeToString(payload)
		tampered, _ := json.Marshal(env)
		if _, err := VerifyEnvelope(tampered, pub, signer.KeyID()); err == nil {
			t.Fatal("verified a mutated payload")
		}
	})
	t.Run("signature from a different key", func(t *testing.T) {
		foreign, err := other.Sign(ts)
		if err != nil {
			t.Fatalf("Sign: %v", err)
		}
		if _, err := VerifyEnvelope(foreign, pub, ""); !errors.Is(err, ErrSignatureInvalid) {
			t.Fatalf("err = %v, want ErrSignatureInvalid", err)
		}
		// Sanity: it DOES verify under its own key, so the rejection above is about the key and
		// not about the envelope being malformed.
		if _, err := VerifyEnvelope(foreign, otherPub, other.KeyID()); err != nil {
			t.Fatalf("the foreign envelope does not verify under its own key either: %v", err)
		}
	})
	t.Run("keyid mismatch", func(t *testing.T) {
		if _, err := VerifyEnvelope(envelope, pub, other.KeyID()); !errors.Is(err, ErrKeyIDMismatch) {
			t.Fatalf("err = %v, want ErrKeyIDMismatch", err)
		}
	})
	t.Run("wrong payload type", func(t *testing.T) {
		var env DSSEEnvelope
		_ = json.Unmarshal(envelope, &env)
		env.PayloadType = "application/json"
		bad, _ := json.Marshal(env)
		if _, err := VerifyEnvelope(bad, pub, signer.KeyID()); !errors.Is(err, ErrSignatureInvalid) {
			t.Fatalf("err = %v, want ErrSignatureInvalid", err)
		}
	})
	t.Run("no signatures", func(t *testing.T) {
		var env DSSEEnvelope
		_ = json.Unmarshal(envelope, &env)
		env.Signatures = nil
		bad, _ := json.Marshal(env)
		if _, err := VerifyEnvelope(bad, pub, ""); !errors.Is(err, ErrSignatureInvalid) {
			t.Fatalf("err = %v, want ErrSignatureInvalid", err)
		}
	})
}

// TestTombstoneSigningCannotLaunderAForbiddenField proves the allow-list runs BEFORE the
// signature, so a forbidden field cannot become attested — and therefore unrewritable — evidence.
func TestTombstoneSigningCannotLaunderAForbiddenField(t *testing.T) {
	signer, pub := newTestSigner(t)
	ts, _ := mustMint(t, goodRequest())

	// A genuine envelope, re-signed around a predicate carrying a smuggled field. This models an
	// attacker or a patched build that holds the key but must still pass the reader's checks.
	statement, err := Statement(ts)
	if err != nil {
		t.Fatalf("Statement: %v", err)
	}
	predicate := statement["predicate"].(map[string]any)
	predicate["subject_pseudonym"] = "deadbeef"
	payload, _ := json.Marshal(statement)
	sig := ed25519.Sign(signerPrivate(t, signer), dssePAE("application/vnd.in-toto+json", payload))
	forged, _ := json.Marshal(DSSEEnvelope{
		PayloadType: "application/vnd.in-toto+json",
		Payload:     base64.StdEncoding.EncodeToString(payload),
		Signatures:  []DSSESignature{{KeyID: signer.KeyID(), Sig: base64.StdEncoding.EncodeToString(sig)}},
	})
	if _, err := VerifyEnvelope(forged, pub, signer.KeyID()); !errors.Is(err, ErrForbiddenField) {
		t.Fatalf("a validly-signed envelope carrying subject_pseudonym was accepted: err=%v", err)
	}

	// And the minting path refuses at source.
	bad := ts
	bad.SchemaVersion = "" // an incomplete document must not be signable either
	if _, err := signer.Sign(bad); err == nil {
		t.Error("Sign accepted a document with an empty schema_version")
	}
}

func TestTombstoneSignerRefusesBadKeys(t *testing.T) {
	if _, err := NewTombstoneSignerFromPEM(nil); err == nil {
		t.Error("accepted empty PEM")
	}
	if _, err := NewTombstoneSignerFromPEM([]byte("not a pem")); err == nil {
		t.Error("accepted non-PEM bytes")
	}
	if _, err := NewTombstoneSigner(""); err == nil {
		t.Error("accepted an empty key path")
	}
	if _, err := NewTombstoneSigner("/nonexistent/tombstone.pem"); err == nil {
		t.Error("accepted a missing key file")
	}
	// A valid PKCS#8 key that is not Ed25519.
	rsaLike, err := x509.MarshalPKCS8PrivateKey(mustECDSA(t))
	if err != nil {
		t.Fatalf("marshal ecdsa: %v", err)
	}
	block := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: rsaLike})
	if _, err := NewTombstoneSignerFromPEM(block); !errors.Is(err, ErrNotEd25519) {
		t.Errorf("err = %v, want ErrNotEd25519", err)
	}
}
