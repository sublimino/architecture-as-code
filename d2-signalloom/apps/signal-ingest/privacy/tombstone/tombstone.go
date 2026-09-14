// Package tombstone defines the attested record published when an Article 17 erasure completes.
//
// # The problem this package exists to solve
//
// An erasure that leaves no trace cannot be proven to a regulator. A trace that names what was
// erased re-establishes exactly the association the erasure removed. The naive resolution —
// "publish a signed record, just redact the name" — does not work, because a link is not a
// substring. A link is any function an adversary can compute from public data that narrows the
// candidate set for the erased subject. Three mechanisms carry one:
//
//  1. Direct carriage: the field is the identifier, or a deterministic function of it under a key
//     the platform still holds.
//  2. Recomputation oracle: the field is a digest over data the adversary can guess, so
//     guess-and-check confirms a candidate.
//  3. Selector: the value is rare enough to select a single row in retained evidence.
//
// Every field admitted by [AllowedFields] was chosen because it falls into none of the three, and
// [Tombstone] is closed under [ValidateDocument] so a later card cannot widen it silently.
//
// # Deviation from SLDP-P4-PRE §6.2
//
// The Phase 4 preflight allow-listed two fields this package deliberately does not implement:
//
//   - receipt_digest as "hex SHA-256 digest of KeyDestructionReceipt". That struct is
//     {SubjectID, TenantID, KeysRemoved, DestroyedAt}. Every field except SubjectID would have
//     been published in the same tombstone, so the digest reduces to a confirmation oracle whose
//     only unknown is the subject — mechanism 2, in its strongest form. [ReceiptCommitment] is
//     computed over [ReceiptProjection], which has no subject in its domain at all.
//   - erased_at at RFC3339Nano resolution. The erasure audit row carries decided_at at the same
//     resolution alongside subject_pseudonym, so nanosecond equality is a join key — mechanism 3.
//     [Tombstone] carries [Tombstone.ErasedDay] instead, and holds no time.Time field, so a
//     nanosecond value cannot re-enter by type.
//
// # The auditability tension, and its resolution
//
// A record that is perfectly unlinkable is also one that cannot answer "prove my erasure ran".
// Optimising either side alone is wrong. The resolution is selective disclosure:
// [Tombstone.ConfirmationCommitment] is an HMAC over (tenant, subject, request) under a one-time
// [ConfirmationKey] minted at erasure, returned once to the caller, and never persisted by this
// package or by anything it calls. Without the key the field is a PRF output — indistinguishable
// from random, unlinkable even to an adversary holding the full subject list. With the key, the
// data subject or their regulator can test membership against a specific tombstone and nobody
// else can. The platform, having destroyed the key along with the data, can do neither: it cannot
// re-identify, which is what "erased" ought to mean, and it therefore cannot be compelled to.
//
// That is the same crypto-shredding primitive as the erasure itself, applied to the proof rather
// than to the data.
//
// # Published limit: there is no external anchor
//
// Tombstones are signed locally by [TombstoneSigner]. Rekor anchoring is refused outright at
// apps/fe-signalloom/src/audit_anchor/anchor.py:407 ("Rekor anchoring is not implemented; no
// checkpoint was published to Rekor") and Archivista publication is optional. A holder of the
// tombstone signing key can therefore mint a tombstone for an erasure that never happened, or
// backdate one, and no party outside the deployment can detect it. The signature proves
// custody of the key; it does not prove the time or the fact of the erasure. Do not represent it
// as tamper-evident to a regulator until an external anchor exists. See
// docs/signalloom/tombstone-signing-authority.md.
//
// # Wiring note for SLDP-P4-1
//
// This package imports privacy (for [ProjectReceipt]), so privacy must not import it. When the
// erasure saga needs to emit a tombstone, declare the publisher interface in package privacy and
// inject a tombstone-backed implementation from main.go. That is the dependency inversion Go
// wants here, and it keeps the compile-checked link between [ReceiptProjection] and
// privacy.KeyDestructionReceipt intact.
package tombstone

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/privacy"
)

// SchemaVersion identifies the tombstone document shape.
const SchemaVersion = "signalloom.tombstone/v1"

