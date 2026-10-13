# Proposal: CPAI Engineer Task Input Validation, Offline HTTP Method Gates, and RFC 9110 HEAD Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/cpai-engineer/main.go`, `d2-signalloom/apps/cpai-engineer/executor.go`, `d2-signalloom/apps/cpai-engineer/main_test.go`

## Executive Summary

This proposal hardens the `cpai-engineer` HTTP service against input injection, protocol non-conformance, and missing test coverage.
It validates repository and branch parameters against flag injection.
It adds double-dash delimiters to git subprocess executions.
It enforces HTTP method gates and `Allow` headers across all registered endpoints.
It verifies RFC 9110 Section 6.4.1 response body suppression for HEAD requests.
It establishes a comprehensive offline unit test suite in `main_test.go` that executes during standard test runs.

## Problem Statement

Automated security sweeps identified three defects in `cpai-engineer`:
1. In `main.go`, `POST /tasks` accepted repository and branch fields starting with a dash (`-`).
2. In `executor.go`, `ensureRepo` passed these strings directly to git clone and checkout without `--` delimiters, allowing argument injection.
3. In `acceptance_test.go`, the test suite was gated by `//go:build acceptance`, skipping all HTTP server tests during default `go test ./...` invocations.
4. HTTP method matrix coverage and `Allow` header assertions were absent across `/health`, `/healthz`, `/readyz`, `/tasks`, and `/tasks/{id}`.

## Technical Design

### Input Validation and Argument Injection Defenses

In `main.go`, `validateRepo` and `validateBranch` enforce boundaries:
1. `validateRepo` rejects empty strings, leading dashes, and strings exceeding 1024 characters.
2. `validateBranch` rejects leading dashes, path traversal (`..`), reflog syntax (`@{`), double slashes (`//`), and strings exceeding 255 characters.
3. In `executor.go`, git invocations include `--` delimiters before positional repository and branch arguments.

### HTTP Method Matrix and RFC 9110 Section 6.4.1 HEAD Body Suppression

1. Health probe endpoints (`/health`, `/healthz`, `/readyz`) serve GET and HEAD requests.
2. Mutating verbs (POST, PUT, DELETE, PATCH) on probe endpoints return HTTP 405 Method Not Allowed with `Allow: GET, HEAD`.
3. The `/tasks` endpoint serves POST for submission and GET/HEAD for listing.
4. Mutating verbs (PUT, DELETE, PATCH) on `/tasks` return HTTP 405 with `Allow: GET, HEAD, POST`.
5. The `/tasks/{id}` endpoint serves GET and HEAD.
6. Non-conforming verbs (POST, PUT, DELETE, PATCH) on `/tasks/{id}` return HTTP 405 with `Allow: GET, HEAD`.
7. HEAD requests across all statuses (200, 202, 400, 404, 405) emit zero body bytes via `headResponseWriter`.

### Offline Unit Test Suite

A new file `main_test.go` executes under default `go test ./...`:
1. `TestHealthProbes_MethodsAndHeadBodySuppression`: verifies GET, HEAD, and disallowed verbs across health probes.
2. `TestTasksSubmission_ValidationAndGates`: exercises input validation, error handling, task creation, and method gates on `/tasks`.
3. `TestTasksDetail_MethodsAndHeadParity`: verifies retrieval, 404 error suppression, and method gates on `/tasks/{id}`.
4. `TestAgentCard_MethodsAndHeadParity`: verifies agent card serving, 405 method rejection, and HEAD body suppression.
5. `TestUnmatchedRoutes_HeadBodySuppression`: validates 404 status and body suppression for unknown paths.
6. `TestHeadResponseWriter_Direct`: unit-tests response writing, header tracking, and body suppression across status codes.
7. `TestHeadBodySuppressingMiddleware_Direct`: validates pass-through and suppression behavior for wrapped handlers.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./...` in `d2-signalloom/apps/cpai-engineer`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -tags acceptance -v ./...` in `d2-signalloom/apps/cpai-engineer`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — CPAI Engineer Task Input Validation, Offline HTTP Method Gates, and RFC 9110 HEAD Parity (2026-Q4).md"`
