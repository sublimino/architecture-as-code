# Proposal — Host Traffic Control, Integration Proxy Test Routes, and Resolver Test Stub Method Parity (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`, `d2-signalloom/apps/fake-integration-proxy`, `d2-signalloom/netassert-runner`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP endpoints must strictly adhere to RFC 9110 Section 6.4.1.
A server must not send a message body in response to a HEAD request.
Endpoints must also return status 405 with an Allow header when an unsupported HTTP method is received.

Adversarial exploration identified three components with response body leaks or missing method gates:

1. **Host Traffic Control CLI Server (`d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`)**:
   In `main.go`, `triggerHandler` handles isolation and release triggers.
   When requests arrive with invalid HTTP methods or missing parameters, it emits plain text error bodies.
   On HEAD requests returning 405 Method Not Allowed or 400 Bad Request, these bodies leak over the wire.
   Furthermore, the multiplexer lacks a blanket HEAD body suppression layer for mounted endpoints.

2. **Fake Integration Proxy Control API (`d2-signalloom/apps/fake-integration-proxy`)**:
   In `server.py`, `_handle_control` processes requests under `/_test/`.
   Endpoints `/_test/requests` and `/_test/fixtures` only accept GET.
   They reject HEAD with 404 Not Found instead of 200 OK.
   Unsupported methods return 404 Not Found rather than 405 Method Not Allowed with RFC 9110 Allow headers.
   On `/_test/fixtures/{category}/{name}`, non-PUT methods return 404 rather than 405 with `Allow: PUT`.

3. **NetAssert Pod Resolver Test Stub (`d2-signalloom/netassert-runner`)**:
   In `test_resolve_agent_pod.py`, `ApiHandler.send_error` catches code 501 and converts it to 405.
   However, it does not set the `Content-Length` header.
   It also writes body bytes unconditionally even when `self.command == "HEAD"`.

---

## 2. Proposed Architecture & Remediation

### 2.1 Host Traffic Control CLI Server Hardening

Introduce an RFC 9110-compliant `headResponseWriter` and `headBodySuppressingMiddleware` in `stun-tcctl`:

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

Wrap the ServeMux in `main.go` with `headBodySuppressingMiddleware(mux)`.
In `triggerHandler`, guard error and response body writes against `r.Method == http.MethodHead`.

### 2.2 Fake Integration Proxy Control Routes

Update `_handle_control` in `server.py`:
- Support GET and HEAD for `/_test/requests` and `/_test/fixtures`.
- On `/_test/requests`, return 405 Method Not Allowed with `Allow: GET, HEAD, DELETE` for other verbs.
- On `/_test/fixtures`, return 405 Method Not Allowed with `Allow: GET, HEAD` for other verbs.
- On valid `/_test/fixtures/{category}/{name}` paths, return 405 with `Allow: PUT` for non-PUT verbs.
- Ensure all 405 and HEAD responses suppress response bodies while preserving headers.

### 2.3 NetAssert Runner Resolver Test Stub

In `test_resolve_agent_pod.py`, update `ApiHandler.send_error`:
- Add `Content-Length: 18` and `Content-Type: text/plain; charset=utf-8` on 405 Method Not Allowed.
- Guard `self.wfile.write(body)` against `self.command == "HEAD"`.

---

## 3. Verification Plan

1. **Host Traffic Control CLI Tests**:
   Run unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`.
   Verify HEAD on `/v1/isolate` and `/v1/release` returns 405 with `Allow: POST` and empty body.

2. **Fake Integration Proxy Tests**:
   Run pytest suite in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`.
   Verify HEAD on `/_test/requests` and `/_test/fixtures` returns 200 with empty body.
   Verify unsupported verbs return 405 with correct Allow headers.

3. **NetAssert Runner Tests**:
   Run unit tests in `d2-signalloom/netassert-runner/test_resolve_agent_pod.py`.
   Verify 405 Method Not Allowed response headers and HEAD body suppression.
