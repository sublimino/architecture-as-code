# Proposal: fe-signalloom Mutable Response Default Isolation and Header Sanitation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/api_compat.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_agents.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_crypto_health.py`

## Executive Summary

This proposal eliminates mutable default argument antipatterns across `fe-signalloom` API endpoints.
It replaces module-level `response: Response = Response()` defaults with nullable parameters and per-request instance allocations.
This prevents cross-request header retention and cross-tenant metadata bleeding.
It ensures that mutated response headers remain strictly isolated to the originating call context.
It hardens `crypto_health` against HTTP 204 No Content and empty body upstream responses.
It expands regression tests to verify that repeated calls never leak mutated headers.

## Problem Statement

Static analysis identified three endpoints in `fe-signalloom/src/api_compat.py` with mutable default arguments:
1. `get_capabilities`: `response: Response = Response()` at line 4292.
2. `agents`: `response: Response = Response()` at line 4589.
3. `crypto_health`: `response: Response = Response()` at line 4962.

Default parameter expressions in Python evaluate exactly once when the module imports.
When these functions run directly or without explicit response arguments, every call shares one instance.
When an endpoint sets `response.headers["X-Source-Health"] = "healthy"`, that header persists across subsequent calls.
This allows headers modified in one tenant request to bleed into subsequent requests.

Additionally, `crypto_health` executes `res.json()` directly on the upstream prover response.
When upstream returns HTTP 204 No Content or empty bytes, `res.json()` raises `ValueError`.
The exception handler converts this valid response into HTTP 503 upstream_unavailable.

## Technical Design

### Mutable Response Default Elimination

In `d2-signalloom/apps/fe-signalloom/src/api_compat.py`:
1. Change the signature of `get_capabilities` to `response: Response = None`.
Allocate a fresh `Response` instance when `response is None`.
Set both `X-Source-Health` and `source_health` headers on the allocated response.
2. Change the signature of `agents` to `response: Response = None`.
Allocate a fresh `Response` instance when `response is None`.
Set both `source_health` and `X-Source-Health` headers on the allocated response.
3. Change the signature of `crypto_health` to `response: Response = None`.
Allocate a fresh `Response` instance when `response is None`.
Set both `source_health` and `X-Source-Health` headers on the allocated response.

### Empty Body and Status Resilience in crypto_health

In `d2-signalloom/apps/fe-signalloom/src/api_compat.py`:
1. Inspect upstream status code and content bytes before decoding JSON.
2. If status code is 204, 205, or 304, or content is empty, yield an empty proof list.
3. Preserve HTTP 503 upstream_unavailable for real transport and connectivity failures.

### Regression Testing

1. In `fe-signalloom/src/tests/test_agents.py`, verify that consecutive calls to `agents` never leak headers.
2. In `fe-signalloom/src/tests/test_crypto_health.py`, verify that consecutive calls isolate response headers.
3. In `fe-signalloom/src/tests/test_crypto_health.py`, verify that HTTP 204 No Content returns empty proofs without 503 errors.

## Verification Strategy

1. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests/test_agents.py`
2. `UV_CACHE_DIR=/tmp/uv-cache UV_CONFIG_FILE=/dev/null uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests/test_crypto_health.py`
3. `./scripts/signalloom-api-test.sh contract`
4. `bats test/docs-index-sync.bats`
5. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom Mutable Response Default Isolation and Header Sanitation (2026-Q4).md"`
