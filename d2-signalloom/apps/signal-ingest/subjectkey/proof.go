// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package subjectkey

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ProofVerdict is the outcome of a post-destruction verification.
type ProofVerdict string

const (
	// VerdictDestroyed is the only verdict that discharges a compliance claim. It requires BOTH that
	// every targeted version refuses to unwrap AND that a control subject in the same tenant still
	// unwraps successfully.
	VerdictDestroyed ProofVerdict = "destroyed"

	// VerdictLive means at least one targeted version still unwraps. The key is not gone.
	VerdictLive ProofVerdict = "live"

	// VerdictInconclusive means the target refused to unwrap AND so did the control.
	//
	// This verdict is the entire point of the type. "The unwrap failed" is satisfied by two
	// mechanisms: the key was destroyed (what we want), or the whole key path is broken — wrong
	// master key loaded, wrong tenant, store returning garbage (what we do not). Both produce an
	// identical error at the target. Only the control distinguishes them, and without a working
	// control the honest answer is "I cannot tell", never "destroyed".
	VerdictInconclusive ProofVerdict = "inconclusive"

	// VerdictControlUnavailable means no live control subject exists in the tenant, so the
	// discriminating observation could not be made. It is NOT a pass.
	VerdictControlUnavailable ProofVerdict = "control_unavailable"
)

// VersionProof is the per-version evidence.
type VersionProof struct {
	KeyVersion int    `json:"key_version"`
	KeyEpoch   uint32 `json:"key_epoch"`
	// RowPresent asserts the row still exists. A DELETED row would prove nothing: absence is
	// consistent with "destroyed", with "never existed", and with "the query was wrong".
	RowPresent bool `json:"row_present"`
	// DestroyedAtSet asserts the durable destruction flag.
	DestroyedAtSet bool       `json:"destroyed_at_set"`
	DestroyedAt    *time.Time `json:"destroyed_at,omitempty"`
	// UnwrapAttempted records that the proof actually tried, rather than inferring from the flag.
	UnwrapAttempted bool `json:"unwrap_attempted"`
	// UnwrapFailed is the positive evidence of unusability.
	UnwrapFailed bool `json:"unwrap_failed"`
	// UnwrapError is the error text, recorded so an operator can see WHICH failure occurred.
	UnwrapError string `json:"unwrap_error,omitempty"`
	// StoredBytesDiffer asserts the bytes in the row hash to something other than the
	// pre-destruction digest recorded in the receipt — so the live key is genuinely overwritten and
	// not merely flagged.
	StoredBytesDiffer bool `json:"stored_bytes_differ"`
	// BytesPresent asserts the column still holds a full-length wrapped key.
	//
	// Without it, an EMPTY or TRUNCATED column reads as destroyed: the unwrap fails, and failure is
	// the evidence the proof is looking for. But an emptied column is data loss, not destruction —
	// and the difference matters, because destruction is something we did deliberately and can
	// attest to, whereas loss is something that happened to us.
	BytesPresent bool `json:"bytes_present"`
}

// ControlProof is the discriminating observation.
type ControlProof struct {
	Available        bool   `json:"available"`
	SubjectPseudonym string `json:"subject_pseudonym,omitempty"`
	KeyVersion       int    `json:"key_version,omitempty"`
	UnwrapSucceeded  bool   `json:"unwrap_succeeded"`
	UnwrapError      string `json:"unwrap_error,omitempty"`
}

// DestructionProof is what an operator shows a regulator.
//
// It is a structure rather than a bool because "prove the key is gone" has three distinguishable
// answers and a bool can carry two. It is also never derived from a destroy call's return value:
// every field here comes from reading the store back and attempting real cryptographic operations.
type DestructionProof struct {
	Verdict          ProofVerdict   `json:"verdict"`
	TenantID         string         `json:"tenant_id"`
	SubjectPseudonym string         `json:"subject_pseudonym"`
	Versions         []VersionProof `json:"versions"`
	Control          ControlProof   `json:"control"`
	// TenantKEKFingerprint proves the tenant key that wraps every OTHER subject is unchanged. A
	// per-subject erasure that quietly took the tenant KEK with it would erase the whole tenant, and
	// nothing in a per-version check would notice.
	TenantKEKFingerprint string    `json:"tenant_kek_fingerprint"`
	VerifiedAt           time.Time `json:"verified_at"`
	Notes                []string  `json:"notes,omitempty"`
}

// ErrProofNotDestroyed is returned when the verdict is anything other than VerdictDestroyed.
var ErrProofNotDestroyed = errors.New("subjectkey: destruction could not be proven")

