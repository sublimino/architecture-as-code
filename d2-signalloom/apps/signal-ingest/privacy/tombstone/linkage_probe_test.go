package tombstone

// The adversarial linkage probe.
//
// This file is a _test.go file deliberately and permanently. It implements a re-identification
// attack, and a re-identification tool that ships in the binary is a re-identification tool an
// operator can be compelled to run. Go does not compile _test.go files into the package archive,
// so keeping it here is a structural guarantee rather than a convention.
//
// The probe's job is to FAIL to link. That is a dangerous shape for a test, because a probe that
// does nothing also fails to link, and the two are indistinguishable from a green run. Every
// negative assertion in this file is therefore paired with a positive control that plants the
// exact defect the assertion is meant to catch and requires the SAME code path to find it.
//
// # What counts as a link
//
// Not "a strategy matched something". A tombstone publishes its tenant and a calendar day on
// purpose, so a strategy that matches every row in the tenant on that day has found the scope, not
// the subject. A strategy has LINKED when it narrows the candidate set below MinAnonymitySet —
// that is the DPO's question ("better than 1 in k?") stated as code. Raw hit counts are reported
// alongside, so a zero is always distinguishable from a strategy that never ran.

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------------------------
// Shared helpers used by both test files.
// ---------------------------------------------------------------------------------------------

func readSource(name string) (string, error) {
	b, err := os.ReadFile(name)
	return string(b), err
}

// signerPrivate reaches the signing key for the laundering test, which must produce a VALID
// signature over an INVALID predicate — a forgery the reader has to reject on content, not on
// cryptography. This test file is in package tombstone, so the field is directly reachable; using
// reflection here would panic on the unexported field and prove nothing.
func signerPrivate(_ *testing.T, s *TombstoneSigner) ed25519.PrivateKey { return s.privateKey }

func mustECDSA(t *testing.T) any {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate ecdsa key: %v", err)
	}
	return k
}

// ---------------------------------------------------------------------------------------------
// The retained-evidence corpus.
// ---------------------------------------------------------------------------------------------

// evidenceRow models one row of retained evidence as it actually exists after an erasure.
//
// The fields mirror what survives: the erasure audit row written by privacy.Service.writeDecision
// (subject_pseudonym, decided_at at RFC3339Nano, request_id) and a columnar segment row carrying
// the HMAC actor pseudonym produced by store.SegmentPseudonymiser.
type evidenceRow struct {
	SubjectPseudonym string // audit: keyed pseudonym of the erased or retained subject
	DecidedAtNano    string // audit: RFC3339Nano
	RequestID        string // audit
	ActorHMAC        string // segment: HMAC actor pseudonym
	TenantID         string

	// ObservedKeyCount is what an adversary can ESTIMATE about a subject's key count from retained
	// evidence, because activity volume tracks key count. It is the attribute that re-splits a
	// k=5 (tenant, day) bucket into singletons if the tombstone publishes an exact count.
	ObservedKeyCount int

	// EnrolmentGeneration is what an adversary can ESTIMATE about when a subject enrolled, by
	// ranking subjects by first-seen in segment rows. It is the attribute that makes an exact
	// generation range a rank-matching attack.
	EnrolmentGeneration uint64

	// KeyGeneration is zero in a compliant corpus. The invariant on ProjectReceipt says a
	// generation identifier must never reach retained evidence; TestTombstoneLinkageProbeDetects
	// GenerationCollision sets it to demonstrate what happens when that invariant is broken.
	KeyGeneration uint64

	// cleartextSubject is the ground truth, held only so the test can state which row it hoped not
	// to find. It is never offered to the joiner as a joinable field.
	cleartextSubject string
}

// corpusKey models the pseudonymisation key that survives the erasure of one subject: every other
// subject's pseudonym stays derivable, which is the realistic adversary rather than a convenient
// one.
var corpusKey = []byte("corpus-pseudonymisation-key-32b!!")

func pseudonymise(tenant, subject string) string {
	m := hmac.New(sha256.New, corpusKey)
	m.Write([]byte(tenant))
	m.Write([]byte{0})
	m.Write([]byte(subject))
	return hex.EncodeToString(m.Sum(nil))
}

