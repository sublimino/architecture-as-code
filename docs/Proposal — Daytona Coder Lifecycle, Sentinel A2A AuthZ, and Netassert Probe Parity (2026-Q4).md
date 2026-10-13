# Proposal: Daytona Coder Lifecycle, Sentinel A2A AuthZ, and Netassert Probe Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/hosted-daytona-coder/`, `olly-replica/apps/sentinel/`, `d2-signalloom/apps/netassert-controller/`

## Executive Summary

This proposal hardens workspace lifecycle management, A2A token validation, and health probe parity across three platform services.
It adds explicit teardown and prune endpoints with tenant ID validation to `hosted-daytona-coder`.
It adds RFC 7515 header algorithm validation and strict numeric timestamp checks to `olly-sentinel` A2A authentication.
It enforces socket timeout limits and bounded teardown waits in `netassert-controller`.
It establishes `/livez` liveness probe parity across all three components.

## Problem Statement

Platform auditing identified several lifecycle and protocol inconsistencies:
1. `hosted-daytona-coder` lacked an explicit teardown endpoint, relying solely on DELETE. It had no HTTP prune endpoint for scheduled garbage collection. It did not validate tenant ID formats against DNS naming conventions or path traversal characters.
2. `olly-sentinel` A2A token decoding accepted non-HS256 algorithms if HMAC verification succeeded. It threw uncaught `TypeError` exceptions when expiration (`exp`) or not-before (`nbf`) claims contained non-numeric types. Top-level imports of cloud libraries also blocked offline test execution.
3. `netassert-controller` had unbounded socket timeout defaults on HTTP connections. Previous scan cleanup could hang indefinitely without bounded loop limits.
4. Kubernetes deployment manifests and services lacked uniform `/livez` probe endpoints.

## Technical Design

### Hosted Daytona Coder Lifecycle and Tenant Validation

In `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`:
1. `validateTenant` verifies tenant IDs match `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` and remain within 63 characters.
2. `POST /workspaces/{id}/teardown` terminates the specified workspace and sets its status to `terminated`.
3. `POST /workspaces/prune` prunes expired workspaces based on a configurable TTL query parameter.
4. Routing collisions on `/workspaces/prune` return 405 Method Not Allowed with `Allow: POST` for non-POST methods.
5. `GET /livez` and `HEAD /livez` are registered alongside existing probe routes.
6. A background prune ticker runs every five minutes with a 24-hour default TTL.
7. `entrypoint.sh` includes `--` delimiters in git checkout commands.

### Sentinel A2A AuthZ Token Validation and Offline Testing

In `olly-replica/apps/sentinel/olly_sentinel/authz.py`:
1. Token header verification rejects missing headers, unexpected algorithms (`none`, `RS256`), and invalid type claims. Only `HS256` is permitted.
2. The decoder validates that `exp`, `nbf`, and `iat` claims are real numeric timestamps and rejects boolean or string values.
3. Defensive helpers (`to_map`, `intersect`, `allows`) guard against malformed lists, missing dictionary keys, non-string actions, and negative numeric limits.
4. `olly_sentinel/__init__.py`, `agent.py`, `contracts.py`, `metrics.py`, and `orbit.py` use import fallbacks to support offline testing without Google ADK.
5. `GET /livez` and `HEAD /livez` routes are added to the metrics server in `main.py`.

### Netassert Controller Timeout Bounds and Probe Parity

In `d2-signalloom/apps/netassert-controller/server.py`:
1. `ControllerHandler` sets `timeout = 10.0` seconds to bound socket operations.
2. `_handle_scan` implements bounded deletion wait loops with maximum attempt limits, returning HTTP 409 Conflict if prior jobs cannot terminate cleanly.
3. Health probes accept `/livez` in addition to `/healthz` and `/readyz`.
4. Method gates ensure non-POST requests to `/scan` return HTTP 405 with `Allow: POST`.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/go GOCACHE=/tmp/gocache go test -v ./...` in `d2-signalloom/apps/hosted-daytona-coder`
2. `pytest olly-replica/apps/sentinel/tests/test_authz_ctx.py olly-replica/apps/sentinel/tests/test_redact.py`
3. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with respx --with-requirements olly-replica/apps/sentinel/requirements.txt pytest olly-replica/apps/sentinel/tests/`
4. `pytest d2-signalloom/apps/netassert-controller/test/test_controller.py`
5. `bats test/docs-index-sync.bats`
6. `./scripts/docs-lint.sh "docs/Proposal — Daytona Coder Lifecycle, Sentinel A2A AuthZ, and Netassert Probe Parity (2026-Q4).md"`