// MinAnonymitySet is the smallest bucket population for which a tombstone may be published.
//
// A coarse timestamp is not a privacy control on its own. "An erasure happened in tenant T on
// 2026-09-14" identifies the subject exactly if only one subject in T could have been erased that
// day. Five is the conventional small-cell suppression floor in statistical disclosure control;
// it is a defensible default rather than a figure any regulation names, and it is stated here as
// a default so that a deployment with a stricter DPO position can be given a stricter build.
//
// It is a compile-time constant for the same reason privacy.MaxOperators is: a configurable
// privacy floor is a floor that gets lowered during the incident in which it matters.
const MinAnonymitySet = 5

// GenerationEpochSize is the width of the key-generation band a tombstone publishes.
//
// An exact tenant-scoped generation range is a monotonic counter, and a monotonic counter is a
// timestamp wearing a disguise. Three things leak from one:
//
//   - RANK. key_generation_first orders subjects by enrolment. Two tombstones give a rank
//     relation, and ranking candidates by first-seen in retained segment rows turns that into a
//     permutation-matching problem that is often uniquely solvable over a modest candidate pool.
//   - CADENCE. If rotation is roughly periodic, generations-per-day is calibratable from a handful
//     of tombstones, which inverts any generation number into a wall-clock estimate far finer than
//     the calendar day ErasedDay was coarsened to. That estimate then joins to the audit trail's
//     RFC3339Nano decided_at.
//   - POPULATION. Observed maxima and gaps admit a German-tank estimator for tenant size and
//     rotation rate — a commercial disclosure as much as a privacy one.
//
// Publishing the epoch BAND containing the destroyed generations removes all three at band
// resolution: two erasures within one epoch publish byte-identical ranges, so there is no rank to
// recover, no cadence to calibrate and no gap structure to estimate from.
const GenerationEpochSize = 1000

// Domain separation strings for the two commitment constructions. Distinct domains mean a value
// produced for one purpose can never verify against the other, even if the inputs coincide.
const (
	receiptCommitmentDomain = "signalloom.tombstone.receipt.v1"
	confirmationDomain      = "signalloom.tombstone.confirmation.v1"
)

// PolicyBasis is the statutory ground on which the erasure was performed.
//
// It is a closed enumeration of two values, deliberately. A free-text basis would be a channel
// wide enough to carry a case reference, and a case reference is a subject identifier with extra
// steps.
type PolicyBasis string

const (
	// BasisArticle17_1 is an ordinary right-to-erasure request with no active legal hold.
	BasisArticle17_1 PolicyBasis = "article_17_1_erasure"

	// BasisArticle17_3 is an erasure performed over an active hold under a dual-operator
	// retention exception.
	BasisArticle17_3 PolicyBasis = "article_17_3_exception"
)

// Valid reports whether b is one of the two admitted grounds.
func (b PolicyBasis) Valid() bool {
	return b == BasisArticle17_1 || b == BasisArticle17_3
}

var (
	// ErrPopulationUnknown is returned when the caller did not state how many subjects share the
	// tombstone's coarse bucket. Absent is refused rather than defaulted: a zero treated as
	// "unchecked, proceed" would make the k-anonymity guard satisfiable by omission, which is the
	// failure mode the guard exists to prevent.
	ErrPopulationUnknown = errors.New("bucket population is unknown: a coarse timestamp is not a privacy control until the size of its cohort is known")

	// ErrAnonymitySetTooSmall is returned when the stated bucket population is below
	// MinAnonymitySet.
	ErrAnonymitySetTooSmall = errors.New("bucket population is below the minimum anonymity set")

	// ErrInvalidGenerationRange is returned for a key-generation range that is unset or inverted.
	ErrInvalidGenerationRange = errors.New("key generation range is invalid")

	// ErrInvalidPolicyBasis is returned for a ground outside the closed enumeration.
	ErrInvalidPolicyBasis = errors.New("policy basis is not an admitted statutory ground")

	// ErrInvalidRequest is returned for structurally incomplete mint requests.
	ErrInvalidRequest = errors.New("tombstone mint request is invalid")

	// ErrForbiddenField is returned by ValidateDocument for a key outside AllowedFields.
	ErrForbiddenField = errors.New("tombstone document carries a field outside the allow-list")

	// ErrMissingField is returned by ValidateDocument for a key absent from the document.
	ErrMissingField = errors.New("tombstone document is missing an allow-listed field")

	// ErrConfirmationKeyNotSerialisable is returned when something attempts to marshal a
	// ConfirmationKey. The key is the one secret that must not reach storage, so the type refuses
	// to encode itself rather than relying on every future call site to remember.
	ErrConfirmationKeyNotSerialisable = errors.New("a confirmation key must never be serialised: it is returned once to the requester and never persisted")
)

