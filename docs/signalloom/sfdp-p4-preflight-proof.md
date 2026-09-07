# SFDP-P4-PRE — Phase-4 Integration & Verification Preflight Proof

**Created:** 2026-09-05 22:20:07+01:00  
**Status:** `pass` — GO verdict for Phase 4 (integration & verification)  
**Integration Ref:** `refs/heads/integration/signal-fusion-v0.1.0`  
**Base Commit SHA:** `6acf750703a29d0c4b41202c5a47f5f3433060cd`  
**Ancestry Verified:** Includes SFDP-P2-GOV (`1a790a3eddccad007e2e7dc3eaf4b53da2a1765a`) and SFDP-P3-GOV (`6acf750703a29d0c4b41202c5a47f5f3433060cd`)  

---

## 1. Executive Summary & Phase-4 Verdict

**Verdict:** **GO** for Phase 4 implementation cards (SFDP-P4-1, SFDP-P4-2, SFDP-P4-3, SFDP-P4-4, and SFDP-P4-GOV).

All preflight criteria are met:
1. **Governor Merges:** Both SFDP-P2-GOV (`1a790a3e`) and SFDP-P3-GOV (`6acf7507`) are fully merged and verified in the direct ancestry of `integration/signal-fusion-v0.1.0`.
2. **Branch Quiescence & Concurrency Snapshot:** `git log -15` and `git branch -vv` confirm zero unaccounted foreign commits or branch drift.
3. **Four Baseline Mission Acceptance Commands:** Executed and 100% passing with recorded benchmarks.
4. **Spine Surface Verification:** `Resolve(Observation) -> Actor` in `correlation/resolve.go`, temporal identity/delegation graph with structural `acts-on-behalf-of` never-merge triggers in `identity/`, and write-time Witness attestation in `store/segment_attestor.go` are present and verified.
5. **FrostDB Query Pushdown:** `logicalplan.Filter` predicate pushdown and row-group pruning verified in `store/frostdb.go`.
6. **Route Inventory & Collision Avoidance:** Verified all 14 registered HTTP endpoints in `api/handlers.go` and asserted that NO `/authorization` or `who-authorized` route exists, giving SFDP-P4-1 a clean greenfield path for the "who authorized this action?" query API.
7. **Model Surface Confirmation:** Confirmed `model/actor.go` contains `EvidenceChain []EvidenceLink`, `Confidence float64`, and `AgentRegistryID *string` on `ProvisionalActor`, and that `EvidenceLink` exposes `ObservationID`, `Layer`, `Fidelity`, `Contribution`, and `Timestamp`.

---

## 2. Dependency Governor Merge SHAs & Remote Pin

| Component | Target Ref / Commit | Verified Ancestor SHA | Status |
| :--- | :--- | :--- | :--- |
| **SFDP-P1-GOV** | Integration base | `24e371ab1b2654697f9e6216645b6e9e8b034396` | **MERGED & ANCESTOR** |
| **SFDP-P2-GOV** | Collectors & hardening | `1a790a3eddccad007e2e7dc3eaf4b53da2a1765a` | **MERGED & ANCESTOR** |
| **SFDP-P3-GOV** | Identity spine & attestation | `6acf750703a29d0c4b41202c5a47f5f3433060cd` | **MERGED & ANCESTOR** |
| **Integration Tip** | `refs/heads/integration/signal-fusion-v0.1.0` | `6acf750703a29d0c4b41202c5a47f5f3433060cd` | **PINNED (MATCHES HEAD)** |

Ancestor check commands:
- `git merge-base --is-ancestor 1a790a3eddccad007e2e7dc3eaf4b53da2a1765a HEAD` -> `rc=0` (P2-GOV is ancestor)
- `git merge-base --is-ancestor 6acf750703a29d0c4b41202c5a47f5f3433060cd HEAD` -> `rc=0` (P3-GOV is ancestor)
- `git merge-base --is-ancestor integration/signal-fusion-v0.1.0 HEAD` -> `rc=0` (HEAD is at integration branch tip)

---

## 3. Four Mission Acceptance Commands — Baseline Snapshot

