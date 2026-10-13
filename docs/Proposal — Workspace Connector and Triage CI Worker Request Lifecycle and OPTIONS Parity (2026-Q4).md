# Proposal — Workspace Connector and Triage CI Worker Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom operates ingestion and CI automation services.
The Workspace connector ingests audit events and executes stun cascades.
The triage CI worker inspects failed GitHub check runs.
Both microservices expose HTTP interfaces.
These interfaces handle health probes and operational commands.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
Both microservices support OPTIONS on endpoints.
However, their 405 Method Not Allowed responses omit OPTIONS from Allow headers.
They return `Allow: GET, HEAD` or `Allow: POST`.
They must advertise `Allow: GET, HEAD, OPTIONS` or `Allow: POST, OPTIONS`.
Furthermore, incoming mutating requests omit deferred request body closure.
When connections terminate early or fail validation, open sockets leak.
Under continuous load, unclosed request bodies exhaust file descriptors.

## Proposed Changes

### 1. Workspace Connector Hardening
We update `d2-signalloom/apps/workspace-connector/main.go`.
We ensure `handlePoll` and `handleStun` defer `r.Body.Close()`.
We update 405 responses to advertise `Allow: GET, HEAD, OPTIONS` or `Allow: POST, OPTIONS`.
This aligns health, poll, stun, and status routes with RFC 9110.

### 2. Triage CI Worker Hardening
We update `d2-signalloom/apps/triage-ci-worker/main.go`.
We ensure `handleCheckRun` defers `r.Body.Close()`.
We update `methodNotAllowed` calls to advertise `Allow: GET, HEAD, OPTIONS` or `Allow: POST, OPTIONS`.
This prevents socket leakage during webhook ingestion.

### 3. Test Suite Expansion
We expand tests in both microservices.
We verify Allow header parity across all routes.
We verify OPTIONS requests return 204 No Content.
We verify empty response bodies on OPTIONS responses.

## Verification Plan
We execute targeted unit tests for each package.
We run `go test` in `d2-signalloom/apps/workspace-connector`.
We run `go test` in `d2-signalloom/apps/triage-ci-worker`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
