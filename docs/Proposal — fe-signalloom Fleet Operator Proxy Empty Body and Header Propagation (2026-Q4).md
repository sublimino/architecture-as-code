# Proposal: fe-signalloom Fleet Operator Proxy Empty Body and Header Propagation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/fleet_operator.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_fleet_operator.py`

## Executive Summary

This proposal hardens the `fe-signalloom` fleet operator proxy (`_forward`) in `fleet_operator.py`.
It prevents RFC 9110 Section 15.3.5 payload emissions on HTTP 204 No Content and empty response bodies.
It preserves critical upstream response headers.
These include RFC 9110 Section 15.5.6 `Allow` headers on 405 Method Not Allowed, `Location` on 201 Created, `ETag`, `Retry-After`, `X-Tenant-ID`, and `X-Request-ID`.
It expands test coverage in `test_fleet_operator.py` to verify empty response body handling, 204 No Content status, and header propagation.

## Problem Statement

Automated sweeps identified two defects in `fe-signalloom`'s fleet operator proxy in `src/fleet_operator.py`:
1. In `src/fleet_operator.py`, `_forward` attempts `response.json()` on upstream HTTP responses from fleet-manager.
When upstream returns 204 No Content or empty payloads, `response.json()` raises `ValueError`.
The proxy catches `ValueError` and assigns `payload = {"detail": response.text[:512]}`.
For a 204 response or empty payload, `response.text` is empty, so `payload` becomes `{"detail": ""}`.
Then it returns `JSONResponse(status_code=response.status_code, content=payload)`.
This returns a body on a 204 No Content response, violating RFC 9110 Section 15.3.5.
2. The proxy handler returns `JSONResponse` without propagating upstream headers.
Crucial headers such as `Allow` (RFC 9110 Section 15.5.6), `Location` (RFC 9110 Section 10.2.2), `ETag`, `Retry-After`, `X-Tenant-ID`, and `X-Request-ID` are dropped before reaching downstream consumers.

## Technical Design

### Empty Body and 204 No Content Handling

In `src/fleet_operator.py`:
1. Check `response.status_code in (204, 205, 304) or not response.content`.
2. If this condition holds, construct a `Response(status_code=response.status_code, content=b"", headers=forwarded_headers)`.
3. Per RFC 9110 Section 15.3.5, do not attach `Content-Type` to 204 responses. Preserve `Content-Type` for non-204 responses with empty content (such as 304 Not Modified).

### Header Forwarding

1. Collect upstream headers matching `("allow", "etag", "location", "x-tenant-id", "retry-after", "x-request-id")`.
2. On empty body, 204, 205, or 304 responses, include these headers in the returned `Response`.
3. On standard JSON responses, forward collected headers in `JSONResponse`.

### Test Suite Expansion

In `src/tests/test_fleet_operator.py`:
1. `test_fleet_operator_proxy_handles_204_no_content`: verifies that upstream 204 No Content returns 204 with empty body and no error payload across recover and resume routes.
2. `test_fleet_operator_proxy_handles_empty_body`: verifies that upstream with empty body returns empty body without synthesizing fake `{"detail": ""}`.
3. `test_fleet_operator_proxy_propagates_allow_header_on_405`: verifies that upstream 405 Method Not Allowed forwards the `Allow` header.
4. `test_fleet_operator_proxy_propagates_location_and_etag_headers`: verifies that upstream 201 Created forwards `Location` and `ETag` headers.
5. `test_fleet_operator_proxy_propagates_retry_after_and_tenant_headers`: verifies that upstream 429/503 forwards `Retry-After`, `X-Tenant-ID`, and `X-Request-ID`.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_fleet_operator.py`
2. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_event_types.py`
3. `./scripts/signalloom-api-test.sh contract`
4. `bats test/docs-index-sync.bats`
5. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom Fleet Operator Proxy Empty Body and Header Propagation (2026-Q4).md"`
