# Proposal — Triage Worker, Prompt Summarizer, Cardvault, Proof Helper, and Swarm Governor HEAD Body Suppression and Method Gates (2026-Q4)

## 1. Executive Summary

RFC 9110 Section 6.4.1 mandates that servers MUST NOT return a message body in
response to HTTP `HEAD` requests. The response headers on `HEAD` must remain
identical to those of a corresponding `GET` request, including status code,
`Content-Type`, and caching headers.

Adversarial exploration across five Signal Loom services identified HTTP inconsistencies.
`HEAD` requests leak error message bodies or fail to enforce proper method validation:

1. **`triage-ci-worker`** (`d2-signalloom/apps/triage-ci-worker`):
   `handleCheckRun` issues `http.NotFound(w, r)` and `http.Error(w, "bad request", 400)`,
   both of which stream plaintext error payloads on `HEAD` requests. Additionally,
   `newMux` returns an unwrapped multiplexer that leaks body bytes on unregistered
   routes.
2. **`prompt-commit-summarizer`** (`d2-signalloom/apps/prompt-commit-summarizer`):
   `makeSummarizeHandler` issues `http.Error(w, ...)` on invalid JSON, empty diffs,
   and upstream LLM failures, writing body bytes on `HEAD` requests.
3. **`cardvault`** (`d2-signalloom/apps/cardvault`):
   `newMux` returns an unwrapped multiplexer, leaking default Go `404 page not found\n`
   bodies on `HEAD` requests targeting non-existent or unmapped paths.
4. **`proof-helper`** (`d2-signalloom/proof-helper`):
   `newA2AHandlerWithInstance` calls standard `http.Error` across auth rejection paths.
   These calls leak error message bodies to `HEAD` callers.
5. **`swarm-governor`** (`d2-signalloom/apps/swarm-governor`):
   `newMux` lacks middleware suppression, causing unmapped endpoints and 404 paths
   to leak plaintext body payloads on `HEAD`.

This proposal hardens all five services with standardized `headResponseWriter` wrappers.
Error handlers suppress body writes on `HEAD` while preserving HTTP status codes and headers.

---

## 2. Adversarial Discovery & Vulnerability Analysis

### 2.1 Triage CI Worker (`d2-signalloom/apps/triage-ci-worker`)
In `main.go`, `handleCheckRun` validates incoming CloudEvent webhook notifications:
```go
if r.URL.Path != "/" {
    http.NotFound(w, r)
    return
}
```
When `r.Method == http.MethodHead`, `http.NotFound` executes `http.Error(w, "404 page not found", 404)`,
which writes 19 bytes of plaintext. Similarly, invalid JSON payload decoding writes
`bad request\n` on `HEAD`.

### 2.2 Prompt Commit Summarizer (`d2-signalloom/apps/prompt-commit-summarizer`)
In `main.go`, `makeSummarizeHandler` evaluates diff payloads:
```go
if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
    http.Error(w, "bad request: invalid JSON", http.StatusBadRequest)
    return
}
```
If a client issues a `HEAD` request with malformed or empty payloads, `http.Error`
writes error strings to the wire.

### 2.3 Cardvault (`d2-signalloom/apps/cardvault`)
In `main.go`, `handleGetCard` checks card IDs and returns JSON responses. While
`writeJSON` checks `r.Method == http.MethodHead`, the router `newMux` is registered
directly without a body-suppressing middleware. Any unknown route requested via
`HEAD` returns Go's built-in 404 handler with body `404 page not found\n`.

### 2.4 Proof Helper (`d2-signalloom/proof-helper`)
In `main.go`, `newA2AHandlerWithInstance` handles mutual agent-to-agent authentication:
```go
if jwt == "" {
    http.Error(response, "missing SPIFFE JWT-SVID", http.StatusForbidden)
    return
}
```
Seven distinct authorization failure paths invoke `http.Error(response, ..., StatusForbidden)`.
Each writes plaintext explanation bodies to `HEAD` requests.

### 2.5 Swarm Governor (`d2-signalloom/apps/swarm-governor`)
In `main.go`, `newMux` configures `/tasks/submit`, `/tasks/`, `/health`, `/healthz`,
and `/readyz`. While individual probe handlers check `r.Method == http.MethodHead`,
any unregistered route (or missing task query) falling through to the root handler
leaks body bytes on `HEAD`.

---

## 3. Architecture & Remediation Design

### 3.1 Strict HEAD Body Suppression Middleware
Each Go HTTP service integrates `headResponseWriter` and `headBodySuppressingMiddleware`:

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
    // Per RFC 9110 Section 6.4.1, HEAD responses MUST NOT contain a body.
    return len(b), nil
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.Method == http.MethodHead {
            if _, ok := w.(*headResponseWriter); !ok {
                w = &headResponseWriter{ResponseWriter: w}
            }
        }
        next.ServeHTTP(w, r)
    })
}
```

Wrapping the root HTTP handler ensures that any downstream write is dropped cleanly on `HEAD`.
Status codes and response headers remain intact.

---

## 4. Component Verification & Test Plan

1. **`triage-ci-worker`**:
   - `TestHeadErrorBodySuppression`: Verify `HEAD /` returns 405 with 0 body bytes and `Allow: POST`.
   - Verify `HEAD /unknown-route` returns 404 with 0 body bytes and `text/plain` Content-Type.
   - Verify `HEAD /healthz` returns 200 with 0 body bytes.
2. **`prompt-commit-summarizer`**:
   - `TestHeadErrorBodySuppression`: Verify `HEAD /` returns 405 with 0 body bytes and `Allow: POST`.
   - Verify `HEAD /unknown` returns 404 with 0 body bytes.
   - Verify `HEAD /health` returns 200 with 0 body bytes.
3. **`cardvault`**:
   - `TestHeadErrorBodySuppression`: Verify `HEAD /unknown-route` returns 404 with 0 body bytes.
   - Verify `HEAD /api/v1/cards/nonexistent` returns 404 with 0 body bytes.
   - Verify `HEAD /healthz` and `HEAD /api/v1/cards` return 200 with 0 body bytes.
4. **`proof-helper`**:
   - `TestHeadErrorBodySuppression`: Verify `HEAD /a2a` returns 405 with 0 body bytes and `Allow: POST`.
   - Verify `HEAD /unknown-route` returns 404 with 0 body bytes.
   - Verify `HEAD /challenge` and `HEAD /health` return 200 with 0 body bytes.
5. **`swarm-governor`**:
   - `TestHeadErrorBodySuppression`: Verify `HEAD /unknown-route` returns 404 with 0 body bytes.
   - Verify `HEAD /tasks/submit` returns 405 with 0 body bytes and `Allow: POST`.
   - Verify `HEAD /healthz` and `HEAD /readyz` return 200 with 0 body bytes.

---

## 5. Delivery Matrix & Verification Plan

| Component | Target File | Change | Test Command |
|---|---|---|---|
| `triage-ci-worker` | `main.go` | Wrap `newMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `prompt-commit-summarizer` | `main.go` | Wrap `newRouter` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `cardvault` | `main.go` | Wrap `newMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `proof-helper` | `main.go` | Wrap `newA2AHandlerWithInstance` in middleware | `go test ./... -v` |
| `swarm-governor` | `main.go` | Wrap `newMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
