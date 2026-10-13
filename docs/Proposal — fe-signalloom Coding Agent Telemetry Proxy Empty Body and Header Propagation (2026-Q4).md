# Proposal: fe-signalloom Coding Agent Telemetry Proxy Empty Body and Header Propagation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/coding_agent_telemetry.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_coding_agent_telemetry.py`

## Executive Summary

This proposal hardens the `fe-signalloom` coding agent telemetry proxy (`_proxy_telemetry`) in `coding_agent_telemetry.py`.
It prevents upstream HTTP 204 No Content responses from emitting `{"raw": ""}` payloads in violation of RFC 9110.
It handles HTTP 205, 304, HEAD, and empty responses safely.
It preserves critical upstream response headers.
These headers include RFC 9110 Section 15.5.6 `Allow`, `Location`, `ETag`, `Retry-After`, and `X-Tenant-ID`.
It updates route return types to `Response`.
It expands test coverage in `test_coding_agent_telemetry.py` to verify empty response body handling and header propagation.

## Problem Statement

Automated scans identified three defects in `fe-signalloom`'s coding agent telemetry proxy in `src/coding_agent_telemetry.py`:
1. In `src/coding_agent_telemetry.py`, `_proxy_telemetry` executes `resp.json()` inside a `try` block that falls back to `{"raw": resp.text}`.
When upstream returns 204 No Content, `resp.json()` raises `ValueError`.
The fallback then builds a JSON object containing `{"raw": ""}` and returns `JSONResponse(status_code=204, content={"raw": ""})`.
This violates RFC 9110 Section 15.3.5, which mandates zero payload body for 204 No Content responses.
2. Non-JSON empty bodies or HEAD responses also trigger the generic fallback, creating artificial `{"raw": ""}` JSON payloads.
3. The proxy handler returns `JSONResponse` without propagating upstream headers.
Critical headers like `Allow` on 405 Method Not Allowed, `Location` on 201 Created, `ETag`, `Retry-After`, and `X-Tenant-ID` are discarded.

## Technical Design

### Empty Body, 204 No Content, and HEAD Handling

In `src/coding_agent_telemetry.py`:
1. Check `resp.status_code in (204, 205, 304) or not resp.content or method == "HEAD"` before parsing JSON.
2. If this condition holds, construct a `Response(status_code=resp.status_code, content=b"", headers=forwarded_headers)`.
3. Per RFC 9110 Section 15.3.5, omit `Content-Type` on 204 responses.
4. Preserve `Content-Type` for non-204 empty responses like HEAD or 304.
5. For non-empty responses, parse `resp.json()`. On error, fallback to `{"raw": resp.text}` only when text is present.

### Header Forwarding

1. Collect upstream headers matching `("allow", "etag", "location", "x-tenant-id", "retry-after", "x-request-id")`.
2. Include collected headers in all returned `Response` and `JSONResponse` instances.

### Test Suite Expansion

In `src/tests/test_coding_agent_telemetry.py`:
1. `test_coding_agent_telemetry_proxy_handles_204_no_content`: verifies that upstream 204 returns empty body without payload.
2. `test_coding_agent_telemetry_proxy_handles_empty_body`: verifies that empty body responses return empty content cleanly.
3. `test_coding_agent_telemetry_proxy_propagates_allow_header_on_405`: verifies `Allow` header propagation on 405 responses.
4. `test_coding_agent_telemetry_proxy_propagates_location_and_etag`: verifies `Location` and `ETag` forwarding on 201 responses.
5. `test_coding_agent_telemetry_proxy_propagates_retry_after_and_tenant`: verifies `Retry-After`, `X-Tenant-ID`, and `X-Request-ID` forwarding.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_coding_agent_telemetry.py`
2. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_event_types.py`
3. `./scripts/signalloom-api-test.sh contract`
4. `bats test/docs-index-sync.bats`
5. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom Coding Agent Telemetry Proxy Empty Body and Header Propagation (2026-Q4).md"`
