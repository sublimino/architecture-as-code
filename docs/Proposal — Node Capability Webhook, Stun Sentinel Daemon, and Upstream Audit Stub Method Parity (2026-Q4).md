# Proposal — Node Capability Webhook, Stun Sentinel Daemon, and Upstream Audit Stub Method Parity (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/node-capability-guard`, `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`, `d2-signalloom/apps/fe-signalloom/src/tests`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP endpoints must strictly adhere to RFC 9110 Section 6.4.1.
A server must not send a message body in response to a HEAD request.
Endpoints must also return status 405 with an Allow header when an unsupported HTTP method is received.
Responses must set a matching `Content-Length` header on all status codes.

Adversarial exploration identified three components with response body leaks or missing method headers:

1. **Node Capability Guard Webhook Server (`d2-signalloom/apps/node-capability-guard`)**:
   In `handler.go`, `NewMux` creates an unshielded `http.ServeMux`.
   When HEAD requests arrive for unknown routes, the multiplexer returns a plain text 404 body.
   In addition, `WebhookServer.ServeHTTP` directly dispatches without HEAD response body suppression.

2. **Stun Sentinel Host Daemon Server (`d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`)**:
   In `main.go`, `routes()` returns an unshielded `http.ServeMux`.
   When HEAD requests target unmapped paths, the multiplexer leaks plain text 404 bodies.
   Timeout handlers also leak response bodies on HEAD requests when deadlines expire.

3. **Front-End Test Stubs (`d2-signalloom/apps/fe-signalloom/src/tests`)**:
   In `test_audit_anchor_envelope.py`, `_StubArchivista` emits status 405 without `Content-Length`.
   In `test_eap_default_deny.py`, `_RecordingUpstream.send_error` omits `Content-Length` on status 405.
   It also writes body bytes unconditionally on HEAD requests.

---

## 2. Proposed Architecture & Remediation

### 2.1 Node Capability Guard Webhook Hardening

Introduce an RFC 9110-compliant `headResponseWriter` and `headBodySuppressingMiddleware` in `handler.go`:

```go
type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	return len(b), nil
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

Update `NewMux` to return `http.Handler` wrapped with `headBodySuppressingMiddleware(mux)`.
Wrap direct invocations in `WebhookServer.ServeHTTP` with `headResponseWriter` when `r.Method == http.MethodHead`.

### 2.2 Stun Sentinel Host Daemon Hardening

Introduce `headResponseWriter` and `headBodySuppressingMiddleware` in `main.go`.
Update `(s *server) routes() http.Handler` to wrap the ServeMux in `headBodySuppressingMiddleware`.

### 2.3 Front-End Test Stubs Hardening

In `test_audit_anchor_envelope.py`:
- Add `Content-Length: 18` on status 405 in `_StubArchivista`.

In `test_eap_default_deny.py`:
- Add `Content-Length: 18` on status 405 in `_RecordingUpstream.send_error`.
- Guard `self.wfile.write(body)` against `self.command == "HEAD"`.

---

## 3. Verification Plan

1. **Node Capability Guard Tests**:
   Run unit tests in `d2-signalloom/apps/node-capability-guard`.
   Verify `/validate` returns 405 with empty body and `Allow: POST` on HEAD.
   Verify unknown routes return 404 with empty body on HEAD.

2. **Stun Sentinel Host Daemon Tests**:
   Run unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`.
   Verify unknown routes return 404 with empty body on HEAD.

3. **Front-End Test Suites**:
   Run pytest on `test_audit_anchor_envelope.py` and `test_eap_default_deny.py`.
   Verify 405 status headers and HEAD body suppression.
