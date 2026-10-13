# Proposal — ELK Tools Method Gates, Authz Unhandled Verbs, Stun Health Content-Type, and Sentinel Stub Hardening (2026-Q4)

## Context and Motivation

Uniform HTTP method semantics and protocol fidelity are essential across platform services.
Monitoring systems dispatch GET and HEAD requests to evaluate service health and discover tools.
RFC 9110 requires an Allow header on every HTTP 405 Method Not Allowed response.
Health and tool discovery endpoints must support HEAD requests cleanly without emitting message bodies.
Test stubs must mirror production protocol semantics to prevent false test passes.
Socket address reuse prevents address binding collisions under rapid test cycles and restarts.

## Proposed Architectural Hardening

This proposal hardens four subsystems across the platform.

First, the ELK search MCP tool discovery route (`olly-replica/apps/cmd/elk-search-mcp/tools.go`) validates incoming HTTP methods.
The `/tools` route admits GET and HEAD verbs only.
Mutating verbs return 405 with `Allow: GET, HEAD`.
HEAD requests emit standard response headers and suppress JSON body serialization.

Second, the Authz HTTP utility server (`olly-replica/apps/authz/authz/httputil.py`) implements handlers for PUT, DELETE, PATCH, and OPTIONS.
Unhandled verbs route through the central dispatch mechanism.
Non-matching methods return 405 with RFC 9110 Allow headers instead of 501.

Third, the Stun Sentinel daemon health probe (`d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`) sets Content-Type headers on HEAD requests.
Both 200 OK and 503 degraded HEAD responses receive `Content-Type: application/json`.
This ensures complete header parity between GET and HEAD probes.

Fourth, the Sentinel ELK test stub (`olly-replica/apps/sentinel/tests/elk_stub.py`) implements standard health probe endpoints.
The `/health`, `/healthz`, and `/readyz` routes support GET and HEAD requests.
Invalid verbs on probes return 405 with `Allow: GET, HEAD`.
Invalid verbs on MCP and tool routes return 405 with `Allow: POST`.
The HTTP server class configures socket address reuse.

## Target Components and Concrete Changes

### 1. ELK Search MCP Tool Discovery Route Gates

Component path: `olly-replica/apps/cmd/elk-search-mcp/tools.go`.
The `/tools` handler checks request methods.
It returns 405 with `Allow: GET, HEAD` on non-GET and non-HEAD requests.
HEAD requests write headers and return immediately without body serialization.
Unit tests in `olly-replica/apps/cmd/elk-search-mcp/mcp_test.go` verify status codes, Allow headers, and empty HEAD bodies.

### 2. Authz Server Unhandled Verbs

Component path: `olly-replica/apps/authz/authz/httputil.py`.
The server request handler implements `do_PUT`, `do_DELETE`, `do_PATCH`, and `do_OPTIONS`.
Each method delegates to `_dispatch`.
Tests in `olly-replica/apps/authz/tests/test_authz.py` verify 405 rejections and Allow headers for unhandled verbs.

### 3. Stun Sentinel Health Probe Content-Type

Component path: `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`.
The `handleHealth` handler sets `Content-Type: application/json` on HEAD responses.
Unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main_test.go` verify Content-Type presence on HEAD.

### 4. Sentinel ELK Test Stub Hardening

Component path: `olly-replica/apps/sentinel/tests/elk_stub.py`.
The handler implements `/health`, `/healthz`, and `/readyz` endpoints.
It validates HTTP methods and returns 405 with RFC 9110 Allow headers.
The server class sets `allow_reuse_address` to true.
Unit tests in `olly-replica/apps/sentinel/tests/test_elk_stub_contracts.py` verify probes, method gates, and socket reuse.

## Verification Plan

1. Run Go unit tests in `olly-replica/apps/cmd/elk-search-mcp`.
2. Run pytest in `olly-replica/apps/authz`.
3. Run Go unit tests in `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel`.
4. Run pytest in `olly-replica/apps/sentinel/tests/test_elk_stub_contracts.py`.
5. Execute `scripts/docs-lint.sh` to confirm zero broken links or style violations.
