# Proposal: olly-authz JWT Validation, Permits Narrow-Only Type Safety, and ELK Search MCP Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `olly-replica/apps/authz/authz/jwtutil.py`, `olly-replica/apps/authz/authz/permits.py`, `olly-replica/apps/authz/authz/coin.py`, `olly-replica/apps/authz/authz/plainid.py`, `olly-replica/apps/authz/authz/eems.py`, `olly-replica/apps/cmd/elk-search-mcp/authz.go`

## Executive Summary

This proposal hardens the Olly authorization service and the ELK search MCP token verifier.
It prevents JWT signature and expiration bypass attacks caused by missing header verification and non-finite timestamps.
It enforces non-empty secret keys across token generation and validation.
It adds strict type guards and bounds to the narrow-only permission calculation.
It hardens the Policy Decision Point and Policy Information Point against malformed inputs and cascading failures.
It ensures that the ELK search MCP daemon fails closed when unconfigured.

## Problem Statement

Automated security sweeps identified four defects across `olly-replica/apps/authz` and `olly-replica/apps/cmd/elk-search-mcp`:

1. `jwtutil.py` skipped JWT header parsing during token decoding.
It did not verify the `alg` or `typ` header claims.
It permitted empty secret keys during token encoding and decoding.
It checked expiration with `claims.get("exp", 0) < now`.
Non-finite values such as positive infinity or NaN evaluated to false against numeric timestamps.
Tokens with infinite or NaN expiration claims bypassed expiration checks indefinitely.
2. `permits.py` crashed on non-list inputs or elements that were not dictionaries.
It crashed with conversion errors when encountering NaN or infinite limit values.
It interpreted boolean values as numeric limits.
3. `coin.py`, `plainid.py`, and `eems.py` accepted empty subjects and usernames.
Uncaught network or decoding errors during attribute retrieval crashed request processing.
4. `authz.go` in `elk-search-mcp` accepted unconfigured empty secrets.
It evaluated tokens with non-positive expiration values as unexpired.
It skipped header algorithm verification.

## Proposed Changes

### 1. olly-authz JWT Token Hardening

Update `jwtutil.py` in `olly-replica/apps/authz/authz/jwtutil.py`:
- Require non-empty string secrets for both `encode` and `decode`.
- Decode the JWT header and verify that `alg` is `HS256` and `typ` is `JWT`.
- Require `claims` to be a dictionary.
- Require `exp` to be a positive finite number that exceeds the current timestamp.
- Validate optional `nbf` and `iat` claims as positive finite numbers.
- Ensure all parsing or validation errors raise `ValueError` consistently.
- Require `ttl` in `encode` to be a positive finite number within thirty days.

### 2. Permits Narrow-Only Type Safety

Update `permits.py` in `olly-replica/apps/authz/authz/permits.py`:
- In `to_map`, ensure `permitted_actions` is a list and elements are dictionaries.
- Validate action names as non-empty strings.
- Validate limit values as non-negative finite numbers and reject booleans.
- In `intersect`, ensure `local_grants` is a dictionary.
- Preserve the narrow-only property without raising unhandled exceptions on malformed inputs.
- In `allows`, check input types safely.

### 3. Policy Decision and Information Point Robustness

Update `coin.py`, `plainid.py`, and `eems.py`:
- Validate that `acme_id` or `on_behalf_of` is a non-empty string bounded to 256 characters.
- Validate `username` and `action` query parameters and request bodies.
- Catch downstream communication failures in `plainid.py` and fail closed per action.
- Catch evaluation failures in `coin.py` and return HTTP 502 Bad Gateway with audit logging.

### 4. ELK Search MCP Token Verification

Update `authz.go` in `olly-replica/apps/cmd/elk-search-mcp/authz.go`:
- Verify that `secret` is non-empty and return an error immediately if unconfigured.
- Decode the header segment and verify that `alg` equals `HS256`.
- Require `c.Exp` to be strictly positive and greater than or equal to current time.
- Verify `c.Nbf` against the current time with clock skew tolerance.

## Verification Plan

Verify the changes with automated test suites:
- Run `pytest olly-replica/apps/authz/tests`.
- Run Go unit tests in `olly-replica/apps/cmd/elk-search-mcp`.
- Validate documentation sync using `bats test/docs-index-sync.bats`.
- Validate documentation formatting using `scripts/docs-lint.sh`.