// Tombstone is the published record of one completed erasure.
//
// Every field is here because it is safe, and the safety argument for each is one of: constant
// across the tenant population (SchemaVersion, AnonymitySetMin, PolicyBasis), uniform random and
// independent of the subject (TombstoneID, ReceiptNonce), a PRF output under a key the platform
// does not retain (ConfirmationCommitment), a function of published data only
// (ReceiptCommitment), or deliberately coarsened to a cohort of at least MinAnonymitySet
// (ErasedDay).
//
// There is no time.Time field anywhere in this struct, and a test enforces that by reflection.
// That is not stylistic: a time.Time marshals to RFC3339Nano by default, and a nanosecond
// timestamp is the single most effective join key against the erasure audit trail.
type Tombstone struct {
	// SchemaVersion is the document shape. Constant across all tombstones.
	SchemaVersion string `json:"schema_version"`

	// TombstoneID is 128 bits of CSPRNG output, hex-encoded.
	//
	// It is not derived from the request id, and deliberately not HMAC(ephemeral_salt, request_id)
	// as the preflight offered as an alternative: "the salt was discarded" is not a property any
	// test can assert, whereas "this came from crypto/rand" is checkable by observing that two
	// mints from identical inputs differ.
	TombstoneID string `json:"tombstone_id"`

	// TenantID scopes the tombstone. A tenant is not a data subject, and the tenant is the scope
	// within which the anonymity set is counted.
	TenantID string `json:"tenant_id"`

	// ErasedDay is the UTC calendar day of the erasure, as YYYY-MM-DD.
	ErasedDay string `json:"erased_day"`

	// PolicyBasis is the statutory ground. Two possible values, so it partitions the population
	// into two classes rather than identifying anyone.
	PolicyBasis PolicyBasis `json:"policy_basis"`

	// KeyGenerationFirst and KeyGenerationLast bound the destroyed key generations, inclusive,
	// COARSENED to a GenerationEpochSize band by Mint.
	//
	// These are TENANT-scoped generation numbers. If a deployment ever mints per-subject
	// generations, this pair becomes a subject identifier and the whole non-linkability argument
	// collapses. The binding invariant SLDP-P4-1 must honour is stated on ProjectReceipt.
	KeyGenerationFirst uint64 `json:"key_generation_first"`
	KeyGenerationLast  uint64 `json:"key_generation_last"`

	// KeysDestroyedBand is the generalised count of keys the destroyer removed, from
	// KeysDestroyedBands. The exact figure is deliberately not published — see BandKeysDestroyed.
	KeysDestroyedBand string `json:"keys_destroyed_band"`

	// ReceiptCommitment is SHA-256(nonce || canonical(ReceiptProjection)), hex-encoded.
	//
	// The projection contains only fields also published in this document, so this commitment is
	// verifiable by anyone and reveals nothing new. Its function is twofold: it detects a
	// hand-edit of the published counts in an unsigned transport (a JSONL journal, a copied
	// document) independently of the DSSE signature, and — the reason it is shaped this way — it
	// occupies the slot where the preflight put a digest over a struct containing the subject,
	// with a construction that has no subject in its domain and therefore cannot be walked back
	// into one.
	ReceiptCommitment string `json:"receipt_commitment"`

	// ReceiptNonce is 256 bits of CSPRNG output, hex-encoded. It makes the commitment differ
	// between two structurally identical erasures, so equal commitments cannot be used to cluster
	// tombstones.
	ReceiptNonce string `json:"receipt_nonce"`

	// ConfirmationCommitment is HMAC-SHA256(ConfirmationKey, canonical(tenant, subject, request)),
	// hex-encoded. See the package comment: this is the one field an authorised holder can use to
	// confirm that a specific erasure completed, and it is useless to everyone else.
	ConfirmationCommitment string `json:"confirmation_commitment"`

	// AnonymitySetMin is the threshold the bucket was required to meet — MinAnonymitySet — and
	// never the observed population.
	//
	// Publishing the measurement would defeat the point twice over: it is a per-tombstone varying
	// attribute that helps cluster tombstones, and it discloses the tenant's subject volume. The
	// threshold is identical in every tombstone, so it carries no information beyond "this build's
	// floor".
	AnonymitySetMin int `json:"anonymity_set_min"`
}

