# Proposal — Signal Loom Stun Sentinel and Probe Preservation Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom protects workloads through the Stun Sentinel daemon and probe preservation subsystems.
The Stun Sentinel daemon manages cgroup freeze enforcement, forensic captures, and health reporting.
When an agent pod freezes, probe preservation intercepts kubelet liveness probes.
This interception returns synthetic status to prevent premature node kills.
Both subsystems expose HTTP handlers across health, metrics, captures, and probe routes.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
In `signalloom-stun-sentinel`, `/healthz`, `/readyz`, `/captures`, and `/metrics` return 405 Method Not Allowed with `Allow: GET, HEAD`.
The endpoints support OPTIONS returning 204 No Content.
However, their 405 error responses omit OPTIONS from the Allow header.
In both sentinels, `syntheticProbeHandler` rejects OPTIONS requests with 405 Method Not Allowed.
This rejection breaks preflight validation from HTTP probe clients.
The synthetic probe handlers also omit deferred request body closure.
When callers provide unexpected request bodies, sockets risk descriptor leaks.

## Proposed Changes

### 1. Signal Loom Stun Sentinel Health Parity
We update `d2-signalloom/apps/signalloom-stun-sentinel/health.go`.
We ensure 405 Method Not Allowed responses advertise `Allow: GET, HEAD, OPTIONS`.
We add deferred request body closure to prevent socket leaks.

### 2. Synthetic Probe Preservation OPTIONS Dispatch
We update `d2-signalloom/apps/signalloom-stun-sentinel/probe.go`.
We update `d2-signalloom/apps/stun-sentinel/pkg/probe/probe.go`.
We add OPTIONS method handling returning 204 No Content with `Allow: GET, HEAD, OPTIONS`.
We ensure 405 Method Not Allowed responses advertise `Allow: GET, HEAD, OPTIONS`.
We add deferred request body closure to both handlers.

### 3. Test Suite Expansion
We expand tests across both sentinel packages.
We update `health_test.go` and `probe_test.go` in `signalloom-stun-sentinel`.
We update `probe_test.go` in `stun-sentinel/pkg/probe`.
We verify 204 No Content for OPTIONS and Allow header parity across all routes.

## Verification Plan
We execute targeted unit tests for each package.
We run `go test` in `d2-signalloom/apps/signalloom-stun-sentinel`.
We run `go test` in `d2-signalloom/apps/stun-sentinel/pkg/probe`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
