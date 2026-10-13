# Proposal: prod-deploy-gate Token Bounds, Webhook SSRF Guard, and Cardvault Authentication Isolation

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/prod-deploy-gate/token.go`, `d2-signalloom/apps/prod-deploy-gate/main.go`, `d2-signalloom/apps/prod-deploy-gate/webhook.go`, `d2-signalloom/apps/cardvault/main.go`

## Executive Summary

This proposal hardens the `prod-deploy-gate` deployment approval service and the `cardvault` service.
It prevents token signature bypass attacks from trailing dot segment injection.
It bounds approval request identifiers and prevents empty secret calculation.
It rejects non-HTTP webhook schemes to prevent server-side request forgery attacks.
It enforces fail-closed behavior on unconfigured credentials in `cardvault`.
It eliminates path traversal flaws in `cardvault` card retrieval.
It adds complete RFC 9110 HTTP method handling across both microservices.

## Problem Statement

Automated security sweeps identified five defects across `prod-deploy-gate` and `cardvault`:

1. `token.go` used `strings.SplitN(token, ".", 2)` during token validation.
Tokens with trailing dot segments passed validation if the prefix matched.
`ValidateToken` did not verify non-empty secrets.
It accepted non-positive timestamp values and empty request identifiers.
2. `main.go` in `prod-deploy-gate` accepted unbounded strings for requester, description, and approver fields.
Unbounded inputs risk memory saturation and log injection.
3. `webhook.go` accepted arbitrary webhook URLs without scheme validation.
Callers could pass local file URLs or non-HTTP protocols.
4. `cardvault` allowed unauthenticated access when configured with empty credentials.
An empty Basic Auth header matched empty server credentials.
5. `cardvault` permitted path traversal via `..` in card query paths.
Requests to `/api/v1/cards/card-001/../../cards` returned HTTP 200 instead of HTTP 404.

## Proposed Changes

### 1. prod-deploy-gate Token Validation

Update `ValidateToken` in `token.go` to split tokens using `strings.Split(token, ".")`.
Require exactly two dot-separated segments.
Verify non-empty secret keys.
Reject non-positive or zero expiry timestamps.
Reject empty request identifiers extracted from decoded payloads.
In `GenerateToken`, require positive duration values below 24 hours.

### 2. Request Bounds and Identifier Formatting

Enforce length limits on all user-supplied input fields in `main.go`:
- Requester: maximum 256 characters.
- Approver: maximum 256 characters.
- Description: maximum 4096 characters.
- Environment: maximum 64 characters.
- Request identifier: maximum 128 characters matching alphanumeric characters, hyphens, and underscores.

### 3. Webhook SSRF Prevention

In `webhook.go`, parse webhook URLs with `url.Parse`.
Require the scheme to be `http` or `https`.
Require a non-empty host component.
Drain and close response bodies up to 4096 bytes to enable HTTP connection reuse.

### 4. Cardvault Authentication Fail-Closed

In `cardvault/main.go`, update `requireAuth` to verify non-empty username and password strings.
If either server credential is empty, return HTTP 500 Internal Server Error immediately.

### 5. Cardvault Path Traversal Guard

Add path validation in `cardvault/main.go`.
Reject any request containing `..` or slashes in the card identifier with HTTP 404 Not Found.
Ensure requests to non-existent card identifiers always return HTTP 404.

## Verification Plan

Verify the implementation with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/prod-deploy-gate`.
- Run `go test -v .` in `d2-signalloom/apps/cardvault`.
- Validate documentation sync using `bats test/docs-index-sync.bats`.
- Validate documentation style using `scripts/docs-lint.sh`.