// buildCorpus produces n decoy rows spread across the erasure day, plus the true subject's row.
//
// The decoys start one interval AFTER the true instant, not at it. A generator that emits a decoy
// at offset zero collides with the true row on the nanosecond, which silently turns the
// "nanosecond timestamps select exactly one row" control into a cohort of two and makes the
// control look like a product defect.
func buildCorpus(t *testing.T, tenant, trueSubject string, day time.Time, n int) []evidenceRow {
	t.Helper()
	rows := make([]evidenceRow, 0, n+1)
	rows = append(rows, evidenceRow{
		SubjectPseudonym: pseudonymise(tenant, trueSubject),
		DecidedAtNano:    day.Format(time.RFC3339Nano),
		RequestID:        "req-2026-09-14-0001",
		ActorHMAC:        pseudonymise(tenant, trueSubject),
		TenantID:         tenant,
		cleartextSubject: trueSubject,

		ObservedKeyCount:    3,  // matches goodRequest().KeysDestroyed
		EnrolmentGeneration: 42, // inside goodRequest()'s raw range [41,43]
	})
	for i := 0; i < n; i++ {
		s := fmt.Sprintf("spiffe://cluster.local/ns/payments/sa/agent-%04d", i)
		at := day.
			Add(time.Duration(i+1) * 137 * time.Second).
			Add(time.Duration((i+1)*7919) * time.Nanosecond)
		rows = append(rows, evidenceRow{
			SubjectPseudonym: pseudonymise(tenant, s),
			DecidedAtNano:    at.Format(time.RFC3339Nano),
			RequestID:        fmt.Sprintf("req-2026-09-14-%04d", i+2),
			ActorHMAC:        pseudonymise(tenant, s),
			TenantID:         tenant,
			cleartextSubject: s,

			// Varied, so the band is a real generalisation rather than a constant, and spread well
			// clear of [41,43] so the exact-range control can isolate the true subject.
			ObservedKeyCount:    1 + (i % 7),
			EnrolmentGeneration: uint64(60 + i*13),
		})
	}
	if len(rows) == 0 {
		t.Fatal("corpus is empty: every join below would return zero for the wrong reason")
	}
	seen := map[string]bool{}
	for _, r := range rows {
		if seen[r.DecidedAtNano] {
			t.Fatalf("corpus has duplicate nanosecond timestamp %s; the temporal control would be unable to isolate a row", r.DecidedAtNano)
		}
		seen[r.DecidedAtNano] = true
	}
	return rows
}

// joinableValues exposes the row's fields to the joiner. cleartextSubject is excluded — the
// adversary does not get handed the answer.
func (r evidenceRow) joinableValues() map[string]string {
	return map[string]string{
		"subject_pseudonym": r.SubjectPseudonym,
		"decided_at":        r.DecidedAtNano,
		"request_id":        r.RequestID,
		"actor_hmac":        r.ActorHMAC,
		"tenant_id":         r.TenantID,
	}
}

// ---------------------------------------------------------------------------------------------
// The joiner.
// ---------------------------------------------------------------------------------------------

// strategyResult is one attack strategy's outcome, recorded PER JOIN PREDICATE.
//
// Per-predicate is the correction that matters. An adversary does not union their joins and accept
// the blurriest answer; they run each predicate and keep the sharpest. Aggregating every hit into
// one subject set lets a genuine one-row link (tombstone.subject_pseudonym == audit.subject_
// pseudonym) be diluted to harmlessness by forty scope-level matches on tenant_id, which is
// precisely the false green this probe exists to avoid.
//
// RawHits and the predicate sets answer different questions. RawHits == 0 means the strategy found
// nothing — and a strategy with no code in it reports the same, which is why every strategy has a
// positive control. The minimum predicate set size is the privacy claim.
type strategyResult struct {
	Name    string
	RawHits int
	pairs   map[string]map[string]bool
	Detail  []string
}

func newStrategy(name string) *strategyResult {
	return &strategyResult{Name: name, pairs: map[string]map[string]bool{}}
}

