# SLDP-P1-GOV (Phase 0/1 Governor) Certification Proof

**Status:** PASS — Live holes certified closed, fail-closed controls verified, independent chain verifier operational, milestone sizing attached, tenant-binding contract published, boundary map reconciled.  
**Logical ID:** `SLDP-P1-GOV`  
**Role:** Governor  
**Integration Branch:** `refs/heads/integration/sldp-v0.1.0`  
**Governing Commit:** `ad4c24a4bde3a9fa4e5b708b24f4a23fac809aff`  
**Recorded Date:** 2026-09-14 14:28:12+01:00  

---

## 1. Executive Summary & Certification Verdict

As the Governor for Phase 1 of the Signal Loom Production and Data-Protection Hardening programme (`SLDP`), this document formally certifies that:

1. **The Live Identity-Graph API Hole is Closed:** All 32 route bindings across 23 handler targets in `signal-ingest`—including all 4 Server-Sent Events streams (`/events`, `/stream`, `/quarantine/stream`, `/observations/stream`) and the Prometheus metrics endpoint (`/metrics`)—are strictly protected under SPIFFE JWT-SVID authentication and fine-grained authorization. Unauthenticated calls are refused with `401 Unauthorized` or `403 Forbidden` and logged via fail-closed pseudonymous audit events.
2. **Fail-Open Controls Converted to Fail-Closed:**
   - Empty or missing encryption keys (`NewEncryptorFromKeyString("")`) now cause immediate startup failure in production mode (`ErrNoopEncryptionNotAllowed`). Passthrough `NoopEncryptor` is restricted behind explicit developer opt-in (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true`) and emits a persistent 30-second security warning loop across the process lifetime.
   - `NopWriter` returns `ErrAuditDisabled` by default. High-stakes mutations (`handlePromoteActor`) fail closed with `HTTP 503 Service Unavailable` if audit persistence fails.
3. **Independent Evidence-Segment & Checkpoint Verifier Operational:** A clean standard-library verification package (`store/verify`) and auditor CLI (`cmd/segment-verify`) independently verify Ed25519 DSSE signatures, SHA-256 payload digests, Merkle roots, and sequence/row-count continuity without relying on writer-side runtime state. Negative controls prove the verifier decisively rejects tampered segment bytes, modified checkpoints, broken sequence numbers, intermediate symlinks, and unknown schemas.
4. **Milestone Sizing Attached:** The blank milestone effort fields in the proposal have been replaced with the evidence-based sizing produced in P1-3 (75.25–102.25 working days, 126.5–172.5 person-days, 2 core consultants, D+76–103 relative deadline).
5. **No Third Identity Scheme Created:** Authenticated API requests bind directly to SPIFFE JWT-SVID workload identities and OpenBao key custody. No redundant bearer-token mechanism was invented.
6. **Tenant-Binding Contract Published:** A strict, non-bypassable tenant-binding contract is established for downstream consumption by `SLDP-P2-2` (Row-Level Security).
7. **P0 Boundary Map Reconciled:** Component verdicts have been updated to reflect the transition of verification, HTTP auth, and fail-closed protections from ABSENT/PARTIAL to EXISTS.

---

## 2. Live Hole Closure & API Authentication Certification

### 2.1 Route Inventory & Negative Controls

Every route in `signal-ingest` was audited and tested for negative assertion (unauthenticated requests rejected).

| Route / Stream | Method | Required Permission | Unauthenticated Response | Negative Test Name |
|---|---|---|---|---|
| `/health` | GET | Public Posture | 200 (Posture JSON) | `TestHealth_PostureReporting` |
| `/readyz` | GET | Public Readiness | 200 / 503 | `TestReadyz` |
| `/metrics` | GET | `metrics:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/actors` | GET | `actors:list` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/actors/{id}` | GET | `actors:read` | 401 / 403 (Refused) | `TestActorReadDoesNotGrantActorEnumeration` |
| `/api/v1/actors/{id}/promote` | POST | `actors:promote` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/delegations` | GET | `delegations:list` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/delegations` | POST | `delegations:write` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/delegations/revoke` | POST | `delegations:revoke` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/events` (SSE) | GET | `events:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/events` (SSE) | GET | `events:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/stream` (SSE) | GET | `stream:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/stream` (SSE) | GET | `stream:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/quarantine/stream` (SSE) | GET | `quarantine:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/quarantine/stream` (SSE) | GET | `quarantine:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/observations/stream` (SSE) | GET | `stream:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/observations/stream` (SSE) | GET | `stream:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/observations` | POST | `observations:write` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |
| `/api/v1/query` | GET | `query:read` | 401 / 403 (Refused) | `TestProtectedRouterDeniesEveryRouteWithoutCredentials` |

### 2.2 Hostile Credential Testing
The authentication engine (`api/auth.go`) was subjected to 17 hostile test variations (`TestJWTAuthenticatorHostileCredentials`), asserting that tokens with:
- Missing signatures,
- Wrong key algorithm (e.g. `none`, HMAC with public key),
- Unknown `kid`,
- Mismatched SPIFFE trust domain,
- Expired timestamps,
- Duplicate JSON keys or trailing garbage,
- Cross-tenant claim tampering,
are immediately rejected with zero side-channel leaks.

### 2.3 SSE Lifecycle & Mid-Stream Expiry
Server-Sent Events streams enforce write deadlines and context cancellation matching credential expiry (`ExpiresAt`). `TestRealHTTPServerSSEClosesAtJWTExpiry` and `TestProtectedRouterSSEExpiresAndPreservesFlusher` verify that active connections terminate cleanly when credentials expire, emitting a `credential_expired` audit event.

---

## 3. Fail-Closed Controls Certification

### 3.1 Encryption Key Enforcement
- `NewEncryptorFromKeyString("")` returns `ErrNoopEncryptionNotAllowed` in production mode (`TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey`).
- `NewPostgresRepository(db, nil)` panics in production mode (`TestNewPostgresRepository_RefusesNilEncryptorInProduction`).
- Explicit development opt-in (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true`) is required to use passthrough mode. When enabled, a persistent background ticker logs a security warning every 30 seconds (`TestNoopEncryptor_PersistentWarningCycle`).
- Live Kubernetes deployment manifests (`d2-signalloom/apps/signal-ingest/base/deployment.yaml`) and secrets (`fe-signalloom/base/secrets.yaml`) provision `IDENTITY_ENCRYPTION_KEY`.

### 3.2 Audit Persistence Policy
- `NopWriter{}` returns `ErrAuditDisabled` unless constructed with explicit `AllowDiscard: true` (`TestNopWriter_FailClosedByDefault`).
- In `handlePromoteActor`, audit write failure immediately aborts the transaction and returns `HTTP 503 Service Unavailable` (`TestPromoteActor_AuditFailureFailsClosed`), upholding GDPR Article 5(2) accountability invariants.
- Misleading comments at `audit/audit.go:51` ("log and continue") were removed and replaced with explicit instructions that audit failures must never be swallowed.

---

## 4. Independent Verifier Certification

### 4.1 Implementation Architecture
- **Package:** `d2-signalloom/apps/signal-ingest/store/verify` (Pure Go standard library; no writer imports).
- **CLI:** `d2-signalloom/apps/signal-ingest/cmd/segment-verify`.
- **Properties Checked:**
  1. DSSE envelope signature (`crypto/ed25519`) against pinned trusted keyrings.
  2. In-toto Statement v0.1 / v1 payload schema and predicate compliance.
  3. SHA-256 digest over raw Parquet segment bytes.
  4. Journal entry sequence continuity and monotonic timestamp progression.
  5. Checkpoint chain continuity (`PrevCheckpointDigest`, sequence numbers, cumulative row counts, Merkle tree root).
  6. Highwater mark validation and tip freshness.

### 4.2 Tamper & Defect Injection Evidence

| Defect Injected | Expected Behaviour | Test Result |
|---|---|---|
| 1-bit Parquet segment corruption | Reject with digest mismatch | PASS (`TestVerifyRejectsTamperedSegment`) |
| Checkpoint signature tamper | Reject with signature verification error | PASS (`TestVerifyRejectsTamperedCheckpoint`) |
| Broken sequence number in journal | Reject with sequence discontinuity | PASS (`TestVerifyRejectsJournalSequenceDiscontinuity`) |
| Broken `PrevCheckpointDigest` link | Reject with checkpoint chain mismatch | PASS (`TestVerifyRejectsBrokenCheckpointChain`) |
| Cumulative row count forgery | Reject with row count invariant violation | PASS (`TestVerifyRejectsCheckpointCumulativeRowCount`) |
| Merkle root discrepancy | Reject with Merkle root mismatch | PASS (`TestVerifyRejectsCheckpointMerkleMismatch`) |
| Intermediate symlink injection | Reject symlink traversal | PASS (`TestVerifyRejectsIntermediateSymlink`) |
| Unknown schema version | Reject with `ErrUnknownSchemaVersion` | PASS (`TestVerifyRejectsUnknownSchema`) |
| Historical key rotation | Accept valid historical key in keyring | PASS (`TestVerifySupportsHistoricalKeyRotation`) |

---

## 5. Architectural Decisions

### 5.1 Credential Scheme Decision
**Decision:** Standardise on SPIFFE JWT-SVID workload identity and OpenBao secret custody. Refuse the creation of any third bearer-token scheme.

**Rationale:**
The estate already operates SPIFFE (via SPIRE) for inter-service workload identity and OpenBao for key custody. Introducing a custom bearer-token database would:
- Duplicate token lifecycle, revocation, and rotation infrastructure;
- Create an additional attack surface for credential theft;
- Complicate multi-tenant authorization bindings.

The `JWTAuthenticator` in `signal-ingest` accepts SPIFFE JWT-SVIDs, validates signatures against the SPIRE JWKS bundle, and extracts principal and tenant identities directly from verified SPIFFE SANs (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`).

### 5.2 Metrics Endpoint Security Posture Decision
**Decision:** Authenticate `/metrics` with `PermissionMetrics` (`metrics:read`).

**Rationale:**
High-cardinality metrics labels (SPIFFE IDs, actor identifiers, tenant tags, quarantine counters) leak sensitive system topology and tenant activity. Allowing unauthenticated access would undermine tenant isolation. Metrics scrapers (Prometheus / OTEL collectors) must present authenticated workload identity.

---

## 6. Downstream Tenant-Binding Contract for Phase 2

For `SLDP-P2-2` (Tenant Column and Row-Level Security), the following binding rules are established:

1. **Context Ingestion:**
   Authenticated HTTP handlers receive the verified tenant context via `api.TenantContextFromContext(r.Context())`.
2. **Authoritative Origin:**
   The `TenantContext.TenantID` is derived exclusively from the authenticated principal's verified SPIFFE identity or signed JWT claims.
3. **Strict Header & Parameter Prohibition:**
   Database repositories, stores, and handlers **MUST NEVER** read or trust `X-Tenant-ID` headers or query parameters to determine tenant tenancy.
4. **SQL RLS Enforcement:**
   All SQL statements executed on behalf of a request must apply `SET LOCAL app.current_tenant = $tenant_id` within a transaction, ensuring PostgreSQL Row-Level Security policies reject cross-tenant reads or writes.

---

## 7. Attached Milestone Sizing (M1–M4)

The blank effort fields in the proposal are replaced with the following engineering ranges:

| Milestone | Duration (working days) | Consultants | Person-days | Deadline relative to D0 |
|---|---:|---:|---:|---|
| **M1: Pseudonymisation at rest + separated re-id map + allow-list** | 16–21 | 2 | 26–34 | D+32–43, after M3 |
| **M2: Retention/rotation + crypto-shred erasure + attested tombstones** | 23–31 | 2 | 40–54 | D+56–75, after M1/review |
| **M3: Graph confidentiality (encrypt-at-rest) + multi-tenant isolation** | 16–22 | 2 | 26–36 | D+16–22 |
| **M4: Region-pinned production deploy + KMS signing + DPIA pack** | 18–25 | 2 | 30–42 | D+74–100, after M2 |
| **Mid-project review** | 0.25 | 2 | 0.5 | D+33–44 |
| **Signoff and evidence reconciliation** | 2–3 | 2 | 4–6 | D+76–103 |
| **Total Estimated Effort** | **75.25–102.25** | **2 core** | **126.5–172.5** | **D+76–103 (rounded up)** |

---

## 8. Reconciled P0 Boundary Map

| Primitive | Initial P0 Verdict | Reconciled P1 Verdict | Status & Delta |
|---|---|---|---|
| **HTTP API Authentication** | ABSENT (Bare Mux) | **EXISTS** | `NewProtectedRouter` and `JWTAuthenticator` enforce SPIFFE JWT authentication on all 32 route bindings. |
| **Fail-Closed Encryption** | PARTIAL (Fail-Open) | **EXISTS** | Empty key string fails closed in production (`ErrNoopEncryptionNotAllowed`); persistent warning on dev opt-in. |
| **Fail-Closed Audit Writer** | PARTIAL (Fail-Open) | **EXISTS** | `NopWriter` errors on discard; `handlePromoteActor` fails closed (503) on audit failure. |
| **Go Segment Verifier Entrypoint** | ABSENT | **EXISTS** | Independent package `store/verify` and CLI `cmd/segment-verify` implemented and tested against tampered segments. |
| **Secret Scrubber & HMAC Anonymiser** | PARTIAL | **PARTIAL** | Unchanged; scheduled for storage pipeline wiring in `SLDP-P2-1`. |
| **PostgreSQL Row-Level Security** | ABSENT | **ABSENT (Ready)** | Tenant context contract defined in P1-1; PostgreSQL RLS implementation scheduled for `SLDP-P2-2`. |
| **Attested Tombstones / Erasure** | ABSENT | **ABSENT (Planned)** | Verification semantics defined; tombstone composition scheduled for `SLDP-P4-2`. |
| **KMS-Backed Segment Signer** | ABSENT | **ABSENT (Planned)** | ed25519 signer isolated; KMS signer interface scheduled for `SLDP-P5-1`. |

---

## 9. Tested Properties vs. Assumed Properties

| Property | Classification | Evidence / Basis |
|---|---|---|
| Every HTTP route rejects unauthenticated requests | **PROVEN (Tested)** | 19 passing tests in `api/auth_test.go` asserting 401/403 negative responses. |
| Missing encryption key halts production startup | **PROVEN (Tested)** | `TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey` in `identity/encryption_test.go`. |
| Audit persistence failure prevents actor promotion | **PROVEN (Tested)** | `TestPromoteActor_AuditFailureFailsClosed` in `api/handlers_test.go`. |
| Verifier rejects 1-bit Parquet segment bitflips | **PROVEN (Tested)** | `TestVerifyRejectsTamperedSegment` in `store/segment_verifier_test.go`. |
| Verifier rejects broken checkpoint digest chains | **PROVEN (Tested)** | `TestVerifyRejectsBrokenCheckpointChain` in `store/segment_verifier_test.go`. |
| FrostDB query latency under 2.75ms p95 at 12k rows | **ASSUMED (Historical)** | Grounded in `sfdp-p4-gov-acceptance-evidence.md`; benchmark not rerun in Phase 1. |
| KMS provider compatibility with DSSE Ed25519 | **ASSUMED (Planning)** | Cloud KMS Ed25519 signing support assumed for Phase 5; contingency included in milestone sizing. |
| Legal adequacy of crypto-shred erasure under Art 17 | **ASSUMED (Planning)** | Technical mechanism verified; legal sign-off scheduled as part of DPIA pack in Phase 5. |

---

## 10. Unresolved Findings Passed Downstream

1. **Secret Scrubber Salt Management (`SLDP-P2-1`):** The scrubber fallback salt in `transform/secrets_scrubber.go` remains static; P2-1 must wire dynamic KMS/OpenBao salt material and eliminate default fallbacks.
2. **Additive Schema Versioning in Columnar Store (`SLDP-P3-1`):** `store/frostdb.go` currently lacks physical schema version tags; P3-1 must implement schema versioning without mutating historical Parquet bytes.
3. **KMS Provider Selection (`SLDP-P5-1`):** Production KMS provider (GCP KMS vs AWS KMS vs HashiCorp Vault Transit) must be confirmed during P5-PRE preflight.

---

## 11. Test Execution Evidence

All tests across the signal-ingest test pyramid and governance gates passed cleanly:

- `make test-signal-ingest`: **PASS** (15 packages, 100% ok).
- `make test-signal-segment-verifier`: **PASS** (21 subtests, 0.00s / 2.82s).
- `make demo-signalloom-api-test TIER=contract`: **PASS** (56 passed, 0 failures).
- `bats test/acceptance-spec-coverage.bats`: **PASS** (7 tests, 0 failures).
- `scripts/kanban-check.sh link-check`: **PASS** (0 criticals, 0 failures, 0 orphaned cards).

---

## 12. Certification Sign-Off

Phase 1 (`SLDP-P1`) is certified **COMPLETE and PASSING**. All prerequisites for Phase 2 (`SLDP-P2-PRE`) are met.
