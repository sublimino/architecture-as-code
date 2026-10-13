# Proposal — Daytona Coder, Policy Engine, Telemetry Handler, Harness Dash, and Stun Sentinel HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/hosted-daytona-coder`, `d2-signalloom/apps/policy-engine`, `d2-signalloom/apps/fe-signalloom/pkg/telemetry`, `tools/harness-dash`, `d2-signalloom/apps/signalloom-stun-sentinel`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP endpoints must strictly adhere to RFC 9110 Section 6.4.1.
A server must not send a message body in response to a HEAD request.

Adversarial exploration identified five components with response body leaks or missing method checks:

1. **Hosted Daytona Coder (`d2-signalloom/apps/hosted-daytona-coder`)**:
   `workspace-manager.go` exposes `HEAD /workspaces/{id}`.
   When a workspace is absent, `writeError` returns a JSON body.
   Requests with invalid tenants also leak JSON error payloads.

2. **Policy Engine (`d2-signalloom/apps/policy-engine`)**:
   `handlers.go` uses `writeJSON` and `writeError` to return error responses.
   In `auth.go`, `RequireAPIKey` rejects unauthorized requests with JSON error bodies.
   In `main.go`, `handleEvaluate` issues a JSON body on 405.
   All error paths leak message bodies on HEAD requests.

3. **Front-End Telemetry Handler (`d2-signalloom/apps/fe-signalloom/pkg/telemetry`)**:
   In `handler.go`, `writeError` writes error bodies unconditionally on HEAD.
   This affects 405 Method Not Allowed and 503 Telemetry Unavailable.
   It also affects 404 Telemetry Not Found and 409 Conflict.
   Furthermore, `handleSSE` does not terminate early on HEAD requests.

4. **Harness Dashboard Web Server (`tools/harness-dash/src/dashboard/web-server.ts`)**:
   In `web-server.ts`, `/api/metrics`, `/api/app-metrics`, and `/api/sessions` lack method checks.
   Arbitrary verbs answer with 200 OK.
   On HEAD requests, full response bodies are returned.
   Non-GET verbs on `/api/sessions/:id/transcript` fall through to HTML rendering.

5. **Signal Loom Stun Sentinel Health Server (`d2-signalloom/apps/signalloom-stun-sentinel`)**:
   In `health.go`, `serveCaptures` and `serveMetrics` call `http.Error` or `http.NotFound`.
   These write plain-text bodies on HEAD requests during 404, 405, or 500 responses.

---

## 2. Proposed Architecture & Remediation

### 2.1 RFC 9110 Suppressing Response Writer & Middleware

Introduce an RFC 9110-compliant `headResponseWriter` and `headBodySuppressingMiddleware` in services:

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
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
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

### 2.2 Hosted Daytona Coder Hardening
- Wrap the workspace router returned by `NewServer` with `headBodySuppressingMiddleware`.
- In `writeError`, ensure `headResponseWriter` discards body writes.

### 2.3 Policy Engine Hardening
- Wrap the main HTTP multiplexer in `main.go` with `headBodySuppressingMiddleware(mux)`.
- In `handlers.go`, update `writeJSON` and `writeError` to check for `headResponseWriter`.
- Add test coverage in `handlers_test.go` and `main_test.go` for HEAD error body suppression.

### 2.4 Front-End Telemetry Handler Hardening
- In `handler.go`, update `writeError` to suppress body when `r.Method == http.MethodHead`.
- In `handleSSE`, return early with 200 OK and 0 body bytes if `r.Method == http.MethodHead`.
- Add unit tests verifying 405, 503, 404, and 200 responses under HEAD.

### 2.5 Harness Dashboard Hardening
- In `tools/harness-dash/src/dashboard/web-server.ts`, enforce HTTP method validation.
- Only allow GET and HEAD on `/api/metrics`, `/api/app-metrics`, and `/api/sessions`.
- Return 405 with `Allow: GET, HEAD` on non-GET/HEAD verbs.
- On HEAD requests, return an empty body (`new Response(null, ...)`).
- Enforce method checks for transcript and summarize routes.

### 2.6 Stun Sentinel Health Server Hardening
- Wrap `h.Handler()` in `d2-signalloom/apps/signalloom-stun-sentinel/health.go` with `headBodySuppressingMiddleware`.
- Update `serveCaptures` and `serveMetrics` to suppress error messages when `r.Method == http.MethodHead`.
- Add test assertions in `health_test.go`.

---

## 3. Scope of Affected Files

| Component | File Path | Scope of Changes |
| :--- | :--- | :--- |
| `hosted-daytona-coder` | `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go` | Wrap mux in middleware, suppress HEAD error body |
| `hosted-daytona-coder` | `d2-signalloom/apps/hosted-daytona-coder/workspace_manager_test.go` | Unit tests for 404, 403, and 405 HEAD body suppression |
| `policy-engine` | `d2-signalloom/apps/policy-engine/handlers.go` | `writeJSON` & `writeError` HEAD body suppression |
| `policy-engine` | `d2-signalloom/apps/policy-engine/main.go` | Wrap mux with middleware |
| `policy-engine` | `d2-signalloom/apps/policy-engine/main_test.go` | Verify HEAD on `/api/v1/evaluate` 405 returns 0 body bytes |
| `fe-signalloom` | `d2-signalloom/apps/fe-signalloom/pkg/telemetry/handler.go` | `writeError` & `handleSSE` HEAD body suppression |
| `harness-dash` | `tools/harness-dash/src/dashboard/web-server.ts` | Method gates, Allow headers, and HEAD body suppression |
| `harness-dash` | `tools/harness-dash/test/harness-dash.test.ts` | Unit tests for HTTP method gates and HEAD body suppression |
| `signalloom-stun-sentinel` | `d2-signalloom/apps/signalloom-stun-sentinel/health.go` | Wrap mux with middleware, suppress error bodies on HEAD |
| `signalloom-stun-sentinel` | `d2-signalloom/apps/signalloom-stun-sentinel/health_test.go` | Verify HEAD on `/captures` and `/metrics` error paths |

---

## 4. Verification Plan

1. **Hosted Daytona Coder**: Run `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test ./... -v`.
2. **Policy Engine**: Run `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test ./... -v -run 'TestHealth|TestEvaluate|TestAuth'`.
3. **FE Telemetry Handler**: Run `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test ./pkg/telemetry/... -v`.
4. **Harness Dashboard**: Run `bun test` in `tools/harness-dash`.
5. **Signalloom Stun Sentinel**: Run `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test ./... -v -run 'TestHealth'`.
6. **Documentation Compliance**: Run `./scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
