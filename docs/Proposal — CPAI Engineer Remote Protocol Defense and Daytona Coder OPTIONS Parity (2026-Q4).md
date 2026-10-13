# Proposal: CPAI Engineer Remote Protocol Defense and Daytona Coder OPTIONS Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/cpai-engineer`, `d2-signalloom/apps/hosted-daytona-coder`

## Executive Summary

This proposal hardens two coding execution microservices against protocol injection, resource exhaustion, and HTTP specification gaps.
The first service is `cpai-engineer`.
The second service is `hosted-daytona-coder`.
The changes prevent remote code execution via git helper protocol injection.
They enforce positive token budget bounds to stop resource abuse.
They add deferred request body closure and draining to prevent socket leaks.
They implement RFC 9110 Section 9.3.7 OPTIONS method handling across all routes.

## Problem Statement

Security evaluations revealed four vulnerabilities across the coding harness services:

1. In `cpai-engineer`, `validateRepo` allows git remote helper protocols like `ext::` and `fd::`.
These protocols permit arbitrary shell command execution during git clone operations.
2. In `cpai-engineer`, `token_budget` lacks upper limit bounds checking.
Extremely large token budgets can lead to integer overflow or disproportionate resource consumption.
3. In both services, HTTP request bodies on mutating POST endpoints are decoded without deferred closing and draining.
Unconsumed body bytes on keep-alive connections leak socket file descriptors.
4. Both services reject RFC 9110 OPTIONS preflight requests with HTTP 405 Method Not Allowed.
Clients querying endpoint capabilities receive errors instead of HTTP 204 No Content with `Allow` headers.

## Proposed Changes

### 1. CPAI Engineer Remote Protocol and Budget Defense

In `d2-signalloom/apps/cpai-engineer/main.go`:
- In `validateRepo`, reject repositories starting with `ext::` or `fd::` protocol schemes.
- In `validateRepo`, reject carriage returns, newlines, and null bytes.
- In `POST /tasks`, enforce an upper limit of 1,000,000 tokens on `token_budget`.
- In `POST /tasks`, defer request body closing and drain remaining bytes into `io.Discard`.

### 2. CPAI Engineer RFC 9110 OPTIONS Parity

In `d2-signalloom/apps/cpai-engineer/main.go`:
- Register OPTIONS handlers for `/health`, `/healthz`, and `/readyz` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Register OPTIONS handler for `/tasks` returning HTTP 204 with `Allow: GET, HEAD, POST, OPTIONS`.
- Register OPTIONS handler for `/tasks/{id}` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Register OPTIONS handler for `/.well-known/agent-card.json` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.

### 3. Hosted Daytona Coder OPTIONS and Body Lifecycle Parity

In `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`:
- Register OPTIONS handlers for `/health`, `/healthz`, `/readyz`, and `/livez` returning HTTP 204 with `Allow: GET, HEAD, OPTIONS`.
- Register OPTIONS handler for `/workspaces` returning HTTP 204 with `Allow: GET, HEAD, POST, OPTIONS`.
- Register OPTIONS handler for `/workspaces/{id}` returning HTTP 204 with `Allow: GET, HEAD, DELETE, OPTIONS`.
- Register OPTIONS handler for `/workspaces/{id}/teardown` returning HTTP 204 with `Allow: POST, OPTIONS`.
- Register OPTIONS handler for `/workspaces/prune` returning HTTP 204 with `Allow: POST, OPTIONS`.
- Defer request body closing and drain up to 4096 bytes on `/workspaces`, `/workspaces/{id}/teardown`, and `/workspaces/prune`.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/cpai-engineer`.
- Run `go test -v .` in `d2-signalloom/apps/hosted-daytona-coder`.
- Run `bats test/docs-index-sync.bats`.
- Run `scripts/docs-lint.sh`.
