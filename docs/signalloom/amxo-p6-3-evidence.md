# AMXO-P6-3 — Deterministic Local Onboarding-to-Removal Acceptance Journey

**Status:** PASS — Full 5-phase deterministic local acceptance journey implemented, automated, and verified  
**Completed at:** 2026-09-13 20:41:00+01:00  
**Task ID:** `03790` (`AMXO-P6-3`)  
**Role:** implementation  
**Branch:** `feat/amxo-p6-3-acceptance-journey`  
**Base:** `9a11117f776bcbbda69622d17c76891eb7058df5`  

---

## 1. Executive Summary & Verification Verdict

`AMXO-P6-3` establishes the definitive, deterministic acceptance test suite validating the complete lifecycle journey of external Linux agents on Signal Loom — spanning from initial operator registration through host enrollment, session upload with hash-chain telemetry, privacy sanitization, denial falsification, and independent operator revocation with subsequent upload refusal.

### Core Deliverables:
1. **Python Deterministic Acceptance Journey Suite (`test_agentmaxxing_acceptance_journey.py`)**:
   - Implemented in `d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py`.
   - Structures the 8 core operational lifecycle steps into modular, reusable steps and independent phase test functions:
     - **Phase 1: Attributable Operator Registration & Token Issuance**: Registered via OIDC operator subject bearer token (`POST /api/v1/external-agents/register`), returning `pending` enrollment status. Issues one-time enrollment token (`POST /api/v1/external-agents/registrations/{agent_id}/token`).
     - **Phase 2: One-Time Host Enrollment Exchange & Atomic Single-Use Check**: External Linux host exchanges the enrollment token with host public key and SPIFFE identity (`POST /v1/external-agents/enroll`), receiving least-privilege audit credentials. Atomic redemption is verified: immediate re-submission of the identical token is strictly rejected with `HTTP 409 Conflict`.
     - **Phase 3: Audit Session Upload & Projection Sanitization**: Host submits finalized session (`POST /api/audit/sessions`) with structured process spawn (`exec`), artifact written (`write`), and network egress (`connect`) events. Cryptographic SHA-256 hash-chain continuity is verified. External evidence projections (`GET /api/v1/agents/{agent_id}/external-evidence`) confirm verified status and allowlisted metadata, while prohibited fields (`raw_payload`, `payload`, `memory_dump`, `terminal_out`) are strictly stripped.
     - **Phase 4: Idempotency & Denial Falsification**: Identical session uploads are idempotent (`HTTP 200/201`). Uploads under identical `session_id` with conflicting root hash return `HTTP 409 Conflict`. Broken hash chains (tampered event timestamps) return `HTTP 400 Bad Request`. Missing sequence numbers (sequence gaps) return `HTTP 400 Bad Request`.
     - **Phase 5: Host Revocation & Post-Revocation Refusal**: Attributable operator revokes host registration (`POST /v1/external-agents/{agent_id}/revocations`) returning `HTTP 202 Accepted` with `revocation-accepted`. Subsequent session uploads from the revoked host are denied with `HTTP 403 Forbidden` (`host_revoked`).
   - Supports execution via `pytest` (6 unit tests) and CLI execution (`--phase 1..5` and `--phase all`).
2. **Companion BATS Acceptance Suite (`agentmaxxing-acceptance-journey.bats`)**:
   - Authored `test/signalloom/agentmaxxing-acceptance-journey.bats` with 6 dedicated test cases asserting phase outcomes and overall lifecycle completion.
3. **Dedicated Make Target (`demo-agentmaxxing-acceptance-test`)**:
   - Added `demo-agentmaxxing-acceptance-test` to `Makefile` and `.PHONY`. Runs both pytest and BATS suites with zero external cluster dependencies.
   - Verified 100% pass across all 6 pytest cases and 6 BATS test cases.
4. **Acceptance Spec Coverage Guard**:
   - Executed `bats test/acceptance-spec-coverage.bats` (7/7 passed), confirming zero drift in test registry and pipeline declarations.

---

## 2. Verification Command Output

