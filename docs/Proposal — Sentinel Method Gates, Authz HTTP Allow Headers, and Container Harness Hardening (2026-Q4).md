# Proposal — Sentinel Method Gates, Authz HTTP Allow Headers, and Container Harness Hardening (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol fidelity are essential across daemon, microservice, and authorization boundaries.
Standard health monitoring agents and kubelet probes issue both GET and HEAD requests to assess component vitality.
Handlers answering HEAD requests must return exact headers while completely suppressing message body transmission.
When microservices reject unsupported verbs, RFC 9110 requires an Allow header that enumerates supported methods.
Omitting Allow headers or transmitting payloads on HEAD requests leads to monitoring alerts, socket desynchronization, and unnecessary heap pressure.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, the Olly Sentinel authorization HTTP utility (`olly-replica/apps/authz/authz/httputil.py`) implements HEAD request dispatching and suppresses response bodies on HEAD in `send_json`.
Unmatched routes inspect candidate methods and return four-zero-five Method Not Allowed with an RFC 9110 compliant Allow header.

Second, the Signal Loom warden health server (`d2-signalloom/apps/signalloom-stun-sentinel/health.go`) adds an Allow header on four-zero-five responses across liveness, readiness, captures, and metrics routes.
HEAD requests suppress body writes across all four handlers while maintaining accurate headers.

Third, the hosted Daytona coder workspace manager (`d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`) suppresses body transmission on HEAD requests for health probes and workspace query routes.

Fourth, the Kusari agent HTTP handler (`d2-signalloom/apps/kusari-agent/main.go`) short-circuits HEAD requests in `getOnly`, eliminating JSON encoding overhead and ensuring zero body transmission.

Fifth, the Tier Zero containment daemon (`d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`) supplies an Allow header with value POST when rejecting non-POST verbs on stun, resume, and snapshot prune endpoints.
Snapshot inspection routes accept HEAD requests cleanly and return an Allow header on invalid verbs.

Sixth, the production deployment gate (`d2-signalloom/apps/prod-deploy-gate/main.go`) supplies an Allow header with value POST on request and approval endpoints.
Health probe endpoints consistently declare application/json Content-Type headers when responding to HEAD requests.

## Target Components and Concrete Changes

### 1. Olly Sentinel Authz HTTP Dispatching and Allow Headers

Component path: `olly-replica/apps/authz/authz/httputil.py`.
The server helper implements `do_HEAD` in its handler and falls back to GET routes for HEAD requests.
The `send_json` helper suppresses body transmission when handling HEAD commands and optionally emits an Allow header.
When a requested path exists under alternative methods, the dispatcher emits four-zero-five Method Not Allowed with the allowable methods listed in the Allow header.
Unit tests in `olly-replica/apps/authz/tests/test_authz.py` verify HEAD handling and Allow headers.

### 2. Signal Loom Warden Probe and Capture Method Gates

Component path: `d2-signalloom/apps/signalloom-stun-sentinel/health.go`.
The server sets `Allow: GET, HEAD` when rejecting unsupported HTTP verbs on `/healthz`, `/health`, `/readyz`, `/metrics`, and `/captures`.
Response bodies are omitted when processing HEAD requests on all endpoints.
Unit tests in `d2-signalloom/apps/signalloom-stun-sentinel/health_test.go` verify method enforcement and body suppression.

### 3. Hosted Daytona Coder HEAD Suppression

Component path: `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`.
The server handles HEAD requests on `/health`, `/healthz`, `/readyz`, `/workspaces`, and `/workspaces/{id}` without writing body bytes.
Unit tests in `d2-signalloom/apps/hosted-daytona-coder/workspace_manager_test.go` verify HEAD responses across all endpoints.

### 4. Kusari Agent GET and HEAD Dispatching

Component path: `d2-signalloom/apps/kusari-agent/main.go`.
The `getOnly` middleware detects HEAD requests and writes two-hundred OK headers with application/json Content-Type, short-circuiting handler execution and body serialization.
Unit tests in `d2-signalloom/apps/kusari-agent/methods_test.go` verify that HEAD requests return empty bodies.

### 5. Stun Sentinel Snapshot HEAD Support and POST Method Gates

Component path: `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`.
The server emits `Allow: POST` when rejecting non-POST verbs on `/stun`, `/resume`, and `/quarantine/prune`.
The `/quarantine/snapshots` and `/quarantine/snapshots/` routes accept both GET and HEAD requests with `Allow: GET, HEAD` on invalid verbs, and suppress body transmission on HEAD requests.
Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main_test.go` verify method validation and HEAD responses.

### 6. Production Deployment Gate Method Gates and Content-Type Fidelity

Component path: `d2-signalloom/apps/prod-deploy-gate/main.go`.
The server sets `Allow: POST` when returning four-zero-five on `/gate/request` and `/gate/approve`.
Health handlers set the application/json Content-Type header on HEAD requests.
Unit tests in `d2-signalloom/apps/prod-deploy-gate/main_test.go` verify method gating and header consistency.

## Verification Plan

1. Run Python unit tests in `olly-replica/apps/authz/tests/test_authz.py`.
2. Run Go unit tests in `d2-signalloom/apps/signalloom-stun-sentinel`.
3. Run Go unit tests in `d2-signalloom/apps/hosted-daytona-coder`.
4. Run Go unit tests in `d2-signalloom/apps/kusari-agent`.
5. Run Go unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`.
6. Run Go unit tests in `d2-signalloom/apps/prod-deploy-gate`.
7. Execute `scripts/docs-lint.sh` to verify link and path integrity.