// AllowedFields is the exhaustive, ordered set of JSON keys a tombstone document may carry.
//
// It is the schema's closure. TestTombstoneAllowListMatchesStruct asserts set equality against
// the struct's reflected tags in both directions, so adding a field to Tombstone without adding
// it here fails the build's test phase, and so does the reverse.
var AllowedFields = []string{
	"schema_version",
	"tombstone_id",
	"tenant_id",
	"erased_day",
	"policy_basis",
	"key_generation_first",
	"key_generation_last",
	"keys_destroyed_band",
	"receipt_commitment",
	"receipt_nonce",
	"confirmation_commitment",
	"anonymity_set_min",
}

// ForbiddenFieldSubstrings are fragments that must not appear anywhere in a tombstone JSON key.
//
// These are safe as raw substrings because none of them is a fragment of an innocuous word.
var ForbiddenFieldSubstrings = []string{
	"subject",
	"pseudonym",
	"actor",
	"request",
	"operator",
	"approver",
	"email",
	"spiffe",
	"principal",
	"username",
	"hostname",
	"identifier",
}

// ForbiddenFieldTokens are whole underscore-delimited segments that must not appear in a key.
//
// They are matched per segment rather than as substrings because short identifier fragments
// false-positive against ordinary words. "ip" is the live example: a naive substring check for it
// fires on "rece-ip-t", so a guard written that way would reject the schema's own
// receipt_commitment field and would have to be weakened — at which point it stops catching
// ip_address, which is the thing it was for.
var ForbiddenFieldTokens = []string{
	"ip", "addr", "address", "host", "user", "uid", "sub", "dn", "cn", "sid", "upn",
}

// ReceiptProjection is the non-identifying view of a key-destruction receipt.
//
// privacy.KeyDestructionReceipt carries SubjectID. This type does not, and TestTombstone... asserts
// by reflection that it never acquires a field whose name mentions a subject. The projection is
// the only thing the receipt commitment is ever computed over.
// Every field here must also be published in the Tombstone. That is not tidiness: the nonce is
// published too, so the commitment is BINDING but not HIDING — anyone can recompute
// SHA-256(nonce || candidate) and confirm a guess. That is harmless only while the projection is a
// strict subset of already-published data. One unpublished low-entropy field would make the
// published nonce an enumeration oracle for it. TestTombstoneProjectionIsASubsetOfPublishedFields
// enforces the subset relation rather than trusting the weaker "contains no subject" property.
type ReceiptProjection struct {
	TenantID           string `json:"tenant_id"`
	KeysDestroyedBand  string `json:"keys_destroyed_band"`
	KeyGenerationFirst uint64 `json:"key_generation_first"`
	KeyGenerationLast  uint64 `json:"key_generation_last"`
	DestroyedDay       string `json:"erased_day"`
}

// ProjectReceipt reduces a real privacy.KeyDestructionReceipt to its non-identifying projection.
//
// It takes the concrete erasure type rather than an interface so that the compiler, not a comment,
// enforces the correspondence: if SLDP-P4-1 changes the receipt shape, this function stops
// compiling and someone has to decide again whether the new field is safe to commit to.
//
// INVARIANT FOR SLDP-P4-1. The generation numbers passed here must be tenant-scoped and must never
// appear in retained evidence — not in a segment column, not in an audit detail payload, not in a
// key-metadata table readable by a query path. A generation identifier present on both sides is a
// join key, and TestTombstoneLinkageProbeDetectsGenerationCollision demonstrates that the probe
// finds it the moment it is.
func ProjectReceipt(r privacy.KeyDestructionReceipt, generationFirst, generationLast uint64) ReceiptProjection {
	lo, hi := CoarsenGenerationRange(generationFirst, generationLast)
	return ReceiptProjection{
		TenantID:           r.TenantID,
		KeysDestroyedBand:  BandKeysDestroyed(r.KeysRemoved),
		KeyGenerationFirst: lo,
		KeyGenerationLast:  hi,
		DestroyedDay:       CoarsenDay(r.DestroyedAt),
	}
}

// ConfirmationKey is the one-time secret that makes a specific erasure confirmable.
//
// It is returned by Mint exactly once and is never persisted by this package. It refuses to
// marshal and it redacts itself when formatted, because the cost of one accidental log line is
// the entire non-linkability property. Disclose is the deliberate, greppable escape hatch for
// handing it to the requester.
//
// Note the residual hole, stated rather than papered over: fmt "%x" on an array type prints the
// bytes regardless of the Stringer. The defence against that is Disclose being the obvious way to
// do it on purpose, plus the fact that the key is never stored in a struct that something might
// dump wholesale.
type ConfirmationKey [32]byte

