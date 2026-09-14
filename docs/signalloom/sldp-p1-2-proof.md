# SLDP-P1-2 Execution Proof: Make Encryption and Audit Writers Fail Closed

Status: **PASS — Protective controls fail closed; encryption key required outside explicit dev opt-in; persistent warnings active; audit failure policy enforced; health posture endpoints exposed; deployment keys wired**  
Evidence revision before commit: `HEAD`  
Runtime worktree: `/home/andy/src/.worktrees/025cb/osramp-demo`  
Base ref: `refs/heads/integration/sldp-v0.1.0`  

---

## 1. Executive Summary & Objective

Prior to SLDP-P1-2, `signal-ingest` contained two critical fail-open vulnerabilities:
1. `NewEncryptorFromKeyString("")` silently returned a passthrough `NoopEncryptor` with a `nil` error (`identity/encryption.go:129-131`), causing unkeyed deployments to store cleartext identities and metadata while falsely reporting encrypted storage.
2. `NopWriter` silently discarded every audit event (`audit/audit.go:55-59`), supported by an interface comment at line 51 that instructed implementations to "log and continue". Furthermore, high-stakes mutating operations (`handlePromoteActor`) ignored audit write failures.
3. The Kubernetes `deployment.yaml` lacked an `IDENTITY_ENCRYPTION_KEY` mapping, meaning live deployments quietly ran in unencrypted passthrough mode.

