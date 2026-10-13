# Proposal — Prod Deploy Gate, Stun Tcctl, and Triage CI Worker HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `PRODDEPLOYGATECALLERTRIAGE`  

## Executive Summary

Platform HTTP services and test harnesses must enforce strict RFC 9110 compliance.
Handlers must reject disallowed HTTP verbs with status 405 and Allow headers.
Responses to HEAD requests must never contain body bytes.
This proposal hardens prod-deploy-gate, stun-tcctl, and triage-ci-worker services.

## Background and Context

The prod-deploy-gate service gates production deployments with cryptographic tokens.
Previous test suites omitted PATCH verb checks on gate submission and approval routes.
Read routes for gate status lacked test verification for disallowed mutating methods.
The test harness lacked validation edge case coverage for tokens and approver identities.

The stun-tcctl tool controls host-side traffic severance for stunned agents.
Its HTTP trigger server isolates and releases veth network interfaces.
The test harness lacked PATCH verb checks across health and trigger routes.
Unmatched routes lacked explicit HEAD body suppression checks.
Non-veth device rejection and dry-run release semantics required dedicated test verification.

The triage-ci-worker service performs deterministic failure triage for CI runs.
Health probes and the root event handler lacked PATCH verb rejection tests.
The test suite lacked end-to-end verification of successful failure triage responses.

## Problem Statement

1. Gate request and approve endpoints lacked test coverage for PATCH method rejection.
2. Gate status routes lacked method rejection tests for POST, PUT, DELETE, and PATCH.
3. Prod deploy gate lacked tests for HEAD error body suppression across 400 and 404.
4. The test suite lacked coverage for invalid HMAC tokens and missing approvers.
5. Stun-tcctl lacked PATCH method gate checks on probes, metrics, and trigger routes.
6. Stun-tcctl lacked HEAD body suppression checks on unmatched paths.
7. Triage CI worker lacked PATCH method checks on health probes and root routes.
8. Triage CI worker lacked tests verifying successful failure triage payloads.

## Proposed Changes

### 1. Prod Deploy Gate Test Hardening

Harden `TestServer_HealthEndpoints` to test PUT, DELETE, and PATCH methods.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty body.
Harden `TestServer_MethodGates` with PATCH method checks on mutating routes.
Assert status 405 with `Allow: POST` and zero body bytes on HEAD.
Test POST, PUT, DELETE, and PATCH on `/gate/` and `/gate/{id}` with `Allow: GET, HEAD`.
Add `TestServer_ApproveValidationEdgeCases` covering malformed JSON and missing tokens.
Verify 400 Bad Request on empty approvers and 403 Forbidden on invalid HMAC tokens.
Verify 404 Not Found when approving nonexistent or already resolved gates.
Add `TestServer_GateHeadErrorBodySuppression` verifying zero body bytes on HEAD requests.
Verify 400 on missing gate IDs and 404 on nonexistent gates.
Add `TestWriteJSON_HEADBodySuppressionAcrossStatuses` covering eleven standard HTTP status codes.

### 2. Stun Tcctl HTTP Trigger Test Hardening

Add PATCH method rejection checks across `/health`, `/healthz`, `/readyz`, and `/metrics`.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD`.
Add PATCH method rejection checks on `/v1/isolate` and `/v1/release`.
Assert status 405 Method Not Allowed with `Allow: POST`.
Add `TestMuxUnmatchedRoutesHEAD` verifying 404 Not Found and zero body bytes.
Add `TestTriggerHandler_DryRunExecutionAndNonVethRejection` using dry-run loaders.
Verify 403 Forbidden when attempting isolation on non-veth devices like eth0 and lo.
Verify 500 Internal Server Error when isolating nonexistent veth interfaces.
Verify 200 OK on dry-run release calls demonstrating idempotent fail-open semantics.

### 3. Triage CI Worker Method Gates and Triage Tests

Harden `TestHealthAndProbeEndpoints` with PUT, DELETE, and PATCH checks.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD`.
Add PATCH method checks to `TestRootMethodNotAllowed` asserting `Allow: POST`.
Add `TestRootSuccessfulTriage` verifying 200 OK responses with real and flaky failures.
Add `TestMethodNotAllowed_DirectInvocationAndHEAD` asserting 405 with Allow headers.
Verify zero body bytes on HEAD requests to methodNotAllowed.

## Verification Plan

Run the Go test suite for prod-deploy-gate.
Run the Go test suite for stun-tcctl.
Run the Go test suite for triage-ci-worker.
Run the documentation index synchronization suite.
Run the documentation linting suite.
