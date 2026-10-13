# Proposal — Multi-Engine Stream Hardening and Tenancy Contradiction Defenses (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** fe-signalloom, policy-engine, d2-osramp-apps, olly-replica
**Tag:** ENGINESTREAM

## Context

Platform services enforce tenant isolation across HTTP proxies, policy evaluation engines, and background processors.
Slices must handle large payloads without exceeding Linux kernel argument limits.
In parallel, authorization modules must safely parse and encode query parameters.

## Problem statement

An audit revealed subtle tenancy bypass risks and buffer exhaustion bugs.
In `fe-signalloom`, using python `or` when evaluating tenant keys permitted malicious payloads containing both matching and foreign tenant identifiers.
Callers could supply foreign tenant IDs in query parameters or request bodies without rejection.
In the Go policy engine, `extractTenant` ignored `tenant_id` query parameters, missing header and query conflicts.
In `d2-osramp-apps`, `enhance_sbom_with_dependencies.sh` passed complete JSON dependency blocks across command line arguments.
Large dependency manifests risk exceeding the 128 KiB `MAX_ARG_STRLEN` limit, triggering `E2BIG` process termination.
In `olly-replica`, `plainid.py` formatted query parameters via string interpolation without percent-encoding.

## Proposed changes

First, enforce exhaustive tenant key inspection in `fe-signalloom`.
Check every instance of `tenant` and `tenant_id` across query parameters and body fields, rejecting mismatches with HTTP 403.
Second, expand `extractTenant` in the Go policy engine to validate both `tenant` and `tenant_id` parameters.
Detect contradictions between headers and query parameters, returning HTTP 403 on conflict.
Third, refactor `enhance_sbom_with_dependencies.sh` to read `package.json` directly using `jq --slurpfile`.
Streaming dependency manifests from disk avoids placing bulk data into command arguments.
Fourth, apply `urllib.parse.urlencode` in `olly-replica` to encode query parameters safely.

## Security and reliability impact

These defenses guarantee strict tenant isolation across nested proxy routes.
Attackers cannot bypass tenant checks by combining valid and foreign parameters.
Bill of materials processing remains stable under massive dependency manifests.
Safe URL encoding prevents query parameter injection and URL parse failures.

## Verification plan

Run pytest suites in `fe-signalloom` validating multi-key and repeated query rejection.
Run Go unit and contract tests in `policy-engine` verifying contradiction detection.
Verify JSON equivalence and stream safety in `enhance_sbom_with_dependencies.sh`.
Run unit tests across `olly-replica` verifying parameter encoding.
Execute documentation linting and index synchronization suites.
