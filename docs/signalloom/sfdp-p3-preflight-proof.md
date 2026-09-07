# SFDP-P3-PRE — Phase-3 Identity Spine Preflight Proof

**Created:** 2026-09-05 16:56:00+01:00  
**Status:** `pass` — baseline green, contracts frozen, attestation targets resolved, seams and collision map verified.  
**Integration Ref:** `refs/heads/integration/signal-fusion-v0.1.0`  
**Base Commit SHA:** `d1fff0c5625ff77ef11bf2ba9e5cb37730e2ea6b` (ancestor includes SFDP-P1-GOV `24e371ab1b2654697f9e6216645b6e9e8b034396` and SFDP-P2-GOV `1a790a3eddccad007e2e7dc3eaf4b53da2a1765a`)  

---

## 1. Executive Summary & Objective

This preflight proof establishes that the integration branch is clean and green off the P1-GOV and P2-GOV merges, the P1 `Resolve()` / actor model and FrostDB Arrow store are present and importable, root attestation targets resolve without error, and the exact code seams and collision boundaries for the five Phase-3 implementation cards (SFDP-P3-1 through SFDP-P3-5) are mapped and frozen.

Downstream Phase-3 cards can proceed directly from this verified baseline without environment drift or uncoordinated file collisions.

---

## 2. Environment & Toolchain Verification

| Component | Target / Required | Measured State | Verdict |
| :--- | :--- | :--- | :--- |
| **Go Module Version** | `go 1.24.1` | `go 1.24.1` (`d2-signalloom/apps/signal-ingest/go.mod:3`) | **PASS** |
| **Go Runtime Compiler** | Go 1.24+ | `go version go1.26.2 linux/amd64` | **PASS** |
| **CGO / Non-root Cache** | Sandbox compatible | `GOCACHE=/tmp/gocache CGO_ENABLED=0` | **PASS** |
| **Signal Ingest Unit Suite** | 100% Pass | `make test-signal-ingest` (all packages green) | **PASS** |
| **FrostDB Store Suite** | 100% Pass | `make test-signal-ingest-frostdb` (all frostdb tests green) | **PASS** |
| **Weave Dashboard Suite** | 100% Pass | `test-dashboard-weave` (67/67 vitest passing) | **PASS** |
| **Signal Fusion BATS** | 100% Pass | `test-signalfusion-bats` (14/14 bats passing) | **PASS** |

---

## 3. Root Attestation Targets Availability

All five root attestation targets in `/home/andy/src/cp/osramp-demo/Makefile` resolve cleanly:

1. **`make workload-key`** (`Makefile:367`):
   - Invokes `wait_k8s_exists namespace frontend` and `$(MAKE) -C d2-osramp-apps signing-key` to generate ed25519 workload key for processor signing.
2. **`make signing-keys`** (`Makefile:169`):
   - Generates `.keys/cosign.key`, `.keys/signing-config.json`, `.keys/witness.pem`, `.keys/witness-pub.pem`, and `.keys/orbit-approval.pem`.
3. **`make attested-test`** (`Makefile:976`):
   - Invokes `./scripts/attested-test.sh` to run the test suite under `witness run` and record DSSE envelopes.
4. **`make audit-anchor-tamper-demo`** (`Makefile:1014`):
   - Executes `KEYS_DIR=$(KEYS_DIR) PYTHON=$(AUDIT_ANCHOR_PY) ./scripts/audit-anchor-tamper-demo.sh` to prove tampering detection against Postgres audit anchors.
5. **`make audit-anchor-verify`** (`Makefile:1004`):
   - Executes `cd d2-signalloom/apps/fe-signalloom/src && python3 -m audit_anchor --public-key .keys/witness-pub.pem verify`.

---

## 4. Frozen Core Contracts & Schema Verification

### 4.1. Resolution & Identity Contracts
- **`Resolve(Observation) -> (*ProvisionalActor, error)`** (`correlation/resolve.go:50`):
  - Deterministically derives canonical actor ID and correlation key from `ActorHint`, `PrincipalID`, `ActorID`, `Source`, or `ID`.
- **`ResolvePair(a, b Observation, rule Rule) -> (*ProvisionalActor, error)`** (`correlation/resolve.go:126`):
  - Enforces the **`false-merge == 0`** hard invariant by returning `ErrContradictoryPrincipals` if `a` and `b` carry differing non-empty principal hints (`correlation/resolve.go:99`).
- **Fidelity Gate & Corroboration Cap** (`model/confidence.go:21`):
  - `CorroborationCap = 0.49`: purely suggestive/circumstantial evidence chains never reach actionable status (`>= 0.5`) without strong or definitive corroboration.
