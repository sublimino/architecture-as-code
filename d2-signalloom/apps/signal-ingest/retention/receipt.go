// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

// ReceiptSchema is the version-pinned schema label, fixed by SLDP-P6-PRE §6.
//
// Bumping it is a coordinated change, not a local one: P6-GOV's downstream contract and any ledger
// row written under /v1 are both pinned to these exact bytes.
const ReceiptSchema = "signalloom.retention-deletion-receipt/v1"

// receiptNonceBytes is the length of the per-receipt nonce.
//
// The nonce is not decoration. A receipt digest over (tenant, sink, boundary, counts, timestamps) is
// a digest over a small and highly guessable field set, so without salt an adversary holding a
// candidate tenant and a plausible boundary could grind it and confirm the guess — which would make
// the ledger a confirmation oracle for "this tenant held data about this window". 32 random bytes
// make that search infeasible. Same reasoning as subjectkey.receiptNonceBytes.
const receiptNonceBytes = 32

// Disposition names what actually happened to one copy.
//
// Five values, never collapsed. The card's failure mode — "a deletion sweep that skips an
// unreachable sink and reports success" — is only expressible as a defect if unreachable is a
// first-class outcome rather than an absence.
type Disposition string

const (
	// DispositionPurged means rows or bytes were removed.
	DispositionPurged Disposition = "purged"

	// DispositionAlreadyAbsent means the copy was not present. It still earns a receipt, because
	// "deleted" and "never existed" are different facts and a ledger that cannot tell them apart
	// cannot distinguish a working sweep from a sweep pointed at the wrong store.
	DispositionAlreadyAbsent Disposition = "already_absent"

	// DispositionHeld means an active legal hold blocked deletion. NOT complete: a held copy stays
	// outstanding and goes overdue past its deadline, so a hold cannot quietly become indefinite
	// retention.
	DispositionHeld Disposition = "held"

	// DispositionUnreachable means the sink could not be reached. NOT complete.
	DispositionUnreachable Disposition = "unreachable"

	// DispositionRetainedUnresolvableToken means attested bytes were retained because deleting them
	// would break verification, while the linkage copies that made their pseudonyms resolvable were
	// purged. See the package comment for the full argument.
	DispositionRetainedUnresolvableToken Disposition = "retained_unresolvable_token"
)

// allDispositions is the closed set. Validation refuses anything outside it rather than treating an
// unknown string as benign.
var allDispositions = []Disposition{
	DispositionPurged,
	DispositionAlreadyAbsent,
	DispositionHeld,
	DispositionUnreachable,
	DispositionRetainedUnresolvableToken,
}

// Valid reports whether d is a known disposition.
func (d Disposition) Valid() bool {
	for _, known := range allDispositions {
		if d == known {
			return true
		}
	}
	return false
}

// Complete reports whether this disposition discharges the copy's retention obligation.
//
// held and unreachable do not. That is the single most load-bearing line in the package: if held
// counted as complete, a permanently held copy would leave the outstanding set, never go overdue,
// and legal hold would become a laundering path for indefinite retention that the metric could not
// see.
func (d Disposition) Complete() bool {
	switch d {
	case DispositionPurged, DispositionAlreadyAbsent, DispositionRetainedUnresolvableToken:
		return true
	default:
		return false
	}
}

