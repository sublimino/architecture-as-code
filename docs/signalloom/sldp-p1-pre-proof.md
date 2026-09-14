# SLDP-P1-PRE execution proof

Status: **PASS — Phase 1 preflight complete; seams, route inventory, identity binding, fail-open sites, verifier state, and empty-key reliance confirmed**
Evidence revision before documentation: `6e18e38168d8c6c6997c167edf4358494fdd3de2`
Runtime worktree: `/home/andy/src/.worktrees/18fc3/osramp-demo`

## Contract interpretation

Phase 1 preflight (SLDP-P1-PRE) confirms the concrete code seams that the three Phase 1 implementation cards (`SLDP-P1-1`, `SLDP-P1-2`, `SLDP-P1-3`) will touch before execution begins. Phase 1 closes an open HTTP API, converts two fail-open controls to fail-closed, and builds the first Go verifier for attested evidence.

This preflight:
1. Enumerates the full route surface of `signal-ingest` from the mux at `main.go:224` and `api/handlers.go:77-111` (all 32 registered endpoints including the 4 SSE streams and `/metrics`).
2. Confirms the existing estate identity scheme (SPIFFE/SPIRE for workload identity, OpenBao for secrets and JWT backend, Dex OIDC for human users) and records the decision that P1-1 binds to SPIFFE workload identity.
3. Re-confirms both fail-open sites at exact file and line locations (`identity/encryption.go:103-134` and `audit/audit.go:55-59`).
4. Confirms that no `Verify*` entrypoint exists in Go `store/segment_attestor.go`, proving P1-3 is building rather than extending.
5. Documents that the current live deployment (`base/deployment.yaml`) runs with an empty encryption key, establishing that P1-2 requires deployment key provisioning to avoid crash-looping.

## Pre-execution gates

| Gate | Evidence | Result |
|---|---|---|
| Isolated runtime | `pwd` returned `/home/andy/src/.worktrees/18fc3/osramp-demo`, not `/home/andy/src/cp/osramp-demo`. | PASS |
| Clean status | `git status -s` returned zero entries; porcelain status clean. | PASS |
| Required base at task creation | `git merge-base --is-ancestor integration/sldp-v0.1.0 HEAD` exited `0` with HEAD and integration ref both resolving to `6e18e38168d8c6c6997c167edf4358494fdd3de2`. | PASS |
| Board snapshot | `kanban-check.sh progress` reported `P1-PRE` in progress with health checked OK; no runtime state was mutated. | PASS |

## Deliverable 1: Complete route inventory for `signal-ingest`

The HTTP route surface is declared in `d2-signalloom/apps/signal-ingest/main.go:224-246` and registered via `d2-signalloom/apps/signal-ingest/api/handlers.go:77-111`. Exactly 32 route bindings exist across 23 unique handler targets and 9 path aliases.

