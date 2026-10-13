# Proposal: Agent Trust A2A Token Validation, Socket Error Propagation, and CPAI Runtime Alignment

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-agent-trust/adapters/spire_workload_api.py`, `d2-agent-trust/a2a/service.py`, `d2-agent-trust/test/test_contracts.py`, `d2-signalloom/apps/docs-signalloom/src/content/docs/operate/cpai-runtime-proxy.mdx`

## Executive Summary

This proposal hardens the SPIFFE Workload API adapter and A2A service.
It closes critical timestamp bypass vulnerabilities in `d2-agent-trust`.
It rejects boolean values, non-finite floats, and negative timestamps in `nbf` and `exp` claims.
It bounds replay store `jti` length and entries against exhaustion attacks.
It propagates detailed socket error messages from `spire-agent`.
It aligns CPAI documentation with canonical Kubernetes deployment and service definitions.

## Problem Statement

Automated security sweeps identified four defects across `d2-agent-trust` and `d2-cpai`:

1. `a2a/service.py` accepted `float("inf")`, `float("nan")`, and boolean timestamps in `nbf` and `exp` claims.
Tokens with infinite expiry bypassed expiration checks.
Tokens with infinite expiry remained in the replay store indefinitely.
2. `adapters/spire_workload_api.py` discarded command stderr on execution failures.
Callers received generic errors without diagnostic details when the SPIRE socket was unavailable.
3. `adapters/spire_workload_api.py` accepted boolean and non-finite values for command timeouts.
4. `a2a/service.py` converted unsupported methods on unmapped paths to 405 Method Not Allowed instead of 404 Not Found.
5. `cpai-runtime-proxy.mdx` referenced `cpai-proxy` instead of canonical `cpai-runtime` resources.

## Technical Design

### Finite Timestamp Enforcement

In `d2-agent-trust/a2a/service.py`:
1. Enforce `math.isfinite()` on `nbf`, `exp`, and `now`.
2. Reject boolean types for timestamps.
3. Require positive numbers and `nbf <= now < exp`.
4. Validate `jti` strings within 512 characters in `ReplayStore`.

### SPIFFE Workload Adapter Resilience

In `d2-agent-trust/adapters/spire_workload_api.py`:
1. Check `math.isfinite()` and reject booleans for timeout values within `(0, 30]`.
2. Fall back to `/run/spire/sockets/agent.sock` when `SPIRE_AGENT_SOCKET` is empty.
3. Include stderr in `RuntimeError` on subprocess failure.
4. Verify SVID payloads contain valid dictionaries and tokens.

### Route Handling and CPAI Alignment

1. Return 404 Not Found without `Allow` headers for unsupported methods on unmapped routes in `a2a/service.py`.
2. Update `cpai-runtime-proxy.mdx` deployment, service, and log selector names to `cpai-runtime`.

## Verification Strategy

1. `pytest -v d2-agent-trust/test`
2. `bats test/docs-index-sync.bats`
3. `./scripts/docs-lint.sh "docs/Proposal — Agent Trust A2A Token Validation, Socket Error Propagation, and CPAI Runtime Alignment (2026-Q4).md"`
