# AMXO-P5-1 Verification Evidence

**Recorded:** 2026-09-13T20:01:00+01:00  
**Scope:** Verification of finalized Nono audit sessions, rejection of invalid audit chains, sequence gap/out-of-order rejection, terminal finalization markers, cryptographic integrity across Go signal-ingest and Python FastAPI ingest.

## Test Ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `go test -v ./collectors/agentnono/...` | 25 passed | 0 | Go unit test suite in `signal-ingest` asserting `VerifyFinalizedSession`, valid finalized chains, unfinalized session rejection, empty session rejection, session ID mismatch rejection, sequence gap rejection, out-of-order sequence rejection, hash chain break rejection, and forged signature rejection |
| `python3 -m pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py` | 29 passed | 0 | Pytest contract test suite asserting `/sessions/finalized` and `require_finalized=true` endpoints, unfinalized session rejection (HTTP 422), sequence gap rejection (HTTP 400), out-of-order sequence rejection (HTTP 400), empty session rejection (HTTP 400), hash chain corruption rejection (HTTP 400), forged signature rejection (HTTP 400), and probe endpoint validation |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI Tier 1 contract tests and numbered migration sequence validation |
| `make demo-agentmaxxing-host-test` | 70 passed | 0 | 38 unittest + 6 pytest + 26 BATS tests asserting nono profile, anti-escape, and TOCTOU hasher integrity |

## Cryptographic Invariants & Verification Details

1. **Contiguous Sequence Ordering**:
   - In Go (`VerifyFinalizedSession`): Asserts `ev.Seq == firstSeq + int64(i)`. If `ev.Seq <= events[i-1].Seq`, returns status `StatusTampered` with violation `out_of_order_sequence`. If `ev.Seq != expectedSeq`, returns `StatusTampered` with violation `sequence_gap`.
   - In Python (`validate_finalized_session_chain`): Asserts contiguous increments from initial sequence. Duplicate or backward steps return HTTP 400 with `out_of_order_sequence`; forward jumps return HTTP 400 with `sequence_gap`.

2. **SHA-256 Hash-Chain Continuity**:
   - Every event block incorporates `prev_digest` (or `prev_hash`) calculated from the canonical payload of the immediately preceding event.
   - Any break in digest continuity or mutation of prior payload content invalidates downstream hash computations and is immediately rejected with HTTP 400 / `StatusTampered`.

3. **Terminal Finalization Invariant**:
   - A session is verified as complete and immutable only when a terminal finalization marker is present.
   - Go `IsFinalizedEvent`: Inspects `LifecycleState` (`finalized`, `completed`, `terminated`, `closed`), `EventType` (`session_finalized`, `session_end`, `finalized`), or metadata flags (`finalized: true`).
   - Python `validate_finalized_session_chain`: Inspects `session.ended_at` and terminal event `event_type`, `action`, or `detail.finalized`.
   - Unfinalized sessions submitted to finalized endpoints fail with HTTP 422 Unprocessable Entity (`unfinalized_session`).

4. **Detached Signature & SPIFFE Trust Validation**:
   - Every audit session carries a detached cryptographic signature over the root hash (`root_digest`).
   - Verified against SPIFFE SVID certificates, asymmetric public keys (ECDSA P-256, Ed25519, RSA), or HMAC SPIFFE digest tokens.
   - Forged, tampered, or mismatched signatures are rejected with HTTP 400 / `StatusTampered`.

5. **Landlock ABI & GitOID Attribution**:
   - Go `VerifyFinalizedSession` inspects and records maximum Landlock ABI level encountered across the session execution.
   - Computes deterministic GitOID (SHA-256 blob header `blob <len>\0<data>`) for each event signature block, providing immutable provenance anchors.

## Delivery Boundaries

- Executed within isolated worktree `67394` / branch `feat/amxo-p5-1-session-verification`.
- Clean unsigned commits (`git commit --no-gpg-sign`).
- Zero database migrations or backward compatibility breaks.
- Full parity between Go ingestion daemon and Python API proxy.