// String redacts.
func (ConfirmationKey) String() string { return "ConfirmationKey(redacted)" }

// GoString redacts, so %#v does not leak either.
func (ConfirmationKey) GoString() string { return "ConfirmationKey(redacted)" }

// MarshalJSON refuses.
func (ConfirmationKey) MarshalJSON() ([]byte, error) { return nil, ErrConfirmationKeyNotSerialisable }

// Disclose renders the key for out-of-band delivery to the requester. Named to be conspicuous in
// a diff and in a grep.
func (k ConfirmationKey) Disclose() string { return hex.EncodeToString(k[:]) }

// ParseConfirmationKey reads a key back from its disclosed form.
func ParseConfirmationKey(s string) (ConfirmationKey, error) {
	var k ConfirmationKey
	raw, err := hex.DecodeString(strings.TrimSpace(s))
	if err != nil {
		return k, fmt.Errorf("parse confirmation key: %w", err)
	}
	if len(raw) != len(k) {
		return k, fmt.Errorf("parse confirmation key: got %d bytes, want %d", len(raw), len(k))
	}
	copy(k[:], raw)
	return k, nil
}

// MintRequest is the input to Mint.
//
// SubjectID and RequestID are consumed to compute the confirmation commitment and are not carried
// into the Tombstone. They are named on this struct rather than hidden behind a callback so that
// the one place cleartext identity enters this package is visible in a single type.
type MintRequest struct {
	TenantID  string
	SubjectID string
	RequestID string

	PolicyBasis PolicyBasis

	// ErasedAt is the instant of the erasure. Only its UTC calendar day survives into the
	// tombstone; the rest is discarded by CoarsenDay.
	ErasedAt time.Time

	KeyGenerationFirst uint64
	KeyGenerationLast  uint64
	KeysDestroyed      int

	// BucketPopulation is how many data subjects in this tenant could have been the subject of an
	// erasure recorded on ErasedAt's calendar day — the size of the cohort the coarse timestamp
	// hides this erasure within. Mint refuses below MinAnonymitySet and refuses an unset value.
	BucketPopulation int
}

// randRead is the CSPRNG seam. Tests substitute it to exercise the failure path; nothing else
// should touch it.
var randRead = func(b []byte) error {
	_, err := io.ReadFull(rand.Reader, b)
	return err
}

// KeysDestroyedBands is the published generalisation of a destroyed-key count.
//
// The exact count must not be published. k enforced over (tenant, day) alone is defeated by any
// unbucketed attribute that re-splits the bucket, and a key count is exactly that: five tombstones
// sharing a tenant and a day with counts 3, 7, 1, 22 and 4 are five singletons to an adversary who
// can estimate a candidate's key count — which retained segment rows permit, because activity
// volume tracks key count.
var KeysDestroyedBands = []string{"0", "1", "2-5", "6-20", "21+"}

// BandKeysDestroyed generalises an exact count to its published band.
func BandKeysDestroyed(n int) string {
	switch {
	case n <= 0:
		return "0"
	case n == 1:
		return "1"
	case n <= 5:
		return "2-5"
	case n <= 20:
		return "6-20"
	default:
		return "21+"
	}
}

// CoarsenGenerationRange widens a raw generation range to the epoch band that contains it.
//
// The returned range is closed and epoch-aligned: first is 1 mod GenerationEpochSize and last is
// 0 mod GenerationEpochSize, so Validate can check alignment and an un-coarsened range cannot be
// published by a caller assembling a Tombstone by hand.
func CoarsenGenerationRange(first, last uint64) (uint64, uint64) {
	if first == 0 || first > last {
		return 0, 0
	}
	lo := ((first-1)/GenerationEpochSize)*GenerationEpochSize + 1
	hi := ((last-1)/GenerationEpochSize + 1) * GenerationEpochSize
	return lo, hi
}

// CoarsenDay reduces an instant to its UTC calendar day, as YYYY-MM-DD.
//
// The UTC conversion is load-bearing, not tidiness: coarsening in local time would put two
// erasures either side of a local midnight into different buckets while an adversary reading the
// audit trail in UTC sees them in the same one, and the mismatch is a distinguishing attribute.
func CoarsenDay(t time.Time) string {
	return t.UTC().Format("2006-01-02")
}

