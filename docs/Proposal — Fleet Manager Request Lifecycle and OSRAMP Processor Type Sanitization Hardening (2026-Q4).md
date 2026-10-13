# Proposal: Fleet Manager Request Lifecycle and OSRAMP Processor Type Sanitization Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/fleet-manager`, `d2-osramp-apps/apps/processor`

## Executive Summary

This proposal hardens the fleet management control plane and the OSRAMP task processor against resource leakage, protocol mismatches, and log injection.
The first service is `fleet-manager`.
The second service is `osramp-apps/processor`.
The changes prevent TCP socket descriptor leaks by closing and draining HTTP request bodies.
They implement RFC 9110 Section 9.3.7 OPTIONS method handling across all HTTP endpoints.
They permit preflight OPTIONS requests without bearer credentials.
They sanitize task types in the processor to prevent log injection and command execution defects.

## Problem Statement

Security evaluations revealed three issues across fleet management and task processing services:

1. In `fleet-manager`, HTTP endpoints reject preflight RFC 9110 OPTIONS requests with HTTP 405 Method Not Allowed or HTTP 401 Unauthorized.
Clients probing endpoint capabilities receive error responses rather than HTTP 204 No Content with `Allow` headers.
2. In `fleet-manager`, mutating POST endpoints process JSON request bodies without deferred closing and draining.
Unconsumed body bytes on persistent connections prevent TCP socket recycling and lead to socket exhaustion.
3. In `osramp-apps/processor`, `consumeTasks` and `prepareTaskCommand` handle unvalidated `task.Type` strings.
Malicious task messages containing control characters, carriage returns, or newlines cause log injection and corrupted process environments.

## Proposed Changes

### 1. Fleet Manager RFC 9110 OPTIONS Parity

In `d2-signalloom/apps/fleet-manager`:
- In `callerauth.go`, allow unauthenticated preflight `OPTIONS` requests through `require` and `requireAny` without HTTP 401 errors.
- In `main.go`, handle `OPTIONS` on `/health`, `/healthz`, `/readyz`, `/api/v1/fleet/topology`, `/api/v1/fleet/policies`, `/api/v1/fleet/audit/events`, and `/api/v1/fleet/audit/stream` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `main.go`, handle `OPTIONS` on `/api/v1/fleet/deploy`, `/api/v1/fleet/stun/`, `/api/v1/fleet/resume`, `/api/v1/fleet/scan`, `/api/v1/fleet/recover`, `/api/v1/fleet/reset`, and `/api/v1/fleet/policies/evaluate` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `workload_handlers.go`, handle `OPTIONS` on `/api/v1/fleet/workloads` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `workload_handlers.go`, handle `OPTIONS` on `/api/v1/fleet/workloads/report` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `remote_stun.go`, handle `OPTIONS` on `/api/v1/fleet/stun-state` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- In `remote_stun.go`, handle `OPTIONS` on `/api/v1/fleet/stun-state/ack` returning HTTP 204 with `Allow: POST, OPTIONS`.
- In `consistency.go`, handle `OPTIONS` on `/consistency` and `/metrics` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Preserve existing Allow header values on HTTP 405 responses for contract compatibility.

### 2. Fleet Manager HTTP Request Body Draining

In `d2-signalloom/apps/fleet-manager`:
- In `handleDeploy`, `handleStun`, `handleRecover`, `handleResume`, `handleScan`, `handleReset`, and `handlePolicyEvaluate`, add deferred body closing.
- In `handleWorkloadReport` and `handleRemoteStunAck`, add deferred body closing.
- Drain unread bytes up to 4096 bytes into `io.Discard` before closing each request body.

### 3. OSRAMP Processor Task Type Sanitization

In `d2-osramp-apps/apps/processor/processor.go`:
- Introduce `sanitizeTaskType` to validate `task.Type` against invalid characters, control characters, carriage returns, and newlines.
- Bound task type length to 64 characters and default empty or invalid values to `generic`.
- In `consumeTasks`, sanitize both `task.ID` and `task.Type` immediately upon parsing.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/fleet-manager`.
- Run `go test -v .` in `d2-osramp-apps/apps/processor`.
- Run `bats test/docs-index-sync.bats`.
- Run `scripts/docs-lint.sh`.
