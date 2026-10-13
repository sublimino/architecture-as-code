# Proposal — Fleet Manager Subsystems Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom coordinates autonomous fleet containment and agent lifecycle governance.
The fleet manager orchestrates agent rollouts, containment cascades, workload registration, and audit telemetry streams.
It exposes HTTP interfaces across management, workload registry, remote containment, consistency verification, and audit event streams.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers on 405 Method Not Allowed responses.
In `fleet-manager`, all endpoints support OPTIONS returning 204 No Content with `Allow: <methods>, OPTIONS`.
However, 405 Method Not Allowed responses truncate Allow headers to `POST` or `GET, HEAD`.
The 405 Allow headers omit OPTIONS across main, remote stun, workloads, consistency, and audit subsystems.
Furthermore, read endpoints omit early deferred request body closures.
Mutating endpoints defer body draining only after method checks succeed.
Requests rejected with 405 Method Not Allowed leak socket descriptors under high-throughput probe sweeps.

## Objectives
1. Restore RFC 9110 Section 9.3.7 Allow header parity across all `fleet-manager` endpoints on 405 Method Not Allowed.
2. Ensure early deferred request body draining and closure on all HTTP handlers.
3. Update contract and regression tests to assert RFC 9110 compliant Allow headers.

## Proposed Changes

### 1. Fleet Manager Main Handlers Allow Parity
We update `d2-signalloom/apps/fleet-manager/main.go`.
We change 405 Allow headers from `GET, HEAD` to `GET, HEAD, OPTIONS` on `/health`, `/healthz`, `/readyz`, `/api/v1/fleet/topology`, and `/api/v1/fleet/policies`.
We change 405 Allow headers from `POST` to `POST, OPTIONS` on `/api/v1/fleet/deploy`, `/api/v1/fleet/stun/`, `/api/v1/fleet/resume`, `/api/v1/fleet/scan`, `/api/v1/fleet/recover`, `/api/v1/fleet/reset`, and `/api/v1/fleet/policies/evaluate`.
We add early deferred request body closures across all handlers to eliminate socket leak risks.

### 2. Fleet Manager Remote Stun, Workloads, Consistency, and Audit Handlers
We update `d2-signalloom/apps/fleet-manager/remote_stun.go`.
We update `d2-signalloom/apps/fleet-manager/workload_handlers.go`.
We update `d2-signalloom/apps/fleet-manager/consistency.go`.
We update `d2-signalloom/apps/fleet-manager/audit_events.go`.
We ensure 405 Allow headers advertise `GET, HEAD, OPTIONS` or `POST, OPTIONS` matching OPTIONS preflight responses.
We add early deferred request body closures across all handlers.

### 3. Test Suite Updates
We update `d2-signalloom/apps/fleet-manager/callerauth_test.go`.
We update `d2-signalloom/apps/fleet-manager/remote_stun_test.go`.
We update `d2-signalloom/apps/fleet-manager/workload_registry_test.go`.
We update `d2-signalloom/apps/fleet-manager/consistency_test.go`.
We update `d2-signalloom/apps/fleet-manager/audit_events_test.go`.
We assert that 405 Method Not Allowed responses return complete Allow headers containing OPTIONS.

## Verification Plan
We execute targeted unit tests for `fleet-manager`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
