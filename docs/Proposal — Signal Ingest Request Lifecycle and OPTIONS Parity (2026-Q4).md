# Proposal — Signal Ingest Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom coordinates autonomous fleet containment and agent governance.
The signal ingest service collects observations, correlates actor graphs, and verifies audit event streams.
It exposes HTTP endpoints for observations, actors, delegations, coverage, telemetry, audit ingestion, and health probes.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers on 405 Method Not Allowed responses.
In signal ingest, HTTP handlers reject OPTIONS with 405 Method Not Allowed.
Furthermore, 405 Method Not Allowed responses advertise truncated Allow headers omitting OPTIONS.
These truncated headers span general handlers, authorization, delegations, subject rights, audit receivers, and telemetry routes.
Additionally, several endpoints omit early deferred request body closures.
Mutating endpoints defer body draining only after JSON decoding or authentication checks succeed.
Requests rejected with early errors leak socket descriptors under high throughput probe sweeps.

## Objectives
1. Support RFC 9110 Section 9.3.7 OPTIONS preflight returning 204 No Content with complete Allow headers.
2. Restore RFC 9110 Section 9.3.7 Allow header parity across all signal ingest handlers on 405 responses.
3. Ensure early deferred request body draining and closure on all HTTP handlers.
4. Update unit and contract tests to assert RFC 9110 compliant Allow headers.

## Proposed Changes

### 1. API Handlers OPTIONS and Allow Parity
We update `d2-signalloom/apps/signal-ingest/api/handlers.go`.
We add OPTIONS preflight handling returning 204 No Content with complete Allow headers.
We update 405 Allow headers to include OPTIONS on all observation, actor, correlation, and probe routes.
We add early deferred request body closures across all handlers to eliminate socket leak risks.

### 2. Authorization, Delegations, and Subject Rights Routes
We update `d2-signalloom/apps/signal-ingest/api/authorization.go`.
We update `d2-signalloom/apps/signal-ingest/api/promote.go`.
We update `d2-signalloom/apps/signal-ingest/api/revocation_handler.go`.
We update `d2-signalloom/apps/signal-ingest/api/erasure.go`.
We update `d2-signalloom/apps/signal-ingest/api/export.go`.
We add OPTIONS dispatch and update 405 Allow headers to include OPTIONS.
We ensure early deferred request body closures across all handlers.

### 3. Telemetry, Policy, and Audit Webhook Receivers
We update `d2-signalloom/apps/signal-ingest/api/telemetry_handler.go`.
We update `d2-signalloom/apps/signal-ingest/api/policy_routes.go`.
We update `d2-signalloom/apps/signal-ingest/api/audit/receiver.go`.
We update `d2-signalloom/apps/signal-ingest/api/audit/gke_adapter.go`.
We update `d2-signalloom/apps/signal-ingest/api/probe.go`.
We ensure OPTIONS support and full Allow header parity across all routes.

### 4. Test Suite Updates
We update test suites across `d2-signalloom/apps/signal-ingest/api`.
We update Allow header assertions to include OPTIONS across all method gating tests.
We add tests asserting 204 No Content responses for OPTIONS preflight requests.

## Verification Plan
We run unit and contract tests for signal ingest.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
