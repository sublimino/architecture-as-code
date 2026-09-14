// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

//go:build frostdb

package store

import "github.com/apache/arrow-go/v18/arrow"

// Segment column-schema versions.
//
// These name the *column layout* of an observation segment. They are deliberately NOT the DSSE
// attestation schema. `store/verify/verify.go:28` pins `segmentSchema = "signalloom.segment/v1"`
// for the signed statement, and the verifier hashes `data.parquet` bytes without ever parsing a
// Parquet column. Those are two different versioned surfaces and only this one moves in SLDP-P3-1.
//
// Getting that distinction wrong is the card's first hard blocker: bumping the attestation schema
// would invalidate every signed segment already on disk. Bumping the column schema invalidates
// nothing, because no attested byte changes and no verifier reads a column name.
const (
	// SegmentSchemaV1 is the original layout. It carried six direct identifiers in cleartext:
	// actor_hint, actor_id, principal_id, session_id, impersonated_user and raw_evidence_ref.
	// No v1 segment declares its own version — absence of the schema_version column IS v1.
	SegmentSchemaV1 = "signalloom.observations/v1"

	// SegmentSchemaV2 replaces every direct identifier with a keyed, tenant-and-epoch-scoped
	// HMAC pseudonym, and raw_evidence_ref with a domain-separated keyed digest.
	SegmentSchemaV2 = "signalloom.observations/v2"

	// SegmentSchemaVersionColumn is the column that makes a v2 segment self-describing. It is
	// written by the writer and read by the decoder; a record without it is v1 by construction.
	SegmentSchemaVersionColumn = "schema_version"
)

// LabelColumnPrefix is the Arrow/Parquet prefix under which dynamic label columns materialise.
const LabelColumnPrefix = "labels."

// v1RemovedColumns are the cleartext identifier columns that SLDP-P3-1 removes from the v2 layout.
//
// The card's objective names three (actor_hint, raw_evidence_ref, impersonated_user). The
// deliverable says the schema must carry "pseudonyms only", and SLDP-P3-PRE §3.2 classifies
// actor_id, principal_id and session_id as High / Medium-High cleartext identity in the same audit
// table. Removing only the three named would leave "no cleartext identity in the immutable store"
// false while every named criterion passed — a criterion that passes whether or not the control
// works, which the card forbids. All six go.
var v1RemovedColumns = []string{
	"actor_hint",
	"actor_id",
	"principal_id",
	"session_id",
	"impersonated_user",
	"raw_evidence_ref",
}

// V1RemovedColumns returns the identifier columns absent from the v2 layout.
func V1RemovedColumns() []string {
	out := make([]string, len(v1RemovedColumns))
	copy(out, v1RemovedColumns)
	return out
}

// Pseudonymous replacement column names. Each holds a 64-character lowercase hex digest, which is
// the same width as the plaintext it replaces was unbounded — so dictionary encoding and predicate
// pushdown behave the same way, and equality on the pseudonym is equality on the plaintext.
const (
	ColHMACActorHint        = "hmac_actor_hint"
	ColHMACActorID          = "hmac_actor_id"
	ColHMACPrincipalID      = "hmac_principal_id"
	ColHMACSessionID        = "hmac_session_id"
	ColHMACImpersonatedUser = "hmac_impersonated_user"
	ColEvidenceRefDigest    = "evidence_ref_digest"
)

// v2Columns is the complete, closed column set of the v2 layout, in the order schemaDef declares
// it. A test enumerates this against schemaDef() so a column added to one and not the other is a
// failure rather than a silent divergence.
var v2Columns = []string{
	"id",
	"timestamp",
	"layer",
	"fidelity",
	"source",
	"confidence",
	"description",
	"delegation_depth",
	SegmentSchemaVersionColumn,
	ColHMACActorHint,
	ColHMACActorID,
	ColHMACPrincipalID,
	ColHMACSessionID,
	ColHMACImpersonatedUser,
	ColEvidenceRefDigest,
	"labels",
}

// V2Columns returns the closed v2 column set.
func V2Columns() []string {
	out := make([]string, len(v2Columns))
	copy(out, v2Columns)
	return out
}

// SegmentSchemaOf reports which column-schema generation an Arrow record belongs to.
//
// Detection is by column presence, not by a stored flag on the table: a FrostDB table carries one
// schema, but a bucket accumulates blocks whose Parquet schemas diverge by design (dynamic columns
// guarantee it). So a corpus containing both generations is the normal steady state after this
// change, and the decoder — not the table — is where the generations are told apart.
func SegmentSchemaOf(r arrow.Record) string {
	if r == nil {
		return SegmentSchemaV1
	}
	for _, f := range r.Schema().Fields() {
		if f.Name == SegmentSchemaVersionColumn {
			return SegmentSchemaV2
		}
	}
	return SegmentSchemaV1
}
