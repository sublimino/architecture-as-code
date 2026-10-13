# Proposal — Workspace, Ingest, Appraiser, and Kusari Agent HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Short Code:** `MICROSERVICEHEADROUND29`  
**Author:** Antigravity Autonomous Security Engineer  
**Date:** 2026-10-13  
**Scope:** `d2-signalloom/apps/cpai-engineer`, `d2-signalloom/apps/factory-appraiser`, `d2-signalloom/apps/kusari-agent`, `d2-signalloom/apps/workspace-connector`, `d2-signalloom/apps/signal-ingest`

---

## 1. Executive Summary

Autonomous adversarial auditing revealed that several Go microservices violate RFC 9110 Section 6.4.1 on HTTP `HEAD` requests. When handling `HEAD` requests producing error statuses, these services transmit JSON or plaintext response bodies rather than suppressing them.

RFC 9110 Section 6.4.1 explicitly dictates:
> "The server MUST NOT send a message body in the response for a HEAD request."

This proposal specifies and executes systematic hardening across five affected services:
1. **`cpai-engineer`**: Suppress JSON error bodies on `HEAD` requests (`/tasks/{id}` 404, `/tasks` 400/500), and wrap the server with `headBodySuppressingMiddleware`.
2. **`factory-appraiser`**: Suppress JSON error bodies on `HEAD` requests (`/api/v1/factory/appraise` 400/422, `/api/v1/factory/validate-promotion` 400/403), and wrap the multiplexer with `headBodySuppressingMiddleware`.
3. **`kusari-agent`**: Suppress `actResult` JSON response bodies on `HEAD` requests encountering `405 Method Not Allowed` on `/act/*` routes, and ensure `writeJSON` suppresses body bytes on `HEAD`.
4. **`workspace-connector`**: Suppress JSON error bodies on `HEAD` requests (`/api/v1/workspace/poll` 500, `/api/v1/workspace/stun` 400/500), and wrap the multiplexer with `headBodySuppressingMiddleware`.
5. **`signal-ingest`**: Update `writeJSON` and `writeError` in `api/handlers.go` and `NewProbeHandler` to strictly suppress response bodies when `r.Method == http.MethodHead`.

---

## 2. Vulnerability Surface & Discovery Findings

| Service | Target File | Vulnerability & Impact | Status |
| :--- | :--- | :--- | :--- |
| `cpai-engineer` | `main.go` | `writeError` encodes `ErrorResponse` on `HEAD` requests (e.g. `HEAD /tasks/unknown` returns 404 with JSON body). | Hardened |
| `factory-appraiser` | `main.go` | `appraiseHandler` and `validate-promotion` encode JSON bodies on `HEAD` requests for 400, 403, and 422 errors. | Hardened |
| `kusari-agent` | `main.go` | `writeJSON` in `postOnly` encodes `actResult` JSON on `HEAD /act/*` requests returning 405 Method Not Allowed. | Hardened |
| `workspace-connector` | `main.go` | `handlePoll` and `handleStun` encode JSON error responses on `HEAD` requests returning 400 or 500 errors. | Hardened |
| `signal-ingest` | `api/handlers.go` | `writeJSON` and `writeError` encode JSON bodies unconditionally on `HEAD` requests unless individual endpoints manually guard against it. | Hardened |

---

## 3. Architecture & Implementation Plan

### 3.1 Response Body Suppression Middleware (`headResponseWriter`)

Where multiplexers dispatch multiple routes, a wrapping `http.Handler` middleware wraps the `http.ResponseWriter` with a `headResponseWriter` whenever `r.Method == http.MethodHead`:

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

### 3.2 Direct Handler `writeJSON` and `writeError` Guards

In `signal-ingest`, `writeJSON` suppresses body serialization on `HEAD` requests. Similarly, `cpai-engineer` and `kusari-agent` ensure `writeError` and `writeJSON` suppress body bytes.

---

## 4. Verification Record

- **`cpai-engineer`**: Tested with `go test ./... -v` verifying `HEAD /tasks/nonexistent-id` returns 404 with 0 body bytes and valid JSON headers.
- **`factory-appraiser`**: Tested with `go test ./... -v` verifying `HEAD /api/v1/factory/appraise` returns 405 with 0 body bytes and valid headers.
- **`kusari-agent`**: Tested with `go test ./... -v` verifying `HEAD /act/*` returns 405 with `Allow: POST` and 0 body bytes.
- **`workspace-connector`**: Tested with `go test ./... -v` verifying `HEAD /api/v1/workspace/poll` and `/stun` return 0 body bytes on error and method gates.
- **`signal-ingest`**: Tested with `go test ./api -v` verifying probe handler and API route HEAD error response body suppression.
- **Documentation Linting**: Verified with `./scripts/docs-lint.sh` (0 findings) and `bats test/docs-index-sync.bats` (7/7 passing).
