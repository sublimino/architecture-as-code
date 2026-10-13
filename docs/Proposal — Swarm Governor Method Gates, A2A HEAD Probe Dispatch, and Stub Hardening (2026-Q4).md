# Proposal — Swarm Governor Method Gates, A2A HEAD Probe Dispatch, and Stub Hardening (2026-Q4)

## Context and Motivation

Microservice architectures depend on uniform HTTP method semantics across monitoring and control plane endpoints.
Standard Kubernetes kubelet health probes and external HTTP monitors issue both GET and HEAD requests.
Handlers must accept both methods consistently without transmitting response payloads for HEAD requests.
Handlers rejecting non-allowed verbs must supply an RFC 9110 compliant Allow header.
Request payload headers like Content-Length must be parsed with bounded error handling.
These constraints prevent thread crashes, memory exhaustion, and ambiguous monitoring signals.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, the swarm governor restricts its health probes and agent card routes to GET and HEAD.
Requests using other verbs return four-zero-five Method Not Allowed with an Allow header.
The task query endpoint supports HEAD requests without payload transmission.

Second, the cardvault service advertises an Allow header on all four-zero-five responses.
HEAD requests on health and card routes return headers without JSON body bytes.

Third, the A2A trust service implements HEAD request dispatching.
Probes, challenges, and agent card endpoints respond to HEAD without writing body bytes.
The authorization header parser strips leading and trailing whitespace.

Fourth, the user surface gate stub server implements HEAD request handling.
Probe checks succeed on HEAD without writing body bytes.
The request reader safely parses Content-Length headers without uncaught exceptions.

Fifth, the netassert controller enables HEAD dispatching for cluster probes.
Liveness and readiness endpoints succeed on both GET and HEAD.

Sixth, the Sentinel ASGI application explicitly registers GET and HEAD methods on probe routes.
Probe endpoints respond cleanly to standard HTTP HEAD checks.

## Target Components and Concrete Changes

### 1. Swarm Governor Probe and Card Method Gates

Component path: `d2-signalloom/apps/swarm-governor/main.go`.
The server restricts `/health`, `/healthz`, `/readyz`, and `/.well-known/agent-card.json` to GET and HEAD.
Other verbs return four-zero-five Method Not Allowed with `Allow: GET, HEAD`.
The `/tasks/{id}` handler supports HEAD requests returning two-hundred OK with no body.
Unit tests in `d2-signalloom/apps/swarm-governor/dispatcher_test.go` verify method enforcement.

### 2. Cardvault Allow Header and HEAD Body Elimination

Component path: `d2-signalloom/apps/cardvault/main.go`.
Handlers for `/health`, `/healthz`, `/readyz`, and `/api/v1/cards` add `Allow: GET, HEAD` to four-zero-five responses.
HEAD requests return two-hundred OK with headers and zero body bytes.
Unit tests in `d2-signalloom/apps/cardvault/main_test.go` verify headers and empty bodies.

### 3. A2A Service HEAD Probe Dispatch

Component path: `d2-agent-trust/a2a/service.py`.
The server defines `do_HEAD` for health, challenge, and agent card routes.
Bearer authorization tokens are trimmed of whitespace.
Unit tests in `d2-agent-trust/test/test_contracts.py` verify HEAD probe responses.

### 4. Stub Surface Server HEAD Support and Content-Length Safety

Component path: `test/fixtures/user-surface-gate/stub-surface-server.py`.
The server defines `do_HEAD` for `/health`, `/healthz`, and `/readyz`.
The request handler parses Content-Length safely with fallback for invalid or negative integers.
Authorization header comparisons trim whitespace.
Integration tests in `test/user-surface-gate.bats` verify safe parsing and HEAD responses.

### 5. Netassert Controller HEAD Probe Support

Component path: `d2-signalloom/apps/netassert-controller/server.py`.
The controller maps `do_HEAD = _dispatch` and permits HEAD on probe routes.
Unit tests in `d2-signalloom/apps/netassert-controller/test/test_controller.py` verify probe responses.

### 6. Olly Sentinel Probe Route Method Expansion

Component path: `olly-replica/apps/sentinel/olly_sentinel/main.py`.
The application registers `/health`, `/healthz`, `/readyz`, and `/orbit/proposals` with `methods=["GET", "HEAD"]`.
Unit tests in `olly-replica/apps/sentinel/tests/test_a2a_app.py` verify probe access.

## Verification Plan

Every hardened component is validated by automated tests.

1. Run `go test ./...` in `d2-signalloom/apps/swarm-governor`.
2. Run `go test ./...` in `d2-signalloom/apps/cardvault`.
3. Run `pytest d2-agent-trust/test`.
4. Run `bats test/user-surface-gate.bats`.
5. Run `pytest d2-signalloom/apps/netassert-controller/test`.
6. Run `pytest olly-replica/apps/sentinel/tests/test_a2a_app.py`.
7. Verify documentation indexing and linting with `make docs-lint`.
