# Proposal — CPAI Engineer, Hosted Daytona Coder, and Fleet Caller Auth HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `CPAIDAYTONAFLEETCALLERHEAD`  

## Executive Summary

Stateful harnesses and fleet dispatchers require strict HTTP contract compliance.
Missing method gates and unsuppressed HEAD response bodies violate RFC 9110 standards.
This proposal hardens cpai-engineer, hosted-daytona-coder, and fleet-manager test harnesses.
It establishes verified method restrictions, Allow headers, and complete HEAD body suppression.

## Background and Context

The cpai-engineer service implements in-cluster sandboxed coding harness workflows.
Its HTTP server serves task submission, task querying, agent card discovery, and health probes.
Mock LLM contract test servers simulate OpenAI and Anthropic upstream endpoints.
Previously, unit test suites lacked assertions for method rejection and HEAD error handling.

The hosted-daytona-coder service provisions isolated devcontainer workspaces on Kubernetes.
It validates persistent volume claims, branch names, and tenant isolation identifiers.
Prior tests validated positive flows and 404 responses on HEAD requests.
However, tests lacked validation of method gates on workspace endpoints and health probes.
Tests also lacked verification of HEAD body suppression across validation and capacity errors.

The fleet-manager service enforces caller key scopes across mutating and read routes.
Mutating routes require bearer tokens and specific capabilities.
Prior tests checked unauthenticated POST requests but omitted HEAD and unsupported methods.
Read endpoints and mutating endpoints required verification of RFC 9110 compliance.

## Problem Statement

1. CPAI engineer tests omitted method gate validation for task and health endpoints.
2. Mock LLM endpoints did not verify HEAD response body suppression on errors.
3. Hosted Daytona coder tests omitted method gate checks on workspace endpoints.
4. Daytona coder tests omitted HEAD body suppression on 400, 403, and 503 errors.
5. Fleet manager caller auth tests omitted HEAD body suppression on 401 and 403.
6. Fleet manager tests omitted method gate checks on authorized mutating endpoints.

## Proposed Changes

### 1. CPAI Engineer Method Gates and HEAD Body Suppression

Add `TestCpaiEngineer_MethodGatesAndHEADBodySuppression` to `executor_test.go`.
Verify that `/tasks` rejects PUT, DELETE, and PATCH with 405 and Allow headers.
Verify that `/tasks/{id}` rejects POST, PUT, DELETE, and PATCH with 405.
Verify that `/.well-known/agent-card.json` rejects POST, PUT, and DELETE with 405.
Verify that health endpoints reject POST, PUT, and DELETE with 405.
Verify that HEAD requests on 404 and error status codes return zero body bytes.
Wrap mock LLM servers in `llm_contract_test.go` with `headBodySuppressingMiddleware`.
Add `TestLLM_MockServer_HEADBodySuppressionAcrossStatuses` across ten standard status codes.

### 2. Hosted Daytona Coder Method Gates and Error Body Suppression

Add `TestWorkspaceManager_MethodGates` to `workspace_manager_test.go`.
Verify that `/workspaces` rejects PUT, DELETE, and PATCH with 405 and Allow headers.
Verify that `/workspaces/{id}` rejects POST, PUT, and PATCH with 405 and Allow headers.
Verify that health endpoints reject POST, PUT, and DELETE with 405 and Allow headers.
Add `TestHeadErrorBodySuppression_AllStatuses` to `workspace_manager_test.go`.
Verify HEAD body suppression on 400 validation failures and 403 cross-tenant conflicts.
Verify HEAD body suppression across all standard error codes via middleware.

### 3. Fleet Manager Caller Auth Method Gates and HEAD Body Suppression

Add `TestCallerAuth_MethodGatesAndHEADBodySuppression` to `callerauth_test.go`.
Verify unauthenticated HEAD on mutating routes returns 401 with zero body bytes.
Verify unauthenticated HEAD retains the required `WWW-Authenticate: Bearer` challenge header.
Verify insufficient scope HEAD on mutating routes returns 403 with zero body bytes.
Verify authorized mutating requests with GET and HEAD return 405 with `Allow: POST`.
Verify read routes return 200 with zero body bytes on HEAD.
Verify read routes reject POST, PUT, and DELETE with 405 and `Allow: GET, HEAD`.

## Verification Plan

Run unit test suites for cpai-engineer using `go test`.
Run unit test suites for hosted-daytona-coder using `go test`.
Run unit test suites for fleet-manager using `go test`.
Confirm all tests pass without failures or race conditions.
Run documentation index synchronization check with bats.
Run documentation linting script across all repository documents.