- **Additive Observation Model** (`model/signal.go:100`):
  - Fields: `PrincipalID`, `ActorID`, `SessionID`, `ImpersonatedUser`, `DelegationDepth`, `DelegationEdge` (`*EvidenceLink`).

### 4.2. FrostDB Arrow Schema Columns (`store/frostdb.go:87`)
The FrostDB `observations` table schema is confirmed with the following columns:
1. `id` (STRING)
2. `timestamp` (INT64 UnixNano)
3. `layer` (STRING)
4. `fidelity` (STRING)
5. `source` (STRING)
6. `confidence` (DOUBLE)
7. `actor_hint` (STRING)
8. `raw_evidence_ref` (STRING)
9. `description` (STRING)
10. `principal_id` (STRING)
11. `actor_id` (STRING)
12. `session_id` (STRING)
13. `impersonated_user` (STRING)
14. `delegation_depth` (INT64)
15. `labels` (STRING, Dynamic: true)

---

## 5. Phase-3 Seam Inventory & Collision Map

The Phase-3 cards mutate specific files and seams. Sibling implementation cards must respect these function boundaries to avoid merge collisions:

```
                  ┌──────────────────────────────────────────────────────────┐
                  │                 Phase-3 Implementation                    │
                  └──────────────────────────────────────────────────────────┘
                                   │                           │
                   [P3-1: Resolver Engine]         [P3-3: Write-time Attestation]
                   [P3-2: Postgres Graph ]         [P3-4: Query Pushdown        ]
                                   │                           │
                                   ▼                           ▼
                     correlation/ & model/             store/frostdb.go
                     ────────────────────              ────────────────
                     • P3-1: correlation/resolve.go    • P3-3: Append() / InsertRecord
                       deterministic actor engine        write-time Parquet signing
                     • P3-2: audit/ & graph/           • P3-4: QueryRange() / scan
                       Postgres graph & OBO edges        logicalplan.Filter pushdown
```

### Seam Map Table

| Card ID | Scope | Target Files / Seams | Collision Hazard | Safe Boundary Guideline |
| :--- | :--- | :--- | :--- | :--- |
| **SFDP-P3-1** | Deterministic actor-resolution engine | `correlation/resolve.go`<br/>`correlation/engine.go`<br/>`model/actor.go` | **P3-1 vs P3-2** on `model/` & `correlation/` types | P3-1 refines `Resolve()` logic and edge typing; must preserve `model.ProvisionalActor` exported fields consumed by graph persistence. |
| **SFDP-P3-2** | Postgres identity & delegation graph | `audit/postgres.go`<br/>`api/`<br/>`graph/` (net-new) | **P3-2 vs P3-1** on graph model interface | P3-2 implements Postgres table migrations and `acts-on-behalf-of` delegation query APIs without mutating `correlation/resolve.go` core rules. |
| **SFDP-P3-3** | Write-time Witness attestation | `store/frostdb.go` (`Append` / flush)<br/>`scripts/attested-test.sh` | **P3-3 vs P3-4** on `store/frostdb.go` | **Write Path:** P3-3 edits `Append()` / `InsertRecord()` (lines 116-240) to sign flushed Parquet segments via `go-witness`. Do NOT edit `QueryRange()`. |
| **SFDP-P3-4** | FrostDB query pushdown & benchmark | `store/frostdb.go` (`QueryRange` / scan) | **P3-4 vs P3-3** on `store/frostdb.go` | **Read Path:** P3-4 edits `QueryRange()` (lines 240-350) to attach `logicalplan.Filter` predicates for time/layer/actor. Do NOT edit `Append()`. |
| **SFDP-P3-5** | Collector falsification test suite | `collectors/*_test.go`<br/>`collectors/falsification_test.go` | Independent test suite | Hardening test suite asserting mock vs live distinction across all Phase-2 collectors. |

---

## 6. Preflight Conclusion & Authorization

- **Baseline:** 100% Green on all unit, frostdb, and dashboard test suites.
- **Toolchain:** `go 1.24.1` verified; cgo/frostdb tag verified; attestation targets verified.
- **Seams:** Collision boundaries strictly separated between write-path (P3-3) and read-path (P3-4) in `store/frostdb.go`, and resolver (P3-1) vs persistence (P3-2) in `correlation/` and `audit/`.
- **Verdict:** Phase 3 implementation cards (SFDP-P3-1, SFDP-P3-2, SFDP-P3-3, SFDP-P3-4, SFDP-P3-5) are **UNBLOCKED** to proceed.