func (s *strategyResult) hit(predicate, subject, detail string) {
	s.RawHits++
	if s.pairs[predicate] == nil {
		s.pairs[predicate] = map[string]bool{}
	}
	s.pairs[predicate][subject] = true
	if len(s.Detail) < 8 {
		s.Detail = append(s.Detail, detail)
	}
}

// Narrowed is the size of the smallest candidate set any single predicate leaves — the adversary's
// best result under this strategy. Zero means the strategy matched nothing at all.
func (s *strategyResult) Narrowed() int {
	best := 0
	for _, set := range s.pairs {
		if n := len(set); n > 0 && (best == 0 || n < best) {
			best = n
		}
	}
	return best
}

// NarrowestSubjects returns the candidate set of the sharpest predicate.
func (s *strategyResult) NarrowestSubjects() map[string]bool {
	var out map[string]bool
	for _, set := range s.pairs {
		if len(set) > 0 && (out == nil || len(set) < len(out)) {
			out = set
		}
	}
	if out == nil {
		out = map[string]bool{}
	}
	return out
}

// Links reports whether any single predicate narrowed the subject below the anonymity floor.
//
// Zero is not a link (the strategy found nothing) and a set at or above the floor is not a link
// (the strategy found the cohort, which the tombstone publishes on purpose).
func (s *strategyResult) Links() bool {
	n := s.Narrowed()
	return n > 0 && n < MinAnonymitySet
}

func (s *strategyResult) String() string {
	return fmt.Sprintf("%s{raw=%d predicates=%d narrowed=%d links=%v}", s.Name, s.RawHits, len(s.pairs), s.Narrowed(), s.Links())
}

type joinReport struct {
	DocFields, CorpusRows, Candidates                   int
	Exact, Substring, Digest, Generation, Cohort, Quasi *strategyResult
	CohortBasis                                         string
}

func (r joinReport) strategies() []*strategyResult {
	return []*strategyResult{r.Exact, r.Substring, r.Digest, r.Generation, r.Cohort, r.Quasi}
}

// Linking returns the strategies that narrowed below the floor.
func (r joinReport) Linking() []*strategyResult {
	var out []*strategyResult
	for _, s := range r.strategies() {
		if s.Links() {
			out = append(out, s)
		}
	}
	return out
}

// BestNarrowing is the adversary's best result across every strategy: the smallest non-empty
// candidate set any of them produced.
func (r joinReport) BestNarrowing() int {
	best := r.Candidates
	for _, s := range r.strategies() {
		if n := s.Narrowed(); n > 0 && n < best {
			best = n
		}
	}
	return best
}

func (r joinReport) String() string {
	parts := make([]string, 0, 7)
	parts = append(parts, fmt.Sprintf("fields=%d rows=%d candidates=%d", r.DocFields, r.CorpusRows, r.Candidates))
	for _, s := range r.strategies() {
		parts = append(parts, s.String())
	}
	parts = append(parts, "cohortBasis="+r.CohortBasis, fmt.Sprintf("best=1/%d", r.BestNarrowing()))
	return strings.Join(parts, " ")
}

// minJoinableLength stops the value strategies matching on short shared tokens, where a collision
// is more plausible than a leak. 8 hex characters is 32 bits.
const minJoinableLength = 8

