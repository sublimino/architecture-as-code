# AMXO-P5-PRE — Phase 5 Server-Side Session Verification and Ingestion Preflight Proof

**Status:** PASS — Phase 5 Server-Side Session Verification, Ingestion Pipeline & Tenant Evidence Projections may proceed from verified baseline  
**Verified at:** 2026-09-13 19:20:00+01:00  
**Logical ID:** `P5-PRE`  
**Role:** preflight  
**Launch base:** `edbf6d0f6565367d6dc934fa8da1c12ff93a285a`  
**Integration tip inspected:** `98792e9124430f80bc24ad1f49ae6a45fcbcf1c6`  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/osramp-demo/agentmaxxing-onboarding-v0.1.0/governor`

---

## 1. Executive Summary & Verdict

Phase 4 deliverables (Linux host confinement profile, systemd unit, SHA-256 preflight digest gate, bounded process lifecycle telemetry sensor, descriptor-relative `openat2` anti-escape validation, streaming artifact hasher, and post-read TOCTOU verification) are fully merged and certified on `integration/agentmaxxing-onboarding-v0.1.0`.

Preflight verification for Phase 5 confirms:
1. **Go Session-Integrity Verifier Ownership:** Go package `d2-signalloom/apps/signal-ingest/collectors/agentnono` is confirmed as the authoritative session-integrity verification service across 18 test suites (0 failures). In accordance with the Architectural Constitution, FastAPI `fe-signalloom` does NOT implement an independent verifier; FastAPI acts as the tenant-facing identity, registration, authorization, and audit projection plane.
2. **Accepted Host Fixture Digests:** All Phase 4 host sensor and confinement fixtures are present on disk, syntactically valid, and verified against pinned SHA-256 digests:
   - `profile.json`: `79480c7cfeb31bd8d8d09c781a701a550a80f266bbe398ce928f867278143773`
   - `agentmaxxing-agent.service`: `8aa008f75ea34ff05350428c1cecd610c3b361c080660750fcdf146ab8188e49`
   - `process-lifecycle-telemetry.v1.schema.json`: `bd820bff2bcfc7014d8f5030aef860d143d2f3c63d3042e0c82ae7008ca435ca`
   - `agentmaxxing-host-policy.v1.json`: `6435bae4e0fafbfbe84241fd06aadfb6fe022b1cd67f4aaf608e148701b4c43a`
   - `agentmaxxing-raw-telemetry.v1.json`: `072934471d9d10b722a1ce4d5f01e3ef33e9b152c253273ada4c043f8354d0d6`
3. **Database Migration Sequence Audit:** The database migration sequence in `d2-signalloom/apps/fe-signalloom/src/db/migrations/` is contiguous and strictly ordered through `041_external_host_revocation.sql`. Migration `042` is completely uncontested and designated for Phase 5 allowlisted evidence persistence and tenant-scoped projections (`AMXO-P5-3`).
4. **Wire Contracts & Ingestion Boundaries:** The HTTP boundary for audit session upload and telemetry ingestion preserves strict tenant-agent binding. The host credentials generated in Phase 3 (`HostCredentialScopeMiddleware`) enforce audit-upload-only scope, preventing external hosts from calling administrative or tenant management APIs.
5. **Phase 4 Host Confinement & Anti-Escape Baseline:** The unified host test suite (`make demo-agentmaxxing-host-test`) passes 70/70 tests with zero skips and zero failures across Linux kernel Landlock LSM, cgroups v2 resource accounting, procfs collectors, `openat2` anti-escape descriptors, and concurrent TOCTOU mutations.
6. **Doctor Check & Repository Cleanliness:** `kanban-check.sh doctor` reports 0 blocking exceptions, 0 action exceptions, 0 unmerged commits, and 0 dangling commits.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Evidence / Probe | Result |
| :--- | :--- | :---: |
| Integration ancestry | `git merge-base --is-ancestor edbf6d0f integration/agentmaxxing-onboarding-v0.1.0` exited `0` | PASS |
| Phase 4 deliverables merged | Commit `edbf6d0f` on integration branch contains all Phase 4 modules | PASS |
| Migration sequence audit | Migrations `001`–`041` contiguous; next available migration slot is `042` | PASS |
| Go verifier suite | `go test -v ./collectors/agentnono/...` passed 18/18 test suites (0 failures) | PASS |
| Host fixture digest: profile | `79480c7cfeb31bd8d8d09c781a701a550a80f266bbe398ce928f867278143773` | PASS |
| Host fixture digest: systemd | `8aa008f75ea34ff05350428c1cecd610c3b361c080660750fcdf146ab8188e49` | PASS |
| Host fixture digest: schema | `bd820bff2bcfc7014d8f5030aef860d143d2f3c63d3042e0c82ae7008ca435ca` | PASS |
| Host fixture digest: policy | `6435bae4e0fafbfbe84241fd06aadfb6fe022b1cd67f4aaf608e148701b4c43a` | PASS |
| Host fixture digest: telemetry | `072934471d9d10b722a1ce4d5f01e3ef33e9b152c253273ada4c043f8354d0d6` | PASS |
| Host sensor test target | 70 passed in `make demo-agentmaxxing-host-test` | PASS |
| Operator contract suite | 6 passed in `make demo-agentmaxxing-contract-test` | PASS |
| Execution evidence | `docs/signalloom/amxo-p5-preflight-proof.md` and `docs/signalloom/amxo-p5-pre-proof.md` | PASS |
| Proposal errata | Qualified `AMXO-P5-PRE` block appended with `status=pass` | PASS |
| Implementation boundary | Clean preflight proof and errata only; no Phase 5 implementation deliverables altered | PASS |

---

## 3. Go Session-Integrity Verifier Ownership & Architecture

The session-integrity verification architecture strictly follows the constitutional division of responsibility:

```
+------------------------------------+       +------------------------------------+
|     agentmaxxing-host-sensor       |       |       Go signal-ingest             |
|                                    |       |                                    |
| - Finalizes nono session           | ----> | - Verifies session integrity       |
| - Computes sha256 digests          |       | - Checks Merkle hash chain         |
| - Enforces openat2 anti-escape     |       | - Validates Ed25519 signatures     |
| - Packages signed audit envelope   |       | - Rejects broken/tampered chains   |
+------------------------------------+       +------------------------------------+
                                                                |
                                                                v
                                             +------------------------------------+
                                             |       FastAPI fe-signalloom        |
                                             |                                    |
                                             | - Authorizes host credentials      |
                                             | - Enforces tenant-agent binding    |
                                             | - Deduplicates & stores evidence   |
                                             | - Exposes tenant timeline views    |
                                             +------------------------------------+