| # | HTTP Method | Path / Pattern | Handler Function | Source Location | Classification & P1-1 Auth Requirement |
|---|---|---|---|---|---|
| 1 | `GET` | `/healthz` | `handleHealthz` | `api/handlers.go:78` | **Operational:** Startup/liveness probe (unauthenticated, 200 OK) |
| 2 | `GET` | `/readyz` | `h.handleReadyz` | `api/handlers.go:79` | **Operational:** Readiness probe (unauthenticated, checks audit DB & collectors) |
| 3 | `GET` | `/metrics` | `main.go` anonymous func | `main.go:240-246` | **Operational:** Prometheus metrics scraper (unauthenticated cluster scrape) |
| 4 | `POST` | `/api/v1/observations` | `h.handleIngestObservations` | `api/handlers.go:80` | **Data Ingest:** Append raw observations (P1-1: authenticated & authorized) |
| 5 | `GET` | `/api/v1/observations` | `h.handleQueryObservations` | `api/handlers.go:81` | **Query:** Read observations range/filters (P1-1: authenticated & authorized) |
| 6 | `GET` | `/api/v1/actors` | `h.handleListActors` | `api/handlers.go:82` | **Identity Graph:** List resolved actors (P1-1: authenticated & authorized) |
| 7 | `GET` | `/api/v1/actors/{id}` | `h.handleGetActor` | `api/handlers.go:83` | **Identity Graph:** Get actor details (P1-1: authenticated & authorized) |
| 8 | `GET` | `/api/v1/actors/{id}/authorization` | `h.handleGetActorAuthorization` | `api/handlers.go:84` | **Identity Graph:** Get authorization chain (P1-1: authenticated & authorized) |
| 9 | `GET` | `/api/v1/authorization` | `h.handleQueryAuthorization` | `api/handlers.go:85` | **Identity Graph:** Query authz relations (P1-1: authenticated & authorized) |
| 10 | `POST` | `/api/v1/actors/{id}/promote` | `h.handlePromoteActor` | `api/handlers.go:86` | **Identity Mutation:** Promote actor state (P1-1: authenticated & authorized) |
| 11 | `POST` | `/api/v1/delegations` | `h.handleCreateDelegation` | `api/handlers.go:87` | **Delegation Graph:** Create delegation edge (P1-1: authenticated & authorized) |
| 12 | `POST` | `/api/v1/delegations/clamp` | `h.handleClampDelegation` | `api/handlers.go:88` | **Delegation Graph:** Clamp delegation window (P1-1: authenticated & authorized) |
| 13 | `POST` | `/api/v1/delegations/revoke` | `h.handleRevokeDelegations` | `api/handlers.go:89` | **Delegation Graph:** Revoke delegation authority (P1-1: authenticated & authorized) |
| 14 | `DELETE` | `/api/v1/delegations` | `h.handleClampDelegation` | `api/handlers.go:90` | **Delegation Graph:** HTTP DELETE clamp alias (P1-1: authenticated & authorized) |
| 15 | `GET` | `/api/v1/coverage` | `handleCoverage` | `api/handlers.go:91` | **Analysis:** MITRE ATT&CK coverage metrics (P1-1: authenticated & authorized) |
| 16 | `POST` | `/api/v1/correlate` | `h.handleCorrelate` | `api/handlers.go:92` | **Engine:** Trigger on-demand correlation (P1-1: authenticated & authorized) |
| 17 | `POST` | `/api/v1/collectors/seed` | `h.handleSeed` | `api/handlers.go:93` | **Demo/Seed:** Synthetic collector seeding (P1-1: authenticated & authorized) |
| 18 | `GET` | `/api/v1/store/stats` | `h.handleStoreStats` | `api/handlers.go:94` | **Telemetry:** Store partition/evidence stats (P1-1: authenticated & authorized) |
| 19 | `GET` | `/api/v1/stream` | `h.handleStream` | `api/handlers.go:95` | **SSE Stream 1:** Live observations/events stream (P1-1: authenticated & authorized) |
| 20 | `GET` | `/api/v1/observations/stream` | `h.handleStream` | `api/handlers.go:96` | **SSE Stream 2:** Alias path for observations stream (P1-1: authenticated & authorized) |
| 21 | `GET` | `/stream` | `h.handleStream` | `api/handlers.go:97` | **SSE Stream 3:** Root alias for event stream (P1-1: authenticated & authorized) |
| 22 | `GET` | `/observations/stream` | `h.handleStream` | `api/handlers.go:98` | **SSE Stream 4:** Root alias for observations stream (P1-1: authenticated & authorized) |
| 23 | `POST` | `/api/v1/audit/webhook` | `h.handleAuditWebhook` | `api/handlers.go:99` | **Audit Ingestion:** K8s APIServer audit webhook (`apiaudit.WebhookPath`) |
| 24 | `POST` | `/audit/webhook` | `h.handleAuditWebhook` | `api/handlers.go:100` | **Audit Ingestion:** Alias path for APIServer audit webhook |
| 25 | `POST` | `/api/v1/audit/gke` | `h.handleGKECloudLogging` | `api/handlers.go:101` | **Audit Ingestion:** GKE Cloud Logging audit records (`apiaudit.GKEWebhookPath`) |
| 26 | `POST` | `/audit/gke` | `h.handleGKECloudLogging` | `api/handlers.go:102` | **Audit Ingestion:** Alias path for GKE Cloud Logging audit |
| 27 | `POST` | `/api/v1/audit/nono` | `h.handleNonoAudit` | `api/handlers.go:103` | **Audit Ingestion:** Agent Nono Landlock audit session events |
| 28 | `POST` | `/audit/nono` | `h.handleNonoAudit` | `api/handlers.go:104` | **Audit Ingestion:** Alias path for Nono Landlock audit events |
| 29 | `GET` | `/api/v1/risk/agents/{id}` | `h.handleGetAgentRisk` | `api/handlers.go:107` | **OpenFAIR Risk:** Individual agent risk evaluation (P1-1: authenticated & authorized) |
| 30 | `GET` | `/api/v1/risk/fleet` | `h.handleGetFleetRisk` | `api/handlers.go:108` | **OpenFAIR Risk:** Fleet-wide risk distribution (P1-1: authenticated & authorized) |
| 31 | `GET` | `/v1/risk/agents/{id}` | `h.handleGetAgentRisk` | `api/handlers.go:109` | **OpenFAIR Risk:** Alias path for agent risk |
| 32 | `GET` | `/v1/risk/fleet` | `h.handleGetFleetRisk` | `api/handlers.go:110` | **OpenFAIR Risk:** Alias path for fleet risk |