// Compliance notes. Constants rather than prose assembled at the call site, because the note is what
// reaches a regulator and a claim that lives only in a log line is a claim the artefact does not make.
const (
	ComplianceNotePurged = "article_5_1_e_storage_limitation_satisfied_for_expired_partition"

	ComplianceNoteAlreadyAbsent = "article_5_1_e_no_expired_copy_present_at_evaluation"

	ComplianceNoteHeld = "article_17_3_legal_hold_takes_precedence_over_article_5_1_e_expiry_copy_remains_outstanding"

	ComplianceNoteUnreachable = "retention_not_demonstrated_sink_unreachable_copy_remains_outstanding"

	// ComplianceNoteRetainedToken states, rather than claims away, what the attested plane does.
	//
	// It does NOT assert Article 5(1)(e) satisfaction for the retained bytes, and it names the one
	// precondition without which the whole position is theatre. The segment pseudonym is a KEYED
	// derivative -- identity.NewPseudonymKeyRing(rootKey, epoch) produces an HMAC, not a random
	// surrogate -- so while that epoch key exists, anyone holding it regenerates the map by enumerating
	// a low-entropy actor-ID space. Purging the re-identification table then destroys a convenience
	// index, not the linkage. "Unresolvable" is therefore a CONDITIONAL claim, and the condition is
	// named here rather than left for a reader to assume, because an unnamed precondition is exactly how
	// a truthful disposition becomes a euphemism.
	ComplianceNoteRetainedToken = "linkage_index_purged_attested_bytes_retained_for_checkpoint_continuity_token_is_a_keyed_hmac_so_unresolvability_is_CONDITIONAL_on_destruction_of_the_pseudonym_key_epoch_and_expiry_of_pitr_and_replica_windows_recital_26_assessment_including_joinable_copies_held_by_any_other_person_is_the_controllers"
)

// Residual states. Each names what a deletion does NOT reach.
const (
	// ResidualPostgresMVCC is the truthful state for any PostgreSQL row deletion. Same statement
	// subjectkey.StorageResidualMVCCAndBackup makes for an overwritten BYTEA column, and for the same
	// reason: the operator who needs bit-level erasure must also VACUUM, expire WAL and roll backups.
	ResidualPostgresMVCC = "mvcc_dead_tuples_wal_and_physical_backups_retain_rows_until_vacuum_and_backup_expiry"

	// ResidualNone applies to in-memory copies, where the removed bytes were the only bytes.
	ResidualNone = "none_in_memory_copy"

	// ResidualFilesystemUnlinked applies to an unlinked file: the inode is gone but the blocks are
	// not overwritten and any filesystem snapshot still holds them.
	ResidualFilesystemUnlinked = "inode_unlinked_blocks_not_overwritten_filesystem_snapshots_retain_content"

	// ResidualAttestedBytes applies to the attested plane.
	//
	// "linkage index purged", not "linkage destroyed". The earlier wording claimed more than the act
	// achieves: the pseudonym is a keyed HMAC, so the key epoch and any PITR or replica window are
	// further copies of the linkage that this purge does not reach.
	ResidualAttestedBytes = "attested_segment_and_checkpoint_bytes_retained_linkage_index_purged_pseudonym_key_epoch_and_pitr_replica_windows_retain_regenerable_linkage"

	// ResidualNotDemonstrated is the only honest residual when nothing was demonstrated.
	ResidualNotDemonstrated = "not_demonstrated_no_deletion_was_performed"
)

// ErrReceiptIncomplete is returned when a receipt is missing a field the digest depends on.
var ErrReceiptIncomplete = errors.New("retention: receipt is incomplete and cannot be digested")

// ErrReceiptInvalid is returned when a receipt is internally contradictory.
var ErrReceiptInvalid = errors.New("retention: receipt is internally inconsistent")

// DeletionReceipt is the per-copy record of one retention decision and its execution.
//
// Field set fixed by SLDP-P6-PRE §6, extended with PropagationDeadline, Disposition, SinkClass,
// ClockSource and LinkageReceipts — each of which the P6-1 card requires and none of which the P4
// receipt shape carried.
type DeletionReceipt struct {
	Schema      string `json:"schema"`
	OperationID string `json:"operation_id"`
	TenantID    string `json:"tenant_id"`
	SinkID      string `json:"sink_id"`
	SinkClass   string `json:"sink_class"`

	// DroppedBefore is the retention boundary: data older than this was in scope.
	DroppedBefore time.Time `json:"dropped_before"`

	// PropagationDeadline is the instant by which this copy must have reached a complete
	// disposition. Past it with no complete receipt, the copy is overdue and the gauge counts it.
	PropagationDeadline time.Time `json:"propagation_deadline"`

	Disposition Disposition `json:"disposition"`

	RecordsRemoved    int64 `json:"records_removed"`
	PartitionsDropped int   `json:"partitions_dropped"`

	EvaluatedAt time.Time `json:"evaluated_at"`
	CompletedAt time.Time `json:"completed_at"`

	// ClockSource is read from the Clock that authorised this decision, never a constant.
	ClockSource string `json:"clock_source"`

	// HoldIDs names what blocked deletion, when something did.
	HoldIDs []string `json:"hold_ids,omitempty"`

	// LinkageReceipts are the operation IDs of the purges that made a retained token unresolvable.
	// Present only for DispositionRetainedUnresolvableToken, where they are the whole argument: they
	// are what makes "we kept the bytes" a defensible position rather than an admission.
	LinkageReceipts []string `json:"linkage_receipts,omitempty"`

	ReceiptNonce  string `json:"receipt_nonce"`
	ReceiptDigest string `json:"receipt_digest"`

	ResidualState  string `json:"residual_state"`
	ComplianceNote string `json:"compliance_note"`
}

