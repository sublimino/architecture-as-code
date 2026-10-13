# Proposal — Go ServeMux HEAD Parity, Probe Method Registration, and Appraiser Response Fidelity (2026-Q4)

| Attribute | Value |
| :--- | :--- |
| **Status** | Proposed |
| **Date** | 2026-10-13 |
| **Author** | Antigravity AI Engine |
| **Scope** | `d2-signalloom/apps/{signal-ingest,hosted-daytona-coder,cpai-engineer,workspace-connector,factory-appraiser}` |
| **Tag** | `GOMUXHEADPARITY` |

## 1. Executive Summary

Go 1.22 introduced method-scoped routing in `http.ServeMux`.
Registering a route with a method prefix like `GET /path` matches only GET requests.
Requests with the `HEAD` method receive automatic `405 Method Not Allowed` responses.
Multiple Signal Loom Go services implement `HEAD` handling inside their handler bodies.
However, their muxes registered the routes with `GET ` prefixes.
This mismatched configuration breaks RFC 9110 compliance and prevents probe verification.
This proposal remedies this across five core services.

## 2. Problem Statement

Adversarial exploration identified latent method rejection across multiple services:

1. **Signal Ingest Probe Mux (`signal-ingest/api/probe.go`)**:
   `NewProbeHandler` registered `GET /healthz` and `GET /readyz`.
   Underlying handlers `handleHealthz` and `handleReadyz` implement HEAD handling.
   Yet incoming HEAD probes fail with HTTP 405.

2. **Hosted Daytona Coder (`hosted-daytona-coder/workspace-manager.go`)**:
   `healthHandler`, workspace detail, and workspace list handlers check `r.Method == http.MethodHead`.
   The routes were registered with `GET ` prefixes.
   As a consequence, HEAD requests on `/health`, `/healthz`, `/readyz`, `/workspaces`, and `/workspaces/{id}` fail with 405.

3. **CPAI Engineer (`cpai-engineer/main.go`)**:
   `healthHandler`, `/tasks`, and `/tasks/{id}` implement HEAD body suppression.
   Because `newServer` registered `GET /health`, `GET /tasks`, and `GET /tasks/{id}`, HEAD requests fail.

4. **Workspace Connector (`workspace-connector/main.go`)**:
   `healthHandler`, `/readyz`, and `handleStatus` implement HEAD body suppression.
   Because mux routes used `GET ` prefixes, HEAD requests are rejected.

5. **Factory Appraiser (`factory-appraiser/main.go`)**:
   `healthHandler` implements HEAD status handling.
   The mux registered `GET /healthz`, `GET /readyz`, and `GET /health`.
   In addition, `appraiseHandler` omitted `Content-Type: application/json` on 400 and 422 error paths.

## 3. Architecture and Implementation Design

### 3.1 Go 1.22 ServeMux HEAD Parity Registration

Each service registers both `GET` and `HEAD` verbs on read-only endpoints:

```go
mux.HandleFunc("GET /health", healthHandler)
mux.HandleFunc("HEAD /health", healthHandler)
```

This preserves method gating while admitting HEAD probes.
Non-GET/HEAD verbs continue to be rejected by ServeMux with `405 Method Not Allowed`.
The ServeMux includes the required `Allow: GET, HEAD` header.

### 3.2 Error Header Consistency

In `factory-appraiser`, error responses must consistently set the JSON content type:

```go
w.Header().Set("Content-Type", "application/json")
w.WriteHeader(http.StatusBadRequest)
```

## 4. Verification Plan

1. Unit tests verifying 200 OK with empty body on HEAD for all affected routes.
2. Unit tests verifying 405 Method Not Allowed with `Allow: GET, HEAD` on mutating verbs.
3. Content-Type assertions for all error responses.
4. Regression suite runs across all five services.
