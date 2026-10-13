# Proposal — CPAI LLM Contract, Signal Ingest Containment, Fe EAP Upstream, Fleet Bao Plane, and OpenBao Accessor Mock HEAD Body Suppression and Method Gates (2026-Q4)

- **Date:** 2026-10-13
- **Author:** Antigravity Autonomous Security Engineer
- **Status:** Proposed
- **Tag:** `CPAIINGESTEAPBAOLOOKUP`
- **Scope:** `d2-signalloom/apps/cpai-engineer/llm_contract_test.go`, `d2-signalloom/apps/signal-ingest/correlation/containment_test.go`, `d2-signalloom/apps/fe-signalloom/src/tests/test_eap_default_deny.py`, `d2-signalloom/apps/fleet-manager/bao_plane_tokens_test.go`, and `d2-signalloom/apps/fleet-manager/openbao_lookup_test.go`

---

## 1. Problem Statement

Across test suites and mock infrastructure, HTTP servers simulate upstream LLM providers, Stun Sentinels, OpenBao endpoints, and Signal Ingest services.
These mocks frequently accept arbitrary HTTP verbs.
They do not set standard `Allow` headers on 405 Method Not Allowed responses.
Additionally, they emit response bodies on HTTP HEAD requests.
This breaks RFC 9110 Section 6.4.1 compliance.
It masks contract regressions in client callers.

Five specific areas require hardening:

1. **CPAI Engineer LLM Contract Mocks (`cpai-engineer/llm_contract_test.go`):**
   Mocks for OpenAI chat completions and Anthropic messages APIs accept any verb.
   They lack `Allow: POST` headers and leak response bodies on HEAD requests.

2. **Signal Ingest Containment Mocks (`signal-ingest/correlation/containment_test.go`):**
   Mock Stun Sentinel servers in containment tests accept arbitrary methods without `Allow: POST`.
   They encode JSON response bodies directly on HEAD requests.

3. **Fe EAP Default Deny Upstream Mock (`fe-signalloom/src/tests/test_eap_default_deny.py`):**
   `_RecordingUpstream` delegates error responses to `super().send_error`.
   This emits HTML error bodies and leaks content on HEAD requests.
   It also emits plaintext errors instead of structured JSON.

4. **Fleet Manager Bao Plane Tokens Mock (`fleet-manager/bao_plane_tokens_test.go`):**
   Mock OpenBao server accepts arbitrary verbs on sys leases revoke.
   It emits JSON error bodies on HEAD requests on 500 error paths.

5. **Fleet Manager OpenBao Accessor Lookup Mock (`fleet-manager/openbao_lookup_test.go`):**
   Mock accessor server lacks method gating across accessors, lookup-accessor, and revoke-accessor routes.
   It leaks response bodies on HEAD requests across both success and failure paths.

---

## 2. Proposed Architecture & Hardening

### 2.1 CPAI Engineer LLM Contract Mocks

- Update all mock LLM servers to reject non-POST requests with HTTP 405.
- Set `Allow: POST` and `Content-Type: application/json`.
- Suppress response bodies on HEAD requests across both OpenAI and Anthropic mocks.
- Add test assertions verifying HEAD parity and method rejection.

### 2.2 Signal Ingest Containment Mocks

- Update mock Stun Sentinel servers to reject non-POST requests with HTTP 405.
- Set `Allow: POST` and `Content-Type: application/json`.
- Suppress response bodies on HEAD requests.
- Add assertions verifying HEAD body suppression.

### 2.3 Fe EAP Upstream Mock

- Override `send_error` in `_RecordingUpstream` to set `Content-Type: application/json`.
- Return structured JSON errors `{"error": {"code": code, "message": message}}`.
- Ensure zero bytes are written when `self.command == "HEAD"`.
- Enforce `Allow: GET, POST, HEAD` on method not allowed responses.

### 2.4 Fleet Manager Bao Plane Tokens Mock

- Gate methods on `/v1/sys/leases/revoke` to `PUT`, `POST`, and `HEAD` with `Allow: PUT, POST, HEAD`.
- Suppress response bodies on HEAD requests for 500 Internal Server Error responses.
- Add unit assertions testing HEAD body suppression.

### 2.5 Fleet Manager OpenBao Accessor Lookup Mock

- Gate `/v1/auth/token/accessors` to `GET` and `HEAD` with `Allow: GET, HEAD`.
- Gate `/v1/auth/token/lookup-accessor` and `/v1/auth/token/revoke-accessor` to `POST` and `HEAD` with `Allow: POST, HEAD`.
- Suppress response bodies on HEAD requests on 200, 500, and 405 paths.
- Add unit assertions testing method gates and HEAD body suppression.

---

## 3. Verification Plan

- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v .` in `d2-signalloom/apps/cpai-engineer`
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./correlation` in `d2-signalloom/apps/signal-ingest`
- `UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with-requirements src/requirements.txt --with pytest --with pytest-asyncio python -m pytest src/tests/test_eap_default_deny.py -q` in `d2-signalloom/apps/fe-signalloom`
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v -run 'TestBaoPlane_TokenRevocationFailureIsNotContained' .` in `d2-signalloom/apps/fleet-manager`
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v -run 'TestTokenLookupsRunConcurrentlyAndBounded|TestATokenLookupFailureStillFailsClosed|TestACancelledEnumerationIsNotReadAsComplete|TestOneBadLookupDoesNotOpenTheBreaker' .` in `d2-signalloom/apps/fleet-manager`
- `make docs-lint` and `bats test/docs-index-sync.bats`
