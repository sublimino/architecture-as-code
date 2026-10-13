# Proposal: Cardvault Agent Endpoint Validation, Body Draining, and Stun Sentinel OPTIONS Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/cardvault-agent`, `d2-signalloom/apps/signalloom-stun-sentinel`

## Executive Summary

This proposal hardens two security microservices against request forgery, connection resource leaks, and HTTP specification discrepancies.
The first service is `cardvault-agent`.
The second service is `signalloom-stun-sentinel`.
The changes prevent server-side request forgery by validating endpoint URLs before issuing requests.
They ensure clean TCP socket recycling through HTTP response body draining.
They add RFC 9110 Section 9.3.7 OPTIONS method handling across health, metrics, and capture endpoints.

## Problem Statement

Security reviews identified three vulnerabilities in agent containment and telemetry services:

1. `cardvault-agent` accepts unvalidated URLs for OpenBao, Cardvault, and Signal Loom claim endpoints.
Malformed strings or unexpected protocols can trigger unintended network operations or internal service probing.
2. In `cardvault-agent`, HTTP response bodies in login, credential retrieval, card access, and auto-claim flows close without reading remaining bytes.
Unconsumed bytes prevent persistent HTTP keep-alive connections from returning to the connection pool.
3. In `signalloom-stun-sentinel`, HTTP endpoints reject RFC 9110 OPTIONS requests with status 405.
Routes for liveness, readiness, Prometheus metrics, and audit captures lack 204 No Content responses with Allow headers.

## Proposed Changes

### 1. Cardvault Agent Endpoint Validation

In `d2-signalloom/apps/cardvault-agent/main.go`:
- Implement a URL validator using `url.Parse`.
- Verify that URL schemes equal `http` or `https`.
- Verify that the hostname is non-empty.
- Validate `baoAddr`, `cardvaultURL`, and `claimURL` flags and environment configurations during startup.
- Validate destination endpoints before executing network requests.

### 2. HTTP Response Body Draining

In `d2-signalloom/apps/cardvault-agent/main.go` and `autoclaim.go`:
- Read and discard up to 4096 bytes before closing response bodies in `login`, `readCredentials`, `accessCardvault`, and `autoClaim`.
- Allow TCP socket reuse across successive polling runs.

### 3. Stun Sentinel RFC 9110 OPTIONS Parity

In `d2-signalloom/apps/signalloom-stun-sentinel/health.go`:
- Handle OPTIONS requests on `/health`, `/healthz`, and `/readyz` by returning HTTP 204 No Content.
Set the `Allow` header to `GET, HEAD, OPTIONS`.
- Handle OPTIONS requests on `/metrics` by returning HTTP 204 No Content with `Allow: GET, HEAD, OPTIONS`.
- Handle OPTIONS requests on `/captures` and `/captures/` by returning HTTP 204 No Content with `Allow: GET, HEAD, OPTIONS`.
- Preserve existing Allow header values on HTTP 405 Method Not Allowed responses.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/cardvault-agent`.
- Run `go test -v -run TestHealth .` in `d2-signalloom/apps/signalloom-stun-sentinel`.
- Validate documentation sync using `bats test/docs-index-sync.bats`.
- Validate documentation style using `scripts/docs-lint.sh`.
