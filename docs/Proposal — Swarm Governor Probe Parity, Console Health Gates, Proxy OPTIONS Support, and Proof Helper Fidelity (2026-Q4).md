# Proposal: Swarm Governor Probe Parity, Console Health Gates, Proxy OPTIONS Support, and Proof Helper Fidelity (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Engine
**Date:** 2026-10-13
**Document ID:** SWARMCONSOLEPROXY
**Component:** `d2-signalloom/apps/swarm-governor`, `tools/demo-console`, `d2-signalloom/apps/fake-integration-proxy`, `d2-signalloom/proof-helper`

---

## 1. Problem Statement

HTTP services must adhere to uniform semantics across all standard verbs.
RFC 9110 requires strict consistency between `GET` and `HEAD` requests.
A `HEAD` request must return identical headers to a `GET` request.
However, a `HEAD` request must never emit a response body.

Four distinct platform components exhibit behavioral discrepancies:

1. **Swarm Governor Probes (`d2-signalloom/apps/swarm-governor`):**
   The `/healthz` and `/readyz` handlers omit the `Content-Type: application/json` header on `HEAD` requests.
   In addition, `writeJSON` unconditionally writes bytes to the response writer.
   This leaks error bodies on `HEAD` requests when returning 400, 404, or 405 status codes.

2. **Demo Console Health (`tools/demo-console`):**
   The `healthHandler` ignores the request method completely.
   It accepts `POST`, `PUT`, `DELETE`, and `PATCH` requests without returning 405 Method Not Allowed.
   It also writes a JSON body on `HEAD` requests.

3. **Fake Integration Proxy (`d2-signalloom/apps/fake-integration-proxy`):**
   The `ProxyHandler` class does not define `do_OPTIONS`.
   Incoming `OPTIONS` requests return 501 Unsupported Method instead of 405 Method Not Allowed with an `Allow` header.

4. **Proof Helper A2A Server (`d2-signalloom/proof-helper`):**
   The `/health`, `/challenge`, and `/a2a` endpoints call `http.Error` on method mismatch.
   `http.Error` writes a plaintext message body on `HEAD` requests.
   This violates RFC 9110 response body suppression.

---

## 2. Proposed Architecture and Changes

### 2.1 Swarm Governor Media-Type and Body Suppression Parity

In `d2-signalloom/apps/swarm-governor/main.go`:
- Update `handleHealthz` and `handleReadyz` to emit `Content-Type: application/json` on `HEAD` requests.
- Update `writeJSON` to accept the `http.Request` pointer.
- Suppress body emission when the request method is `HEAD`.
- Add comprehensive HTTP contract tests in `d2-signalloom/apps/swarm-governor/main_test.go`.

### 2.2 Demo Console Health Method Gates

In `tools/demo-console/main.go`:
- Restrict `healthHandler` to `GET` and `HEAD` methods.
- Return 405 Method Not Allowed with `Allow: GET, HEAD` on non-GET/HEAD verbs.
- Suppress JSON body serialization when handling `HEAD` requests.
- Add unit tests in `tools/demo-console/health_test.go`.

### 2.3 Fake Integration Proxy OPTIONS Dispatch

In `d2-signalloom/apps/fake-integration-proxy/server.py`:
- Add `do_OPTIONS = _dispatch` to `ProxyHandler`.
- Ensure `OPTIONS` requests return 405 Method Not Allowed with RFC 9110 `Allow` headers.
- Add tests in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`.

### 2.4 Proof Helper HEAD Response Body Suppression

In `d2-signalloom/proof-helper/main.go`:
- Replace direct calls to `http.Error` with a helper that suppresses the message body on `HEAD` requests.
- Ensure 405 responses include RFC 9110 `Allow` headers.
- Add unit tests in `d2-signalloom/proof-helper/main_test.go`.

---

## 3. Verification Plan

1. **Swarm Governor:** Run `go test ./...` in `d2-signalloom/apps/swarm-governor`.
2. **Demo Console:** Run `go test ./...` in `tools/demo-console`.
3. **Fake Integration Proxy:** Run `pytest d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`.
4. **Proof Helper:** Run `go test ./...` in `d2-signalloom/proof-helper`.
5. **Documentation Lint:** Run `./scripts/docs-lint.sh`.
