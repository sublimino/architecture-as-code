# Proposal — Netassert Controller, Olly AuthZ, and SPA Server Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom coordinates agent execution across network boundaries and governance planes.
The `netassert-controller` process orchestrates isolated network connectivity probes.
The Olly replica authorization service coordinates policy decision points and entitlement issuers.
The Jev test bot provides a loopback single-page app server for offline interface testing.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling across HTTP surfaces.
Servers advertising supported methods must include OPTIONS in Allow headers.
In `netassert-controller`, `server.py` rejects OPTIONS requests across all routes with 405 Method Not Allowed.
Its 405 error responses advertise truncated Allow headers that omit OPTIONS.
Its `_json` helper serializes null bodies on 204 No Content responses, violating RFC 9110 Section 15.3.5.
In `olly-replica/apps/authz`, `httputil.py` rejects OPTIONS requests with 405 Method Not Allowed.
Its `build_server` dispatcher omits OPTIONS from Allow headers across policy evaluation and probe routes.
Its `send_json` helper emits Content-Type, Content-Length, and response bodies on 204 No Content responses.
In `scripts/jev-test-bot`, `spa-server.py` maps OPTIONS requests to 405 Method Not Allowed with truncated Allow headers.

## Proposed Changes

### 1. Netassert Controller OPTIONS Parity and Clean No-Content Responses
We update `d2-signalloom/apps/netassert-controller/server.py`.
We add OPTIONS method dispatch returning 204 No Content with `Allow: GET, HEAD, OPTIONS` on health probes.
We add OPTIONS method dispatch returning 204 No Content with `Allow: POST, DELETE, OPTIONS` on `/scan`.
We update 405 Method Not Allowed responses to advertise complete Allow headers including OPTIONS.
We update `send_error(501)` to dynamically inspect paths: route-specific Allow headers on valid routes, and 404 on unknown paths.
We update `_json` to omit Content-Type, Content-Length, and response bodies on 204 No Content responses while preserving Content-Length on non-204 empty bodies.
We harden `_drain_body` to decode chunked transfer encoding and mark connection close on oversized payloads.
We update unit tests in `d2-signalloom/apps/netassert-controller/test/test_controller.py` to assert OPTIONS preflight, route-specific Allow headers, chunked draining, and connection close.

### 2. Olly Replica AuthZ HTTP Utility Hardening
We update `olly-replica/apps/authz/authz/httputil.py`.
We update `send_json` to omit Content-Type, Content-Length, and body writes on 204 No Content responses while preserving Content-Length on non-204 responses.
We add OPTIONS handling in `_dispatch` returning 204 No Content with complete Allow headers computed from registered routes.
We update `send_error(501)` to return 405 with route-specific Allow headers on valid routes and 404 on unknown paths.
We harden `drain_body` with chunked transfer decoding and connection close on payloads exceeding 4 MiB.
We update `olly-replica/apps/authz/tests/test_authz.py` to assert OPTIONS preflight, complete Allow headers across GET and POST endpoints, and chunked draining.

### 3. Jev SPA Server OPTIONS Dispatch Parity
We update `scripts/jev-test-bot/spa-server.py`.
We implement `do_OPTIONS` returning 204 No Content with `Allow: GET, HEAD, OPTIONS` and empty body.
We update `_send_405` and `send_error` to advertise `Allow: GET, HEAD, OPTIONS` and close connection on oversized payloads.
We harden `_drain_body` with chunked transfer decoding and connection close on payloads exceeding 1 MiB.
We update `scripts/jev-test-bot/test_spa_server.py` to assert OPTIONS preflight, complete Allow headers, chunked draining, and oversized payload handling.

## Verification Plan
We run `PYTHONPATH=d2-signalloom/apps/netassert-controller pytest -v d2-signalloom/apps/netassert-controller/test`.
We run `pytest -v olly-replica/apps/authz/tests`.
We run `pytest -v scripts/jev-test-bot/test_spa_server.py`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
