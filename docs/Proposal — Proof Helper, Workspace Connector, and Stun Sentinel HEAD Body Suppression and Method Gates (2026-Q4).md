# Proposal — Proof Helper, Workspace Connector, and Stun Sentinel HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `PROOFHELPERWORKSPACESTUNSENTINELHEAD`  

## Executive Summary

All platform HTTP microservices must enforce RFC 9110 compliance across endpoints.
Disallowed HTTP methods must receive status 405 Method Not Allowed with explicit Allow headers.
Responses to HEAD requests must never return response body bytes.
This proposal hardens proof-helper, workspace-connector, and stun-sentinel handlers and test suites.

## Background and Context

The proof-helper daemon provides agent-to-agent challenge validation and OpenBao JWT verification.
Its test suite previously tested GET, HEAD, and POST on probe and challenge routes.
The suite omitted PUT, DELETE, and PATCH methods across probes, challenge, and action routes.
The OpenBao mock server login endpoint lacked PUT, DELETE, and PATCH method tests.
Direct unit tests for the methodNotAllowed helper were absent.

The workspace-connector service synchronizes external reports and issues containment stun operations.
Its test suite checked GET and HEAD on probes and status routes.
The suite omitted POST, PUT, DELETE, and PATCH rejection assertions on probes and status routes.
The poll and stun routes lacked GET, PUT, DELETE, and PATCH method matrix checks.
The handlers lacked defense-in-depth method checks when invoked directly without ServeMux.

The stun-sentinel daemon enforces host cgroup containment and manages forensic snapshots.
Its test suite checked POST rejection on probe endpoints.
The suite omitted PUT, DELETE, and PATCH rejections across probe endpoints.
The authenticated stun, resume, and prune routes lacked PATCH method rejection tests.
The snapshots endpoints omitted non-POST method coverage and direct writeJSON unit verification.

## Problem Statement

1. Proof-helper probes, challenge, and a2a routes omitted PUT, DELETE, and PATCH checks.
2. Proof-helper OpenBao mock login endpoint omitted PUT, DELETE, and PATCH method assertions.
3. Proof-helper lacked direct unit tests for methodNotAllowed across request methods and nil requests.
4. Workspace-connector probes and status routes omitted POST, PUT, DELETE, and PATCH rejection checks.
5. Workspace-connector poll and stun routes omitted GET, PUT, DELETE, and PATCH rejection checks.
6. Workspace-connector handlers lacked direct method gating when invoked without ServeMux routing.
7. Workspace-connector lacked direct unit tests for headResponseWriter and middleware body suppression.
8. Stun-sentinel health probes omitted PUT, DELETE, and PATCH method rejection assertions.
9. Stun-sentinel action routes and snapshots routes lacked PATCH method rejection checks.
10. Stun-sentinel lacked direct unit tests for writeJSON verifying HEAD response body suppression.

## Proposed Changes

### 1. Proof Helper Test and Handler Hardening

Elevate `methodNotAllowed` to a package function.
Verify status 405, explicit Allow headers, and 0 body bytes on HEAD requests.
Expand `TestA2AHandlerHealthAndChallengeMethods` with PUT, DELETE, and PATCH checks on probes and challenge.
Expand `/a2a` route tests with GET, PUT, DELETE, and PATCH checks asserting `Allow: POST`.
Expand `TestOpenBaoMockMethodGatesAndHEADBodySuppression` with GET, PUT, DELETE, and PATCH checks on login.
Add `TestMethodNotAllowedDirect` testing GET, HEAD, and nil requests.

### 2. Workspace Connector Handler and Test Hardening

Add direct method gating in `handlePoll`, `handleStun`, `handleStatus`, `healthHandler`, and `readyHandler`.
Return status 405 Method Not Allowed with explicit Allow headers on disallowed methods.
Expand `TestServer_Routes` with POST, PUT, DELETE, and PATCH checks on probes and status routes.
Expand `TestHeadErrorBodySuppression` with GET, PUT, DELETE, and PATCH checks on poll and stun routes.
Add `TestDirectHandlerMethodRejectionAndHead` verifying direct handler method gating.
Add `TestWorkspaceConnectorHeadResponseWriterDirect` verifying body suppression across status codes.

### 3. Stun Sentinel Test Hardening

Expand `TestHealthMethodRejectionAndHead` with POST, PUT, DELETE, and PATCH checks on health probes.
Expand `TestSnapshotAndStunMethodGates` with PATCH method checks across stun, resume, and prune routes.
Add method matrix tests for `/quarantine/snapshots` and `/quarantine/snapshots/{id}` with disallowed methods.
Add `TestStunSentinelWriteJSONDirectAndHEAD` verifying writeJSON across status codes.
Confirm HEAD requests produce 0 body bytes across success, client error, and server error paths.

## Verification Plan

Run Go test suites for proof-helper, workspace-connector, and stun-sentinel using cached Go toolchain settings.
Verify docs index consistency with `bats test/docs-index-sync.bats`.
Verify style rules with `./scripts/docs-lint.sh`.
