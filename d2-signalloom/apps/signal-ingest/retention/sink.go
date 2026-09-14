// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package retention

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"
)

// SinkClass classifies a storage copy by the kind of thing it is.
//
// The class is not cosmetic: it decides the default period, whether purge is available in-process,
// and which residual statement is truthful.
type SinkClass string

const (
	ClassPrimary      SinkClass = "primary"
	ClassTransparency SinkClass = "transparency"
	ClassQueue        SinkClass = "queue"
	ClassCache        SinkClass = "cache"
	ClassSnapshot     SinkClass = "snapshot"
	ClassBackup       SinkClass = "backup"
	ClassExport       SinkClass = "export"
)

var allClasses = []SinkClass{
	ClassPrimary, ClassTransparency, ClassQueue, ClassCache, ClassSnapshot, ClassBackup, ClassExport,
}

// Valid reports whether c is a known class.
func (c SinkClass) Valid() bool {
	for _, known := range allClasses {
		if c == known {
			return true
		}
	}
	return false
}

// Reach says where a copy can be purged from.
//
// This distinction is the one that keeps the control honest. A copy Signal Loom cannot reach from
// inside its own process — a WAL segment, a physical backup, a subject-access export already
// delivered to a data subject — must still appear in the inventory, must still carry a deadline, and
// must therefore still be capable of going overdue. Leaving it out of the enumeration would make the
// gauge read zero for a reason that has nothing to do with the data being gone.
type Reach string

const (
	// ReachInProcess means the running service can delete this copy itself.
	ReachInProcess Reach = "in_process"

	// ReachExternalAttestation means deletion happens outside this process and must be attested back
	// in via SubmitExternalReceipt. Until it is, the copy is outstanding.
	ReachExternalAttestation Reach = "external_attestation"

	// ReachContinuityBearing means the bytes cannot be deleted without breaking attestation
	// verification. Its retention is enforced at its linkage copies instead; see the package comment.
	ReachContinuityBearing Reach = "continuity_bearing"
)

var (
	// ErrSinkUnreachable is the sentinel a sink returns when it could not be reached.
	//
	// It is a distinct error rather than a bool on PurgeOutcome so that it cannot be lost by a caller
	// that only checks err != nil, and cannot be mistaken for a successful no-op by one that only
	// checks the outcome.
	ErrSinkUnreachable = errors.New("retention: sink is unreachable; deletion was not demonstrated")

	// ErrSinkMisconfigured is returned when a sink was constructed without its dependency.
	ErrSinkMisconfigured = errors.New("retention: sink is misconfigured")
)

// PurgeRequest is one instruction to remove everything older than Before.
type PurgeRequest struct {
	TenantID string
	Before   time.Time
}

// PurgeOutcome is what a sink did.
type PurgeOutcome struct {
	RecordsRemoved    int64
	PartitionsDropped int

	// AlreadyAbsent reports that there was nothing in scope. Distinct from RecordsRemoved == 0
	// because "I looked and there was nothing older than the boundary" and "I removed zero rows for a
	// reason I did not report" are different claims.
	AlreadyAbsent bool

	// ResidualState is what this deletion did NOT reach. A sink that returns an empty residual is
	// refused by the controller: silence about residue reads as "nothing survives", which for any
	// PostgreSQL row and any unlinked file is false.
	ResidualState string

	// LinkageReceipts is set only by a continuity-bearing sink, naming the purges that made its
	// retained tokens unresolvable.
	LinkageReceipts []string
}

// Sink is one storage copy the controller can act on.
type Sink interface {
	SinkID() string
	Class() SinkClass
	Reach() Reach
	Purge(ctx context.Context, req PurgeRequest) (PurgeOutcome, error)
}

