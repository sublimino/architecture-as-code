# AMXO-P5-2 Verification Evidence

**Recorded:** 2026-09-13T20:13:30+01:00  
**Scope:** Enforcement of audit upload idempotency across concurrency, repeated submissions, and interrupted network retries; transactional deduplication in Go signal-ingest verifier and Python FastAPI `audit_ingest.py`; strict conflict rejection (HTTP 409) for mismatched payloads under duplicate session IDs.

## Test Ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `make demo-agentmaxxing-ingest-test` | 29 Go tests + 12 Pytest tests passed | 0 | Integrated AgentMaxxing audit session ingest, deduplication, and verification test target |
| `go test -race -v ./collectors/agentnono/...` | 29 passed | 0 | Go unit test suite in `signal-ingest` with race detector asserting `VerifyFinalizedSession`, idempotent re-verification, concurrent duplicate verification (25 goroutines), interrupted retry resumption, and conflicting session rejection |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k "test_idempotency or test_concurrent_upload or test_interrupted_retry"` | 5 passed | 0 | Pytest contract test suite asserting HTTP 200 idempotent returns on duplicate sessions, HTTP 200 on finalized duplicate sessions, HTTP 409 Conflict on payload mismatch, 10-thread concurrent upload deduplication, and retry resumption |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI Tier 1 contract tests and numbered migration sequence validation |
| `make demo-agentmaxxing-host-test` | 70 passed | 0 | 38 unittest + 6 pytest + 26 BATS tests asserting nono profile, anti-escape, and TOCTOU hasher integrity |

## Cryptographic Invariants & Idempotency Mechanics

1. **Go Verifier In-Memory Deduplication & Per-Session Synchronization**:
   - `AuditVerifier` maintains `finalizedSessions map[string]*FinalizedSessionVerification` and `sessionLocks map[string]*sync.Mutex`.
   - `VerifyFinalizedSession` acquires a granular per-session mutex to serialize concurrent submissions for the same `session_id`, ensuring thread safety while allowing independent sessions to verify fully in parallel.
   - Upon encountering an existing cached verification, the verifier asserts equivalence across `RootDigest`, `EventCount`, and `ActorID`. If identical, it returns a clone with `IsIdempotent: true`.
   - If an incoming session reuses an existing `session_id` with conflicting digests or counts, it is immediately rejected with `StatusTampered`, error `session conflict`, and violation `session_conflict`.

2. **FastAPI Upload Idempotency & Conflict Resolution**:
   - `AuditSessionVerificationResult` includes `is_idempotent: bool = False`.
   - Endpoint `POST /sessions` (and `/sessions/finalized`) takes `response: Response` to dynamically set HTTP status.
   - Initial ingestion returns HTTP 201 Created (`is_idempotent: false`).
   - Re-uploading an identical session returns HTTP 200 OK (`is_idempotent: true`) with an identical confirmation root hash and verification proof.
   - Attempting to submit conflicting event streams or altered parameters under an existing session ID raises an `APIError(status_code=409, code="session_conflict")`.

3. **Concurrency & Thread Safety**:
   - Python ingest employs `_get_session_async_lock(session_key)` and `_SESSIONS_LOCK` to eliminate race windows between concurrent coroutines.
   - 10-thread concurrent submission tests (`ThreadPoolExecutor`) confirm that simultaneous uploads of identical sessions yield valid responses (one 201 Created and nine 200 OK), without duplicate entries or state corruption.
   - Go verifier was validated under `-race` with 25 concurrent goroutines without memory errors or data races.

4. **Interrupted Retry Resumption**:
   - Network timeouts or interrupted transport retries are handled cleanly: if the prior upload successfully verified and persisted, the retry receives the verified confirmation hash immediately.
   - If a prior attempt failed before persistence, the subsequent retry verifies through the canonical hash chain and signature pipeline without leftover corruption.

## Delivery Boundaries

- Executed on task branch `feat/amxo-p5-2-upload-idempotency`.
- Clean unsigned commits (`git commit --no-gpg-sign`).
- Obsidian proposal file NOT touched or committed to git.