```

All 18 Go test suites in `d2-signalloom/apps/signal-ingest/collectors/agentnono/` pass:
- `TestUploadMutationMatrix`: Validates receipt authority, sequence continuity, unknown attribute rejection, tenant injection rejection, reversed ranges, and count mismatches.
- `TestTimestampWireGrammar`: Enforces strict ISO 8601 UTC timestamp format.
- `TestRequiredKeysAndDuplicateKeysAreRejectedRecursively`: Rejects duplicate keys, aliased keys, missing root scalars, and unknown envelope/evidence keys.
- `TestSignedCaseAliasedRootKeysAreRejected`: Guarantees case-canonical JSON keys.
- `TestClosedAttributeObjectsRejectUnknownKeys`: Validates process, artifact, network, and limit attribute objects against strict schemas.
- `TestCanonicalInputLexicalContract`: Falsifies lexical deviations (fractional integers, exponents, negative zero, unsafe integers, non-ASCII values).
- `TestProcessExitCodeIsRequiredAndNullable`: Validates nullable exit codes.
- `TestArtifactMtimeUsesBoundedUint64DecimalString`: Validates nanosecond timestamps.
- `TestServerIntegrityResultIsGoOwned`: Guarantees server integrity results are generated exclusively by Go verifier logic.
- `TestLocalFinalizedChainCanBeIndependentlyVerified`: Proves cryptographic chain reproducibility.
- `TestRingBuffer_BoundedCapacityAndDropTail`: Verifies bounded memory ingestion.
- `TestAuditVerifier_SignatureRoundtrip`: Validates Ed25519 signing and verification.
- `TestAuditVerifier_TamperedPayloadRejected`: Proves tampered payloads fail verification.
- `TestAuditVerifier_HashChainBreakRejected`: Proves broken hash chains fail closed.

---

## 4. Database Migration Sequence Baseline

The migration sequence in `d2-signalloom/apps/fe-signalloom/src/db/migrations/` was verified:

```
001_initial_schema.sql
002_add_agents_table.sql
003_add_governance_rules.sql
004_add_compliance_reports.sql
005_add_collusion_rules.sql
006_add_api_keys.sql
007_add_audit_trail.sql
008_platform_users.sql
009_agent_groups.sql
010_tenant_isolation.sql
011_federated_services.sql
012_operational_event_types.sql
020_user_preferences.sql
021_user_currency_event_type.sql
030_audit_events_append_only.sql
031_signal_fusion_provisional_actors.sql
032_generated_demo_event_types.sql
033_quarantine_synthetic_audit_events.sql
034_agent_origin_verification.sql
035_agent_claim_contract.sql
036_agent_claim_persistence.sql
037_signed_audit_sessions.sql
038_operator_identities.sql
039_external_agent_registrations.sql
040_host_enrollment_tokens.sql
041_external_host_revocation.sql
```

**Next Migration Slot:** `042_agentmaxxing_host_evidence_projections.sql` is reserved for Phase 5 implementation (`AMXO-P5-3`). There are zero name, sequence, or table collisions.

---

## 5. Phase 5 Execution Roadmap & Invariant Contracts

1. **AMXO-P5-1 (Session Verification & Chain Validation)**:
   - Ingest finalized sessions via `/v1/audit/sessions`.
   - Forward to Go verifier for signature and hash chain validation.
   - Fail closed on missing, altered, reordered, or forged records.
2. **AMXO-P5-2 (Upload Idempotency & Concurrency Resilience)**:
   - Enforce transactional deduplication keyed by `(tenant_id, agent_id, session_id)`.
   - Prevent duplicate uploads, handle concurrent retries cleanly, and return idempotent receipts.
3. **AMXO-P5-3 (Allowlisted Evidence Persistence & Tenant Projections)**:
   - Apply migration `042` creating tenant-scoped evidence projections.
   - Filter and persist strictly allowlisted attributes (`health_state`, `cpu_time_ms`, `resident_memory_bytes`, `sha256`, `observation_state`, `integrity_state`).
   - Strictly prohibit customer payloads, commands, raw memory, or file content persistence.
4. **AMXO-P5-GOV (Ingestion Governor)**:
   - Reconcile shared files across `api_compat.py`, `models.py`, `Makefile`, and migration registry.
   - Run unified ingestion test suite `make demo-agentmaxxing-ingest-test`.
   - Verify tenant data isolation and certify Phase 5 completion.

Phase 5 Preflight is certified. Phase 5 implementation cards (`AMXO-P5-1`, `AMXO-P5-2`, `AMXO-P5-3`) may proceed.
