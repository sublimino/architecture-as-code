# Proposal — Netassert Controller, Sentinel ELK Stub, Teardown Stubs, Jev Bot Stubs, and Integration Proxy Error Fidelity and HEAD Body Suppression (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/netassert-controller`, `olly-replica/apps/sentinel/tests`, `d2-signalloom/apps/fe-signalloom/src/tests`, `scripts/jev-test-bot`, `d2-signalloom/apps/fake-integration-proxy`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP services, test harnesses, and integration proxies must strictly adhere to RFC 9110 Section 6.4.1.
A server must never send a message body in response to a HEAD request.
Endpoints must also return status 405 with an `Allow` header when an unsupported HTTP method is received.
Error responses must maintain uniform format (`application/json` where JSON is standard) and set matching `Content-Length` headers across all status codes.

Adversarial exploration identified five components with response body leaks or missing method error gates:

1. **Netassert Controller Server (`d2-signalloom/apps/netassert-controller/server.py`)**:
   In `server.py`, `ControllerHandler` lacked a `send_error` override.
   When unsupported HTTP verbs or parsing errors occurred, it fell back to default `BaseHTTPRequestHandler.send_error`, emitting HTML error bodies and leaking them on HEAD requests.

2. **Sentinel ELK Test Stub (`olly-replica/apps/sentinel/tests/elk_stub.py`)**:
   In `elk_stub.py`, `_Handler` delegated 404, 400, and unsupported method errors to `BaseHTTPRequestHandler.send_error`.
   This produced plain text/HTML error responses without `application/json` Content-Type and leaked body bytes on HEAD requests.

3. **Front-End Teardown Test Stubs (`d2-signalloom/apps/fe-signalloom/src/tests`)**:
   In `test_environment_teardown.py` and `test_environment_teardown_review_regressions.py`, `_Handler.send_error`, `SlowDrip.send_error`, and `Redirect.send_error` wrote 405 error bodies unconditionally to `self.wfile` without checking `if self.command != "HEAD"`.
   In addition, non-501 error codes delegated to unshielded `super().send_error`, emitting unsuppressed HTML bodies on HEAD.

4. **Jev Exploratory Test Bot Stubs (`scripts/jev-test-bot`)**:
   In `test_bot_coverage.py`, `_Shell.send_error` wrote 405 error bodies unconditionally on HEAD and delegated non-501 codes to unshielded `super().send_error`.
   In `test_chaos_fuzzing.py`, `_MockApiServer` lacked a `send_error` override, leaking default bodies on error paths.

5. **Fake Integration Proxy (`d2-signalloom/apps/fake-integration-proxy/server.py`)**:
   In `server.py`, `ProxyHandler` lacked a `send_error` override.
   When unsupported HTTP verbs or syntax errors occurred, `send_error` fell back to default HTML responses and leaked bodies on HEAD requests.

---

## 2. Proposed Architecture & Remediation

### 2.1 Netassert Controller Hardening

In `server.py`, override `send_error` in `ControllerHandler`:
- Status 501 is mapped to 405 Method Not Allowed with `Allow: GET, HEAD, POST`.
- Formats errors as JSON (`Content-Type: application/json`).
- Sets `Content-Length` and suppresses body if `self.command == "HEAD"`.

### 2.2 Sentinel ELK Test Stub Hardening

In `elk_stub.py`, override `send_error` in `_Handler`:
- Status 501 maps to 405 Method Not Allowed with route-specific `Allow` headers (`GET, HEAD` for health routes, `POST` for `/mcp` and tools, and `GET, HEAD, POST` for root).
- Formats errors as JSON via `self._send({"error": msg}, status=code)`.
- Enforces zero body bytes on HEAD requests and preserves `Content-Length`.

### 2.3 Teardown Test Stubs Hardening

In `test_environment_teardown.py` and `test_environment_teardown_review_regressions.py`:
- In `_Handler.send_error`, `SlowDrip.send_error`, and `Redirect.send_error`, guard body writes with `if self.command != "HEAD":`.
- Handle non-501 codes directly with `Content-Type: text/plain; charset=utf-8`, `Content-Length`, and HEAD body suppression instead of unshielded `super().send_error`.

### 2.4 Jev Bot Stubs Hardening

In `scripts/jev-test-bot/test_bot_coverage.py` and `test_chaos_fuzzing.py`:
- In `_Shell.send_error`, guard body writes with `if self.command != "HEAD":` and handle non-501 codes with `Content-Length` and HEAD body suppression.
- In `_MockApiServer`, add `send_error` override mapping 501 to 405 with `Allow` header, formatting errors as JSON, setting `Content-Length`, and suppressing body on HEAD.

### 2.5 Fake Integration Proxy Hardening

In `d2-signalloom/apps/fake-integration-proxy/server.py`:
- In `ProxyHandler`, override `send_error` to emit JSON `{"error": ...}` with `Content-Type: application/json`, `Content-Length`, `Allow` headers on 501/405, and suppress body on HEAD.

---

## 3. Verification Plan

- Run `netassert-controller` unittest suite: `python3 -m unittest discover -s test` (23 tests).
- Run `sentinel` contract tests: `python3 -m unittest olly-replica/apps/sentinel/tests/test_elk_stub_contracts.py` (7 tests).
- Run `fe-signalloom` teardown tests: `pytest src/tests/test_environment_teardown.py src/tests/test_environment_teardown_review_regressions.py` (66 tests).
- Run `jev-test-bot` tests: `pytest scripts/jev-test-bot/test_bot_coverage.py scripts/jev-test-bot/test_chaos_fuzzing.py` (21 tests).
- Run `fake-integration-proxy` tests: `env PYTHONPATH=. pytest test/test_proxy.py` (71 tests).
- Run `bats test/docs-index-sync.bats`.
- Run `./scripts/docs-lint.sh`.
