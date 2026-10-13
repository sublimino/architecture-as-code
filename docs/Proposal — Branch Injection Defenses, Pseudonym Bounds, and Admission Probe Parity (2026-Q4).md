# Proposal — Branch Injection Defenses, Pseudonym Bounds, and Admission Probe Parity (2026-Q4)

## Context and Motivation

Cloud native platforms require rigorous boundary enforcement across all operational tiers.
Input parameters destined for source control operations must prevent CLI flag injection.
Cryptographic keyring primitives must reject negative or out-of-range epoch inputs.
Probe endpoints must support standard HTTP methods while rejecting improper verbs.
Wildcard route handlers must reject requests targeting undefined subpaths.
These defenses eliminate silent protocol failures and maintain fail-closed execution.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, Hosted Daytona Coder validates requested git branch names.
Branch names cannot start with dashes or contain shell metacharacters.

Second, the fake integration proxy supports HEAD requests on probe routes.
Liveness and readiness checks return appropriate headers without body transmission.

Third, the host sensor pseudonym keyring validates rotation epochs.
Epochs must be positive thirty-two bit unsigned integers.

Fourth, the CI triage worker restricts its webhook handler to the exact root path.
Unmatched subpaths return four-zero-four Not Found instead of invoking check execution.

Fifth, the traffic control sentinel restricts probe and metric endpoints.
Requests using verbs other than GET or HEAD return four-zero-five Method Not Allowed.

Sixth, the node capability guard admission webhook enforces GET and HEAD on probes and metrics.
Non-idempotent HTTP methods return four-zero-five Method Not Allowed.

## Target Components and Concrete Changes

### 1. Hosted Daytona Coder Branch Validation

Component path: `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`.
The server validates requested branch names against git reference rules.
Branches cannot begin with dashes or contain path traversal markers.
Invalid branch names return four-hundred Bad Request.
Unit tests in `d2-signalloom/apps/hosted-daytona-coder/workspace_manager_test.go` verify validation rules.

### 2. Fake Integration Proxy HEAD Probe Dispatch

Component path: `d2-signalloom/apps/fake-integration-proxy/server.py`.
The handler dispatches HEAD requests to the primary route dispatcher.
Probe checks on `/health`, `/healthz`, and `/readyz` succeed on both GET and HEAD.
Unit tests verify header generation for both HTTP methods.

### 3. Host Sensor Pseudonym KeyRing Epoch Bounds

Component path: `d2-signalloom/apps/agentmaxxing-host-sensor/pseudonym.py`.
The constructor checks that epoch values fit within unsigned thirty-two bit bounds.
Non-positive or overflowing epochs raise an explicit invalid epoch error.
The `is_pseudonym` validator guards against non-string inputs safely.
Unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_models.py` verify epoch boundaries.

### 4. Triage CI Worker Root Route Enforcement

Component path: `d2-signalloom/apps/triage-ci-worker/main.go`.
The webhook handler verifies that the request URL matches the root path exactly.
Unmatched paths return four-zero-four Not Found.
Unit tests in `d2-signalloom/apps/triage-ci-worker/main_test.go` verify route matching.

### 5. Traffic Control Sentinel Method Gate

Component path: `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go`.
Handlers for `/health`, `/healthz`, `/readyz`, and `/metrics` verify request methods.
Verbs other than GET and HEAD return four-zero-five Method Not Allowed.
Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main_test.go` verify verb rejection.

### 6. Node Capability Guard Probe Method Gate

Component path: `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`.
Handlers for health and metric endpoints check that requests use GET or HEAD.
Other verbs return four-zero-five Method Not Allowed.
Unit tests in `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go` verify method enforcement.

## Verification Plan

Every hardened component is validated by automated tests.

1. Run `go test ./...` in `d2-signalloom/apps/hosted-daytona-coder`.
2. Run `pytest d2-signalloom/apps/fake-integration-proxy/test_server.py`.
3. Run `pytest d2-signalloom/apps/agentmaxxing-host-sensor/test_models.py`.
4. Run `go test ./...` in `d2-signalloom/apps/triage-ci-worker`.
5. Run `go test ./...` in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`.
6. Run `go test ./...` in `d2-signalloom/apps/node-capability-guard/pkg/webhook`.
7. Verify documentation indexing and linting with `make docs-lint`.