// SinkSpec is the declarative inventory entry for one copy.
//
// The inventory is data rather than code so that parity with the upstream inventory documents is a
// property a test can assert by PARSING THEM, rather than a property a reviewer has to check by
// reading. That distinction is the whole design: the sink set is the denominator of every coverage
// figure and every overdue count, so an authored set that drifts from the documents makes a
// forgotten sink LOWER the denominator and RAISE apparent coverage. See inventory_parity_test.go,
// which derives the expected set from both documents and fails when either gains a row this table
// does not carry.
type SinkSpec struct {
	ID    string
	Class SinkClass
	Reach Reach

	// DefaultPeriod is the bounded default. Every one is positive and at or under
	// MaxRetentionPeriod, asserted by test rather than by inspection.
	DefaultPeriod time.Duration

	// Residual is the truthful residual statement for this copy's substrate.
	Residual string

	// P6PRERow is the row number in the SLDP-P6-PRE §3 reconciled table, or 0 if that table omits
	// this copy.
	P6PRERow int

	// P0Row is the verbatim leading cell of this copy's row in the SLDP-P0 boundary map's
	// "Personal-data storage-copy inventory", or "" if that table omits it. Verbatim so the parity
	// test can match on it rather than on a paraphrase.
	P0Row string

	// CardNamed records a copy class the P6-1 card names in its approach ("queues, caches, snapshots,
	// backups and exports") that NEITHER upstream document enumerates.
	CardNamed bool

	// Notes records why a copy is classified as it is, for the proof document.
	Notes string
}

// Retention defaults by role. Named constants rather than inline literals so the proof document and
// the code cannot disagree about what was configured.
const (
	// DefaultIdentityPeriod covers the identity graph: actors, aliases, delegations.
	DefaultIdentityPeriod = 365 * 24 * time.Hour

	// DefaultLinkagePeriod covers the two copies that make a pseudonym resolvable. Deliberately the
	// SHORTEST period in the set: it is the lever the whole continuity resolution turns on, so the
	// sooner it expires the sooner a retained token stops being linkable.
	DefaultLinkagePeriod = 90 * 24 * time.Hour

	// DefaultObservationPeriod covers the columnar observation plane.
	DefaultObservationPeriod = 180 * 24 * time.Hour

	// DefaultEvidencePeriod covers the attestation plane. Longer than the observation plane because
	// evidence outliving the data it attests is the point of evidence.
	DefaultEvidencePeriod = 5 * 365 * 24 * time.Hour

	// DefaultCachePeriod covers in-memory and quarantine caches.
	DefaultCachePeriod = 7 * 24 * time.Hour

	// DefaultBackupPeriod covers physical backups and WAL.
	DefaultBackupPeriod = 35 * 24 * time.Hour

	// DefaultExportPeriod covers generated subject-access exports.
	DefaultExportPeriod = 30 * 24 * time.Hour
)