### Key findings for P1-1:
- `main.go:224` constructs a bare `mux := http.NewServeMux()` with no global or per-route middleware.
- Currently, **100% of these routes are served openly** without authentication or tenant context checks.
- P1-1 must establish authentication and authorization middleware wrapping the protected routes while preserving unauthenticated access for `/healthz`, `/readyz`, and `/metrics`.
- The 4 SSE endpoints (`/api/v1/stream`, `/api/v1/observations/stream`, `/stream`, `/observations/stream`) stream long-lived HTTP event connections and must enforce caller authentication at handshake time.

## Deliverable 2: Identity system binding decision

### Estate identity inventory
1. **Workload Identity (SPIFFE/SPIRE):** Deployed via `d2-agent-trust/` and `d2-signalloom/infra/inf-bao`. SPIRE issues cryptographically verifiable JWT-SVIDs and X.509 SVIDs rooted in the cluster trust domain (`spiffe://cluster.local/...`).
2. **Secrets & JWT Validation Roles (OpenBao):** Deployed via `d2-signalloom/infra/inf-bao`. Provides Vault-compatible JWT authentication backend and role validation.
3. **End-User Identity (Dex OIDC):** Deployed via `d2-signalloom/infra/inf-signalloom/base/dex.yaml` for human dashboard authentication.

### Decision & Rationale
**Decision:** P1-1 binds service-to-service and agent-to-service API authentication for `signal-ingest` to **SPIFFE Workload Identity (JWT-SVID)**, validated against the SPIRE/OpenBao trust domain.

**Rationale:**
1. **Existing Estate Standard:** SPIFFE is already the established workload identity primitive in `d2-agent-trust` and `d2-signalloom`. Reusing it avoids creating an ad-hoc API key or bearer secret mechanism.
2. **Cryptographic Provenance:** JWT-SVID tokens carry caller claims (`sub: spiffe://...`, `aud: ...`) allowing `signal-ingest` to cryptographically identify the caller service (e.g. `fe-signalloom`, `workspace-connector`, `agent-nono`).
3. **Defense in Depth:** Binds cleanly with existing Kubernetes NetworkPolicies (L3/L4) and OpenBao role policies (L7).

## Deliverable 3: Re-confirmation of fail-open sites

Both fail-open sites identified during the baseline review were inspected and verified in the source code:

### Fail-Open Site 1: Identity Encryptor
- **File & Lines:** `d2-signalloom/apps/signal-ingest/identity/encryption.go:103-134`
- **Code:**
  ```go
  // NoopEncryptor is a passthrough Encryptor for unencrypted environments or development.
  type NoopEncryptor struct{}
  ...
  func NewEncryptorFromKeyString(keyStr string) (Encryptor, error) {
      if keyStr == "" {
          return NewNoopEncryptor(), nil
      }
      return NewAESGCMEncryptor([]byte(keyStr))
  }
  ```
- **Sibling site:** `d2-signalloom/apps/signal-ingest/identity/repository.go:45-58` (`NewPostgresRepository` replaces `nil` encryptor with `NewNoopEncryptor()`).
- **Defect:** An empty or missing key string silently returns a passthrough `NoopEncryptor` that stores plaintext alias metadata while claiming encryption.
- **P1-2 mandate:** `NewEncryptorFromKeyString("")` must return a non-nil error, and `signal-ingest` startup must fail closed (fatal exit) if key material is missing or invalid.

### Fail-Open Site 2: Audit Writer
- **File & Lines:** `d2-signalloom/apps/signal-ingest/audit/audit.go:55-59`
- **Code:**
  ```go
  // NopWriter is an AuditWriter that silently discards all events.
  // Used when no Postgres connection is configured.
  type NopWriter struct{}

  func (NopWriter) WriteAuditEvent(context.Context, Event) error { return nil }
  ```
