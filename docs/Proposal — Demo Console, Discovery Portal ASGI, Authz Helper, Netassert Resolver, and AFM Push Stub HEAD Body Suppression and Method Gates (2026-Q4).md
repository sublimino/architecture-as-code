# Proposal — Demo Console, Discovery Portal ASGI, Authz Helper, Netassert Resolver, and AFM Push Stub HEAD Body Suppression and Method Gates (2026-Q4)

## 1. Executive Summary

RFC 9110 Section 6.4.1 dictates that servers MUST NOT return a message body on HTTP `HEAD`.
Headers on `HEAD` must remain identical to those of an equivalent `GET`.

Adversarial discovery identified HTTP protocol gaps across five platform components.
`HEAD` requests leak error message bodies or fail to enforce proper method gates:

1. **`demo-console`** (`tools/demo-console`):
   `newConsoleMux` returns an unwrapped multiplexer.
   Unregistered paths and missing files stream plaintext 404 bodies on `HEAD`.
2. **`fe-signalloom`** (`d2-signalloom/apps/fe-signalloom`):
   The FastAPI application lacks an ASGI response body suppression middleware.
   `HEAD` requests returning 404, 405, or unhandled exceptions stream JSON bodies over the wire.
3. **`authz-httputil`** (`olly-replica/apps/authz/authz`):
   The `Handler` class in `httputil.py` does not override `send_error`.
   Standard library error paths emit HTML error bodies and leak bytes on `HEAD`.
4. **`netassert-resolver-stub`** (`d2-signalloom/netassert-runner`):
   `ApiHandler.send_error` delegates non-501 error codes to `super().send_error`.
   This emits HTML error bodies and leaks payloads on `HEAD`.
5. **`afm-rbac-push-stubs`** (`test/afm-rbac-exporter-push.bats`):
   `KubeHandler` lacks `do_HEAD` handling and `Content-Length` response headers.
   `AFMHandler` omits `Content-Length` headers and lacks 405 method gates with `Allow: POST`.

This proposal hardens all five components with RFC 9110 compliant body suppression and method gates.

---

## 2. Adversarial Discovery & Vulnerability Analysis

### 2.1 Demo Console Unmapped Route Leaks

In `tools/demo-console/main.go`:
`newConsoleMux` configures API routes, health probes, and static UI file serving.
However, `newConsoleMux` returns a bare `*http.ServeMux`.
When a client sends `HEAD /api/nonexistent`, Go returns a 19-byte plaintext 404 body.
Static file requests for missing resources similarly leak 404 bodies on `HEAD`.

### 2.2 Discovery Portal ASGI Body Leaks on Error Paths

In `d2-signalloom/apps/fe-signalloom/src/main.py`:
The FastAPI application registers `IdentityHeaderStripMiddleware` but lacks body suppression.
Starlette automatically strips bodies on matching routes.
However, when a request yields 404 Not Found or 405 Method Not Allowed, Starlette emits a JSON error body.
Uvicorn transmits this body on `HEAD`, violating RFC 9110 Section 6.4.1.

### 2.3 Authz Helper send_error Degradation

In `olly-replica/apps/authz/authz/httputil.py`:
`build_server` provides a lightweight `BaseHTTPRequestHandler` implementation.
While `_dispatch` handles explicit routes and method gates, `send_error` is not overridden.
Protocol-level errors or explicit `send_error` invocations generate Python HTML pages.
These pages leak HTML error bodies on `HEAD` requests.

### 2.4 Netassert Resolver Stub Non-501 Leaks

In `d2-signalloom/netassert-runner/test_resolve_agent_pod.py`:
`ApiHandler.send_error` special-cases status 501 into 405 Method Not Allowed.
For all other status codes, such as 400, 404, or 500, it falls back to `super().send_error`.
This produces HTML bodies and leaks error payloads on `HEAD`.

### 2.5 AFM RBAC Push Test Stubs

In `test/afm-rbac-exporter-push.bats`:
`KubeHandler` defines `do_GET` but omits `do_HEAD`.
Responses omit the standard `Content-Length` header.
`AFMHandler` defines `do_POST` but does not validate HTTP methods or emit `Content-Length`.

---

## 3. Remediation Architecture

### 3.1 Demo Console Middleware

In `tools/demo-console/main.go`:
1. Define `headResponseWriter` and `headBodySuppressingMiddleware`.
2. Wrap `mux` in `headBodySuppressingMiddleware` before returning from `newConsoleMux`.
3. Add `TestConsoleHeadUnmatchedRoutes` in `tools/demo-console/main_test.go`.

### 3.2 Discovery Portal ASGI HeadBodySuppressingMiddleware

In `d2-signalloom/apps/fe-signalloom/src/main.py`:
1. Define `HeadBodySuppressingMiddleware` that intercepts ASGI `http.response.body` messages.
2. Replace message bodies with `b""` when `scope["method"] == "HEAD"`.
3. Install `HeadBodySuppressingMiddleware` on `app`.
4. Add verification tests in `d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py`.

### 3.3 Authz HTTP Helper JSON and HEAD Error Shield

In `olly-replica/apps/authz/authz/httputil.py`:
1. Override `send_error(self, code, message=None, explain=None)` in `Handler`.
2. Format errors as JSON: `{"error": message or self.responses[code][0]}`.
3. Emit `Content-Type: application/json` and `Content-Length`.
4. If `code == 405`, emit `Allow` header if known.
5. Suppress body writes when `self.command == "HEAD"`.
6. Add verification tests in `olly-replica/apps/authz/tests/test_authz.py`.

### 3.4 Netassert Resolver Stub Comprehensive Error Shield

In `d2-signalloom/netassert-runner/test_resolve_agent_pod.py`:
1. Update `ApiHandler.send_error` to handle all error codes with structured JSON and body suppression.
2. Add verification assertions in `ResolverTest`.

### 3.5 AFM RBAC Push Test Stubs Method Parity

In `test/afm-rbac-exporter-push.bats`:
1. Add `do_HEAD` in `KubeHandler` that delegates to `do_GET`.
2. Add `Content-Length` headers on all responses in `KubeHandler` and `AFMHandler`.
3. Override `send_error` in both handlers to enforce method gates (405 with `Allow`) and suppress bodies on `HEAD`.

---

## 4. Verification Plan

1. **Demo Console**:
   Run `go test -v ./...` in `tools/demo-console`.
2. **Discovery Portal**:
   Run `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py`.
3. **Authz Helper**:
   Run `pytest olly-replica/apps/authz/tests/test_authz.py`.
4. **Netassert Resolver Stub**:
   Run `python3 -m unittest d2-signalloom/netassert-runner/test_resolve_agent_pod.py`.
5. **AFM RBAC Push Stubs**:
   Run `bats test/afm-rbac-exporter-push.bats`.
6. **Documentation & Index**:
   Run `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
