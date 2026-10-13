# Proposal — Microservice HEAD Error Response Body Suppression and Method Gates (2026-Q4)

| Attribute | Value |
| :--- | :--- |
| **Status** | Proposed |
| **Date** | 2026-10-13 |
| **Author** | Antigravity AI Engine |
| **Scope** | `prod-deploy-gate`, `cardvault`, `prompt-commit-summarizer`, `stun-sentinel`, `fleet-manager` |
| **Tag** | `HEADERRORSUPPRESS` |

## 1. Executive Summary

HTTP microservices across the platform expose HTTP probe and RPC endpoints.
RFC 9110 Section 9.3.2 requires that HEAD responses omit bodies.
Section 6.4.1 states that servers must never send a body for HEAD requests, even on errors.
Several microservices serialize JSON or text errors when answering HEAD requests with 401, 404, or 405.
This proposal remedies these issues by enforcing body suppression on HEAD requests across all status codes in affected services.

## 2. Problem Statement

Adversarial exploration identified latent gaps across several Go services:

1. **Prod Deploy Gate (`prod-deploy-gate/main.go`)**:
   `writeJSON` unconditionally encoded JSON payloads into the `http.ResponseWriter`.
   When incoming HEAD requests triggered 405 Method Not Allowed on `/gate/request` or `/gate/approve`, the server transmitted serialized JSON bodies to the client.

2. **Cardvault Service (`cardvault/main.go`)**:
   `writeJSON` unconditionally wrote JSON bodies for all responses.
   Incoming HEAD requests to `/api/v1/cards` without authentication received 401 Unauthorized with a non-empty JSON error body.

3. **Prompt Commit Summarizer (`prompt-commit-summarizer/main.go`)**:
   The root summarize handler returned 405 Method Not Allowed using `http.Error`.
   This leaked message body bytes on incoming HEAD requests.

4. **Stun Sentinel (`stun-sentinel/cmd/stun-sentinel/main.go`)**:
   `writeJSON` unconditionally serialized response bodies.
   When unauthenticated HEAD requests hit `/stun` or `/quarantine/prune`, error payloads were written to the socket.

5. **Fleet Manager (`fleet-manager/main.go`)**:
   `writeError` encoded JSON error responses without checking for HTTP HEAD requests.
   Calls rejected with 405 Method Not Allowed or 401 Unauthorized leaked JSON error bodies on HEAD requests.


## 3. Architecture and Implementation Design

### 3.1 Request-Aware JSON Writers

Handlers in `prod-deploy-gate`, `cardvault`, and `stun-sentinel` update `writeJSON` to accept the `*http.Request` context.
When `r.Method == http.MethodHead`, writing the serialized JSON body is omitted:

```go
func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}
```

### 3.2 HEAD Body Suppression Middleware

For services with extensive route trees such as `fleet-manager`, a lightweight middleware intercepts HEAD requests.
The middleware wraps the `http.ResponseWriter` to discard body writes while preserving headers and status codes:

```go
type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (h *headResponseWriter) WriteHeader(code int) {
	if !h.wroteHeader {
		h.wroteHeader = true
		h.ResponseWriter.WriteHeader(code)
	}
}

func (h *headResponseWriter) Write(b []byte) (int, error) {
	if !h.wroteHeader {
		h.WriteHeader(http.StatusOK)
	}
	return len(b), nil
}
```

### 3.3 Endpoint Method Gates and Headers

Mutating endpoints enforce HTTP method checks.
Unsupported methods return status 405 with the RFC 9110 `Allow` header and empty bodies on HEAD requests.

## 4. Verification Plan

1. Verify HEAD requests to mutating routes return status 405 with zero body bytes.
2. Verify unauthenticated HEAD requests return status 401 with zero body bytes.
3. Verify HEAD requests to unknown entities return status 404 with zero body bytes.
4. Verify existing test suites in each service continue to pass without regression.
5. Validate documentation linting and index synchronization via `bats test/docs-index-sync.bats`.
