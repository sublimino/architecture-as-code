# SLON-P2-2 Verification Evidence: Dynamic Nono Capability Detection & Signed Audit Ingest

**Card ID:** `SLON-P2-2`  
**Title:** Implement dynamic Nono optionality detection and signed audit session telemetry ingest  
**Phase:** Phase 2 (Dual Demo Agent Onboarding & Live Demo)  
**Agent:** `antigravity`  
**Worktree:** `/home/andy/src/.worktrees/254f7/osramp-demo`  
**Base Ref:** `refs/heads/integration/slon-v0.1.0`  
**Status:** `Completed` — 100% Verification Pass  

---

## 1. Executive Summary

Task `SLON-P2-2` implemented dynamic Nono capability detection and signed audit session telemetry ingest conforming strictly to **SP-5** (Optional Nono Capability Detection & Fallback Invariant):
1. **Dynamic Pre-Execution Probe Script (`probe-nono-capability.sh`)**:
   - Authored in `d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh`.
   - Inspects both binary presence (`command -v nono` / `$NONO_BIN`) and Linux Landlock LSM support (kernel ABI level >= 1, `/sys/kernel/security/lsm`, unprivileged user namespaces).
   - If present: launches agent workload under `nono run --audit-out <path>` and signs session hash with agent SPIFFE SVID key.
   - If absent or Landlock disabled: outputs structured warning telemetry (`{"nono_capability_available": false, "status": "fallback", "fallback": "unconfined"}`) and executes standard entrypoint unconfined without crashing or causing pod `CrashLoopBackOff`.
2. **Signed Audit Ingest Backend (`fe-signalloom`)**:
   - Authored in `d2-signalloom/apps/fe-signalloom/src/audit_ingest.py` and mounted in `main.py`.
   - Exposes `POST /api/audit/sessions`, `GET /api/audit/sessions`, `GET /api/audit/sessions/{session_id}`, and `POST /api/audit/sessions/verify`.
   - Cryptographically verifies hash-chain integrity (`H_i = sha256(H_{i-1} || canonical_json(event_i))`) from genesis to root hash.
   - Verifies detached cryptographic signatures across ECDSA (P-256), Ed25519, RSA, and SPIFFE SVID HMAC formats.
   - Persists verified sessions to PostgreSQL (`public.signed_audit_sessions` via migration `035_signed_audit_sessions.sql`) and in-memory registry with strict multi-tenant isolation.
   - Rejects tampered logs and forged signatures with HTTP 400.

---

## 2. Invariants & Architecture Compliance (SP-5)

| Invariant / Standard | Implementation & Enforcement | Verification Proof |
| :--- | :--- | :--- |
| **SP-5 Dynamic Probe** | `probe-nono-capability.sh` pre-execution inspection of binary & Landlock ABI | `--dry-run` and synthetic missing tests pass (10/10 BATS) |
| **SP-5 Zero CrashLoop Fallback** | Fallback gracefully executes unconfined `exec "$@"` or unconfined agent loop | Verified unconfined exec exit code 0; cluster pod 0 restarts |
| **Hash-Chain Verification** | RFC-8785 deterministic canonical event serialization with SHA-256 chaining | 14/14 Pytest assertions; tampered events rejected with HTTP 400 |
| **SPIFFE Signature Ingest** | Detached signatures verified against SPIFFE SVID and public key credentials | ECDSA, Ed25519, RSA, and SPIFFE HMAC token verification pass |
| **Tenant Isolation** | All sessions queried and stored strictly partitioned by `authenticated_tenant` | Multi-tenant cross-boundary query tests return HTTP 404 |

---

## 3. Verification Test Evidence

### 3.1 BATS Test Suite (`test/signalloom/nono-optionality-fallback.bats`)

