# Proposal — Deployment Gate Method Checks, Proof Helper Boundaries, and Auto-Claim Defenses (2026-Q4)

## Context and Motivation

Cloud native platforms require consistent boundary defense across all operational microservices.
Probe endpoints must support standard HTTP methods while rejecting improper verbs.
Wildcard route handlers must reject requests targeting undefined subpaths.
Authentication helpers must trim whitespace from tokens to avoid parsing errors.
Client registration hooks must validate required parameters before network transmission.
These defenses eliminate protocol ambiguities and maintain deterministic fail-closed execution.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, the production deployment gate enforces HTTP method checks on health probes and supports HEAD requests on gate inspection.
Other methods return four-zero-five Method Not Allowed.

Second, the proof helper restricts its probe and challenge handlers to GET and HEAD methods.
Unmatched methods return four-zero-five Method Not Allowed.

Third, the prompt commit summarizer validates HTTP methods on health endpoints and enforces exact root path matching.
Unmatched subpaths return four-zero-four Not Found.

Fourth, the stun sentinel restricts health endpoints to GET and HEAD methods and trims bearer tokens.
Invalid methods return four-zero-five Method Not Allowed.

Fifth, the kusari agent permits HEAD requests on all read-only endpoints.
The server returns an Allow header naming GET and HEAD.

Sixth, the cardvault agent validates auto-claim parameters before making HTTP requests.
Empty or blank values fail immediately.

## Target Components and Concrete Changes

### 1. Production Deployment Gate Method Checks

Component path: `d2-signalloom/apps/prod-deploy-gate/main.go`.
The server permits GET and HEAD on `/health`, `/healthz`, `/readyz`, and `/gate/{id}`.
Other verbs return four-zero-five Method Not Allowed.
Unit tests in `d2-signalloom/apps/prod-deploy-gate/main_test.go` verify method enforcement.

### 2. Proof Helper Probe and Challenge Method Gates

Component path: `d2-signalloom/proof-helper/main.go`.
The server restricts `/health`, `/healthz`, `/readyz`, and `/challenge` to GET and HEAD.
Non-allowed verbs return four-zero-five Method Not Allowed.
Unit tests in `d2-signalloom/proof-helper/main_test.go` verify verb rejection.

### 3. Prompt Commit Summarizer Root Isolation

Component path: `d2-signalloom/apps/prompt-commit-summarizer/main.go`.
The health handler validates that requests use GET or HEAD.
The commit summarization handler verifies that the request path matches the root exactly.
Non-root paths return four-zero-four Not Found.
Unit tests in `d2-signalloom/apps/prompt-commit-summarizer/main_test.go` verify path routing.

### 4. Stun Sentinel Health Method Checks and Bearer Trimming

Component path: `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`.
The health handler verifies that requests use GET or HEAD.
Bearer authentication trims whitespace from authorization headers.
Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main_test.go` verify method checks.

### 5. Kusari Agent HEAD Method Parity

Component path: `d2-signalloom/apps/kusari-agent/main.go`.
The `getOnly` middleware allows both GET and HEAD methods.
The `Allow` header advertises `GET, HEAD`.
Unit tests in `d2-signalloom/apps/kusari-agent/methods_test.go` verify HEAD responses.

### 6. Cardvault Agent Auto-Claim Validation

Component path: `d2-signalloom/apps/cardvault-agent/autoclaim.go`.
The `autoClaim` method validates that the SPIFFE identity and token are non-empty.
Empty or blank values fail immediately with descriptive errors.
Unit tests in `d2-signalloom/apps/cardvault-agent/autoclaim_test.go` verify parameter validation.

## Verification Plan

Every hardened component is validated by automated tests.

1. Run `go test ./...` in `d2-signalloom/apps/prod-deploy-gate`.
2. Run `go test ./...` in `d2-signalloom/proof-helper`.
3. Run `go test ./...` in `d2-signalloom/apps/prompt-commit-summarizer`.
4. Run `go test ./...` in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`.
5. Run `go test ./...` in `d2-signalloom/apps/kusari-agent`.
6. Run `go test ./...` in `d2-signalloom/apps/cardvault-agent`.
7. Verify documentation indexing and linting with `make docs-lint`.
