# Proposal — Policy Engine and Daytona Coder Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom coordinates regulatory compliance verification and developer sandboxing.
The policy engine evaluates Open Policy Agent bundles, CEL assertions, and regulatory frameworks.
The hosted Daytona coder orchestrates isolated ephemeral developer workspaces.
Both services expose HTTP interfaces for agent governance, evaluation scans, and lifecycle management.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
In `policy-engine`, endpoints support OPTIONS returning 204 No Content.
However, 405 Method Not Allowed responses truncate Allow headers to `POST` or `GET, HEAD`.
The Allow headers omit OPTIONS across policy evaluation, compliance scans, summaries, and observations.
Furthermore, `HandleScanFleet` in `pkg/compliance/fleet_scan.go` rejects OPTIONS requests with 405 Method Not Allowed.
`HandleScanFleet` also omits deferred request body closure.
In `hosted-daytona-coder`, GET and DELETE `/workspaces/prune` return 405 Method Not Allowed with `Allow: POST`.
The endpoint supports OPTIONS returning `Allow: POST, OPTIONS`.
The 405 error responses violate RFC 9110 Allow header parity.

## Proposed Changes

### 1. Policy Engine Allow Parity and Fleet Scan OPTIONS Dispatch
We update `d2-signalloom/apps/policy-engine/handlers.go`.
We update `d2-signalloom/apps/policy-engine/compliance.go`.
We update `d2-signalloom/apps/policy-engine/main.go`.
We update `d2-signalloom/apps/policy-engine/observations.go`.
We update `d2-signalloom/apps/policy-engine/pkg/compliance/fleet_scan.go`.
We add OPTIONS dispatch returning 204 No Content to `HandleScanFleet`.
We ensure all 405 Method Not Allowed responses advertise `Allow: POST, OPTIONS` or `Allow: GET, HEAD, OPTIONS`.
We add early deferred request body closures across all handlers to eliminate socket leak risks.

### 2. Hosted Daytona Coder Prune Route Parity
We update `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`.
We ensure GET and DELETE `/workspaces/prune` advertise `Allow: POST, OPTIONS` on 405 responses.

### 3. Test Suite Expansion
We expand tests across `policy-engine` and `hosted-daytona-coder`.
We verify Allow header parity on 405 responses across compliance, policy, and observation suites.
We verify OPTIONS requests return 204 No Content for fleet scans and workspace pruning.

## Verification Plan
We execute targeted unit tests for each package.
We run `go test` in `d2-signalloom/apps/policy-engine`.
We run `go test` in `d2-signalloom/apps/hosted-daytona-coder`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