// NewOperationID derives the deterministic identity of one retention operation.
//
// SHA-256 over (tenant, sink, boundary-in-microseconds) and nothing else. Determinism is what makes
// the controller idempotent without bookkeeping: a re-run after a partial sweep recomputes the same
// ID, the ledger upsert collapses it, and the copy is neither double-counted nor skipped. Note that
// the nonce is deliberately NOT an input — a nonce-dependent ID would be fresh on every retry and
// idempotence would silently become at-least-once.
func NewOperationID(tenantID, sinkID string, droppedBefore time.Time) string {
	h := sha256.New()
	put := func(s string) {
		var lenBuf [4]byte
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(s)))
		h.Write(lenBuf[:])
		h.Write([]byte(s))
	}
	put(tenantID)
	put(sinkID)
	put(encodeInstant(droppedBefore))
	return hex.EncodeToString(h.Sum(nil))
}

// NewReceiptNonce mints a fresh 32-byte CSPRNG nonce.
func NewReceiptNonce() (string, error) {
	b := make([]byte, receiptNonceBytes)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return "", fmt.Errorf("retention: system CSPRNG unavailable, refusing to mint a receipt nonce: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// Validate reports whether the receipt is complete and self-consistent.
func (r DeletionReceipt) Validate() error {
	if r.Schema != ReceiptSchema {
		return fmt.Errorf("%w: schema %q is not %q", ErrReceiptIncomplete, r.Schema, ReceiptSchema)
	}
	if r.OperationID == "" || r.TenantID == "" || r.SinkID == "" || r.SinkClass == "" || r.ReceiptNonce == "" {
		return fmt.Errorf("%w: operation_id, tenant_id, sink_id, sink_class and receipt_nonce are all required", ErrReceiptIncomplete)
	}
	if !r.Disposition.Valid() {
		return fmt.Errorf("%w: disposition %q is not a known value", ErrReceiptIncomplete, r.Disposition)
	}
	if r.ResidualState == "" {
		return fmt.Errorf("%w: residual_state is required; a receipt that does not say what survives is not a receipt", ErrReceiptIncomplete)
	}
	if r.ComplianceNote == "" {
		return fmt.Errorf("%w: compliance_note is required", ErrReceiptIncomplete)
	}
	if r.ClockSource == "" {
		return fmt.Errorf("%w: clock_source is required; a receipt must name the clock that authorised it", ErrReceiptIncomplete)
	}
	if r.DroppedBefore.IsZero() {
		return fmt.Errorf("%w: dropped_before is zero", ErrReceiptIncomplete)
	}
	if r.PropagationDeadline.IsZero() {
		return fmt.Errorf("%w: propagation_deadline is zero", ErrReceiptIncomplete)
	}
	if r.EvaluatedAt.IsZero() {
		return fmt.Errorf("%w: evaluated_at is zero", ErrReceiptIncomplete)
	}
	if r.RecordsRemoved < 0 || r.PartitionsDropped < 0 {
		return fmt.Errorf("%w: negative removal counts", ErrReceiptInvalid)
	}
	// A receipt that removed nothing must not claim to have. This is the anti-criterion that stops an
	// unreachable sink from reading as a successful purge if a future caller wires the counts wrongly.
	switch r.Disposition {
	case DispositionUnreachable, DispositionHeld, DispositionAlreadyAbsent:
		if r.RecordsRemoved != 0 || r.PartitionsDropped != 0 {
			return fmt.Errorf("%w: disposition %q reports %d records and %d partitions removed",
				ErrReceiptInvalid, r.Disposition, r.RecordsRemoved, r.PartitionsDropped)
		}
	}
	if r.Disposition == DispositionHeld && len(r.HoldIDs) == 0 {
		return fmt.Errorf("%w: disposition held names no hold IDs", ErrReceiptInvalid)
	}
	if r.Disposition == DispositionUnreachable && r.ResidualState != ResidualNotDemonstrated {
		return fmt.Errorf("%w: an unreachable sink cannot report residual %q", ErrReceiptInvalid, r.ResidualState)
	}
	if r.Disposition.Complete() && r.CompletedAt.IsZero() {
		return fmt.Errorf("%w: disposition %q is complete but completed_at is zero", ErrReceiptInvalid, r.Disposition)
	}
	return nil
}

// canonical encodes the receipt into a deterministic byte string.
//
// Hand-written rather than json.Marshal, for the two reasons subjectkey/receipt.go records and the
// second of which is the one that bites: a struct's JSON encoding is stable in Go today but is not a
// specified property anything downstream may rely on, and adding a field later would silently change
// every digest, so a ledger row written before the change would stop verifying with no error naming
// the cause. Here a new field requires an explicit edit to this function AND a ReceiptSchema bump,
// which is a change nobody makes by accident.
//
// Slices are sorted so the encoding does not depend on iteration order.
func (r DeletionReceipt) canonical() ([]byte, error) {
	if err := r.Validate(); err != nil {
		return nil, err
	}
	out := make([]byte, 0, 512)
	put := func(s string) {
		out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
		out = append(out, s...)
	}
	put(r.Schema)
	put(r.OperationID)
	put(r.TenantID)
	put(r.SinkID)
	put(r.SinkClass)
	put(string(r.Disposition))
	put(r.ReceiptNonce)
	put(r.ClockSource)
	put(r.ResidualState)
	put(r.ComplianceNote)

	put(encodeInstant(r.DroppedBefore))
	put(encodeInstant(r.PropagationDeadline))
	put(encodeInstant(r.EvaluatedAt))
	put(encodeInstant(r.CompletedAt))

	out = binary.BigEndian.AppendUint64(out, uint64(r.RecordsRemoved))
	out = binary.BigEndian.AppendUint32(out, uint32(r.PartitionsDropped))

	holds := append([]string(nil), r.HoldIDs...)
	sort.Strings(holds)
	out = binary.BigEndian.AppendUint32(out, uint32(len(holds)))
	for _, h := range holds {
		put(h)
	}

	linkage := append([]string(nil), r.LinkageReceipts...)
	sort.Strings(linkage)
	out = binary.BigEndian.AppendUint32(out, uint32(len(linkage)))
	for _, l := range linkage {
		put(l)
	}
	return out, nil
}

// Digest returns the hex SHA-256 of the receipt's canonical encoding.
//
// ReceiptDigest itself is excluded from the encoding, so Digest is stable whether or not the field
// has already been populated.
func (r DeletionReceipt) Digest() (string, error) {
	canon, err := r.canonical()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canon)
	return hex.EncodeToString(sum[:]), nil
}

// Seal computes and sets ReceiptDigest, returning the sealed copy.
func (r DeletionReceipt) Seal() (DeletionReceipt, error) {
	digest, err := r.Digest()
	if err != nil {
		return DeletionReceipt{}, err
	}
	r.ReceiptDigest = digest
	return r, nil
}

// VerifyDigest recomputes the digest and compares it against the stored value.
func (r DeletionReceipt) VerifyDigest() error {
	want := r.ReceiptDigest
	if want == "" {
		return fmt.Errorf("%w: receipt carries no digest", ErrReceiptIncomplete)
	}
	got, err := r.Digest()
	if err != nil {
		return err
	}
	if !strings.EqualFold(got, want) {
		return fmt.Errorf("%w: digest %s does not match stored %s", ErrReceiptInvalid, got, want)
	}
	return nil
}