// attemptJoin runs every re-identification strategy the adversary has against one tombstone
// document and the retained corpus.
//
// The document is a map rather than a Tombstone so that the positive controls can plant fields the
// struct is incapable of holding — which is the whole point of the struct being incapable.
func attemptJoin(doc map[string]string, corpus []evidenceRow, candidates []string, generationRange [2]uint64) joinReport {
	rep := joinReport{
		DocFields: len(doc), CorpusRows: len(corpus), Candidates: len(candidates),
		Exact:      newStrategy("exact"),
		Substring:  newStrategy("substring"),
		Digest:     newStrategy("digest"),
		Generation: newStrategy("generation"),
		Cohort:     newStrategy("cohort"),
		Quasi:      newStrategy("quasi-identifier"),
	}

	for dk, dv := range doc {
		if len(dv) < minJoinableLength {
			continue
		}
		for _, row := range corpus {
			for ek, ev := range row.joinableValues() {
				if ev == "" {
					continue
				}
				// Strategy 1: exact equality.
				if dv == ev {
					rep.Exact.hit(dk+"=="+ek, row.cleartextSubject, dk+"=="+ek)
					continue
				}
				// Strategy 2: containment, both directions.
				if len(ev) >= minJoinableLength && (strings.Contains(dv, ev) || strings.Contains(ev, dv)) {
					rep.Substring.hit(dk+"~"+ek, row.cleartextSubject, dk+"~"+ek)
				}
			}
		}
	}

	// Strategy 3: digest recomputation. The adversary holds the candidate list and every published
	// field, and tries the canonicalisations a real implementation might plausibly have used —
	// including, specifically, the SLDP-P4-PRE §6.2 receipt shape.
	tenant := doc["tenant_id"]
	for _, cand := range candidates {
		for _, g := range digestGuesses(doc, tenant, cand, corpus) {
			for dk, dv := range doc {
				if len(dv) >= minJoinableLength && dv == g.value {
					rep.Digest.hit(dk+"=="+g.name, cand, dk+"=="+g.name)
				}
			}
		}
	}

	// Strategy 4: key-generation collision.
	if generationRange[0] != 0 {
		for _, row := range corpus {
			if row.KeyGeneration != 0 && row.KeyGeneration >= generationRange[0] && row.KeyGeneration <= generationRange[1] {
				rep.Generation.hit("key_generation_range", row.cleartextSubject, fmt.Sprintf("generation %d in [%d,%d]", row.KeyGeneration, generationRange[0], generationRange[1]))
			}
		}
	}

	// Strategy 6: the QUASI-IDENTIFIER conjunction.
	//
	// The five strategies above each evaluate one predicate. Predicates that are individually safe
	// narrow multiplicatively when intersected: a key-count attribute might leave 24 candidates and
	// a generation attribute 30, and their intersection might leave one. A probe that only ever
	// evaluates predicates independently is structurally incapable of finding that, which makes it
	// a definitional gap rather than a coding one — no number of passing single-predicate tests
	// speaks to it.
	//
	// The conjunction below is the full published tuple, evaluated against the attributes an
	// adversary can ESTIMATE from retained evidence rather than read from it.
	quasiCandidates := map[string]bool{}
	for _, row := range corpus {
		if day, ok := doc["erased_day"]; ok && day != "" {
			if len(row.DecidedAtNano) < 10 || row.DecidedAtNano[:10] != day {
				continue
			}
		}
		if nano, ok := doc["erased_at"]; ok && nano != "" && row.DecidedAtNano != nano {
			continue
		}
		if band, ok := doc["keys_destroyed_band"]; ok && band != "" && BandKeysDestroyed(row.ObservedKeyCount) != band {
			continue
		}
		if exact, ok := doc["keys_destroyed"]; ok && exact != "" && fmt.Sprintf("%d", row.ObservedKeyCount) != exact {
			continue
		}
		if generationRange[0] != 0 && row.EnrolmentGeneration != 0 {
			if row.EnrolmentGeneration < generationRange[0] || row.EnrolmentGeneration > generationRange[1] {
				continue
			}
		}
		quasiCandidates[row.cleartextSubject] = true
	}
	for subject := range quasiCandidates {
		rep.Quasi.hit("day AND key-count AND generation", subject, "consistent with the published tuple")
	}

	// Strategy 5: temporal. The adversary uses the most precise temporal field present.
	if nano, ok := doc["erased_at"]; ok && nano != "" {
		rep.CohortBasis = "erased_at (nanosecond)"
		for _, row := range corpus {
			if row.DecidedAtNano == nano {
				rep.Cohort.hit("erased_at==decided_at", row.cleartextSubject, "nanosecond equality")
			}
		}
	} else if day, ok := doc["erased_day"]; ok && day != "" {
		rep.CohortBasis = "erased_day (UTC day)"
		for _, row := range corpus {
			if len(row.DecidedAtNano) >= 10 && row.DecidedAtNano[:10] == day {
				rep.Cohort.hit("erased_day==decided_at[day]", row.cleartextSubject, "same UTC day")
			}
		}
	} else {
		rep.CohortBasis = "no temporal field"
		for _, row := range corpus {
			rep.Cohort.hit("none", row.cleartextSubject, "no temporal narrowing")
		}
	}
	return rep
}

