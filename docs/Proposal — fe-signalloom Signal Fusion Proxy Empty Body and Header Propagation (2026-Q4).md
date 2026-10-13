# Proposal: fe-signalloom Signal Fusion Proxy Empty Body and Header Propagation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/signal_fusion.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_signal_fusion.py`

## Executive Summary

This proposal hardens the `fe-signalloom` Signal Fusion proxy (`_proxy`) in `signal_fusion.py`.
It prevents upstream HTTP 204 No Content, empty bodies, and non-JSON responses from raising JSON decode exceptions converted to 502.
It suppresses RFC 9110 Section 15.3.5 payload emissions on HTTP 204 No Content.
It preserves critical upstream response headers.
These include RFC 9110 Section 15.5.6 `Allow` headers on 405 Method Not Allowed, `Location` on 201 Created, `ETag`, `Retry-After`, `X-Tenant-ID`, and `X-Request-ID`.
It expands test coverage in `test_signal_fusion.py` to verify empty response body handling, 204 No Content status, and header propagation.

## Problem Statement

Automated sweeps identified three defects in `fe-signalloom`'s Signal Fusion proxy in `src/signal_fusion.py`:
1. In `src/signal_fusion.py`, `_proxy` executes `content = resp.json()` inside a `try` block that catches only specific network errors before a blanket `except Exception as exc: raise APIError(502, "upstream_unavailable", "signal-ingest proxy error")`.
When upstream returns 204 No Content, empty payloads, or HEAD responses, `resp.json()` raises `ValueError`.
This exception is caught by `except Exception`, converting successful 204 No Content responses, empty payloads, and HEAD checks into 502 Bad Gateway errors.
2. Non-JSON error bodies like 405 or 503 plain text raise `ValueError` on `resp.json()`.
The proxy catches this and converts it into 502 Bad Gateway, hiding the true status code.
3. The proxy handler returns `JSONResponse` without propagating upstream headers.
Crucial headers such as `Allow` (RFC 9110 Section 15.5.6), `Location` (RFC 9110 Section 10.2.2), `ETag`, `Retry-After`, and `X-Tenant-ID` are dropped before reaching downstream consumers.
4. If a 204 response were handled with `JSONResponse`, it would emit a JSON body on a 204 No Content response, violating RFC 9110 Section 15.3.5.

## Technical Design

### Empty Body, 204 No Content, and HEAD Handling

In `src/signal_fusion.py`:
1. Move `resp.json()` after status and content checks.
2. Check `resp.status_code in (204, 205, 304) or not resp.content or method == "HEAD"`.
3. If this condition holds, construct a `Response(status_code=resp.status_code, content=b"", headers=forwarded_headers)`.
4. Per RFC 9110 Section 15.3.5, do not attach `Content-Type` to 204 responses. Preserve `Content-Type` for non-204 responses with empty content (such as HEAD responses or 304 Not Modified).
5. For non-empty responses, attempt `resp.json()`. On `ValueError`, fallback to `content = {"detail": resp.text[:512]}`, preserving upstream status code instead of converting to 502.

### Header Forwarding

1. Collect upstream headers matching `("allow", "etag", "location", "x-tenant-id", "retry-after", "x-request-id")`.
2. On empty body, 204, 205, 304, or HEAD responses, include these headers in the returned `Response`.
3. On standard JSON responses, forward collected headers in `JSONResponse`.

### Test Suite Expansion

In `src/tests/test_signal_fusion.py`:
1. `test_signal_fusion_proxy_handles_204_no_content`: verifies that upstream 204 No Content returns 204 with empty body and no error payload.
2. `test_signal_fusion_proxy_handles_empty_body`: verifies that upstream with empty body returns empty body without synthesizing 502 error.
3. `test_signal_fusion_proxy_handles_non_json_upstream_error`: verifies that upstream non-JSON response preserves status code rather than becoming 502.
4. `test_signal_fusion_proxy_propagates_allow_header_on_405`: verifies that upstream 405 Method Not Allowed forwards the `Allow` header.
5. `test_signal_fusion_proxy_propagates_location_and_etag_headers`: verifies that upstream 201 Created forwards `Location` and `ETag` headers.
6. `test_signal_fusion_proxy_propagates_retry_after_and_tenant_headers`: verifies that upstream 429/503 forwards `Retry-After`, `X-Tenant-ID`, and `X-Request-ID`.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_signal_fusion.py`
2. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_signal_fusion_adversarial.py`
3. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_event_types.py`
4. `./scripts/signalloom-api-test.sh contract`
5. `bats test/docs-index-sync.bats`
6. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom Signal Fusion Proxy Empty Body and Header Propagation (2026-Q4).md"`
