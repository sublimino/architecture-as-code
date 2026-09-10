# SFAS-P1-3 Evidence: Authenticated Human Onboarding Claims & Delegation Graph Injection

**Card**: `SFAS-P1-3` (`56aea`)  
**Timestamp**: `2026-09-10T21:20:00Z`  
**Base Ref**: `integration/sfas-v0.1.0`  
**Harness**: `antigravity` (`agy`)  
**Status**: `VERIFIED_PASS`  

---

## 1. Executive Summary

`SFAS-P1-3` implements the direct connection between Signal Loom operator onboarding claims (`POST /api/v1/agents/claim` and `POST /api/v1/agents/{agent_id}/claim`) and the Signal Fusion Actor-Resolution Spine (SFAS) delegation graph.

Key capabilities delivered:
1. **Automated Delegation Synchronization**:
   - `sync_claim_delegation_to_spine` and `clamp_claim_delegation_in_spine` in `d2-signalloom/apps/fe-signalloom/src/agent_claim.py`.
   - On operator claim creation, an authenticated `acts-on-behalf-of` delegation edge is posted to `signal-ingest:8082/api/v1/delegations` with principal actor, delegate agent, capabilities, and containment claims.
2. **Capability Scope Enforcement & Landlock Attestation**:
   - `CapabilityClaimVerifier` in `d2-signalloom/apps/signal-ingest/identity/claim_verifier.go`.
   - 100% rejection on unauthorized capability escalations (`ScopeExceededError` / `ErrScopeExceeded` / HTTP 403).
   - Mandatory Landlock attestation (`containment:landlock`) for `agent-nono-evidenced` workloads (`ErrMissingLandlockClaim` / HTTP 403).
   - Tamper and violation logging to `store.SignalStore`.
3. **Idempotent Seeding & Non-Destructive Clamping**:
   - Migration `003_idempotent_seeding.sql` with unique index constraints `idx_aliases_idempotent_seed` and `idx_delegations_idempotent_seed`.
   - `ClampDelegation(ctx, identifier, clampTime)` updates `valid_until` to terminate active delegation traversal upon claim release without row destruction.
4. **Resilient Non-Blocking Degradation**:
   - If `signal-ingest` is unreachable or degraded during claim creation, fe-signalloom logs a warning and completes agent governance onboarding without blocking user workflow.

---

## 2. Test Execution & Evidence

### 2.1 Python Delegation Integration Suite (`test_claim_delegation.py`)
```text
============================= test session starts ==============================
rootdir: /home/andy/src/cp/osramp-demo/d2-signalloom/apps/fe-signalloom/src
configfile: pytest.ini
collected 6 items

d2-signalloom/apps/fe-signalloom/src/tests/test_claim_delegation.py ...... [100%]

========================= 6 passed, 1 warning in 0.75s =========================
```

### 2.2 Python Regression Suite (`test_agent_claim.py`)
```text
============================= test session starts ==============================
rootdir: /home/andy/src/cp/osramp-demo/d2-signalloom/apps/fe-signalloom/src
configfile: pytest.ini
collected 10 items

d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py .......... [100%]

======================== 10 passed, 1 warning in 35.61s ========================
```

### 2.3 Go Identity & API Race Detector Suite
```text
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/identity	2.485s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api	9.376s
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/api/audit	1.187s
```

All subtests passed, including:
- `TestCapabilityClaimVerifier/ValidClaim`
- `TestCapabilityClaimVerifier/ForgedSignature`
- `TestCapabilityClaimVerifier/CapabilityEscalation`
- `TestCapabilityClaimVerifier/MissingLandlock`
- `TestSeedFixtureGraph_Idempotent`
- `TestClampDelegation`
- `TestDelegationEndpoints`

---

## 3. Review Checklist & Gate Compliance

| Requirement | Target | Actual | Verdict |
| :--- | :--- | :--- | :--- |
| Delegation sync on operator claim mutation | `fe-signalloom` -> `signal-ingest` | Implemented in `_execute_claim` & `agent_claim.py` | PASS |
| Delegation clamping on claim release | `DELETE /claim/{id}` -> `/delegations/clamp` | Implemented in `release_agent_claim` | PASS |
| Scope-exceeded capability escalation check | HTTP 403 Forbidden | Verified in `TestCapabilityClaimVerifier` & `delegations_test.go` | PASS |
| Landlock attestation enforcement | HTTP 403 Forbidden | Verified in `TestCapabilityClaimVerifier` & `delegations_test.go` | PASS |
| Idempotent seed migration | SQL Unique Indexes | Migration `003_idempotent_seeding.sql` verified | PASS |
| Clean test runs with race detector | Go & Python | 100% tests passing | PASS |
