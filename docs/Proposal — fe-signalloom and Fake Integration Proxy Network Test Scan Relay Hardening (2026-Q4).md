# Proposal: fe-signalloom and Fake Integration Proxy Network Test Scan Relay Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/api_compat.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_network_tests.py`, `d2-signalloom/apps/fake-integration-proxy/server.py`, `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`

## Executive Summary

This proposal hardens the network test scan relay across `fe-signalloom` and `fake-integration-proxy`.
It prevents upstream HTTP 204 No Content and empty bodies from raising JSON decode exceptions converted to 502.
It suppresses RFC 9110 Section 15.3.5 body payload emissions on HTTP 204 No Content.
It preserves critical upstream response headers.
These headers include RFC 9110 Section 15.5.6 `Allow`, `Location`, `Retry-After`, and `ETag`.
It updates `network_tests_scan` in `api_compat.py` to return `Response`.
It expands test coverage across both services to verify empty body handling, 204 No Content status, and header propagation.

## Problem Statement

Automated sweeps identified three defects across the network test scan proxy chain:
1. In `fake-integration-proxy/server.py`, `_trigger_netassert_scan` executes `json.load(response)` directly without checking status code or body length.
When `netassert-controller` returns 204 No Content or empty payloads, `json.load(response)` raises `ValueError`.
The exception is caught by `except (OSError, ValueError, error.URLError)`, converting successful 204 responses into 502 Bad Gateway errors.
2. In `fake-integration-proxy/server.py`, `_handle_network_tests_scan` calls `self._json(status, body)`, emitting a JSON body on 204 responses in violation of RFC 9110.
3. In `fe-signalloom/src/api_compat.py`, `network_tests_scan` calls `payload = response.json()` inside `try` block catching `(httpx.HTTPError, ValueError)`.
When upstream returns 204 No Content, empty bodies, or non-JSON text errors, it converts them into 502 upstream_unavailable.
4. Both handlers discard upstream response headers, dropping critical `Allow`, `Location`, and `Retry-After` headers.

## Technical Design

### Fake Integration Proxy Hardening

In `d2-signalloom/apps/fake-integration-proxy/server.py`:
1. In `_trigger_netassert_scan`, check `response.status in (204, 205, 304)` before reading JSON.
2. Safely read response bytes. If empty or 204, return empty payload dictionary.
3. Extract and return upstream headers including `Allow`, `Location`, and `Retry-After`.
4. In `_handle_network_tests_scan`, return empty body without `Content-Length` or JSON payload when status is 204 No Content.

### Frontend BFF Hardening

In `d2-signalloom/apps/fe-signalloom/src/api_compat.py`:
1. In `network_tests_scan`, inspect `response.status_code in (204, 205, 304) or not response.content`.
2. For 204 or empty responses, return `Response(status_code=response.status_code, content=b"", headers=forwarded_headers)`.
3. For non-empty responses, parse `response.json()`, falling back to `{"error": response.text[:512]}` on non-JSON payloads.
4. Collect and forward upstream headers `Allow`, `Location`, `Retry-After`, and `ETag`.

### Test Suite Expansion

1. In `fake-integration-proxy/test/test_proxy.py`, add tests verifying 204 No Content, empty bodies, and header propagation.
2. In `fe-signalloom/src/tests/test_network_tests.py`, add tests verifying 204 No Content, empty bodies, and header propagation.

## Verification Strategy

1. `python3 -m unittest d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`
2. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_network_tests.py`
3. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --project d2-signalloom/apps/fe-signalloom pytest d2-signalloom/apps/fe-signalloom/src/tests/test_resilience_dependency_faults.py`
4. `./scripts/signalloom-api-test.sh contract`
5. `bats test/docs-index-sync.bats`
6. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom and Fake Integration Proxy Network Test Scan Relay Hardening (2026-Q4).md"`