```
nono-optionality-fallback.bats
   1. Dynamic Nono capability probe script exists and is executable 1/10 ✓ 1. Dynamic Nono capability probe script exists and is executable
   2. Probe script executes with --dry-run and returns valid structured JSON telemetry 2/10 ✓ 2. Probe script executes with --dry-run and returns valid structured JSON telemetry
   3. Probe script detects Nono binary and Landlock capability when present 3/10 ✓ 3. Probe script detects Nono binary and Landlock capability when present
   4. Probe script gracefully falls back when Nono is simulated as missing 4/10 ✓ 4. Probe script gracefully falls back when Nono is simulated as missing
   5. Fallback path executes workload unconfined without crashing 5/10 ✓ 5. Fallback path executes workload unconfined without crashing
   6. Backend audit session ingest accepts and verifies valid hash-chained session 6/10 ✓ 6. Backend audit session ingest accepts and verifies valid hash-chained session
   7. Backend audit session ingest rejects broken or tampered hash chains with HTTP 400 7/10 ✓ 7. Backend audit session ingest rejects broken or tampered hash chains with HTTP 400
   8. Backend audit session ingest rejects invalid or forged signatures with HTTP 400 8/10 ✓ 8. Backend audit session ingest rejects invalid or forged signatures with HTTP 400
   9. Standalone session verify probe endpoint validates session without persistence 9/10 ✓ 9. Standalone session verify probe endpoint validates session without persistence
   10. In-cluster demo agent pods in fe-signalloom-agents are healthy with zero crashloops 10/10 ✓ 10. In-cluster demo agent pods in fe-signalloom-agents are healthy with zero crashloops

10 tests, 0 failures
```

### 3.2 Pytest Backend Ingest Suite (`d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py`)

```
============================= test session starts ==============================
platform linux -- Python 3.14.4, pytest-9.1.1, pluggy-1.6.0
rootdir: /home/andy/src/.worktrees/254f7/osramp-demo/d2-signalloom/apps/fe-signalloom/src
configfile: pytest.ini
collected 14 items

d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_valid_signed_audit_session PASSED [  7%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_requires_authentication PASSED [ 14%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_rejects_broken_hash_chain PASSED [ 21%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_rejects_mismatched_root_hash PASSED [ 28%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_rejects_invalid_signature PASSED [ 35%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_with_ecdsa_p256_key PASSED [ 42%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_with_ed25519_key PASSED [ 50%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_verify_probe_endpoint PASSED [ 57%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_list_and_get_sessions_with_tenant_isolation PASSED [ 64%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_with_rsa_key PASSED [ 71%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_ingest_empty_session_with_genesis PASSED [ 78%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_list_sessions_filter_and_pagination PASSED [ 85%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_get_nonexistent_session_returns_404 PASSED [ 92%]
d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py::test_canonical_event_json_determinism PASSED [100%]

======================== 14 passed in 1.12s ========================
```

### 3.3 Dynamic Probe Execution Proofs

#### Host Detection Output:
```json
{
  "timestamp": "2026-09-10T10:06:23Z",
  "event": "nono_probe",
  "status": "detected",
  "nono_capability_available": true,
  "binary": "/usr/bin/nono",
  "sandboxing": "landlock",
  "evidence_signing": "spiffe",
  "landlock_abi_version": 1
}
```

#### Synthetic Fallback Output (`NONO_FORCE_FALLBACK=1`):
```json
{
  "timestamp": "2026-09-10T10:03:34Z",
  "event": "nono_probe",
  "status": "fallback",
  "nono_capability_available": false,
  "warning": "Nono binary or Landlock LSM not available on container substrate; executing unconfined without crashing or blocking pod scheduling",
  "fallback": "unconfined"
}
```

---

## 4. Acceptance Spec Coverage Guard

```
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts 1/7 ✓
   every spec on disk has exactly one registry row, and every row has a spec 2/7 ✓
   every registry runner is a known kind, and every non-CI row gives a reason 3/7 ✓
   a spec matches a playwright project if and only if the registry says so 4/7 ✓
   every ci: row names a stage that really runs that spec 5/7 ✓
   every spec a CI stage runs is registered as ci: 6/7 ✓
   every make: row names a target whose recipe runs that spec 7/7 ✓

7 tests, 0 failures
```
