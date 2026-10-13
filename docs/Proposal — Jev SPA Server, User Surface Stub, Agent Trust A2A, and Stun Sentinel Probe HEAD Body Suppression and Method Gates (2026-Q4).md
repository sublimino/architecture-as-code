# Proposal — Jev SPA Server, User Surface Stub, Agent Trust A2A, and Stun Sentinel Probe HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `scripts/jev-test-bot`, `test/fixtures/user-surface-gate`, `d2-agent-trust/a2a`, `d2-signalloom/apps/stun-sentinel`, `d2-signalloom/apps/signalloom-stun-sentinel`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP services, test harnesses, and daemon probe preservers must strictly adhere to RFC 9110 Section 6.4.1.
A server must never send a message body in response to a HEAD request.
Endpoints must return status 405 with an `Allow` header when an unsupported HTTP method is received.
Error responses must maintain uniform format (`application/json` where JSON is standard) and set matching `Content-Length` headers across all status codes.

Adversarial exploration identified five components with response body leaks or missing method error gates:

1. **Jev Test Bot SPA Server (`scripts/jev-test-bot/spa-server.py`)**:
   In `spa-server.py`, `_send_405` wrote 405 body bytes unconditionally to `self.wfile` without verifying `if self.command != "HEAD"`.
   In addition, `SpaHandler` lacked a `send_error` override, emitting unshielded HTML bodies on HEAD for errors and unhandled verbs.

2. **User Surface Gate Stand-in Stub (`test/fixtures/user-surface-gate/stub-surface-server.py`)**:
   In `stub-surface-server.py`, `Handler` lacked a `send_error` override.
   Unsupported verbs (such as TRACE) or protocol errors triggered `BaseHTTPRequestHandler.send_error`.
   This emitted HTML bodies and leaked them on HEAD requests without route-specific `Allow` headers.

3. **Agent Trust A2A Service (`d2-agent-trust/a2a/service.py`)**:
   In `service.py`, `H` lacked a `send_error` override.
   When unhandled HTTP verbs or request parse errors occurred, default HTML bodies were emitted, leaking on HEAD requests.

4. **Stun Sentinel Probe Preserver (`d2-signalloom/apps/stun-sentinel/pkg/probe/probe.go`)**:
   In `probe.go`, `SyntheticProbeHandler` lacked HTTP method gating, returning status 200 OK to POST, PUT, DELETE, and other verbs.
   It also lacked HEAD body suppression, writing full JSON bodies unconditionally on HEAD requests.

5. **Signal Loom Stun Sentinel Probe Preserver (`d2-signalloom/apps/signalloom-stun-sentinel/probe.go`)**:
   In `probe.go`, `syntheticProbeHandler` returned plaintext error bodies on 405 Method Not Allowed without Content-Length headers.
   It also lacked `headBodySuppressingMiddleware` protection.

---

## 2. Proposed Architecture & Remediation

### 2.1 Jev Test Bot SPA Server Hardening

In `scripts/jev-test-bot/spa-server.py`:
- In `_send_405`, guard body writes with `if self.command != "HEAD":`.
- Add `send_error` override mapping 501 to 405 with `Allow: GET, HEAD`.
- Format non-405 errors as JSON with `Content-Type: application/json; charset=utf-8` and `Content-Length`.
- Suppress response bodies on HEAD requests across all error codes.

### 2.2 User Surface Gate Stub Hardening

In `test/fixtures/user-surface-gate/stub-surface-server.py`:
- Add `send_error` override to `Handler`.
- Map status 501 to 405 Method Not Allowed with route-specific `Allow` headers (`GET, HEAD` on health/status/steps, `POST` on dex/token and runs).
- Format errors via `self._err` with `Content-Type: application/json` and `Content-Length`.
- Suppress body writes on HEAD requests per RFC 9110 Section 6.4.1.

### 2.3 Agent Trust A2A Service Hardening

In `d2-agent-trust/a2a/service.py`:
- Add `send_error` override to `H`.
- Map status 501 to 405 Method Not Allowed with route-specific `Allow` headers (`GET, HEAD` for metadata and health endpoints, `POST` for `/a2a`, and `GET, HEAD, POST` as default).
- Emit JSON errors via `self._send_json` with `Content-Type: application/json` and `Content-Length`.
- Enforce zero body bytes on HEAD requests.

### 2.4 Stun Sentinel Probe Preserver Hardening

In `d2-signalloom/apps/stun-sentinel/pkg/probe/probe.go`:
- Implement `headResponseWriter` and `headBodySuppressingMiddleware`.
- In `SyntheticProbeHandler`, restrict accepted methods to `GET` and `HEAD`.
- Reject other methods with status 405 Method Not Allowed, `Allow: GET, HEAD`, and JSON error format.
- Suppress response bodies on HEAD requests and wrap the handler in `headBodySuppressingMiddleware`.

### 2.5 Signal Loom Stun Sentinel Probe Preserver Hardening

In `d2-signalloom/apps/signalloom-stun-sentinel/probe.go`:
- In `syntheticProbeHandler`, format status 405 errors as JSON with `Content-Type: application/json` and `Allow: GET, HEAD`.
- Suppress response bodies on HEAD requests.
- Wrap `syntheticProbeHandler` in `headBodySuppressingMiddleware`.

---

## 3. Verification Plan

- Run `jev-test-bot` contract test suite: `python3 -m unittest scripts/jev-test-bot/test_spa_server.py` and `pytest scripts/jev-test-bot/test_spa_server.py` (5 tests).
- Run all `jev-test-bot` tests: `pytest scripts/jev-test-bot/test_*.py` (71 tests).
- Run `user-surface-gate` unit test suite: `python3 test/fixtures/user-surface-gate/test_stub_surface_server.py` (4 tests).
- Run `user-surface-gate` BATS test suite: `bats test/user-surface-gate.bats` (23 tests).
- Run `agent-trust` test suite: `pytest d2-agent-trust/test/test_contracts.py` (8 tests).
- Run documentation link and index verification: `bats test/docs-index-sync.bats`.
- Run documentation lint check: `./scripts/docs-lint.sh`.
