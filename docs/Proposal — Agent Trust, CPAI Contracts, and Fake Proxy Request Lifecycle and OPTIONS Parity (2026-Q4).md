# Proposal — Agent Trust, CPAI Contracts, and Fake Proxy Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom connects workloads across trust boundaries through the Agent Trust slice and the Fake Integration Proxy.
The Agent Trust receiver validates SPIFFE identities, OpenBao JWT roles, and platform-signed authorization contexts.
The CPAI slice deploys an OpenAI-compatible runtime proxy for governed model inference.
The Fake Integration Proxy simulates external integrations and serves discovery endpoints across the testing estate.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
In `d2-agent-trust`, `a2a/service.py` rejects OPTIONS requests with 405 Method Not Allowed.
Its 405 error responses advertise truncated Allow headers that omit OPTIONS.
Its request handlers omit body draining on error paths, risking socket corruption on persistent connections.
In `adapters/spire_workload_api.py`, `workload_api_socket` checks path existence but skips socket type validation.
Its error handler suppresses underlying exception chains with `from None`.
In `fake-integration-proxy`, `server.py` rejects OPTIONS requests across all routes with 405 Method Not Allowed.
Its Allow headers omit OPTIONS across health, agents, crypto proofs, trust topology, and network scan routes.
In `cpai-engineer`, mock LLM contracts enforce `Allow: POST` and reject OPTIONS preflight calls.
In `tools/harness-dash`, `cpai.ts` hardcodes accidental demo data across parsed sessions rather than extracting transcript metrics.

## Proposed Changes

### 1. Agent Trust A2A Receiver Parity and Token Bounds
We update `d2-agent-trust/a2a/service.py`.
We add OPTIONS method handling returning 204 No Content with `Allow: GET, HEAD, OPTIONS` on metadata routes.
We add OPTIONS handling returning 204 No Content with `Allow: POST, OPTIONS` on `/a2a`.
We update 405 Method Not Allowed responses to advertise complete Allow headers including OPTIONS.
We add request body draining on error paths and unsupported methods.
We validate SPIFFE ID formats, URL whitespace bounds, token validity intervals, and claim length limits.

### 2. SPIRE Workload Socket Validation
We update `d2-agent-trust/adapters/spire_workload_api.py`.
We verify that the Workload API socket path is a Unix domain socket.
We preserve execution exception chains using `from exc`.

### 3. Fake Integration Proxy Parity
We update `d2-signalloom/apps/fake-integration-proxy/server.py`.
We add OPTIONS dispatch returning 204 No Content across all endpoints.
We ensure 405 Method Not Allowed responses include OPTIONS in Allow headers.
We update unit tests in `test_proxy.py` to assert OPTIONS preflight and complete Allow headers.

### 4. CPAI LLM Contract and Harness Dashboard Hardening
We update `d2-signalloom/apps/cpai-engineer/llm_contract_test.go`.
We add OPTIONS handling returning 204 No Content with `Allow: POST, OPTIONS` to mock servers.
We verify OPTIONS preflight parity across OpenAI and Anthropic contract tests.
We update `tools/harness-dash/src/adapters/cpai.ts` to parse transcript tokens dynamically and eliminate hardcoded demo data.

## Verification Plan
We run `pytest -v d2-agent-trust/test`.
We run `PYTHONPATH=d2-signalloom/apps/fake-integration-proxy pytest -v d2-signalloom/apps/fake-integration-proxy/test`.
We run `CGO_ENABLED=0 go test -v ./...` in `d2-signalloom/apps/cpai-engineer`.
We run `bun test` in `tools/harness-dash`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