type namedGuess struct {
	name  string
	value string
}

// digestGuesses enumerates the ways a candidate subject might have been folded into a published
// field. Each entry is a construction a reasonable engineer might have written.
func digestGuesses(doc map[string]string, tenant, candidate string, corpus []evidenceRow) []namedGuess {
	sum := func(b []byte) string { d := sha256.Sum256(b); return hex.EncodeToString(d[:]) }
	guesses := []namedGuess{
		{"sha256(subject)", sum([]byte(candidate))},
		{"sha256(tenant|subject)", sum([]byte(tenant + "|" + candidate))},
		{"sha256(tenant+subject)", sum([]byte(tenant + candidate))},
		{"hmac(corpus_key, subject)", pseudonymise(tenant, candidate)},
	}
	// The SLDP-P4-PRE §6.2 construction, reconstructed from published fields. This is the strategy
	// that must find a planted receipt_digest, and must find nothing in a compliant tombstone.
	//
	// keysRemoved is ENUMERATED rather than read. Since the tombstone publishes only a band, an
	// adversary does not know the exact count — but a count is a small integer, so they try all of
	// them, and the band tells them which ones are worth trying first. A probe that hardcoded one
	// value would miss any oracle built over a different one, which is a false negative dressed as
	// a clean result. (The mutation harness found exactly that: a planted oracle over the band
	// string survived a probe that only guessed "3".)
	keysRemoved := []string{doc["keys_destroyed_band"], doc["keys_destroyed"]}
	for n := 0; n <= 25; n++ {
		keysRemoved = append(keysRemoved, fmt.Sprintf("%d", n))
	}
	timestamps := []string{}
	if ts, ok := doc["erased_at"]; ok && ts != "" {
		timestamps = append(timestamps, ts)
	}
	if day, ok := doc["erased_day"]; ok && day != "" {
		timestamps = append(timestamps, day)
		// And every nanosecond timestamp the adversary can read out of the corpus for that day —
		// the realistic upgrade when only a coarse day is published.
		for _, row := range corpus {
			if len(row.DecidedAtNano) >= 10 && row.DecidedAtNano[:10] == day {
				timestamps = append(timestamps, row.DecidedAtNano)
			}
		}
	}
	for _, k := range keysRemoved {
		if k == "" {
			continue
		}
		for _, when := range timestamps {
			guesses = append(guesses, namedGuess{"sha256(P4PRE receipt)", sum(p4preReceiptJSON(candidate, tenant, k, when))})
		}
	}
	for _, row := range corpus {
		guesses = append(guesses, namedGuess{"sha256(subject|request_id)", sum([]byte(candidate + "|" + row.RequestID))})
	}
	return guesses
}

// p4preReceiptJSON reproduces the preflight's "SHA-256 digest of KeyDestructionReceipt" preimage,
// using privacy.KeyDestructionReceipt's own json tags.
// keysDestroyed is rendered as a JSON string rather than a bare number so that the same helper can
// express both the exact-count form the preflight specified and the banded form, without the caller
// having to know which. The oracle property under attack is unaffected by the encoding: what makes
// it an oracle is that the subject is the only unknown in the preimage.
func p4preReceiptJSON(subject, tenant, keysDestroyed, destroyedAt string) []byte {
	return []byte(fmt.Sprintf(`{"subject_id":%q,"tenant_id":%q,"keys_removed":%q,"destroyed_at":%q}`,
		subject, tenant, keysDestroyed, destroyedAt))
}

// docOf flattens a Tombstone to the joiner's string-keyed form.
func docOf(t *testing.T, ts Tombstone) map[string]string {
	t.Helper()
	raw, err := json.Marshal(ts)
	if err != nil {
		t.Fatalf("marshal tombstone: %v", err)
	}
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatalf("unmarshal tombstone: %v", err)
	}
	out := make(map[string]string, len(generic))
	for k, v := range generic {
		out[k] = fmt.Sprintf("%v", v)
	}
	return out
}

