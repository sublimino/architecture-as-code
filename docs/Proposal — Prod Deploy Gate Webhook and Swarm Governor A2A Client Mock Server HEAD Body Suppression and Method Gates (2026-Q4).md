# Proposal — Prod Deploy Gate Webhook and Swarm Governor A2A Client Mock Server HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `PRODDEPLOYGATEWEBHOOKSWARMGOVERNORA2A`  

## Executive Summary

Platform test harnesses must enforce strict HTTP contract compliance.
Mock servers often accept arbitrary verbs and leak response bodies on HEAD requests.
This proposal hardens prod-deploy-gate and swarm-governor services.
It establishes RFC 9110 compliant method gates and HEAD body suppression.

## Background and Context

The prod-deploy-gate service sends approval cards to webhooks.
Previously, webhook dispatch had zero dedicated test coverage.
Empty webhook URLs failed late in the network transport layer.
Mock webhook endpoints accepted any HTTP method without validation.
Mock endpoints leaked response payloads on HEAD requests.

The swarm-governor service coordinates agent task evaluation and dispatch.
Its A2A client communicates with remote agents via JSON-RPC 2.0.
Discovery endpoints and task endpoints require explicit method restrictions.
Mock agent servers in unit tests lacked RFC 9110 HEAD suppression.
Task status retrieval lacked success and method gate verification tests.

## Problem Statement

1. Webhook dispatch in prod-deploy-gate was completely untested.
2. Empty or whitespace webhook URLs performed unnecessary network requests.
3. Webhook mock endpoints did not enforce POST-only method restrictions.
4. Swarm governor mock agents permitted non-POST verbs on task endpoints.
5. Mock agent servers leaked bodies when answering HEAD probes.
6. A2A client tests lacked dedicated coverage for GetTask status queries.
7. Task submission edge cases lacked assertions for HEAD body suppression.

## Proposed Changes

### 1. Prod Deploy Gate Webhook Hardening

Add input validation to reject empty or whitespace webhook URLs immediately.
Create comprehensive unit tests in `webhook_test.go`.
Validate successful delivery and payload decoding.
Verify handling of cancelled contexts and network errors.
Verify proper propagation of HTTP error status codes.
Enforce POST-only method gates with `Allow: POST` headers on mock receivers.
Verify complete body suppression on HEAD requests across all HTTP status codes.

### 2. Swarm Governor A2A Client Mock Server Hardening

Wrap all mock HTTP servers in `client_test.go` with `headBodySuppressingMiddleware`.
Enforce method gating on agent card discovery endpoints.
Discovery routes must allow GET and HEAD while returning 405 on other methods.
Task execution and status endpoints must allow only POST.
Non-POST requests must return 405 Method Not Allowed with `Allow: POST`.
Add test coverage for `GetTask` successful responses and error paths.
Add explicit verification for HEAD request body suppression across mock servers.

### 3. Swarm Governor Task Lifecycle Hardening

Add unit tests for `handleSubmit` in `main_test.go`.
Verify rejection of invalid JSON payloads with 400 Bad Request.
Verify rejection of empty descriptions with 400 Bad Request.
Verify rejection of missing or unavailable agents with 502 Bad Gateway.
Verify successful task evaluation and dispatch with 202 Accepted.
Verify query of created tasks via GET and HEAD on `/tasks/{id}`.
Ensure HEAD requests return empty bodies across all success and error paths.

## Verification Plan

Run the complete Go test suite for prod-deploy-gate.
Run the complete Go test suite for swarm-governor and its a2a package.
Confirm all tests pass without regressions.
Run documentation index synchronization checks.
Run the documentation linting suite.
