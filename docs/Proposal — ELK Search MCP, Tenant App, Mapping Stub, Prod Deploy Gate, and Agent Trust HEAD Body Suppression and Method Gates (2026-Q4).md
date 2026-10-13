# Proposal — ELK Search MCP, Tenant App, Mapping Stub, Prod Deploy Gate, and Agent Trust HEAD Body Suppression and Method Gates (2026-Q4)

## 1. Executive Summary

RFC 9110 Section 6.4.1 dictates that servers MUST NOT return a message body on HTTP `HEAD`.
Headers on `HEAD` must remain identical to those of an equivalent `GET`.

Adversarial exploration identified HTTP protocol gaps across five platform components.
`HEAD` requests leak error message bodies or fail to enforce proper method gates:

1. **`elk-search-mcp`** (`olly-replica/apps/cmd/elk-search-mcp`):
   `newMux` returns an unwrapped multiplexer.
   Unmapped routes return Go default 404 bodies on `HEAD`.
   `s.search` calls `http.Error` for bad requests and upstream errors, leaking body bytes.
2. **`tenant-app`** (`olly-replica/apps/cmd/tenant-app`):
   `newTenantMux` returns an unwrapped multiplexer.
   Unregistered paths stream plaintext 404 bodies on `HEAD`.
   The `/fault` route lacks explicit `HEAD` handling.
3. **`mapping-stub`** (`olly-replica/apps/cmd/mapping-stub`):
   `newMux` returns an unwrapped multiplexer.
   Unmapped routes return Go default 404 bodies on `HEAD`.
4. **`prod-deploy-gate`** (`d2-signalloom/apps/prod-deploy-gate`):
   The root server multiplexer lacks `headBodySuppressingMiddleware`.
   Unmapped paths stream plaintext 404 bodies on `HEAD`.
5. **`agent-trust-a2a`** (`d2-agent-trust/a2a`):
   `H` invokes `send_error(404)` on unregistered routes and unsupported methods.
   This sends non-standard HTML error bodies instead of structured JSON responses.

This proposal hardens all five services with standardized `headResponseWriter` wrappers.
Error handlers suppress body writes on `HEAD` while preserving HTTP status codes and headers.

---

## 2. Adversarial Discovery & Vulnerability Analysis

### 2.1 ELK Search MCP Body Leaks

In `olly-replica/apps/cmd/elk-search-mcp/main.go`:
`newMux` registers `/tools/elk_search_logs`, `/mcp`, and probe endpoints.
However, `newMux` returns a bare `*http.ServeMux`.
When a client sends `HEAD /unknown-route`, Go returns a 19-byte plaintext 404 body.
Furthermore, `s.search` calls `http.Error` on decoding errors and index restrictions.
These calls stream plaintext payloads directly on `HEAD`.

### 2.2 Tenant App Route Exposure

In `olly-replica/apps/cmd/tenant-app/main.go`:
`newTenantMux` assembles tenant routes but returns an unwrapped mux.
`HEAD /unknown` leaks 19 bytes of plaintext body.
The `/fault` handler accepts only `GET` or `POST`, rejecting `HEAD` with body payload.

### 2.3 Mapping Stub Unregistered Route Leaks

In `olly-replica/apps/cmd/mapping-stub/main.go`:
`newMux` registers incidents, metrics, health, and decision endpoints.
Unregistered routes hit Go default handler, leaking 404 bodies on `HEAD`.

### 2.4 Prod Deploy Gate Unregistered Route Leaks

In `d2-signalloom/apps/prod-deploy-gate/main.go`:
`httpSrv` uses a bare `mux` populated by `registerRoutes`.
When receiving `HEAD /unknown`, Go writes `404 page not found\n`.

### 2.5 Agent Trust A2A Non-Uniform Error Handling

In `d2-agent-trust/a2a/service.py`:
`do_HEAD` and `_handle_unsupported_method` call `self.send_error(404)`.
This emits standard Python HTML templates rather than uniform JSON error structures.

---

## 3. Implementation Design

### 3.1 Standard Go Middleware Pattern

In Go services, introduce `headResponseWriter` and `headBodySuppressingMiddleware`:

```go
type headResponseWriter struct {
    http.ResponseWriter
}

func (w *headResponseWriter) Write(p []byte) (int, error) {
    return len(p), nil
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

Wrapping the root HTTP handler ensures that any downstream write is dropped cleanly on `HEAD`.
Status codes and response headers remain intact.

### 3.2 Python Service JSON Error Consistency

In `d2-agent-trust/a2a/service.py`, implement structured JSON responses for 404 errors.
Ensure `Content-Length` and headers match while body writes are skipped on `HEAD`.

---

## 4. Component Verification & Test Plan

1. **`elk-search-mcp`**:
   - `TestElkSearchHeadUnmatchedRoutes`: Verify `HEAD /unknown` returns 404 with 0 body bytes.
   - Verify `HEAD /tools/elk_search_logs` returns 405 with 0 body bytes and `Allow: POST`.
   - Verify `HEAD /healthz` and `HEAD /readyz` return 200 with 0 body bytes.
2. **`tenant-app`**:
   - `TestTenantAppHeadUnmatchedRoutes`: Verify `HEAD /unknown` returns 404 with 0 body bytes.
   - Verify `HEAD /topology` and `HEAD /metrics` return 200 with 0 body bytes.
3. **`mapping-stub`**:
   - `TestMappingStubHeadUnmatchedRoutes`: Verify `HEAD /unknown` returns 404 with 0 body bytes.
   - Verify `HEAD /incidents` returns 200 with 0 body bytes.
4. **`prod-deploy-gate`**:
   - `TestProdDeployGateHeadUnmatchedRoutes`: Verify `HEAD /unknown` returns 404 with 0 body bytes.
   - Verify `HEAD /gate/request` returns 405 with 0 body bytes and `Allow: POST`.
5. **`agent-trust-a2a`**:
   - Verify `HEAD /unknown` returns 404 with 0 body bytes and JSON Content-Type.
   - Run `pytest d2-agent-trust/test/test_contracts.py`.

---

## 5. Delivery Matrix & Verification Plan

| Component | Target File | Change | Test Command |
|---|---|---|---|
| `elk-search-mcp` | `main.go` | Wrap `newMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `tenant-app` | `main.go` | Wrap `newTenantMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `mapping-stub` | `main.go` | Wrap `newMux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `prod-deploy-gate` | `main.go` | Wrap `mux` in `headBodySuppressingMiddleware` | `go test ./... -v` |
| `agent-trust` | `service.py` | Add JSON 404 handler and suppress body on `HEAD` | `pytest test/test_contracts.py` |