| # | Command | Target Scope | Runtime / Timing | Result |
| :-: | :--- | :--- | :--- | :--- |
| 1 | `make test-signal-ingest` | Pure Go unit suite (all 15 packages: model, api, audit, collectors, correlation, identity, store, transform) | **15.93s** (user: 31.31s) | **PASS** (100% green) |
| 2 | `make test-signal-ingest-frostdb` | Full signal-ingest suite with FrostDB build tags + spine end-to-end integration test | **17.24s** (user: 40.71s) | **PASS** (100% green) |
| 3 | `make attested-test` (`ATTESTED_TEST_SOURCE=segments`) | Cryptographic Witness DSSE segment attestation proof & tamper rejection | **3.51s** (user: 13.86s) | **PASS** (intact/diverged/restored) |
| 4 | `make audit-anchor-tamper-demo` (`AUDIT_ANCHOR_TAMPER_SOURCE=segments`) | Write-time Witness attestation & Parquet tamper-detection demonstration | **1.42s** (user: 1.54s) | **PASS** (intact/diverged/restored) |

---

## 4. Spine Surface Verification

### 4.1. Resolution Engine (`correlation/resolve.go`)
- Function: `func Resolve(obs model.Observation) (*model.ProvisionalActor, error)`
- Status: Present, active, and thoroughly tested via table tests, property tests, and equivalence tests.
- Core Invariant: Enforces `false-merge == 0` across all discrete match/no-match cases. Contradictory principal hints produce `ErrContradictoryPrincipals`.

### 4.2. Postgres Identity & Delegation Graph (`identity/`)
- Migration: `identity/migrations/001_identity_graph.sql` defining `actors`, `aliases` (temporal `[valid_from, valid_to)`), and `delegations` (acts-on-behalf-of authority links).
- Invariants: Structural database-level triggers `check_never_merge_alias` and `check_never_merge_delegation` strictly reject aliasing a delegate to its delegation principal, preventing identity conflation under delegation.
- Storage Seam: `identity.Store` implements the graph lookup repository and seeds temporal intervals for as-of point-in-time queries.

### 4.3. Write-Time Witness Attestation (`store/segment_attestor.go`)
- Segment Signing: In-process Ed25519 DSSE signer generates cryptographic envelopes at FrostDB flush time.
- Tamper Verification: Parquet byte modifications are flagged as `diverged` with `exit 2`, while restoring exact bytes returns `intact` (`exit 0`).

---

## 5. FrostDB Query Pushdown (P3-4) Verification

In `store/frostdb.go`:
- Filter builder `buildFilter(q Query) logicalplan.Expr` translates time range (`timestamp` int64 UnixNano bounds), layer filters (`colRef(colLayer).Eq` / `logicalplan.Or`), and actor hints (`colRef(colActorHint).Eq`) into pushdown expressions.
- Row-group pruning eliminates scanning irrelevant Parquet segments before query execution.
- Column name validation guard `validateFilterColumns` asserts schema alignment.

---

## 6. Route Inventory (`api/handlers.go`)

Inspected `RegisterRoutes(mux *http.ServeMux)` in `api/handlers.go:63-83`:

| Method | Path | Handler | Purpose |
| :--- | :--- | :--- | :--- |
| `GET` | `/healthz` | `handleHealthz` | Process liveness probe |
| `GET` | `/readyz` | `h.handleReadyz` | Service and audit backend readiness probe |
| `POST` | `/api/v1/observations` | `h.handleIngestObservations` | Ingest single or batch observations |
| `GET` | `/api/v1/observations` | `h.handleQueryObservations` | Query observations with range/layer/actor filters |
| `GET` | `/api/v1/actors` | `h.handleListActors` | List provisional and resolved actors |
| `GET` | `/api/v1/actors/{id}` | `h.handleGetActor` | Retrieve actor details and evidence chain |
| `POST` | `/api/v1/actors/{id}/promote` | `h.handlePromoteActor` | Promote provisional actor to actionable/promoted |
| `GET` | `/api/v1/coverage` | `handleCoverage` | Report layer and source coverage metrics |
| `POST` | `/api/v1/correlate` | `h.handleCorrelate` | Execute on-demand cross-layer correlation |
| `POST` | `/api/v1/collectors/seed` | `h.handleSeed` | Replay seed fixture events into the store |
| `GET` | `/api/v1/store/stats` | `h.handleStoreStats` | Report columnar store and index statistics |
| `GET` | `/api/v1/stream` | `h.handleStream` | Real-time SSE stream of ingested observations |
| `POST` | `/api/v1/audit/webhook` | `h.handleAuditWebhook` | Ingest Kubernetes APIServer audit events |
| `POST` | `/api/v1/audit/gke` | `h.handleGKECloudLogging` | Ingest GKE Cloud Logging audit log entries |

