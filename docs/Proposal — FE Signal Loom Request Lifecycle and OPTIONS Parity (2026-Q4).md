# Proposal — FE Signal Loom Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom coordinates autonomous fleet containment and agent governance.
The frontend discovery portal and demo runner services expose HTTP endpoints for operators and automated orchestration.
The service handles health probes, readiness checks, demo execution pipelines, and security auditing.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers on 405 Method Not Allowed responses.
In `fe-signalloom`, both the main portal and standalone demo runner reject OPTIONS with 405 Method Not Allowed.
Furthermore, 405 responses advertise truncated Allow headers omitting OPTIONS.
In `demo_runner_main.py`, duplicate registration of `@app.head` on `@app.get` routes corrupts Starlette partial route matching.
This bug causes `POST /health` to return `Allow: HEAD`, completely omitting `GET`.
Additionally, requests rejected with 405 or preflight OPTIONS do not drain inbound request bodies.
This omission risks socket descriptor desynchronization under high-throughput probe sweeps.

## Objectives
1. Support RFC 9110 Section 9.3.7 OPTIONS preflight returning 204 No Content with complete Allow headers.
2. Restore RFC 9110 Section 9.3.7 Allow header parity across all frontend routes on 405 responses.
3. Eliminate duplicate `@app.head` registrations that corrupt route matching in `demo_runner_main.py`.
4. Ensure inbound request body draining and body suppression on 204 and HEAD responses.
5. Update unit and contract tests to assert RFC 9110 compliant Allow headers.

## Proposed Changes

### 1. Enhanced Request Lifecycle and OPTIONS Middleware
We update `HeadBodySuppressingMiddleware` in `d2-signalloom/apps/fe-signalloom/src/demo_runner_main.py`.
We update `HeadBodySuppressingMiddleware` in `d2-signalloom/apps/fe-signalloom/src/main.py`.
The middleware dynamically inspects registered application routes for matching paths.
For incoming OPTIONS requests, it drains the request body and returns 204 No Content with the complete Allow header.
For 405 Method Not Allowed responses, it replaces truncated headers with complete RFC 9110 Allow headers including OPTIONS.
For 204 and 304 responses, it ensures message bodies are suppressed.

### 2. Route Registration Cleanup
We remove redundant `@app.head` route registrations in `demo_runner_main.py`.
`HeadBodySuppressingMiddleware` already dispatches HEAD requests to GET handlers and suppresses response bodies.
Removing duplicate registrations resolves Starlette partial route matching corruption.

### 3. Test Suite Verification
We update `d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py`.
We add assertions verifying OPTIONS preflight responses return 204 No Content with complete Allow headers.
We verify that 405 Method Not Allowed responses include OPTIONS and all permitted methods.
We ensure all existing test suites continue to pass cleanly.

## Verification Plan
We run pytest across all `test_demo_runner*.py` and `test_head_response_suppression.py` suites.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
