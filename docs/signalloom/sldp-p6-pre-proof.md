# SLDP-P6-PRE — Phase 6 Preflight Proof

**Card:** SLDP-P6-PRE (preflight) · **Depends on:** P5-GOV · **Status:** pass
**Worktree:** `/home/andy/src/.worktrees/0bc3e/osramp-demo` (detached, base `integration/sldp-v0.1.0`)
**Base commit at start of run:** `f11422a919e6ffa679ebde24c8c6de26b8fe9cdf`
**Executed:** 2026-09-14

---

## 1. Executive Summary & Objectives

Phase 6 preflight prepares the foundation for Phase 6 (Retention Controller, Self-Hosted Deployment Proof, and Final Governance Certification). This preflight achieves four required deliverables:

1. **Reconciled Storage-Copy Inventory**: Audited all storage sinks and data paths added across Phases 1 through 5 against the original P0 baseline map.
2. **Confirmation of Retention / Deletion Absence**: Verified with exact file and line references that zero deletion or retention execution code exists in the repository, sizing SLDP-P6-1 as a complete new build.
3. **Settled Deployment Model Decision**: Established customer-self-hosted Kubernetes deployment as the **primary** validation target for SLDP-P6-2, with vendor-operated GKE designated as a secondary reference overlay.
4. **Restated Deletion-Receipt Format**: Restated the cryptographic deletion-receipt format established in Phase 4 for consumption by P6-1 retention sweeps.

---

## 2. Baseline & Worktree Verification