**Assertion:** Zero authorization routes exist (`/api/v1/authorization` or `/authorization`). SFDP-P4-1 has full unencumbered ownership of the "who authorized this action?" query endpoint.

---

## 7. Model Surface Confirmation (`model/actor.go`)

Inspected `model/actor.go`:
- `ProvisionalActor` exposes:
  - `EvidenceChain []EvidenceLink` (JSON: `evidence_chain`)
  - `Confidence float64` (JSON: `confidence`)
  - `AgentRegistryID *string` (JSON: `agent_registry_id`)
  - Additive resolution fields: `CanonicalID`, `PrincipalID`, `Aliases`, `AcceptedEdges`, `DeclinedEdges`, `Delegations`, `Lineage`.
- `EvidenceLink` exposes:
  - `ObservationID string` (JSON: `observation_id`)
  - `Layer Layer` (JSON: `layer`)
  - `Fidelity FidelityTier` (JSON: `fidelity`)
  - `Contribution string` (JSON: `contribution`)
  - `Timestamp time.Time` (JSON: `timestamp`)

---

## 8. Concurrency & Branch Snapshot

- **Integration Ref:** `refs/heads/integration/signal-fusion-v0.1.0`
- **HEAD Commit:** `6acf750703a29d0c4b41202c5a47f5f3433060cd`
- **Commit Log (`git log --oneline -15`):**
  ```
  6acf7507 test(signalloom): end-to-end identity spine integration test (SFDP-P3-GOV)
  b89dda92 test(signalloom): collector falsification suite and anti-vacuous-pass registry guard (SFDP-P3-5)
  a8f00d5c feat(signalloom): attest FrostDB flushes and verify segment integrity (SFDP-P3-3)
  3f286dee feat(signalloom): push down query predicates to FrostDB logical plan and add volume benchmark (SFDP-P3-4)
  a3ed25a5 feat(signalloom): persist identity and delegation graph with temporal validity (SFDP-P3-2)
  76e66620 feat(signalloom): deterministic actor-resolution engine (SFDP-P3-1)
  45ea96f6 feat(signalloom): attest FrostDB flushes and verify segment integrity
  d06b9767 fix(signalloom): prioritize SPIFFE canonical resolver identities
  c428f346 test(signalloom): checkpoint SFDP-P3-1 false-merge blocker
  f429b9e1 feat(signalloom): push down query predicates to FrostDB logical plan and add volume benchmark (SFDP-P3-4)
  e1057362 test(signalloom): collector falsification suite and anti-vacuous-pass registry guard
  4946d1df feat(signalloom): persist identity and delegation graph with temporal validity (SFDP-P3-2)
  043c30c1 docs(signalloom): record SFDP-P3-1 deterministic producer blocker
  2efc851d chore(kanban): record APPROVED review ledger verdict for SFDP-P3-PRE (c5f4c)
  fb46e5a7 docs(signalloom): record Phase-3 identity spine preflight proof (SFDP-P3-PRE)
  ```
- **Branch Tracking:** Workspace is on `6acf7507`, zero untracked worktree modifications, clean base.

---

## 9. Downstream Phase-4 Clearances

| Card ID | Scope | Preconditions Status | Clearance |
| :--- | :--- | :--- | :--- |
| **SFDP-P4-1** | "Who authorized this action?" query + API + panel | Spine resolved graph + attested evidence store + clean route space confirmed | **CLEARED** |
| **SFDP-P4-2** | Adversarial resolution red-team (X/N ceiling) | Deterministic resolver + false-merge==0 invariant baseline confirmed | **CLEARED** |
| **SFDP-P4-3** | FrostDB volume benchmark p95 at N | `logicalplan.Filter` pushdown & row-group pruning confirmed | **CLEARED** |
| **SFDP-P4-4** | Spine + attestation regression + e2e | Segment attestation proof + end-to-end integration test confirmed | **CLEARED** |
| **SFDP-P4-GOV**| Phase-4 governor merge | Dependent on P4-1..P4-4 | **PENDING EXECUTION** |
