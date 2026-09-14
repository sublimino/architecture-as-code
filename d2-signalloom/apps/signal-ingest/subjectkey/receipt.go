// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"time"
)

// ReceiptSchema is the version-pinned schema label for a destruction receipt.
//
// SLDP-P4-2's attested tombstone carries a digest of this structure, so the two cards must agree on
// the exact bytes that digest covers. Bumping this label is therefore a coordinated change, not a
// local one: a tombstone verified against /v1 will not verify against /v2.
const ReceiptSchema = "signalloom.key-destruction-receipt/v1"

// receiptNonceBytes is the length of the per-operation nonce.
//
// The nonce exists because the tombstone publishes ONLY the receipt digest, and a digest over a
// small, guessable field set is not a one-way function in practice. Without it, an adversary holding
// a candidate subject identifier, a plausible timestamp and the tenant could grind the digest and
// confirm the guess, which would make the tombstone a re-identification oracle — precisely the
// non-linkability property SLDP-P4-PRE §6.1 requires. 32 random bytes make that search infeasible.
const receiptNonceBytes = 32

// ResidualDisposition names what survives a destruction that the destruction cannot remove.
type ResidualDisposition string

const (
	// ResidualUnresolvableToken is the only honest answer for a pseudonym already written into a
	// signed, chained Parquet segment. The segment cannot be rewritten without breaking checkpoint
	// continuity for everything after it (store/segment_attestor.go chains on PrevCheckpointDigest,
	// Sequence and CumulativeRowCount), so the token stays and only its resolvability is destroyed.
	ResidualUnresolvableToken ResidualDisposition = "unresolvable_token_retained"
)

// StorageResidual names the copies of the wrapped key that destruction does not reach.
type StorageResidual string

const (
	// StorageResidualMVCCAndBackup is the truthful state for a PostgreSQL-backed store. Overwriting
	// a BYTEA column writes a NEW tuple version; the prior version holding the live wrapped key
	// remains on disk until VACUUM, and WAL segments and physical backups hold further copies.
	//
	// This is recorded rather than claimed away. An operator who needs bit-level erasure must also
	// run VACUUM, expire the WAL and roll the backups, and the receipt is where they are told so.
	StorageResidualMVCCAndBackup StorageResidual = "mvcc_dead_tuples_wal_and_backups_retain_ciphertext_until_vacuum_and_backup_expiry"

	// StorageResidualNone applies to the in-memory store, where the overwritten bytes are the only
	// bytes. It exists so a test cannot accidentally assert the Postgres residual on a memory store
	// and read as covering a claim it never exercised.
	StorageResidualNone StorageResidual = "none_in_memory_store"
)

// ComplianceNote is the fixed, deliberate statement of what this destruction did and did not do.
//
// It is a constant in the receipt rather than prose in a README because the receipt is what reaches
// a regulator, and a claim that lives only in documentation is a claim the artefact does not make.
const ComplianceNote = "article_17_satisfied_by_loss_of_resolvability; article_5_1_e_storage_limitation_NOT_satisfied: ciphertext persists"

// DestroyedKeyVersion is the per-version record of one irreversible act.
type DestroyedKeyVersion struct {
	KeyVersion int    `json:"key_version"`
	KeyEpoch   uint32 `json:"key_epoch"`
	// PriorWrappedDigest is SHA-256 over the wrapped bytes as they stood immediately BEFORE
	// destruction. It is what makes destruction provable after the fact: an operator can show the
	// bytes now in the row hash to something else, so the live key is genuinely gone rather than
	// merely flagged. A digest of a 60-byte AES-GCM ciphertext is not invertible.
	PriorWrappedDigest string `json:"prior_wrapped_digest"`
	// DestroyedAt is read back from durable state, never stamped from the retry-time clock.
	DestroyedAt time.Time `json:"destroyed_at"`
}

// DestructionReceipt is the complete, digestible record of one subject's key destruction.
//
// Every field is either an input the caller already knew or a value read back from durable state.
// Nothing here is computed from time.Now() at receipt-construction time; see Saga for why that is
// load-bearing rather than stylistic.
type DestructionReceipt struct {
	Schema           string `json:"schema"`
	OperationID      string `json:"operation_id"`
	TenantID         string `json:"tenant_id"`
	SubjectPseudonym string `json:"subject_pseudonym"`
	// Nonce is hex-encoded receiptNonceBytes of CSPRNG output, persisted with the saga journal row
	// so a resumed saga reproduces the same digest.
	Nonce string `json:"nonce"`

	Versions []DestroyedKeyVersion `json:"versions"`

	CachesPurged      []string            `json:"caches_purged"`
	ResidualPseudonym ResidualDisposition `json:"residual_pseudonym"`
	StorageResidual   StorageResidual     `json:"storage_residual"`
	ComplianceNote    string              `json:"compliance_note"`

	CompletedAt time.Time `json:"completed_at"`
}