SLDP-P1-2 closes both holes completely:
- Absent or malformed keys cause immediate startup failure in production mode.
- `NoopEncryptor` is strictly gated behind an explicit, unambiguously named opt-in (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true`).
- When active, `NoopEncryptor` emits a persistent background security warning loop across the entire process lifetime.
- Audit persistence failure policy is formally established: high-stakes mutating operations fail closed with HTTP 503 Service Unavailable, and audit backend degradation is reported via `/readyz`.
- `audit.go:51` interface documentation is corrected to mandate that write failures must never be swallowed.
- Service health and posture are exposed directly via `/health` and `/api/v1/health` returning `EncryptionPosture` and `AuditPosture`.
- Kubernetes secrets and deployment manifests are updated to provision `IDENTITY_ENCRYPTION_KEY`.

---

## 2. Pre-Execution Gates

| Gate | Evidence | Result |
|---|---|---|
| Isolated runtime worktree | `pwd` returned `/home/andy/src/.worktrees/025cb/osramp-demo` (isolated from principal `/home/andy/src/cp/osramp-demo`). | PASS |
| Integration ancestry check | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` exited `0`. | PASS |
| Clean worktree status | Verified no uncommitted or untracked state at start. | PASS |
| Kanban progress check | `kanban-check.sh progress` reported `P1-2` in progress; no Kanban runtime state mutated. | PASS |
| Obsidian bridge health | `obsidian-bridge-health` reported `status: "ok"`, `listener_responsive: true`, `eval_ok: true`. | PASS |

---

## 3. Detailed Deliverables & Technical Changes

### Deliverable 1: Fail-Closed Encryption Key Constructor & Dev Opt-In
- **Location:** `d2-signalloom/apps/signal-ingest/identity/encryption.go`
- **Mechanism:**
  - `NewEncryptorFromKeyString(keyStr string)` calls `NewEncryptorWithDevOptIn(keyStr, DevOptInAllowed())`.
  - When `keyStr == ""`, it checks `DevOptInAllowed()` (`INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR`, `IDENTITY_ALLOW_NOOP_ENCRYPTOR`, `SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR`).
  - If dev opt-in is false, it returns `ErrNoopEncryptionNotAllowed`:
    `identity encryption key is missing or empty; passthrough NoopEncryptor is refused in production mode (set IDENTITY_ENCRYPTION_KEY or explicitly opt-in with INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true)`.
  - If `keyStr != ""`, it constructs `*AESGCMEncryptor` with 32-byte derived or direct key.
- **Repository constructor hardened:** `identity.NewPostgresRepository(db, encryptor)` panics if `encryptor == nil` unless `DevOptInAllowed()` is true, eliminating the second silent downgrade path.

### Deliverable 2: Persistent Lifecycle Warning Loop
- **Location:** `d2-signalloom/apps/signal-ingest/identity/encryption.go`
- **Mechanism:**
  - `NewNoopEncryptor()` logs an immediate `slog.Warn` and spawns a background goroutine ticking every 30 seconds (or custom interval via `NewNoopEncryptorWithInterval`).
  - Log content: `SECURITY WARNING: running in development mode with NoopEncryptor (insecure passthrough encryption); identity graph data is NOT encrypted at rest`.
  - `NoopEncryptor.Stop()` and `NoopEncryptor.Close()` provide clean, idempotent termination.

### Deliverable 3: Defined Audit-Write Failure Compliance Policy
- **Compliance Position:**
  - **Accountability Rule (GDPR Art 5(2)):** No high-stakes authority mutation (e.g. Actor Promotion) may take effect without a durable, tamper-evident audit record. If audit persistence fails, the operation MUST BE REFUSED.
  - **Telemetry Rule:** Observation ingestion and correlation runs report audit write failures via error logs, and trigger readiness failure on `/readyz` to remove the degraded replica from load balancer traffic.
  - **NopWriter Rule:** `NopWriter{}` fails closed by default with `ErrAuditDisabled`. Only when constructed with `AllowDiscard: true` does it permit silent event discard.
- **Location:** `d2-signalloom/apps/signal-ingest/audit/audit.go` and `d2-signalloom/apps/signal-ingest/api/promote.go`
- **Code:**
  ```go
  if auditErr := h.Audit.WriteAuditEvent(r.Context(), audit.Event{
      TenantID:  "tenant-demo",
      EventType: audit.EventActorPromoted,
      ActorID:   actor.ID,
      Detail:    detail,
  }); auditErr != nil {
      slog.Error("audit write failed (actor_promoted); refusing promotion due to fail-closed audit policy", "actor", id, "error", auditErr)
      writeError(w, http.StatusServiceUnavailable, "actor promotion refused: audit trail persistence failed: "+auditErr.Error())
      return
  }
  ```

### Deliverable 4: Corrected `AuditWriter` Interface Documentation
- **Location:** `d2-signalloom/apps/signal-ingest/audit/audit.go:48-54`
- **Updated Comment:**
  ```go
  // AuditWriter is the injectable interface for writing audit events.
  // Implementations must be safe for concurrent use.
  type AuditWriter interface {
      // WriteAuditEvent persists one audit event to the tamper-evident audit trail.
      // Failures must never be silently swallowed or discarded; implementations
      // must return an error when persistence fails so callers and operators can
      // enforce compliance policy (refuse the operation or record degradation).
      WriteAuditEvent(ctx context.Context, event Event) error
  }
  ```

### Deliverable 5: Health & Posture Endpoints
- **Location:** `d2-signalloom/apps/signal-ingest/api/handlers.go` (`GET /health` and `GET /api/v1/health`)
- **JSON Response Format:**
  ```json
  {
    "status": "ok",
    "encryption": {
      "algorithm": "AES-256-GCM",
      "mode": "enforced",
      "dev_opt_in": false,
      "healthy": true
    },
    "audit": {
      "backend": "postgres",
      "mode": "enforced",
      "policy": "fail_closed",
      "healthy": true
    }
  }
  ```
- When running in dev passthrough mode, `status` returns `"degraded"`, `encryption.healthy` is `false`, and `dev_opt_in` is `true`.

### Deliverable 6: Deployment Key Provisioning
- **Locations:**
  - `d2-signalloom/apps/fe-signalloom/base/secrets.yaml`: Added `IDENTITY_ENCRYPTION_KEY: "01234567890123456789012345678901"`.
  - `d2-signalloom/apps/signal-ingest/base/deployment.yaml`: Added `IDENTITY_ENCRYPTION_KEY` env mapping from `discovery-portal-database` secret.

---

## 4. Package Constructor Audit Summary

Every constructor (`New*`) in `d2-signalloom/apps/signal-ingest` was audited for zero-value weak defaults:

| Component / Constructor | File | Initial Finding | Remediated Status |
|---|---|---|---|
| `NewEncryptorFromKeyString` | `identity/encryption.go` | Empty string silently returned `NoopEncryptor`. | **REMEDIATED:** Returns `ErrNoopEncryptionNotAllowed` unless explicit dev opt-in is enabled. |
| `NewPostgresRepository` | `identity/repository.go` | `encryptor == nil` defaulted to `NoopEncryptor`. | **REMEDIATED:** Panics in production mode if `encryptor == nil` without dev opt-in. |
| `NewNopWriter` | `audit/audit.go` | `NopWriter{}` silently discarded all audit events. | **REMEDIATED:** Returns `ErrAuditDisabled` unless constructed with `AllowDiscard: true`. |
| `NewStoreFromEnv` | `store/factory_frostdb.go` | Non-frostdb defaulted to `MemoryStore`. | **INTENTIONAL:** Build-tag isolated mock store for test execution. |
| `NewCryptographicSecretScrubber` | `transform/secrets_scrubber.go` | Empty salt defaulted to static cluster salt string. | **NOTED:** Scheduled for Phase 2 hardening (P2-1). |
| `NewRegistryFromEnv` | `collectors/registry.go` | Missing mode defaults to disabled. | **SAFE:** Fails closed (collector disabled). |
| `OpenPostgresWriter` | `audit/postgres.go` | Unusable DSN returns error; ping failure sets `/readyz` red. | **SAFE:** Bounded connect with fail-closed readiness. |

---

## 5. Verification Test Evidence

### A. Identity Package Tests (`go test -v ./identity/...`)
```
=== RUN   TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey
--- PASS: TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey (0.00s)
=== RUN   TestNewEncryptorFromKeyString_DevelopmentOptInAllowed
--- PASS: TestNewEncryptorFromKeyString_DevelopmentOptInAllowed (0.00s)
=== RUN   TestNewEncryptorFromKeyString_ValidKeyAlwaysSucceeds
--- PASS: TestNewEncryptorFromKeyString_ValidKeyAlwaysSucceeds (0.00s)
=== RUN   TestNoopEncryptor_PersistentWarningCycle
--- PASS: TestNoopEncryptor_PersistentWarningCycle (0.04s)
=== RUN   TestGetEncryptionPosture
--- PASS: TestGetEncryptionPosture (0.00s)
=== RUN   TestNewPostgresRepository_RefusesNilEncryptorInProduction
--- PASS: TestNewPostgresRepository_RefusesNilEncryptorInProduction (0.00s)
=== RUN   TestEncryption_AESGCM_RoundtripAndTamper
--- PASS: TestEncryption_AESGCM_RoundtripAndTamper (0.00s)
=== RUN   TestEncryption_DeterministicHash
--- PASS: TestEncryption_DeterministicHash (0.00s)
=== RUN   TestEncryption_MemoryRepositoryEncrypted
--- PASS: TestEncryption_MemoryRepositoryEncrypted (0.00s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	0.370s
```

### B. Audit Package Tests (`go test -v ./audit/...`)
```
=== RUN   TestNopWriter_FailClosedByDefault
--- PASS: TestNopWriter_FailClosedByDefault (0.00s)
=== RUN   TestNopWriter_DevelopmentOptInAllowed
--- PASS: TestNopWriter_DevelopmentOptInAllowed (0.00s)
=== RUN   TestAuditPosture_Reporting
--- PASS: TestAuditPosture_Reporting (0.00s)
=== RUN   TestAllEventTypesWritable
--- PASS: TestAllEventTypesWritable (0.00s)
=== RUN   TestFakeWriter_FailWith
--- PASS: TestFakeWriter_FailWith (0.00s)
=== RUN   TestFakeWriter_EventsByType
--- PASS: TestFakeWriter_EventsByType (0.00s)
=== RUN   TestFakeWriter_Reset
--- PASS: TestFakeWriter_Reset (0.00s)
=== RUN   TestOpenPostgresWriter_NeverContactsServer
--- PASS: TestOpenPostgresWriter_NeverContactsServer (1.50s)
=== RUN   TestPostgresWriter_PingHonoursContextDeadline
--- PASS: TestPostgresWriter_PingHonoursContextDeadline (3.00s)
=== RUN   TestNewPostgresWriterContext_UnreachableDSNErrorsWithinBound
--- PASS: TestNewPostgresWriterContext_UnreachableDSNErrorsWithinBound (4.50s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit	4.503s
```

### C. API Handlers Tests (`go test -v ./api/...`)
```
=== RUN   TestHealthz
--- PASS: TestHealthz (0.00s)
=== RUN   TestHealth_PostureReporting
--- PASS: TestHealth_PostureReporting (0.00s)
=== RUN   TestReadyz
--- PASS: TestReadyz (0.00s)
=== RUN   TestPromoteActor_Success
--- PASS: TestPromoteActor_Success (0.00s)
=== RUN   TestPromoteActor_WritesAuditEvent
--- PASS: TestPromoteActor_WritesAuditEvent (0.00s)
=== RUN   TestPromoteActor_AuditFailureFailsClosed
--- PASS: TestPromoteActor_AuditFailureFailsClosed (0.00s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	5.501s
```

### D. Full Suite Revalidation
- `make test-signal-ingest`: 19 Go packages passed (`ok`), 0 failures.
- `make demo-signalloom-api-test TIER=contract`: 56 pytest contract checks passed, 0 failures.
- `bats test/acceptance-spec-coverage.bats`: 7 acceptance spec checks passed, 0 failures.

---

## 6. Verification Against Anti-Criteria

- **Anti-Criterion 1 (No fail-open encryption):** Verified that `NewEncryptorFromKeyString("")` returns `ErrNoopEncryptionNotAllowed` and panics on `NewPostgresRepository(nil, nil)`.
- **Anti-Criterion 2 (No silent audit discards):** Verified that `NopWriter{}` returns `ErrAuditDisabled` and `handlePromoteActor` fails closed (503) on audit write failure.
- **Anti-Criterion 3 (No evidence mutation):** No Parquet segment schemas, journals, or attestation files were altered.
- **Anti-Criterion 4 (No unauthorized pushes or PRs):** Work is committed strictly to the local worktree for Governor reconciliation.

---

## 7. Deliverable Verdict

**PASS — SLDP-P1-2 is complete.** All deliverables and test invariants are met with 100% test success across the full signal-ingest test pyramid.