// Mint validates the request, checks the anonymity set, and produces a signed-ready tombstone
// together with the one-time confirmation key.
//
// The order is the control. Validation and the population check both run before any randomness is
// drawn and before any commitment is computed, so a refusal cannot leave a half-built tombstone
// anywhere, and the caller who ignores the error receives a zero Tombstone rather than a
// plausible one.
func Mint(req MintRequest) (Tombstone, ConfirmationKey, error) {
	var zeroKey ConfirmationKey

	if req.TenantID == "" {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: tenant_id is required", ErrInvalidRequest)
	}
	if req.SubjectID == "" {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: subject_id is required to compute the confirmation commitment", ErrInvalidRequest)
	}
	if req.RequestID == "" {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: request_id is required to compute the confirmation commitment", ErrInvalidRequest)
	}
	if !req.PolicyBasis.Valid() {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: %q", ErrInvalidPolicyBasis, string(req.PolicyBasis))
	}
	if req.ErasedAt.IsZero() {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: erased_at is unset; a zero instant would coarsen to year 1 and stand out", ErrInvalidRequest)
	}
	if req.KeysDestroyed < 0 {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: keys_destroyed is negative", ErrInvalidRequest)
	}
	if req.KeyGenerationFirst == 0 {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: first generation is 0; generations are 1-based so 0 means unset", ErrInvalidGenerationRange)
	}
	if req.KeyGenerationFirst > req.KeyGenerationLast {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: first generation %d exceeds last generation %d",
			ErrInvalidGenerationRange, req.KeyGenerationFirst, req.KeyGenerationLast)
	}

	// The population check. It runs here, unconditionally, on every mint.
	if req.BucketPopulation == 0 {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: tenant %q, day %s", ErrPopulationUnknown, req.TenantID, CoarsenDay(req.ErasedAt))
	}
	if req.BucketPopulation < 0 {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: bucket population is %d", ErrInvalidRequest, req.BucketPopulation)
	}
	if req.BucketPopulation < MinAnonymitySet {
		return Tombstone{}, zeroKey, fmt.Errorf("%w: bucket population is %d, below the minimum anonymity set of %d; publishing would identify the subject by elimination",
			ErrAnonymitySetTooSmall, req.BucketPopulation, MinAnonymitySet)
	}

	idBytes := make([]byte, 16)
	if err := randRead(idBytes); err != nil {
		return Tombstone{}, zeroKey, fmt.Errorf("draw tombstone id: %w", err)
	}
	nonce := make([]byte, 32)
	if err := randRead(nonce); err != nil {
		return Tombstone{}, zeroKey, fmt.Errorf("draw receipt nonce: %w", err)
	}
	var key ConfirmationKey
	if err := randRead(key[:]); err != nil {
		return Tombstone{}, zeroKey, fmt.Errorf("draw confirmation key: %w", err)
	}

	day := CoarsenDay(req.ErasedAt)
	genLo, genHi := CoarsenGenerationRange(req.KeyGenerationFirst, req.KeyGenerationLast)
	band := BandKeysDestroyed(req.KeysDestroyed)
	projection := ReceiptProjection{
		TenantID:           req.TenantID,
		KeysDestroyedBand:  band,
		KeyGenerationFirst: genLo,
		KeyGenerationLast:  genHi,
		DestroyedDay:       day,
	}

	t := Tombstone{
		SchemaVersion:          SchemaVersion,
		TombstoneID:            hex.EncodeToString(idBytes),
		TenantID:               req.TenantID,
		ErasedDay:              day,
		PolicyBasis:            req.PolicyBasis,
		KeyGenerationFirst:     genLo,
		KeyGenerationLast:      genHi,
		KeysDestroyedBand:      band,
		ReceiptCommitment:      ReceiptCommitment(nonce, projection),
		ReceiptNonce:           hex.EncodeToString(nonce),
		ConfirmationCommitment: confirmationCommitment(key, req.TenantID, req.SubjectID, req.RequestID),
		AnonymitySetMin:        MinAnonymitySet,
	}
	return t, key, nil
}