func probeFixture(t *testing.T) (MintRequest, []evidenceRow, []string) {
	t.Helper()
	req := goodRequest()
	day := time.Date(2026, 9, 14, 11, 22, 33, 123456789, time.UTC)
	req.ErasedAt = day
	corpus := buildCorpus(t, req.TenantID, req.SubjectID, day, 40)

	candidates := make([]string, 0, len(corpus))
	for _, row := range corpus {
		candidates = append(candidates, row.cleartextSubject)
	}
	sort.Strings(candidates)
	return req, corpus, candidates
}

// ---------------------------------------------------------------------------------------------
// The negative assertions: the join must fail.
// ---------------------------------------------------------------------------------------------

func TestTombstoneNonJoinability(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	if len(corpus) == 0 || len(candidates) == 0 || len(doc) == 0 {
		t.Fatalf("degenerate fixture: doc=%d corpus=%d candidates=%d", len(doc), len(corpus), len(candidates))
	}
	// The true subject must be in the candidate list, or the digest strategy is searching a space
	// that cannot contain the answer and its zero result means nothing.
	var found bool
	for _, c := range candidates {
		if c == req.SubjectID {
			found = true
		}
	}
	if !found {
		t.Fatal("the true subject is absent from the candidate list; the digest strategy would be vacuous")
	}
	if len(corpus) < MinAnonymitySet {
		t.Fatalf("corpus has %d rows, below MinAnonymitySet=%d: the cohort assertion could not pass for a reason unrelated to the tombstone", len(corpus), MinAnonymitySet)
	}

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (compliant tombstone): %s", rep)

	for _, s := range rep.Linking() {
		t.Errorf("strategy %q narrowed the subject to %d candidates (floor %d): %v", s.Name, s.Narrowed(), MinAnonymitySet, s.Detail)
	}
	// The identifier strategies must find literally nothing, not merely fail to narrow.
	if rep.Exact.RawHits > 0 && rep.Exact.Narrowed() < rep.CorpusRows {
		t.Errorf("exact-equality join matched a proper subset of the corpus: %v", rep.Exact.Detail)
	}
	if rep.Digest.RawHits != 0 {
		t.Errorf("digest recomputation confirmed a candidate subject: %v", rep.Digest.Detail)
	}
	if rep.Generation.RawHits != 0 {
		t.Errorf("key-generation range collided with retained evidence: %v", rep.Generation.Detail)
	}
	// The temporal strategy DOES match — it is supposed to. The claim is a cohort, not a row.
	if rep.Cohort.Narrowed() < MinAnonymitySet {
		t.Errorf("temporal cohort is %d (basis %s), below MinAnonymitySet=%d: the coarse timestamp is selecting rather than hiding",
			rep.Cohort.Narrowed(), rep.CohortBasis, MinAnonymitySet)
	}
	if rep.CohortBasis != "erased_day (UTC day)" {
		t.Errorf("cohort basis is %q; the document exposed a more precise temporal field than the coarse day", rep.CohortBasis)
	}
	if got := rep.BestNarrowing(); got < MinAnonymitySet {
		t.Errorf("the adversary's best result is 1 in %d, below the floor of %d", got, MinAnonymitySet)
	}
}

// ---------------------------------------------------------------------------------------------
// Positive controls. Each plants one defect and requires the SAME joiner to find it.
// ---------------------------------------------------------------------------------------------

func TestTombstoneLinkageProbeDetectsPlantedPseudonym(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	// The defect: the tombstone carries the subject's keyed pseudonym — P4-PRE deny-list item 2,
	// and a shape the Tombstone struct is structurally incapable of producing.
	doc["subject_pseudonym"] = pseudonymise(req.TenantID, req.SubjectID)

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (planted pseudonym): %s", rep)

	if !rep.Exact.Links() {
		t.Fatalf("the joiner did not link a planted subject pseudonym (raw=%d narrowed=%d) — the exact-equality strategy is inert, and every zero it reports elsewhere is meaningless",
			rep.Exact.RawHits, rep.Exact.Narrowed())
	}
	if !rep.Exact.NarrowestSubjects()[req.SubjectID] {
		t.Errorf("exact join linked, but not to the true subject: %v", rep.Exact.Detail)
	}
	if rep.BestNarrowing() != 1 {
		t.Errorf("BestNarrowing = %d, want 1 for a planted cleartext-equivalent link", rep.BestNarrowing())
	}
}

