# Proposal: fe-signalloom Federation Proxy Empty Body and Header Propagation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/routers/federation.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_federation.py`

## Executive Summary

This proposal hardens the `fe-signalloom` federation reverse proxy (`proxy_federation_request`) against 502 Bad Gateway crashes caused by empty response bodies and unparseable JSON deserialization.
It safely handles HTTP 204 No Content, HTTP 304 Not Modified, HEAD responses, and empty upstream payloads without invoking JSON parsing.
It preserves critical upstream response headers.
These include RFC 9110 Section 15.5.6 `Allow` headers on 405 Method Not Allowed, `Location` on 201 Created, `ETag`, and `X-Tenant-ID`.
It adds `HEAD` to the supported methods on federation proxy routes.
It expands test coverage in `test_federation.py` to verify empty response body handling, 204 No Content status, and header propagation.

## Problem Statement

Automated sweeps identified three defects in `fe-signalloom`'s federation proxy:
1. In `src/routers/federation.py`, `proxy_federation_request` checks for JSON content-type and unconditionally calls `resp.json()` on upstream HTTP responses.
When upstream returns 204 No Content, 304 Not Modified, empty payloads, or HEAD responses, this check fails or `resp.json()` raises `json.JSONDecodeError`.
The proxy catches these errors and converts valid upstream responses into spurious 502 `invalid_upstream_response` failures.
2. The proxy handler returns `JSONResponse(..., headers={"Content-Type": "application/json"})`, stripping upstream headers.
Crucial headers such as `Allow`, `Location`, `ETag`, and `X-Tenant-ID` are dropped before reaching downstream consumers.
3. The `@router.api_route` decorators on lines 402-417 declare `methods=["GET", "POST", "PUT", "DELETE", "PATCH"]`, omitting `"HEAD"`.
Direct HEAD requests to federation endpoints outside ASGI middleware dispatch return HTTP 405 Method Not Allowed.

## Technical Design

### Empty Body and 204 No Content Handling

In `src/routers/federation.py`:
1. Check `resp.status_code == 204 or not resp.content or request.method == "HEAD"`.
2. If this condition holds, construct a `Response(status_code=resp.status_code, content=b"", headers=forwarded_headers)`.
3. Per RFC 9110 Section 15.3.5, do not attach `Content-Type` to 204 responses. Preserve `Content-Type` for non-204 responses with empty content (such as HEAD responses or 200/304).

### Header Forwarding and Method Support

1. Collect upstream headers matching `("allow", "etag", "location", "x-tenant-id", "retry-after")`.
2. On empty body / 204 / HEAD responses, include these headers in the returned `Response`.
3. On standard JSON responses, combine `{"Content-Type": "application/json"}` with the collected headers.
4. Add `"HEAD"` to the declared `methods` list on `proxy_federation_route` decorators.

### Test Suite Expansion

In `src/tests/test_federation.py`:
1. `test_federation_proxy_handles_204_no_content`: verifies that upstream 204 No Content returns 204 with empty body and no 502 crash.
2. `test_federation_proxy_handles_empty_body_and_head`: verifies that upstream 200 with empty body returns 200 with empty body.
3. `test_federation_proxy_propagates_allow_header_on_405`: verifies that upstream 405 Method Not Allowed forwards the `Allow` header.
4. `test_federation_proxy_propagates_location_and_etag_headers`: verifies that upstream 201 Created forwards `Location` and `ETag` headers.
5. `test_proxy_federation_request_direct_invocation_empty_and_204`: validates direct execution of `proxy_federation_request` with simulated empty and 204 responses.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest -v tests/test_federation.py`
2. `./scripts/signalloom-api-test.sh contract`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom Federation Proxy Empty Body and Header Propagation (2026-Q4).md"`