// canonical builds a domain-separated, big-endian length-prefixed byte string.
//
// Length prefixing rather than delimiter joining, because ("a","bc") and ("ab","c") must not
// produce the same bytes — a canonicalisation that collides is a commitment scheme that lies.
func canonical(domain string, parts ...string) []byte {
	var b bytes.Buffer
	b.WriteString(domain)
	var l [8]byte
	for _, p := range parts {
		binary.BigEndian.PutUint64(l[:], uint64(len(p)))
		b.Write(l[:])
		b.WriteString(p)
	}
	return b.Bytes()
}

// canonicalProjection renders a ReceiptProjection deterministically.
func canonicalProjection(p ReceiptProjection) []byte {
	return canonical(receiptCommitmentDomain,
		p.TenantID,
		p.KeysDestroyedBand,
		fmt.Sprintf("%d", p.KeyGenerationFirst),
		fmt.Sprintf("%d", p.KeyGenerationLast),
		p.DestroyedDay,
	)
}

// ReceiptCommitment computes SHA-256(nonce || canonical(projection)), hex-encoded.
func ReceiptCommitment(nonce []byte, p ReceiptProjection) string {
	h := sha256.New()
	h.Write(nonce)
	h.Write(canonicalProjection(p))
	return hex.EncodeToString(h.Sum(nil))
}

// VerifyReceiptCommitment recomputes the commitment from the tombstone's own published fields and
// reports whether it matches.
//
// It takes nothing the tombstone does not already carry, which is the point: the commitment is
// checkable by any reader and discloses nothing to them.
func VerifyReceiptCommitment(t Tombstone) bool {
	nonce, err := hex.DecodeString(t.ReceiptNonce)
	if err != nil {
		return false
	}
	want := ReceiptCommitment(nonce, ReceiptProjection{
		TenantID:           t.TenantID,
		KeysDestroyedBand:  t.KeysDestroyedBand,
		KeyGenerationFirst: t.KeyGenerationFirst,
		KeyGenerationLast:  t.KeyGenerationLast,
		DestroyedDay:       t.ErasedDay,
	})
	return hmac.Equal([]byte(want), []byte(t.ReceiptCommitment))
}

// confirmationCommitment computes the selective-disclosure commitment.
func confirmationCommitment(k ConfirmationKey, tenantID, subjectID, requestID string) string {
	mac := hmac.New(sha256.New, k[:])
	mac.Write(canonical(confirmationDomain, tenantID, subjectID, requestID))
	return hex.EncodeToString(mac.Sum(nil))
}

// ConfirmSpecificErasure reports whether t is the tombstone of the named erasure.
//
// This is the whole audit answer. It requires the one-time key, which the platform does not have;
// only the party the key was disclosed to can run it. A false return is genuinely "not this
// tombstone" and not "I am not allowed to say", because the computation is complete and local.
func ConfirmSpecificErasure(t Tombstone, k ConfirmationKey, tenantID, subjectID, requestID string) bool {
	want := confirmationCommitment(k, tenantID, subjectID, requestID)
	return hmac.Equal([]byte(want), []byte(t.ConfirmationCommitment))
}

// documentFields reflects the JSON keys the Tombstone struct can produce.
func documentFields() []string {
	rt := reflect.TypeOf(Tombstone{})
	out := make([]string, 0, rt.NumField())
	for i := 0; i < rt.NumField(); i++ {
		tag := rt.Field(i).Tag.Get("json")
		name, _, _ := strings.Cut(tag, ",")
		if name == "" || name == "-" {
			// A field with no json tag still marshals, under its Go name. Surfacing the Go name
			// keeps the allow-list comparison honest rather than letting an untagged field slip
			// through the set equality by being invisible to it.
			name = rt.Field(i).Name
		}
		out = append(out, name)
	}
	return out
}

// DocumentFields returns the JSON keys reachable by marshalling a Tombstone.
func DocumentFields() []string { return documentFields() }

// ValidateDocument checks a marshalled tombstone against the allow-list in both directions.
//
// Both directions matter. Rejecting unknown keys stops a field being smuggled in; requiring every
// allow-listed key stops a document being published with the confirmation commitment quietly
// dropped, which would look tidier and would destroy the only auditability the design has.
func ValidateDocument(raw []byte) error {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		return fmt.Errorf("parse tombstone document: %w", err)
	}
	allowed := make(map[string]bool, len(AllowedFields))
	for _, f := range AllowedFields {
		allowed[f] = true
	}
	for key := range doc {
		if !allowed[key] {
			return fmt.Errorf("%w: %q", ErrForbiddenField, key)
		}
	}
	for _, f := range AllowedFields {
		if _, ok := doc[f]; !ok {
			return fmt.Errorf("%w: %q", ErrMissingField, f)
		}
	}
	return nil
}