func TestTombstoneLinkageProbeDetectsNanosecondTimestamp(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	// The defect: SLDP-P4-PRE §6.2's `erased_at: RFC3339Nano`.
	doc["erased_at"] = req.ErasedAt.Format(time.RFC3339Nano)

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (planted nanosecond timestamp): %s", rep)

	if rep.CohortBasis != "erased_at (nanosecond)" {
		t.Fatalf("the joiner did not prefer the more precise field: basis=%q", rep.CohortBasis)
	}
	if rep.Cohort.Narrowed() != 1 {
		t.Fatalf("nanosecond cohort narrowed to %d, want exactly 1 — the temporal strategy is not discriminating", rep.Cohort.Narrowed())
	}
	if !rep.Cohort.Links() {
		t.Fatal("a nanosecond timestamp did not register as a link; the cohort assertion in TestTombstoneNonJoinability cannot fail and is therefore worthless")
	}
	if !rep.Cohort.NarrowestSubjects()[req.SubjectID] {
		t.Errorf("the nanosecond join selected the wrong row: %v", rep.Cohort.Detail)
	}
}

func TestTombstoneLinkageProbeDetectsPlantedReceiptDigest(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	// The defect: SLDP-P4-PRE §6.2's `receipt_digest: hex SHA-256 digest of KeyDestructionReceipt`,
	// computed exactly as specified, over the real subject.
	nano := req.ErasedAt.Format(time.RFC3339Nano)
	digest := sha256.Sum256(p4preReceiptJSON(req.SubjectID, req.TenantID, ts.KeysDestroyedBand, nano))
	doc["receipt_digest"] = hex.EncodeToString(digest[:])
	// Published alongside, as the preflight specified — which is what makes the preimage guessable.
	doc["erased_at"] = nano

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (planted P4-PRE receipt_digest): %s", rep)

	if rep.Digest.RawHits == 0 {
		t.Fatal("the digest-recomputation strategy did not confirm the planted P4-PRE receipt_digest — the strategy is inert")
	}
	if !rep.Digest.Links() {
		t.Fatalf("digest strategy found %d hits but narrowed to %d, which is not a link", rep.Digest.RawHits, rep.Digest.Narrowed())
	}
	if !rep.Digest.NarrowestSubjects()[req.SubjectID] {
		t.Fatalf("digest join produced hits but did not name the true subject: %v", rep.Digest.Detail)
	}
}

// TestTombstoneLinkageProbeDetectsCoarseOnlyReceiptDigest is the stronger form of the control
// above: even if the preflight's digest had been taken over the COARSE day rather than the
// nanosecond instant, it is still a subject oracle, because the day is published too.
func TestTombstoneLinkageProbeDetectsCoarseOnlyReceiptDigest(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	digest := sha256.Sum256(p4preReceiptJSON(req.SubjectID, req.TenantID, "3", ts.ErasedDay))
	doc["receipt_digest"] = hex.EncodeToString(digest[:])

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (planted coarse-day receipt_digest): %s", rep)

	if !rep.Digest.Links() || !rep.Digest.NarrowestSubjects()[req.SubjectID] {
		t.Fatalf("coarsening the timestamp did not save the digest construction, yet the probe failed to show it: %s", rep.Digest)
	}
}

