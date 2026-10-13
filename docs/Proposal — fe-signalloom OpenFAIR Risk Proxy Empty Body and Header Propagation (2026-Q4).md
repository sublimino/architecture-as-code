# Proposal: fe-signalloom OpenFAIR Risk Proxy Empty Body and Header Propagation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/risk.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_risk.py`

## Executive Summary

This proposal hardens the `fe-signalloom` OpenFAIR risk proxy (`_proxy`) in `risk.py`.
It prevents RFC 9110 Section 15.3.5 payload emissions on HTTP 204 No Content, empty response bodies, and HEAD responses.
It preserves critical upstream response headers.
These include RFC 9110 Section 15.5.6 `Allow` headers on 405 Method Not Allowed, `Location` on 201 Created, `ETag`, and `X-Tenant-ID`.
It expands test coverage in `test_risk.py` to verify empty response body handling, 204 No Content status, and header propagation.

## Problem Statement

Automated sweeps identified two defects in `fe-signalloom`'s risk proxy in `src/risk.py`:
1. In `src/risk.py`, `_proxy` attempts `resp.json()` on upstream HTTP responses.
When upstream returns 204 No Content, empty payloads, or HEAD responses, `resp.json()` raises an exception.
The proxy catches `Exception` and assigns `content = {"raw": resp.text}`.
For a 204 response or empty payload, `resp.text` is empty, so `content` becomes `{"raw": ""}`.
Then it returns `JSONResponse(status_code=resp.status_code, content=content)`.
This returns a body on a 204 No Content response, violating RFC 9110 Section 15.3.5.
2. The proxy handler returns `JSONResponse` without propagating upstream headers.
Crucial headers such as `Allow`, `Location`, `ETag`, and `X-Tenant-ID` are dropped before reaching downstream consumers.

## Technical Design

### Empty Body and 204 No Content Handling

In `src/risk.py`:
1. Check `resp.status_code == 204 or not resp.content or method == "HEAD"`.
2. If this condition holds, construct a `Response(status_code=resp.status_code, content=b"", headers=forwarded_headers)`.
3. Per RFC 9110 Section 15.3.5, do not attach `Content-Type` to 204 responses. Preserve `Content-Type` for non-204 responses with empty content (such as HEAD responses or 200/304).

### Header Forwarding

1. Collect upstream headers matching `("allow", "etag", "location", "x-tenant-id", "retry-after")`.
2. On empty body, 204, or HEAD responses, include these headers in the returned `Response`.
3. On standard JSON responses, combine `{"Content-Type": "application/json"}` with the collected headers.

### Test Suite Expansion

In `src/tests/test_risk.py`:
1. `test_risk_proxy_handles_204_no_content`: verifies that upstream 204 No Content returns 204 with empty body and no error payload.
2. `test_risk_proxy_handles_empty_body_and_head`: verifies that upstream 200 with empty body returns 200 with empty body.
3. `test_risk_proxy_propagates_allow_header_on_405`: verifies that upstream 405 Method Not Allowed forwards the `Allow` header.
4. `test_risk_proxy_propagates_location_and_etag_headers`: verifies that upstream 201 Created forwards `Location` and `ETag` headers.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest -v tests/test_risk.py`
2. `./scripts/signalloom-api-test.sh contract`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom OpenFAIR Risk Proxy Empty Body and Header Propagation (2026-Q4).md"`