// AllSinkSpecs returns the complete inventory the controller enforces against: the UNION of the two
// upstream inventory documents, plus the copy classes the P6-1 card names that neither enumerates.
//
// The union, rather than either document alone, and the reason is a finding this card records.
// SLDP-P6-PRE §3 carries 23 numbered rows. The SLDP-P0 boundary map's "Personal-data storage-copy
// inventory" carries 21 unnumbered rows. NEITHER IS A SUBSET OF THE OTHER. P6-PRE added eleven
// copies P0 predates (the re-identification map, legal holds, subject keys, the erasure saga
// journal, the keyring, journal/checkpoints, tombstones, the audit in-memory buffer, the objection
// registry, the SPIREA tracker, and the Parquet/FrostDB split). P0 lists nine copies P6-PRE dropped:
// the portal `audit_events` table, audit-anchor local output, Rekor, the segment-attestor queues,
// the identity event bus, Redis, MinIO, backups/snapshots, and application/container logs — the last
// of which P0 marks "Emission confirmed; retention external and unproven".
//
// Taking the smaller set would have been the specific failure this card was warned about, and it is
// worse than a gap: the sink set is the DENOMINATOR of every coverage and overdue figure, so a
// forgotten copy does not show up as a hole, it shows up as higher coverage. Twenty copies would
// have had a gauge reading zero because nothing ever evaluated them.
//
// Three copies are carried with CardNamed because the P6-1 card's approach names "queues, caches,
// snapshots, backups and exports" and neither document enumerates a WAL, a filesystem snapshot or a
// generated export.
//
// Copies this process cannot delete carry ReachExternalAttestation. That includes the ones P0 marks
// "target use not found" (Redis, MinIO) and "Not found for target datasets" (backups/snapshots):
// absence of a confirmed copy is not evidence there is none, so they are outstanding until an
// operator attests otherwise — with DispositionAlreadyAbsent if the honest answer is that no copy
// exists. That keeps "we checked and there is nothing" distinguishable from "nobody looked".
func AllSinkSpecs() []SinkSpec {
	return []SinkSpec{
		// ---- SLDP-P6-PRE §3 rows 1-23 ----
		{ID: "postgres_actors", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 1, P0Row: "Identity PostgreSQL: `actors`",
			Notes: "identity/migrations/001_identity_graph.sql:5-14"},
		{ID: "postgres_aliases", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 2, P0Row: "Identity PostgreSQL: `aliases`",
			Notes: "HMAC pseudonym plus ciphertext alias values"},
		{ID: "postgres_delegations", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 3, P0Row: "Identity PostgreSQL: `delegations`",
			Notes: "the existing reaper at identity/repository.go:372-387 only flips status; this purges"},
		{ID: "postgres_segment_reidentification_map", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultLinkagePeriod, Residual: ResidualPostgresMVCC, P6PRERow: 4,
			Notes: "LINKAGE COPY: pseudonym to actor_id; purging this is what makes a retained segment token unresolvable"},
		{ID: "postgres_retention_legal_holds", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 5,
			Notes: "released holds only; an active hold is never in scope"},
		{ID: "postgres_subject_keys", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultLinkagePeriod, Residual: ResidualPostgresMVCC, P6PRERow: 6,
			Notes: "LINKAGE COPY: wrapped DEK making a pseudonym resolvable"},
		{ID: "postgres_subject_key_erasures", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 7,
			Notes: "erasure saga journal"},
		{ID: "identity_memory_repository", Class: ClassCache, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 8, P0Row: "Identity memory repository",
			Notes: "identity/memory.go:16-273 fallback store"},
		{ID: "frostdb_observations", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultObservationPeriod, Residual: ResidualNone, P6PRERow: 9, P0Row: "FrostDB/Parquet objects",
			Notes: "store.SignalStore.DropPartition; P0 collapses the store and its Parquet objects into one row, P6-PRE splits them"},
		{ID: "parquet_segment_objects", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 10,
			Notes: "verify.go:203 re-reads these bytes and verify.go:650-656 demands inventory set-equality; unlinking one fails VerifyCorpus"},
		{ID: "segment_evidence_directory", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 11, P0Row: "Segment evidence directory",
			Notes: "DSSE envelopes; digests and signer IDs only"},
		{ID: "attestation_public_keyring", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 12,
			Notes: "SPKI public keys; no personal data, required for post-KMS verification"},
		{ID: "attestation_journal_checkpoints", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 13,
			Notes: "chained Merkle roots; a gap is a hard verification error at verify.go:208"},
		{ID: "attestation_high_water", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 14, P0Row: "Segment protected high-water file",
			Notes: "high_water.json; its inventory list is what verify.go:654 compares against"},
		{ID: "attested_tombstones", Class: ClassTransparency, Reach: ReachContinuityBearing, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualAttestedBytes, P6PRERow: 15,
			Notes: "P4-2 non-linkable tombstones; nonce-salted commitments, no subject ID"},
		{ID: "observation_memory_store", Class: ClassCache, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 16, P0Row: "Observation memory store",
			Notes: "store/memory.go:84-97 DropPartition filters the slice; the shipped default store"},
		{ID: "postgres_signal_audit_trail", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P6PRERow: 17, P0Row: "Signal audit PostgreSQL",
			Notes: "the tamper-evident audit trail; retained longer than observations by design"},
		{ID: "audit_memory_buffer", Class: ClassQueue, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 18,
			Notes: "in-process audit buffer"},
		{ID: "k8s_audit_channel_buffer", Class: ClassQueue, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 19, P0Row: "Kubernetes-audit receiver channel",
			Notes: "normalized principal, impersonated user, object names, namespaces"},
		{ID: "workstation_objection_registry", Class: ClassPrimary, Reach: ReachInProcess, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualNone, P6PRERow: 20,
			Notes: "Article 21 objection registry; an objection is itself personal data"},
		{ID: "quarantine_state_cache", Class: ClassCache, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 21, P0Row: "Quarantine caches",
			Notes: "correlation/quarantine.go; also the hold source privacy.QuarantineIncidentSource reads"},
		{ID: "spirea_tracker_cache", Class: ClassCache, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P6PRERow: 22,
			Notes: "collectors/spirea/tracker.go SPIFFE identity tracker"},
		{ID: "archivista_external", Class: ClassBackup, Reach: ReachExternalAttestation, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualFilesystemUnlinked, P6PRERow: 23, P0Row: "Archivista",
			Notes: "external OCI/MinIO attestation store; deletion is the operator's, not this process's"},

		// ---- SLDP-P0 rows the P6-PRE reconciliation dropped. Recorded finding; see the comment above. ----
		{ID: "portal_audit_events", Class: ClassPrimary, Reach: ReachExternalAttestation, DefaultPeriod: DefaultIdentityPeriod, Residual: ResidualPostgresMVCC, P0Row: "Portal `audit_events` PostgreSQL",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. Configured external input to the anchor plane; tenant, actor, agent, detail JSON"},
		{ID: "audit_anchor_local_output", Class: ClassExport, Reach: ReachExternalAttestation, DefaultPeriod: DefaultExportPeriod, Residual: ResidualFilesystemUnlinked, P0Row: "Audit-anchor local output and verifier",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. Python anchor plane output; no deployed scheduler found at P0"},
		{ID: "rekor_transparency_log", Class: ClassTransparency, Reach: ReachExternalAttestation, DefaultPeriod: DefaultEvidencePeriod, Residual: ResidualNotDemonstrated, P0Row: "Rekor",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. Not implemented at P0; a public append-only log is UNDELETABLE, so any future publication needs a pre-publication gate, not a retention sweep"},
		{ID: "segment_attestor_queues", Class: ClassQueue, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P0Row: "Segment-attestor queues",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. Process-local; segment path, digest, byte count, errors"},
		{ID: "identity_event_bus", Class: ClassQueue, Reach: ReachInProcess, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNone, P0Row: "Identity event bus",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. Process-local; SPIFFE identity, pod, namespace, PID, IP, revocation reason"},
		{ID: "redis_shared", Class: ClassCache, Reach: ReachExternalAttestation, DefaultPeriod: DefaultCachePeriod, Residual: ResidualNotDemonstrated, P0Row: "Redis",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. P0 says 'target use not found', which is absence of evidence, not evidence of absence"},
		{ID: "minio_object_store", Class: ClassBackup, Reach: ReachExternalAttestation, DefaultPeriod: DefaultBackupPeriod, Residual: ResidualNotDemonstrated, P0Row: "Signal Loom MinIO",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. P0 says 'target use not found'"},
		{ID: "postgres_physical_backup", Class: ClassBackup, Reach: ReachExternalAttestation, DefaultPeriod: DefaultBackupPeriod, Residual: ResidualPostgresMVCC, P0Row: "Backups/snapshots",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. The copy most likely to outlive the primary record; P0 found no backup tooling for target datasets"},
		{ID: "application_container_logs", Class: ClassExport, Reach: ReachExternalAttestation, DefaultPeriod: DefaultExportPeriod, Residual: ResidualNotDemonstrated, P0Row: "Application/container logs",
			Notes: "FINDING: dropped by the P6-PRE reconciliation. P0: 'Emission confirmed; retention external and unproven'. Carries actor IDs, IPs, pod names, segment paths"},

		// ---- Copy classes the P6-1 card names and neither document enumerates. ----
		{ID: "postgres_wal", Class: ClassQueue, Reach: ReachExternalAttestation, DefaultPeriod: DefaultBackupPeriod, Residual: ResidualPostgresMVCC, CardNamed: true,
			Notes: "holds pre-deletion tuple versions; expires by WAL retention outside this process. The residual every Postgres receipt already names"},
		{ID: "filesystem_snapshot", Class: ClassSnapshot, Reach: ReachExternalAttestation, DefaultPeriod: DefaultBackupPeriod, Residual: ResidualFilesystemUnlinked, CardNamed: true,
			Notes: "an unlinked evidence or export file remains in any volume snapshot taken before the unlink"},
		{ID: "subject_access_export", Class: ClassExport, Reach: ReachExternalAttestation, DefaultPeriod: DefaultExportPeriod, Residual: ResidualFilesystemUnlinked, CardNamed: true,
			Notes: "Article 15 exports leave the boundary; only the local copy is reachable"},
	}
}

// P6PREInventoryRows is the number of numbered rows in the SLDP-P6-PRE §3 reconciled table.
//
// Pinned as a constant so the parity test compares two independently-derived numbers rather than
// comparing a list against itself. It is 23, not 15 — an earlier draft of this package read 15 from
// a windowed extract of the document and would have left twenty copies unevaluated with the gauge
// reading zero.
const P6PREInventoryRows = 23

// P0InventoryRows is the number of rows in the SLDP-P0 boundary map's personal-data storage-copy
// inventory.
const P0InventoryRows = 21

// InventorySinkSpecs returns only the specs that map onto a SLDP-P6-PRE §3 row.
func InventorySinkSpecs() []SinkSpec {
	var out []SinkSpec
	for _, s := range AllSinkSpecs() {
		if s.P6PRERow > 0 {
			out = append(out, s)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].P6PRERow < out[j].P6PRERow })
	return out
}

// SpecByID returns the spec for a sink ID.
func SpecByID(id string) (SinkSpec, bool) {
	for _, s := range AllSinkSpecs() {
		if s.ID == id {
			return s, true
		}
	}
	return SinkSpec{}, false
}

// AllSinkIDs returns every sink ID in the inventory, sorted.
func AllSinkIDs() []string {
	specs := AllSinkSpecs()
	ids := make([]string, 0, len(specs))
	for _, s := range specs {
		ids = append(ids, s.ID)
	}
	sort.Strings(ids)
	return ids
}

// RowPurger removes rows older than before from one store, returning the count removed.
//
// The controller depends on this function type rather than on a concrete repository so that every
// sink is testable without a database, which is the only way the fail-closed paths get exercised at
// all. A nil RowPurger is refused at construction, not treated as a no-op.
type RowPurger func(ctx context.Context, tenantID string, before time.Time) (int64, error)

// PartitionDropper is the slice of store.SignalStore this package needs.
//
// Declared locally rather than importing store.SignalStore so the dependency direction stays one-way
// and the frostdb build tag does not leak into this package.
type PartitionDropper interface {
	DropPartition(ctx context.Context, before time.Time) error
}

// rowSink purges rows from a relational or in-memory store.
type rowSink struct {
	spec   SinkSpec
	purger RowPurger
}

// NewRowSink builds an in-process row-purging sink.
func NewRowSink(spec SinkSpec, purger RowPurger) (Sink, error) {
	if purger == nil {
		return nil, fmt.Errorf("%w: sink %q has no row purger; a nil purger would report success without deleting anything", ErrSinkMisconfigured, spec.ID)
	}
	if spec.ID == "" || !spec.Class.Valid() {
		return nil, fmt.Errorf("%w: sink spec %+v is incomplete", ErrSinkMisconfigured, spec)
	}
	return &rowSink{spec: spec, purger: purger}, nil
}

func (s *rowSink) SinkID() string   { return s.spec.ID }
func (s *rowSink) Class() SinkClass { return s.spec.Class }
func (s *rowSink) Reach() Reach     { return s.spec.Reach }

func (s *rowSink) Purge(ctx context.Context, req PurgeRequest) (PurgeOutcome, error) {
	removed, err := s.purger(ctx, req.TenantID, req.Before)
	if err != nil {
		return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, err
	}
	return PurgeOutcome{
		RecordsRemoved: removed,
		AlreadyAbsent:  removed == 0,
		ResidualState:  s.spec.Residual,
	}, nil
}

// partitionSink purges the columnar observation plane via DropPartition.
type partitionSink struct {
	spec  SinkSpec
	store PartitionDropper
	// rows reports how many observations the drop covered. Optional: DropPartition returns no count,
	// and inventing one would be worse than reporting a partition with no row figure.
	rows RowPurger
}

// NewPartitionSink builds the columnar sink.
func NewPartitionSink(spec SinkSpec, dropper PartitionDropper, rows RowPurger) (Sink, error) {
	if dropper == nil {
		return nil, fmt.Errorf("%w: sink %q has no partition dropper", ErrSinkMisconfigured, spec.ID)
	}
	return &partitionSink{spec: spec, store: dropper, rows: rows}, nil
}

func (s *partitionSink) SinkID() string   { return s.spec.ID }
func (s *partitionSink) Class() SinkClass { return s.spec.Class }
func (s *partitionSink) Reach() Reach     { return s.spec.Reach }

func (s *partitionSink) Purge(ctx context.Context, req PurgeRequest) (PurgeOutcome, error) {
	var removed int64
	if s.rows != nil {
		// Count BEFORE dropping. Counting after would always return zero and the receipt would
		// report a successful purge of nothing.
		n, err := s.rows(ctx, req.TenantID, req.Before)
		if err != nil {
			return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, err
		}
		removed = n
	}
	if err := s.store.DropPartition(ctx, req.Before); err != nil {
		return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, err
	}
	return PurgeOutcome{
		RecordsRemoved:    removed,
		PartitionsDropped: 1,
		AlreadyAbsent:     removed == 0,
		ResidualState:     s.spec.Residual,
	}, nil
}

// continuitySink represents attested bytes that cannot be deleted without breaking verification.
//
// It never touches a file. Its Purge reports what the linkage purges achieved, and the controller
// turns that into a DispositionRetainedUnresolvableToken receipt. If the linkage purges did not
// happen, this sink reports unreachable — so the attested plane goes OVERDUE rather than reporting a
// disposition it has not earned.
type continuitySink struct {
	spec SinkSpec

	// linkage names the sinks whose successful purge is this sink's precondition.
	linkage []string

	// completed is supplied by the controller: the operation IDs of linkage purges that completed in
	// this sweep or a previous one.
	completed func(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error)
}

// NewContinuitySink builds a continuity-bearing sink.
func NewContinuitySink(spec SinkSpec, linkage []string, completed func(ctx context.Context, tenantID string, sinkIDs []string) ([]string, error)) (Sink, error) {
	if len(linkage) == 0 {
		return nil, fmt.Errorf("%w: continuity sink %q declares no linkage copies; its retention would be unenforceable", ErrSinkMisconfigured, spec.ID)
	}
	if completed == nil {
		return nil, fmt.Errorf("%w: continuity sink %q has no linkage lookup", ErrSinkMisconfigured, spec.ID)
	}
	return &continuitySink{spec: spec, linkage: linkage, completed: completed}, nil
}

func (s *continuitySink) SinkID() string   { return s.spec.ID }
func (s *continuitySink) Class() SinkClass { return s.spec.Class }
func (s *continuitySink) Reach() Reach     { return s.spec.Reach }

// Purge deletes nothing. It reports whether the linkage purges that make this sink's retained tokens
// unresolvable have completed.
func (s *continuitySink) Purge(ctx context.Context, req PurgeRequest) (PurgeOutcome, error) {
	digests, err := s.completed(ctx, req.TenantID, s.linkage)
	if err != nil {
		return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, err
	}
	if len(digests) < len(s.linkage) {
		return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, fmt.Errorf(
			"%w: sink %q requires %d completed linkage purges, found %d",
			ErrSinkUnreachable, s.spec.ID, len(s.linkage), len(digests))
	}
	return PurgeOutcome{
		ResidualState:   s.spec.Residual,
		LinkageReceipts: digests,
	}, nil
}

// externalSink represents a copy this process cannot delete.
//
// Its Purge ALWAYS returns ErrSinkUnreachable. That is not a stub: it is the truthful answer, and it
// is what makes the copy outstanding until an operator attests otherwise via
// Controller.SubmitExternalReceipt. A sink that cannot act and returns success is the fail-open path
// this card exists to close.
type externalSink struct {
	spec SinkSpec
}

// NewExternalSink builds an externally-attested sink.
func NewExternalSink(spec SinkSpec) Sink { return &externalSink{spec: spec} }

func (s *externalSink) SinkID() string   { return s.spec.ID }
func (s *externalSink) Class() SinkClass { return s.spec.Class }
func (s *externalSink) Reach() Reach     { return s.spec.Reach }

func (s *externalSink) Purge(_ context.Context, _ PurgeRequest) (PurgeOutcome, error) {
	return PurgeOutcome{ResidualState: ResidualNotDemonstrated}, fmt.Errorf(
		"%w: sink %q is purged outside this process and requires an external deletion attestation",
		ErrSinkUnreachable, s.spec.ID)
}