| Check | Command | Result | Evidence / Citations |
| :--- | :--- | :--- | :--- |
| **Worktree Clean** | `git status --porcelain` | Clean (`0` modified files) | Workspace is clean |
| **Base Ref Inheritance** | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` | `exit 0` | Verified ancestor of `integration/sldp-v0.1.0` (`f11422a919e6ffa679ebde24c8c6de26b8fe9cdf`) |
| **PWD Isolation Gate** | `pwd` | `/home/andy/src/.worktrees/0bc3e/osramp-demo` | Dedicated isolated worktree, distinct from principal checkout |
| **Required Test 1** | `rg -c 'EventPartitionDropped' d2-signalloom/apps/signal-ingest/audit/audit.go` | `2` | `audit/audit.go:28,40` |
| **Required Test 2** | `rg -l 'DeleteActor\|PurgeObservations\|EraseSubject' d2-signalloom` | `2 files` | `api/erasure.go`, `api/auth.go` (`handleEraseSubject`); 0 matches for `DeleteActor`/`PurgeObservations` |
| **Required Test 3** | `make test-signal-ingest` | `PASS` (`ok`, 24 packages) | `make test-signal-ingest` passes 100% |
| **Coverage Spec Guard** | `bats test/acceptance-spec-coverage.bats` | `PASS` (7/7) | CI Stage 1c coverage suite passing |

---

## 3. Reconciled Storage-Copy Inventory (P0 Baseline vs Current P6 State)

The table below reconciles the storage-copy inventory from the P0 baseline against the active codebase following the delivery of Phases 1 through 5.

| # | Sink / Data Copy | Plane | Status in Repo | Personal / Linkable Data Retained | Citations & Implementation Details |
|---|---|---|---|---|---|
| **1** | `actors` (PostgreSQL) | Identity | **Active with `DATABASE_URL`** | Actor UUID, status, created/updated timestamps, envelope-encrypted metadata JSON | Schema: `identity/migrations/001_identity_graph.sql:5-14`<br/>Writes: `identity/repository.go:66-103`<br/>RLS: `006_tenant_isolation_rls.sql:35-47` |
| **2** | `aliases` (PostgreSQL) | Identity | **Active with `DATABASE_URL`** | `actor_id`, `alias_type`, `alias_value_hmac` (64-hex HMAC pseudonym), `alias_value_encrypted` (ciphertext), fidelity, validity | Schema: `001_identity_graph.sql:16-26`, `005_pseudonymisation_and_encryption.sql:1-120`<br/>Writes: `identity/repository.go:145-224`<br/>RLS: `006_tenant_isolation_rls.sql:49-61` |
| **3** | `delegations` (PostgreSQL) | Identity | **Active with `DATABASE_URL`** | `principal_id`, `delegate_id`, `authz_ref_encrypted` (ciphertext), encrypted metadata, validity, revocation state | Schema: `001_identity_graph.sql:29-42`, `004_delegation_revocation.sql:1-25`, `005_pseudonymisation_and_encryption.sql`<br/>Writes: `identity/repository.go:255-300`<br/>RLS: `006_tenant_isolation_rls.sql:63-75` |
| **4** | `segment_reidentification_map` (PostgreSQL) | Identity | **Active with `DATABASE_URL` (Added P2/P3)** | `tenant_id`, `segment_path`, `pseudonym`, `actor_id`, `created_at` | Schema: `007_segment_reidentification_map.sql:1-40`<br/>Writes: `identity/repository.go`<br/>RLS: `007_segment_reidentification_map.sql:30-40` |
| **5** | `retention_legal_holds` (PostgreSQL) | Identity / Privacy | **Active with `DATABASE_URL` (Added P3-2)** | `id`, `tenant_id`, `scope_type`, `scope_id`, `reason`, `authorized_by`, `dual_operator_id`, `created_at`, `released_at`, `released_by` | Schema: `008_retention_legal_holds.sql:59-100`<br/>Writes: `privacy/postgres.go:30-70`, `privacy/legal_hold.go`<br/>RLS: `008_retention_legal_holds.sql:85-98` |
| **6** | `subject_keys` (PostgreSQL) | Identity / Crypto | **Active with `DATABASE_URL` (Added P4-1)** | `tenant_id`, `subject_pseudonym` (64-hex), `key_epoch`, `key_version`, `wrapped_dek` (60 bytes), `prior_wrapped_digest`, `created_at`, `destroyed_at` | Schema: `009_subject_keys.sql:67-120`<br/>Writes: `subjectkey/postgres.go:50-120`, `subjectkey/store.go`<br/>RLS: `009_subject_keys.sql:228-234` |
| **7** | `subject_key_erasures` (PostgreSQL) | Identity / Saga | **Active with `DATABASE_URL` (Added P4-1)** | `operation_id`, `tenant_id`, `subject_pseudonym`, `state`, `target_versions`, `nonce`, `receipt_digest`, `started_at`, `updated_at`, `completed_at` | Schema: `009_subject_keys.sql:157-205`<br/>Writes: `subjectkey/postgres.go:130-220`<br/>RLS: `009_subject_keys.sql:235-241` |
| **8** | Identity In-Memory Repository | Identity | **Active fallback / test store** | In-memory representations of actors, encrypted aliases, delegations, legal holds, subject keys, and erasure sagas | Implementation: `identity/memory.go:16-273`, `privacy/memory.go`, `subjectkey/memory.go` |
| **9** | FrostDB Active Columnar Store | Columnar | **Active with `-tags frostdb`** | Dynamic schema containing HMAC pseudonyms (`actor_pseudonym`, `principal_pseudonym`, `impersonated_user_pseudonym`), redacted IPs, scrubbed descriptions, dynamic labels | Schema: `store/frostdb.go:138-250`, `store/schema.go`<br/>Append: `store/frostdb.go:167-250` |
| **10** | Parquet Segment Objects | Columnar Storage | **Active with FrostDB store** | Immutable signed Arrow/Parquet byte blocks written to local storage / bucket | Writer: `store/frostdb.go:485-512`, `store/segment_attestor.go:931-949` |
| **11** | Segment Evidence Directory | Attestation Plane | **Active when attestation enabled** | `<EvidenceDir>/segments/<digest>.evidence.json` containing DSSE envelopes, predicates, segment digests, signer IDs | `store/segment_attestor.go:128-179,673-929` |
| **12** | Attestation Public Keyring | Attestation Plane | **Active (Added P5-1)** | `<EvidenceDir>/keys/<SPKI-SHA256>.pem` storing retained SPKI public key material for post-KMS verification | `store/segment_attestor.go:225-233`, `store/verify/verify.go:40-85` |
| **13** | Attestation Journal & Checkpoints | Attestation Plane | **Active when attestation enabled** | `<EvidenceDir>/journal.jsonl`, `<EvidenceDir>/checkpoints/<seq>.checkpoint.json` containing chained Merkle roots and sequence numbers | `store/segment_attestor.go:145-158,770-850` |
| **14** | Protected High-Water File | Attestation Plane | **Active when attestation enabled** | `<EvidenceDir>/high_water.json` (mode 0600) storing sequence, journal count, segment tip, and lost-error counts | `store/segment_attestor.go:159-168,905-910`, `store/factory_frostdb.go:36-39` |
| **15** | Attested Tombstones | Attestation Plane | **Active (Added P4-2)** | `<EvidenceDir>/tombstones/<id>.tombstone.json` containing DSSE-signed non-linkable tombstone metadata (`ReceiptCommitment`, `ReceiptNonce`, `KeysDestroyedBand`, `ErasedDay`) | `privacy/tombstone/tombstone.go:120-170,660-720`, `privacy/tombstone/publisher.go` |
| **16** | Observation Memory Store | In-Memory Store | **Active default without `-tags frostdb`** | Process-local slice of observation records; lost on restart | `store/memory.go:11-97`, `store/factory.go:1-8` |
| **17** | `signal_audit_trail` (PostgreSQL) | Audit Plane | **Active with `DATABASE_URL`** | `tenant_id`, `event_type`, `actor_id` (pseudonymized), `detail` JSON (scrubbed), `created_at`. Includes `partition_dropped` events for permitted erasures | Schema: `d2-signalloom/contracts/discovery-portal-bootstrap.sql:336-358`<br/>Writes: `audit/postgres.go:130-152`, `privacy/erasure.go:493-507` |
| **18** | Audit In-Memory Buffer | Audit Plane | **Active fallback / test** | Ring buffer of audit events | `audit/fake.go:10-50` |
| **19** | Kubernetes Audit Channel Buffer | Ingestion | **Active when receiver runs** | Ring buffer of normalized K8s audit events before batch insertion | `api/audit/receiver.go:108-145,245-353` |
| **20** | Workstation Sensor Objection Registry | Sensor Edge | **Active in sensor (Added P5-3)** | In-memory `_objections` map in host sensor matching `actor_id`, `username`, `email` to suppress process sampling (Article 21) | `agentmaxxing-host-sensor/filter.py:144-194`, `sensor.py:80-120` |
| **21** | Quarantine State Cache | Containment | **Active when correlation runs** | Process-local cache of quarantined actor identities, pods, and IP addresses | `correlation/quarantine.go:23-55,265-335`, `correlation/stun_client.go:341-388` |
| **22** | SPIREA Tracker Cache | Collectors | **Active when Spirea collector runs** | Process-local map of active SPIFFE ID to IP mappings with `EvictExpired` | `collectors/spirea/tracker.go:161-180` |
| **23** | Archivista (External OCI/MinIO) | External Store | **Optional target** | DSSE attestation envelopes persisted to Archivista OCI artifact registry | `audit_anchor/anchor.py:269-336`, `store/segment_attestor.go:704-708` |

---

## 4. Confirmation: Zero Deletion / Retention Implementation Exists

A rigorous static scan and code audit confirm that **no retention execution or deletion controller code exists to extend**:

1. **`EventPartitionDropped` in `audit/audit.go:28,40`**:
   - `EventPartitionDropped` is defined in `audit/audit.go:28,40`.
   - The only call site is `privacy/erasure.go:495` (`writeDecision`), which logs permitted Article 17 erasure decisions to `signal_audit_trail`.
   - Zero partition-dropping retention jobs or controllers emit this event.
2. **`DropPartition` Method Analysis**:
   - `FrostDBStore.DropPartition` (`store/frostdb.go:728-735`):
     ```go
     func (f *FrostDBStore) DropPartition(_ context.Context, before time.Time) error {
         f.mu.Lock()
         defer f.mu.Unlock()
         if before.After(f.droppedBefore) {
             f.droppedBefore = before
         }
         return nil
     }
     ```
     This method purely updates an in-memory timestamp `f.droppedBefore` to filter subsequent query responses. It does **not** unlink, delete, or truncate physical Parquet files from disk or object storage.
   - `MemoryStore.DropPartition` (`store/memory.go:84-97`): Filters the in-memory observation slice.
   - Zero callers in `main.go`, `api/`, or background workers invoke `DropPartition` on a schedule.
3. **Absence of SQL Deletions**:
   - `rg 'DELETE FROM' d2-signalloom` returns zero matches across all application repositories.
   - `identity/repository.go:372-387` (`ReapExpiredDelegations`) executes `UPDATE delegations SET status = 'expired'`, updating status flags without removing data.
4. **`privacy.Retention` Evaluator (`privacy/retention.go:47-106`)**:
   - Implements a decision engine reconciling retention periods against `retention_legal_holds` (Article 17(3)).
   - Evaluates `RetentionDecision{Due, Deletable, Holds, Reason}`, but contains zero deletion execution logic.
5. **Conclusion & Sizing**:
   - SLDP-P6-1 must build the complete retention controller, background reconciliation loops, multi-sink deletion dispatchers, and deletion receipt emitters from scratch.

---

## 5. Settled Deployment Model Decision for P6-2

### 5.1 Primary Validation Target: Customer-Self-Hosted Kubernetes Deployment
- **Decision:** Customer-Self-Hosted Kubernetes deployment is settled as the **primary** validation target for SLDP-P6-2.
- **Architectural Rationale:**
  - In regulated banking and financial environments (Tier-1 banks, ARC-class design partners), identity graph telemetry and security evidence cannot leave the customer's controlled network boundary.
  - The customer acts as the GDPR **Data Controller**; Signal Loom operates as software deployed directly within the customer's dedicated Kubernetes cluster / VPC.
  - Software dependencies (PostgreSQL, MinIO / local object store, Vault / local KMS, cert-manager, Envoy Gateway) must operate independently of vendor cloud services.
- **P6-2 Scope & Acceptance:**
  - Deliver self-hosted deployment manifests (Flux ResourceSets / Kustomize overlays in `d2-signalloom/`).
  - Validate in-cluster deployment, automated migration execution (001–009), fail-closed security configuration, and retention/erasure execution via `docs/signalloom/sldp-p6-2-selfhost-install-proof.md`.

### 5.2 Secondary Reference Target: Vendor-Operated GKE Deployment
- **Status:** Labelled strictly as a **secondary reference overlay**.
- **Scope:** Documents Cloud KMS key integration, Cloud SQL connectivity, and GKE Workload Identity bindings as a reference deployment pattern without gating customer-self-hosted delivery.

---

## 6. Deletion-Receipt Format for P6-1

Building upon the cryptographic receipt patterns established in Phase 4 (`privacy.KeyDestructionReceipt` in `privacy/erasure.go:99-121` and `subjectkey.DestructionReceipt` in `subjectkey/receipt.go:88-105`), P6-1 retention deletion sweeps will emit an attested `RetentionDeletionReceipt` for every storage copy purged:

```go
type RetentionDeletionReceipt struct {
    Schema            string    `json:"schema"`             // "signalloom.retention-deletion-receipt/v1"
    OperationID       string    `json:"operation_id"`      // Deterministic hex SHA-256(tenant_id, sink_id, dropped_before)
    TenantID          string    `json:"tenant_id"`
    SinkID            string    `json:"sink_id"`           // e.g. "frostdb_parquet", "postgres_identity", "postgres_audit", "quarantine_cache"
    DroppedBefore     time.Time `json:"dropped_before"`    // Truncated to integer microseconds (no nanosecond drift)
    RecordsRemoved    int64     `json:"records_removed"`
    PartitionsDropped int       `json:"partitions_dropped"`
    EvaluatedAt       time.Time `json:"evaluated_at"`
    CompletedAt       time.Time `json:"completed_at"`
    ReceiptNonce      string    `json:"receipt_nonce"`     // 32-byte hex CSPRNG nonce
    ReceiptDigest     string    `json:"receipt_digest"`    // Hex SHA-256 over canonical binary encoding
    ResidualState     string    `json:"residual_state"`    // Explicit declaration of residual copies (e.g. WAL/backup retention)
    ComplianceNote    string    `json:"compliance_note"`   // e.g. "article_5_1_e_storage_limitation_satisfied_for_expired_partition"
}
```

### Key Invariants for P6-1:
1. **Canonical Binary Encoding**: `ReceiptDigest` must be computed via a deterministic binary encoding (`binary.BigEndian` with length prefixes and microsecond timestamps) matching the `subjectkey/receipt.go` pattern to prevent JSON canonicalization drift.
2. **CSPRNG Salting**: Every receipt carries a 32-byte CSPRNG `ReceiptNonce` to prevent dictionary/rainbow-table linkage.
3. **Audit Trail Linkage**: Retention sweeps must emit a corresponding `audit.EventPartitionDropped` audit event to `signal_audit_trail` carrying `ReceiptDigest`, `SinkID`, and partition parameters.

---

## 7. Assumptions, Limits & Unconfirmed Items

In accordance with the preflight mandate, the following assumptions are documented explicitly:

1. **FrostDB Physical Segment File Unlinking (Unconfirmed)**:
   - `FrostDBStore.DropPartition` currently modifies only an in-memory timestamp cutoff. Whether FrostDB supports safe physical unlinking of underlying `.parquet` segment files without table corruption or invalidating active block readers must be proven during P6-1 implementation.
2. **PostgreSQL WAL and Physical Backup Residuals (Confirmed Limitation)**:
   - Dropping database rows in PostgreSQL creates dead tuples that remain in WAL segments and physical backups until `VACUUM` and backup expiration. P6-1 receipts must declare `StorageResidualMVCCAndBackup` rather than claiming bit-level disk erasure.
3. **Host Sensor Article 21 In-Memory Scope (Confirmed Limitation)**:
   - `agentmaxxing-host-sensor/filter.py` objection registry is process-local and in-memory. Deletion controllers cannot reach workstation sensor memory; sensor restart behavior remains governed by edge deployment policies.

---

## 8. Verification & Next Actions

- **Baseline Tests**: Verified clean baseline (`make test-signal-ingest` PASS, `bats test/acceptance-spec-coverage.bats` PASS).
- **Errata Updated**: SLDP-P6-PRE errata block appended to the proposal with `status=pass`.
- **Ready for Implementation**: SLDP-P6-1 (Retention Controller) and SLDP-P6-2 (Self-Hosted Install Proof) may proceed.
