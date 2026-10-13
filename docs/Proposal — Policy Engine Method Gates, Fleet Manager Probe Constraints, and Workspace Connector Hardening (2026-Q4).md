# Proposal — Policy Engine Method Gates, Fleet Manager Probe Constraints, and Workspace Connector Hardening (2026-Q4)

## Context and Motivation

Microservice architectures depend on uniform HTTP method semantics across monitoring and control plane endpoints.
Standard Kubernetes kubelet health probes and external HTTP monitors issue both GET and HEAD requests.
Handlers must accept both methods consistently without transmitting response payloads for HEAD requests.
Handlers rejecting non-allowed verbs must supply an RFC 9110 compliant Allow header.
Service responses on error paths must declare standard JSON Content-Type headers.
These constraints prevent thread crashes, memory exhaustion, and ambiguous monitoring signals.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, the policy engine restricts its health probes to GET and HEAD with an Allow header on four-zero-five responses.
The evaluation endpoint enforces POST only with an Allow header.
The list policies route supports HEAD requests without payload transmission.

Second, the fleet manager restricts `/health`, `/healthz`, and `/readyz` to GET and HEAD.
Requests using other verbs return four-zero-five Method Not Allowed with an Allow header.
HEAD requests return headers without JSON body bytes.

Third, the workspace connector suppresses body transmission on HEAD requests for health and status endpoints.
Probes succeed on both GET and HEAD cleanly.

Fourth, the factory appraiser health handler suppresses body transmission on HEAD requests.
Validation error responses explicitly set Content-Type to application/json.

Fifth, the CPAI engineer service supports HEAD requests across health and task inspection routes without body leakage.

Sixth, the signal ingest probe handler supports HEAD requests on liveness and readiness endpoints without writing body bytes.

## Target Components and Concrete Changes

### 1. Policy Engine Method Gates and Allow Headers

Component path: `d2-signalloom/apps/policy-engine/handlers.go`.
Component path: `d2-signalloom/apps/policy-engine/main.go`.
The server restricts `/health`, `/healthz`, and `/readyz` to GET and HEAD with `Allow: GET, HEAD`.
The `/api/v1/evaluate` endpoint returns four-zero-five with `Allow: POST` for non-POST requests.
The `/api/v1/policies` handler supports HEAD requests returning two-hundred OK with no body.
Unit tests in `d2-signalloom/apps/policy-engine/main_test.go` verify method enforcement.

### 2. Fleet Manager Probe Method Constraints

Component path: `d2-signalloom/apps/fleet-manager/main.go`.
The server restricts `/health`, `/healthz`, and `/readyz` to GET and HEAD.
Other verbs return four-zero-five Method Not Allowed with `Allow: GET, HEAD`.
HEAD requests return headers without JSON body bytes.
Unit tests in `d2-signalloom/apps/fleet-manager/health_test.go` verify method enforcement and HEAD responses.

### 3. Workspace Connector HEAD Probe Suppression

Component path: `d2-signalloom/apps/workspace-connector/main.go`.
The server handles HEAD requests on `/health`, `/healthz`, `/readyz`, and `/api/v1/workspace/status` without writing body bytes.
Unit tests in `d2-signalloom/apps/workspace-connector/main_test.go` verify HEAD responses.

### 4. Factory Appraiser HEAD Probes and Content-Type Headers

Component path: `d2-signalloom/apps/factory-appraiser/main.go`.
The health handler suppresses response bodies on HEAD requests.
Error responses on `/api/v1/factory/appraise` and `/api/v1/factory/validate-promotion` set `Content-Type: application/json`.
Unit tests in `d2-signalloom/apps/factory-appraiser/main_test.go` verify HEAD responses and error headers.

### 5. CPAI Engineer HEAD Request Handling

Component path: `d2-signalloom/apps/cpai-engineer/main.go`.
Health endpoints and task query endpoints (`/tasks`, `/tasks/{id}`) omit JSON bodies on HEAD requests.
Unit tests in `d2-signalloom/apps/cpai-engineer/acceptance_test.go` verify HEAD handling.

### 6. Signal Ingest Probe HEAD Dispatch

Component path: `d2-signalloom/apps/signal-ingest/api/handlers.go`.
Probe handlers `/healthz` and `/readyz` detect HEAD requests and write headers without payload bytes.
Unit tests in `d2-signalloom/apps/signal-ingest/api/probe_test.go` verify probe HEAD responses.

## Verification Plan

Every hardened component is validated by automated tests.

1. Run `go test ./...` in `d2-signalloom/apps/policy-engine`.
2. Run `go test ./...` in `d2-signalloom/apps/fleet-manager`.
3. Run `go test ./...` in `d2-signalloom/apps/workspace-connector`.
4. Run `go test ./...` in `d2-signalloom/apps/factory-appraiser`.
5. Run `go test ./...` in `d2-signalloom/apps/cpai-engineer`.
6. Run `go test ./api -run TestProbe` in `d2-signalloom/apps/signal-ingest`.
7. Verify documentation indexing and linting with `make docs-lint`.
