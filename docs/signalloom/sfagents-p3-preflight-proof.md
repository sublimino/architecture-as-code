# SFAGENTS-P3-PRE — Phase 3 Pre-Flight & Telemetry Baseline Proof

**Created:** 2026-09-07 11:01:00+01:00  
**Status:** `pass` — baseline green, Phase 2 certified, FrostDB & telemetry correlation verified, Phase 3 workstreams unblocked.  
**Integration Ref:** `integration/sfagents-v0.1.0`  
**Base Commit SHA:** `aa7b2e6f` (`checkpoint/sfagents-p2-certified`)  

---

## 1. Executive Summary & Objectives

This pre-flight verification establishes that the integration branch is clean, unbroken, and fully qualified off the Phase 2 Governor Certification checkpoint (`checkpoint/sfagents-p2-certified`). All 5 Dossier tabs, deep-linking engines, secondary filters, and honest state vocabularies are fully functional.

The telemetry foundation for Phase 3 — specifically the FrostDB columnar signal store, Arrow pushdown query paths, and eBPF Sentinel containment feedback mechanisms — has been tested, validated, and confirmed dispatch-safe.

---

## 2. Environment & Baseline Test Suite Verification

| Verification Target | Command | Result | Verdict |
| :--- | :--- | :--- | :--- |
| **Git Ancestry** | `git merge-base --is-ancestor checkpoint/sfagents-p2-certified HEAD` | Ancestry verified (`exit 0`) | **PASS** |
| **Kanban Dependency Check** | `./scripts/kanban-check.sh link-check --repo /home/andy/src/cp/osramp-demo` | 6/6 rules pass, CRITICAL=0, FAIL=0, WARN=0 | **PASS** |
| **BATS Evidence Suite** | `bats d2-signalloom/test/agents-redesign-evidence.bats` | 60/60 tests passing (0 failures) | **PASS** |
| **FastAPI Backend Contract** | `pytest tests/test_api_compat.py` | 71/71 tests passing (0 failures, 1 warning) | **PASS** |
| **Dashboard TypeScript** | `bunx tsc --noEmit` | Clean compile (0 errors) | **PASS** |
| **Signal Ingest Core Suite** | `make test-signal-ingest` | 100% passing across store, model, correlation | **PASS** |
| **FrostDB Integration Suite** | `make test-signal-ingest-frostdb` | 100% passing including `spine_integration_test.go` | **PASS** |

---

## 3. Phase 3 Workstream Seams & Collision Map

Phase 3 contains four implementation/verification cards and a final governor certification:

1. **`SFAGENTS-P3-1` (`1b125`): FrostDB Telemetry Correlation Integration**
   - **Scope:** Wire FrostDB columnar signal queries into `AgentActivityTab.tsx` / backend audit streams.
   - **Seams:** `d2-signalloom/apps/fe-signalloom/src/api_compat.py`, `AgentActivityTab.tsx`.
   - **Dependencies:** `SFAGENTS-P3-PRE`, `SFAGENTS-P2-5`.

2. **`SFAGENTS-P3-2` (`816d5`): eBPF Sentinel & Stun Containment Feedback**
   - **Scope:** Connect eBPF Sentinel observation ACKs to `AgentAccessTab.tsx` containment tracks (cgroup, TC drops, SPIFFE CRL).
   - **Seams:** `AgentAccessTab.tsx`, `AgentDetailPage.tsx`, Sentinel ACK handlers.
   - **Dependencies:** `SFAGENTS-P3-PRE`, `SFAGENTS-P2-3`.

3. **`SFAGENTS-P3-3` (`724a5`): Vitest & BATS Acceptance Test Suite**
   - **Scope:** Validate all 15 acceptance criteria from the appraisal spec across Vitest and BATS.
   - **Seams:** `d2-signalloom/test/agents-redesign-evidence.bats`, acceptance specs.
   - **Dependencies:** `SFAGENTS-P3-1`, `SFAGENTS-P3-2`.

4. **`SFAGENTS-P3-4` (`c6ec2`): Live Authenticated Origin Verification**
   - **Scope:** End-to-end verification of authenticated origins with real JWTs and proxy routes.
   - **Dependencies:** `SFAGENTS-P3-3`.

5. **`SFAGENTS-P3-GOV` (`2c66c`): Final Mission Governor Certification**
   - **Scope:** Fast-forward governor, run all test gates, and certify 100% completion of the SFAGENTS board.
   - **Dependencies:** `SFAGENTS-P3-1`..`04`.

---

## 4. Verdict & Dispatch Readiness

`SFAGENTS-P3-PRE` is **APPROVED** and dispatch-safe. Downstream parallel streams (`SFAGENTS-P3-1` and `SFAGENTS-P3-2`) can proceed concurrently.
