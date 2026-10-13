# Proposal — Fleet Manager Allow Parity and Test Suite Alignment (2026-Q4)

## Context
Fleet Manager orchestrates agent containment, workload status inspection, and policy evaluation within the Signal Loom control plane.
The service exposes HTTP endpoints for topology checks, policy queries, and mutating actions.
RFC 9110 Section 9.3.7 requires that servers supporting OPTIONS include it in advertised Allow headers.

## Problem Statement
The HTTP router implementation and `TestOPTIONS_Endpoints` in `main_test.go` advertise complete Allow headers including OPTIONS.
Read endpoints advertise `GET, HEAD, OPTIONS`.
Mutating endpoints advertise `POST, OPTIONS`.
However, legacy tests in `main_test.go` and `policy_engine_test.go` still assert truncated Allow headers on 405 Method Not Allowed responses.
These legacy assertions omit OPTIONS.
This mismatch causes `go test .` in `d2-signalloom/apps/fleet-manager` to fail.

## Objectives
1. Align legacy 405 Method Not Allowed test assertions in `main_test.go` with RFC 9110 Allow headers.
2. Align 405 Method Not Allowed test assertions in `policy_engine_test.go` with RFC 9110 Allow headers.
3. Ensure all tests in `d2-signalloom/apps/fleet-manager` pass with zero failures.

## Proposed Changes

### 1. Test Suite Reconciliation in main_test.go
Update `TestHandleTopology_MethodNotAllowed` to expect `Allow: GET, HEAD, OPTIONS`.
Update `TestHandleStun_MethodNotAllowed` to expect `Allow: POST, OPTIONS`.
Update `TestHandleDeploy_MethodNotAllowed` to expect `Allow: POST, OPTIONS`.
Update `TestHandlePolicies_HEADAndMethodNotAllowed` to expect `Allow: GET, HEAD, OPTIONS`.
Update `TestHandleMutating_MethodNotAllowed` to expect `Allow: POST, OPTIONS`.
Update `TestHandleTopology_HEADAndMethodNotAllowed` to expect `Allow: GET, HEAD, OPTIONS`.

### 2. Policy Route Test Reconciliation in policy_engine_test.go
Update `TestPolicyRoutes_Endpoints` POST `/api/v1/fleet/policies` assertion to expect `Allow: GET, HEAD, OPTIONS`.
Update HEAD `/api/v1/fleet/policies/evaluate` assertion to expect `Allow: POST, OPTIONS`.
Update GET `/api/v1/fleet/policies/evaluate` assertion to expect `Allow: POST, OPTIONS`.

## Verification Plan
1. Run `go test . -v` in `d2-signalloom/apps/fleet-manager` to confirm all tests pass cleanly.
2. Run `bats test/docs-index-sync.bats` to verify documentation index synchronization.
3. Run `./scripts/docs-lint.sh` to confirm documentation style compliance.