// TestTombstoneLinkageProbeDetectsUnbandedQuasiIdentifier is the positive control for the
// conjunction strategy.
//
// It publishes the EXACT key count and the EXACT (un-coarsened) generation range — the design this
// package had before generalisation, and the one an engineer reaches for when asked to make a
// tombstone "more useful for debugging". Each attribute alone leaves a large cohort. Together they
// leave one.
func TestTombstoneLinkageProbeDetectsUnbandedQuasiIdentifier(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)

	doc := docOf(t, ts)
	delete(doc, "keys_destroyed_band")
	doc["keys_destroyed"] = fmt.Sprintf("%d", req.KeysDestroyed)
	rep := attemptJoin(doc, corpus, candidates, [2]uint64{req.KeyGenerationFirst, req.KeyGenerationLast})
	t.Logf("linkage probe (exact count + exact generation range): %s", rep)

	if !rep.Quasi.Links() {
		t.Fatalf("the conjunction of exact key count and exact generation range did not link (narrowed=%d); the quasi-identifier strategy is inert",
			rep.Quasi.Narrowed())
	}
	if !rep.Quasi.NarrowestSubjects()[req.SubjectID] {
		t.Fatalf("the conjunction linked to the wrong subject: %v", rep.Quasi.Detail)
	}

	// Each half alone must NOT link, or this demonstrates a single strong attribute rather than a
	// conjunction of weak ones, and proves nothing about the strategy that was added.
	half := docOf(t, ts)
	delete(half, "keys_destroyed_band")
	half["keys_destroyed"] = fmt.Sprintf("%d", req.KeysDestroyed)
	countOnly := attemptJoin(half, corpus, candidates, [2]uint64{0, 0})
	if countOnly.Quasi.Links() {
		t.Fatalf("the exact key count alone already linked (narrowed=%d); the conjunction is not what is being demonstrated", countOnly.Quasi.Narrowed())
	}
	genOnly := attemptJoin(docOf(t, ts), corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	if genOnly.Quasi.Links() {
		t.Fatalf("the coarsened generation range alone already linked (narrowed=%d)", genOnly.Quasi.Narrowed())
	}
	t.Logf("exact count alone: 1/%d · coarsened generation alone: 1/%d · conjunction: 1/%d",
		countOnly.Quasi.Narrowed(), genOnly.Quasi.Narrowed(), rep.Quasi.Narrowed())
}

func TestTombstoneLinkageProbeDetectsGenerationCollision(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	doc := docOf(t, ts)

	// The defect: SLDP-P4-1 leaks a key-generation identifier into retained evidence, breaking the
	// invariant stated on ProjectReceipt.
	corpus[0].KeyGeneration = ts.KeyGenerationFirst

	rep := attemptJoin(doc, corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
	t.Logf("linkage probe (planted generation column): %s", rep)

	if rep.Generation.RawHits == 0 {
		t.Fatal("the generation strategy did not fire when a generation identifier was present in retained evidence")
	}
	if !rep.Generation.Links() || !rep.Generation.NarrowestSubjects()[req.SubjectID] {
		t.Errorf("generation join did not name the true subject: %s %v", rep.Generation, rep.Generation.Detail)
	}
}

// TestTombstoneLinkageProbeSurvivesRepeatedMints guards against a fluke: one mint might happen to
// be unlinkable. Twenty-five must all be.
func TestTombstoneLinkageProbeSurvivesRepeatedMints(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	for i := 0; i < 25; i++ {
		ts, _ := mustMint(t, req)
		rep := attemptJoin(docOf(t, ts), corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})
		if linking := rep.Linking(); len(linking) != 0 {
			t.Fatalf("mint %d linked via %v: %s", i, linking, rep)
		}
		if rep.Digest.RawHits != 0 {
			t.Fatalf("mint %d: digest strategy confirmed a candidate: %v", i, rep.Digest.Detail)
		}
		if rep.BestNarrowing() < MinAnonymitySet {
			t.Fatalf("mint %d narrowed to 1 in %d, below %d", i, rep.BestNarrowing(), MinAnonymitySet)
		}
	}
}

// TestTombstoneAdversaryHoldingEverythingLearnsOnlyTheCohort is the summary claim, stated as the
// measure a DPO would ask for: given the whole public corpus and the tombstone, the adversary's
// best guess is no better than 1 in k.
func TestTombstoneAdversaryHoldingEverythingLearnsOnlyTheCohort(t *testing.T) {
	req, corpus, candidates := probeFixture(t)
	ts, _ := mustMint(t, req)
	rep := attemptJoin(docOf(t, ts), corpus, candidates, [2]uint64{ts.KeyGenerationFirst, ts.KeyGenerationLast})

	best := rep.BestNarrowing()
	if best < MinAnonymitySet {
		t.Fatalf("an adversary narrowed the subject to %d candidates; the floor is %d\n%s", best, MinAnonymitySet, rep)
	}
	t.Logf("adversary best case: 1 in %d (%.1f%%), floor %d — %s", best, 100.0/float64(best), MinAnonymitySet, rep)
}