// VerifyDestroyed proves, or fails to prove, that a subject's key versions are gone.
//
// controlPseudonym names a second subject in the same tenant that must still work. Pass "" only if
// no such subject exists — the verdict is then VerdictControlUnavailable, which is deliberately not
// a pass. receiptDigests maps key version to the PriorWrappedDigest recorded in the receipt; an
// empty map skips the StoredBytesDiffer check and the omission is recorded in Notes.
func (s *Saga) VerifyDestroyed(ctx context.Context, tenantID, subjectPseudonym, controlPseudonym string, priorDigests map[int]string) (DestructionProof, error) {
	proof := DestructionProof{
		TenantID:         tenantID,
		SubjectPseudonym: subjectPseudonym,
		VerifiedAt:       s.now().UTC(),
	}
	if tenantID == "" {
		return proof, ErrTenantRequired
	}
	if subjectPseudonym == "" {
		return proof, ErrSubjectRequired
	}

	fp, err := s.hierarchy.TenantKEKFingerprint(tenantID, 0)
	if err != nil {
		return proof, err
	}
	proof.TenantKEKFingerprint = fmt.Sprintf("%x", fp)

	recs, err := s.store.ListVersions(ctx, tenantID, subjectPseudonym)
	if err != nil {
		return proof, fmt.Errorf("subjectkey: read key versions for proof: %w", err)
	}
	if len(recs) == 0 {
		proof.Notes = append(proof.Notes, "no key versions exist for this subject; absence is not evidence of destruction")
		proof.Verdict = VerdictInconclusive
		return proof, fmt.Errorf("%w: no rows to inspect", ErrProofNotDestroyed)
	}
	if len(priorDigests) == 0 {
		proof.Notes = append(proof.Notes, "no prior wrapped digests supplied; stored_bytes_differ was not evaluated")
	}

	anyLive := false
	for _, r := range recs {
		vp := VersionProof{
			KeyVersion:  r.KeyVersion,
			KeyEpoch:    r.KeyEpoch,
			RowPresent:  true,
			DestroyedAt: r.DestroyedAt,
		}
		vp.DestroyedAtSet = r.DestroyedAt != nil
		vp.BytesPresent = len(r.WrappedDEK) == wrappedDEKLen

		// The real probe. Not "is the flag set" — an attempt to use the key.
		vp.UnwrapAttempted = true
		if _, err := s.hierarchy.UnwrapDEK(r.Scope(), r.WrappedDEK); err != nil {
			vp.UnwrapFailed = true
			vp.UnwrapError = err.Error()
		} else {
			anyLive = true
		}

		if prior, ok := priorDigests[r.KeyVersion]; ok && prior != "" {
			vp.StoredBytesDiffer = WrappedDigest(r.WrappedDEK) != prior
			if !vp.StoredBytesDiffer {
				anyLive = true
				proof.Notes = append(proof.Notes,
					fmt.Sprintf("version %d still holds the pre-destruction bytes; it is flagged, not overwritten", r.KeyVersion))
			}
		}
		proof.Versions = append(proof.Versions, vp)
	}

	// The control. Without it, "unwrap failed" is ambiguous between destruction and a broken key path.
	if controlPseudonym == "" {
		proof.Verdict = VerdictControlUnavailable
		proof.Notes = append(proof.Notes,
			"no control subject supplied; 'unwrap failed' cannot be distinguished from a broken key path")
		return proof, fmt.Errorf("%w: %s", ErrProofNotDestroyed, VerdictControlUnavailable)
	}
	proof.Control.Available = true
	proof.Control.SubjectPseudonym = controlPseudonym
	controlRecs, err := s.store.ListVersions(ctx, tenantID, controlPseudonym)
	if err != nil || len(controlRecs) == 0 {
		proof.Verdict = VerdictControlUnavailable
		proof.Control.Available = false
		proof.Control.UnwrapError = "control subject has no key versions"
		return proof, fmt.Errorf("%w: control subject has no keys", ErrProofNotDestroyed)
	}
	for _, c := range controlRecs {
		if c.Destroyed() {
			continue
		}
		proof.Control.KeyVersion = c.KeyVersion
		if _, err := s.hierarchy.UnwrapDEK(c.Scope(), c.WrappedDEK); err != nil {
			proof.Control.UnwrapError = err.Error()
		} else {
			proof.Control.UnwrapSucceeded = true
		}
		break
	}

	for _, v := range proof.Versions {
		if !v.BytesPresent {
			proof.Verdict = VerdictInconclusive
			proof.Notes = append(proof.Notes, fmt.Sprintf(
				"version %d does not hold a full-length wrapped key; an emptied or truncated column "+
					"fails to unwrap for reasons that are data loss, not destruction", v.KeyVersion))
			return proof, fmt.Errorf("%w: version %d holds no wrapped key bytes", ErrProofNotDestroyed, v.KeyVersion)
		}
	}

	switch {
	case anyLive:
		proof.Verdict = VerdictLive
		return proof, fmt.Errorf("%w: at least one version is still usable", ErrProofNotDestroyed)
	case !proof.Control.UnwrapSucceeded:
		// Target failed AND control failed. The key path itself is suspect, so no claim can be made.
		proof.Verdict = VerdictInconclusive
		proof.Notes = append(proof.Notes,
			"the control subject also failed to unwrap; the key path is broken, so the target's failure proves nothing")
		return proof, fmt.Errorf("%w: %s", ErrProofNotDestroyed, VerdictInconclusive)
	default:
		proof.Verdict = VerdictDestroyed
		return proof, nil
	}
}