// Validate checks that a tombstone's values, not merely its keys, are publishable.
//
// ValidateDocument is a key-set check and deliberately stays one — it answers "is this the right
// shape". It cannot answer "is this a real tombstone", because an empty string still occupies its
// key. Both checks exist because a document that passes only the first is exactly what a partially
// constructed or hand-edited record looks like, and attesting one makes it unrewritable.
func (t Tombstone) Validate() error {
	if t.SchemaVersion != SchemaVersion {
		return fmt.Errorf("%w: schema_version is %q, want %q", ErrInvalidRequest, t.SchemaVersion, SchemaVersion)
	}
	if len(t.TombstoneID) != 32 {
		return fmt.Errorf("%w: tombstone_id is %d hex chars, want 32", ErrInvalidRequest, len(t.TombstoneID))
	}
	if t.TenantID == "" {
		return fmt.Errorf("%w: tenant_id is empty", ErrInvalidRequest)
	}
	if !erasedDayShape.MatchString(t.ErasedDay) {
		return fmt.Errorf("%w: erased_day is %q, want YYYY-MM-DD", ErrInvalidRequest, t.ErasedDay)
	}
	if !t.PolicyBasis.Valid() {
		return fmt.Errorf("%w: %q", ErrInvalidPolicyBasis, string(t.PolicyBasis))
	}
	if t.KeyGenerationFirst == 0 || t.KeyGenerationFirst > t.KeyGenerationLast {
		return fmt.Errorf("%w: [%d,%d]", ErrInvalidGenerationRange, t.KeyGenerationFirst, t.KeyGenerationLast)
	}
	// Alignment, not merely ordering. An un-coarsened range assembled by hand would carry the rank
	// and cadence information GenerationEpochSize exists to destroy, and would otherwise pass every
	// other check in this function.
	if t.KeyGenerationFirst%GenerationEpochSize != 1 || t.KeyGenerationLast%GenerationEpochSize != 0 {
		return fmt.Errorf("%w: [%d,%d] is not aligned to a %d-wide epoch band",
			ErrInvalidGenerationRange, t.KeyGenerationFirst, t.KeyGenerationLast, GenerationEpochSize)
	}
	if !slices.Contains(KeysDestroyedBands, t.KeysDestroyedBand) {
		return fmt.Errorf("%w: keys_destroyed_band is %q, want one of %v", ErrInvalidRequest, t.KeysDestroyedBand, KeysDestroyedBands)
	}
	if len(t.ReceiptCommitment) != 64 {
		return fmt.Errorf("%w: receipt_commitment is %d hex chars, want 64", ErrInvalidRequest, len(t.ReceiptCommitment))
	}
	if len(t.ReceiptNonce) != 64 {
		return fmt.Errorf("%w: receipt_nonce is %d hex chars, want 64", ErrInvalidRequest, len(t.ReceiptNonce))
	}
	if len(t.ConfirmationCommitment) != 64 {
		return fmt.Errorf("%w: confirmation_commitment is %d hex chars, want 64; an absent commitment would make the erasure unprovable to the data subject", ErrInvalidRequest, len(t.ConfirmationCommitment))
	}
	if t.AnonymitySetMin != MinAnonymitySet {
		return fmt.Errorf("%w: anonymity_set_min is %d, want the build's constant %d", ErrInvalidRequest, t.AnonymitySetMin, MinAnonymitySet)
	}
	return nil
}

var erasedDayShape = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

// FieldNameViolations reports which of names carry a forbidden substring or token.
//
// Exported so that the test suite, the signer's pre-sign check, and any future document-ingesting
// path all use one implementation. A guard duplicated is a guard that drifts.
func FieldNameViolations(names []string) []string {
	var bad []string
	for _, n := range names {
		lower := strings.ToLower(n)
		for _, frag := range ForbiddenFieldSubstrings {
			if strings.Contains(lower, frag) {
				bad = append(bad, fmt.Sprintf("%s (substring %q)", n, frag))
			}
		}
		for _, seg := range strings.Split(lower, "_") {
			for _, tok := range ForbiddenFieldTokens {
				if seg == tok {
					bad = append(bad, fmt.Sprintf("%s (token %q)", n, tok))
				}
			}
		}
	}
	return bad
}