### 2.1 Full Acceptance Journey (`make demo-agentmaxxing-acceptance-test`)
```
PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -p no:libtmux -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py
============================= test session starts ==============================
platform linux -- Python 3.14.4, pytest-9.1.1, pluggy-1.6.0 -- /home/linuxbrew/.linuxbrew/opt/python@3.14/bin/python3.14
cachedir: /tmp/pytest_cache_fe
rootdir: /home/andy/src/cp/osramp-demo/d2-signalloom/apps/fe-signalloom/src
configfile: pytest.ini
plugins: anyio-4.14.2
collecting ... collected 6 items

d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_phase_1_registration_and_token PASSED [ 16%]
d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_phase_2_host_enrollment_and_single_use PASSED [ 33%]
d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_phase_3_session_upload_and_evidence_projection PASSED [ 50%]
d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_phase_4_denial_falsification PASSED [ 66%]
d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_phase_5_revocation_and_post_revocation_denial PASSED [ 83%]
d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py::test_complete_onboarding_to_removal_journey PASSED [100%]

========================= 6 passed, 1 warning in 8.65s =========================
bats test/signalloom/agentmaxxing-acceptance-journey.bats
agentmaxxing-acceptance-journey.bats
   AMXO-P6-3 phase 1: attributable operator registration and one-time e...1/6 ✓ AMXO-P6-3 phase 1: attributable operator registration and one-time enrollment token issuance
   AMXO-P6-3 phase 2: one-time host enrollment key exchange, credential...2/6 ✓ AMXO-P6-3 phase 2: one-time host enrollment key exchange, credential binding, and atomic single-use enforcement
   AMXO-P6-3 phase 3: audit session telemetry upload, hash chain valida...3/6 ✓ AMXO-P6-3 phase 3: audit session telemetry upload, hash chain validation, and evidence projection sanitization
   AMXO-P6-3 phase 4: denial falsification on tampered hash chain, sequ...4/6 ✓ AMXO-P6-3 phase 4: denial falsification on tampered hash chain, sequence gap, and conflicting payload
   AMXO-P6-3 phase 5: independent host revocation and subsequent upload...5/6 ✓ AMXO-P6-3 phase 5: independent host revocation and subsequent upload denial (403 host_revoked)
   AMXO-P6-3 e2e acceptance journey: complete onboarding-to-removal lif...6/6 ✓ AMXO-P6-3 e2e acceptance journey: complete onboarding-to-removal lifecycle execution

6 tests, 0 failures
```

### 2.2 Acceptance Spec Coverage Guard (`bats test/acceptance-spec-coverage.bats`)
```
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts1/7 ✓ the guard can read every project in playwright.config.ts
   every spec on disk has exactly one registry row, and every row has a...2/7 ✓ every spec on disk has exactly one registry row, and every row has a spec
   every registry runner is a known kind, and every non-CI row gives a ...3/7 ✓ every registry runner is a known kind, and every non-CI row gives a reason
   a spec matches a playwright project if and only if the registry says so4/7 ✓ a spec matches a playwright project if and only if the registry says so
   every ci: row names a stage that really runs that spec5/7 ✓ every ci: row names a stage that really runs that spec
   every spec a CI stage runs is registered as ci:6/7 ✓ every spec a CI stage runs is registered as ci:
   every make: row names a target whose recipe runs that spec7/7 ✓ every make: row names a target whose recipe runs that spec

7 tests, 0 failures
```

---

## 3. Security & Boundary Assurances

| Boundary / Guard | Verification Mechanism | Status |
|---|---|---|
| **Attributable Registration** | OIDC JWT subject mapping to tenant identity; zero anonymous registrations | **PASS** |
| **Atomic Token Consumption** | Single-use enrollment token; replay returns HTTP 409 | **PASS** |
| **Least-Privilege Credential** | SPIFFE audit-upload-only scope issued on enrollment | **PASS** |
| **Hash-Chain Integrity** | Contiguous sequence and entry-hash chain verified; tampered sequence or broken hash returns HTTP 400 | **PASS** |
| **Privacy Sanitization** | Prohibited fields (`raw_payload`, `payload`, `memory_dump`, `terminal_out`) stripped prior to projection | **PASS** |
| **Idempotency & Conflicts** | Identical payload returns HTTP 200/201; payload mismatch under same session returns HTTP 409 | **PASS** |
| **Operator Revocation** | Authorized operator can immediately revoke host; status transitions to `revoked` | **PASS** |
| **Post-Revocation Denial** | Upload attempts by revoked host are fail-closed with HTTP 403 Forbidden (`host_revoked`) | **PASS** |
| **Zero Cluster Cost** | Fast local execution (~15s) using in-memory mock adapters without requiring Kind or GCP | **PASS** |
