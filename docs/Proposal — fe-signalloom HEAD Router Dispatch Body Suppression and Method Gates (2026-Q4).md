# Proposal: fe-signalloom HEAD Router Dispatch Body Suppression and Method Gates

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fe-signalloom/src/main.py`, `d2-signalloom/apps/fe-signalloom/src/demo_runner_main.py`, `d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py`

## Executive Summary

This proposal hardens `fe-signalloom` and demo-runner ASGI applications against protocol non-conformance.
It enforces RFC 9110 Section 6.4.1 response body suppression on all HEAD requests.
It enforces RFC 9110 Section 9.3.2 GET and HEAD parity by dispatching incoming HEAD requests to matching GET handlers.
This eliminates spurious 405 Method Not Allowed errors on standard read endpoints.
It preserves strict method gates and `Allow` headers on POST-only and GET-only routes.
It expands the test suite to systematically verify the full HTTP method matrix.

## Problem Statement

Automated sweeps identified protocol non-conformance in `fe-signalloom` and `demo_runner_main`:
1. In `fe-signalloom/src/main.py` and `demo_runner_main.py`, `HeadBodySuppressingMiddleware` forwarded raw HEAD methods to FastAPI.
2. In FastAPI and Starlette, endpoints registered via `@router.get(...)` only match GET unless declared otherwise.
3. Therefore, HEAD requests to router read endpoints failed with HTTP 405 Method Not Allowed instead of executing the GET handler.
4. This violated RFC 9110 Section 9.3.2, which mandates GET and HEAD support for resources.
5. `d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py` only exercised `/api/health` and nonexistent paths.
6. It omitted coverage for router read routes, POST-only transition routes, and unsupported verbs.

## Technical Design

### RFC 9110 Section 9.3.2 GET/HEAD Router Dispatch Parity

In `main.py` and `demo_runner_main.py`, `HeadBodySuppressingMiddleware` clones the ASGI scope for HEAD requests.
It sets `scope["method"] = "GET"` before delegating to downstream routers.
1. When the request targets a GET router endpoint, FastAPI matches the GET handler and executes authentication and business logic.
2. The outer `wrapped_send` ASGI callable intercepts `http.response.body` messages and sets `message["body"] = b""`.
3. This ensures zero body bytes reach the client per RFC 9110 Section 6.4.1.
4. When the request targets a POST-only endpoint, FastAPI rejects the GET method with HTTP 405 and sets `Allow: POST`.
5. The outer middleware suppresses the 405 error payload, returning an empty body with status 405.
6. When the request targets an unmapped route, FastAPI returns 404, and the outer middleware suppresses the 404 body.

### Method Matrix and Allow Headers

1. Read endpoints reject mutating verbs (POST, PUT, DELETE, PATCH) with HTTP 405 and an `Allow` header listing allowed methods.
2. Mutating endpoints reject non-matching verbs with HTTP 405 and an `Allow` header matching allowed methods.
3. HEAD requests to any endpoint never emit body bytes, across 200, 202, 401, 404, or 405 outcomes.

### Expanded Test Suite

The test suite in `d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py` expands:
1. Verification of GET and HEAD parity and zero-byte body suppression across router endpoints.
2. Verification of HTTP 405 and `Allow: POST` headers with zero body bytes on HEAD to POST-only endpoints.
3. Verification of HTTP 405 with non-empty error payloads for unsupported verbs on read and write routes.
4. Direct raw ASGI message inspection ensuring zero byte leakage across 200, 401, 404, and 405 outcomes.

## Verification Strategy

1. `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_head_response_suppression.py`
2. `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_health.py`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — fe-signalloom HEAD Router Dispatch Body Suppression and Method Gates (2026-Q4).md"`