// NewReceiptNonce mints a per-operation nonce.
func NewReceiptNonce() (string, error) {
	b := make([]byte, receiptNonceBytes)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return "", fmt.Errorf("subjectkey: system CSPRNG unavailable, refusing to mint a receipt nonce: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// ErrReceiptIncomplete is returned when a receipt is missing a field the digest depends on.
var ErrReceiptIncomplete = errors.New("subjectkey: receipt is incomplete and cannot be digested")

// canonical encodes the receipt into a deterministic byte string.
//
// It is hand-written rather than json.Marshal on purpose. Two reasons, and the second is the one
// that bites. First, a struct's JSON encoding is stable in Go today but is not a specified property
// P4-2 can rely on across versions. Second, adding a field to this struct later would silently
// change every digest under json.Marshal, so a tombstone written before the change would stop
// verifying with no error naming the cause. Here, a new field requires an explicit edit to this
// function AND a ReceiptSchema bump, which is a change nobody can make by accident.
//
// Versions are sorted by key version so the encoding does not depend on store iteration order.
func (r DestructionReceipt) canonical() ([]byte, error) {
	if r.Schema == "" || r.OperationID == "" || r.TenantID == "" || r.SubjectPseudonym == "" || r.Nonce == "" {
		return nil, fmt.Errorf("%w: schema, operation_id, tenant_id, subject_pseudonym and nonce are all required", ErrReceiptIncomplete)
	}
	if r.ResidualPseudonym == "" || r.StorageResidual == "" || r.ComplianceNote == "" {
		return nil, fmt.Errorf("%w: residual and compliance fields are required; an omitted residual would read as 'no residual'", ErrReceiptIncomplete)
	}

	versions := make([]DestroyedKeyVersion, len(r.Versions))
	copy(versions, r.Versions)
	sort.Slice(versions, func(i, j int) bool { return versions[i].KeyVersion < versions[j].KeyVersion })

	caches := make([]string, len(r.CachesPurged))
	copy(caches, r.CachesPurged)
	sort.Strings(caches)

	out := make([]byte, 0, 512)
	put := func(s string) {
		out = binary.BigEndian.AppendUint32(out, uint32(len(s)))
		out = append(out, s...)
	}
	put(r.Schema)
	put(r.OperationID)
	put(r.TenantID)
	put(r.SubjectPseudonym)
	put(r.Nonce)
	put(string(r.ResidualPseudonym))
	put(string(r.StorageResidual))
	put(r.ComplianceNote)

	out = binary.BigEndian.AppendUint32(out, uint32(len(caches)))
	for _, c := range caches {
		put(c)
	}

	out = binary.BigEndian.AppendUint32(out, uint32(len(versions)))
	for _, v := range versions {
		if v.PriorWrappedDigest == "" {
			return nil, fmt.Errorf("%w: version %d has no prior_wrapped_digest", ErrReceiptIncomplete, v.KeyVersion)
		}
		if v.DestroyedAt.IsZero() {
			return nil, fmt.Errorf("%w: version %d has a zero destroyed_at", ErrReceiptIncomplete, v.KeyVersion)
		}
		out = binary.BigEndian.AppendUint32(out, uint32(v.KeyVersion))
		out = binary.BigEndian.AppendUint32(out, v.KeyEpoch)
		put(v.PriorWrappedDigest)
		put(encodeInstant(v.DestroyedAt))
	}
	put(encodeInstant(r.CompletedAt))
	return out, nil
}

// Digest returns the hex-encoded SHA-256 of the receipt's canonical encoding.
//
// SLDP-P4-2's tombstone carries this value in its receipt_digest field. Because every input is read
// from durable state and the nonce is persisted, a resumed or retried saga produces a byte-identical
// digest — which is what makes "one destruction, one tombstone" assertable rather than hoped for.
func (r DestructionReceipt) Digest() (string, error) {
	canon, err := r.canonical()
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(canon)
	return hex.EncodeToString(sum[:]), nil
}

// encodeInstant renders a timestamp as its integer microseconds since the Unix epoch.
//
// NOT RFC3339Nano, and the reason is a defect this very encoding shipped with until an adversarial
// review caught it. PostgreSQL's timestamptz has MICROSECOND resolution; Go's time.Time carries
// NANOSECONDS. So a receipt digested from an in-memory timestamp and re-digested after a round trip
// through the database differ in the sub-microsecond digits -- the resumed saga produces a different
// digest from the first attempt, and SLDP-P4-2's tombstone disagrees with the receipt for a reason
// invisible at every call site. A fixed-second test clock hides it completely.
//
// Integer microseconds remove the whole class: no location, no offset rendering ("Z" versus
// "+00:00"), no monotonic-clock reading, and no precision a timestamptz column cannot hold.
// SagaClock additionally truncates at the source, so PostgreSQL's round-to-nearest never disagrees
// with Go's truncate-toward-zero either.
func encodeInstant(t time.Time) string {
	return strconv.FormatInt(t.UTC().UnixMicro(), 10)
}

// WrappedDigest returns the SHA-256 of wrapped key bytes, for PriorWrappedDigest.
func WrappedDigest(wrapped []byte) string {
	sum := sha256.Sum256(wrapped)
	return hex.EncodeToString(sum[:])
}