- **Sibling site:** `d2-signalloom/apps/signal-ingest/main.go:67-119` (`main.go` falls back to `&audit.NopWriter{}` when database connection fails or `DATABASE_URL` is omitted).
- **Defect:** `NopWriter.WriteAuditEvent` returns `nil` and silently swallows audit records without persisting anything.
- **P1-2 mandate:** `WriteAuditEvent` on an unconfigured or disconnected audit backend must return an error (`ErrAuditDiscarded` / `ErrAuditUnavailable`) or fail closed rather than silently discarding compliance evidence.

## Deliverable 4: Attested evidence verifier confirmation

- **File Inspected:** `d2-signalloom/apps/signal-ingest/store/segment_attestor.go`
- **Search Command:** `rg -n 'func .*Verif' d2-signalloom/apps/signal-ingest/store/segment_attestor.go`
- **Result:** **0 matches (NO MATCH).**
- **Analysis:**
  - `SegmentAttestor` currently implements only writing, signing, queueing, checkpoint generation, and Archivista upload methods (`Status`, `loadState`, `validateHighWater`, `validateSegmentInventory`, `enqueue`, `Wait`, `Close`, `process`, `checkpoint`, `publishArchivista`, `writeHighWater`, `replaceHighWater`, `recordError`).
  - Python verifier exists in `audit_anchor` (`d2-signalloom/apps/fe-signalloom/src/audit_anchor/segments.py:26-45,67-97`), but Go `store/` has zero verification entrypoints.
  - **Verdict:** P1-3 is building `SegmentAttestor.VerifySegment` and `SegmentAttestor.VerifyCheckpointChain` from first principles rather than refactoring an existing method.

## Deliverable 5: Live deployment reliance on empty-key passthrough

- **File Inspected:** `d2-signalloom/apps/signal-ingest/base/deployment.yaml` (lines 66-95)
- **Environment Variables Configured:**
  - `SIGNAL_STORE_DIR: /data/signals`
  - `DATABASE_URL` from secret `discovery-portal-database`
  - `PGSSLMODE: disable`
- **Key Absence:** `IDENTITY_ENCRYPTION_KEY` is **not configured** in `deployment.yaml` or any kustomization overlay in the repository.
- **Live Behavior:** `main.go:180` evaluates `os.Getenv("IDENTITY_ENCRYPTION_KEY")` as `""`, which relies on `NewEncryptorFromKeyString("")` returning `NoopEncryptor` to successfully start.
- **Consequence for P1-2:** When P1-2 makes missing key material a startup refusal, `deployment.yaml` (and test harnesses) must be updated in tandem to supply a valid 32-byte AES key (e.g. from a Secret), otherwise deployment rollouts will fail.

## Baseline and acceptance test checks

| Command | Exit | Output Summary |
|---|---:|---|
| `make test-signal-ingest` | 0 | 19 Go packages passed (`ok`), 0 failures, 1.164s store execution. |
| `make demo-signalloom-api-test TIER=contract` | 0 | 56 tests passed, 0 failures, 1.44s execution. |
| `bats test/acceptance-spec-coverage.bats` | 0 | 7 tests passed, 0 failures. |
| `rg -n 'HandleFunc\|NewServeMux' d2-signalloom/apps/signal-ingest/main.go` | 0 | Found `main.go:224` (mux creation) and `main.go:240` (`/metrics`). |
| `rg -n 'NoopEncryptor\|NopWriter' d2-signalloom/apps/signal-ingest/identity/encryption.go d2-signalloom/apps/signal-ingest/audit/audit.go` | 0 | Found `identity/encryption.go:103,106,110,116,122,128,131` and `audit/audit.go:55,57,59`. |
| `rg -n 'func .*Verif' d2-signalloom/apps/signal-ingest/store/segment_attestor.go` | 1 | 0 matches. No Go verifier entrypoint. |

## Scope and safety evidence

- No production infrastructure or external customers were contacted.
- No historical Parquet segments or evidence records were rewritten.
- No Kanban runtime state (`.kanban/`) was modified.
- No git push to remote was attempted.
- Changes are strictly confined to this preflight evidence proof and the proposal document errata block.

## Verdict

**Phase 1 Preflight PASS.** All seams, routes, identity mechanisms, fail-open sites, verifier requirements, and deployment dependencies are confirmed with exact file/line evidence. Phase 1 implementation cards (`SLDP-P1-1`, `SLDP-P1-2`, `SLDP-P1-3`) are green to proceed.
