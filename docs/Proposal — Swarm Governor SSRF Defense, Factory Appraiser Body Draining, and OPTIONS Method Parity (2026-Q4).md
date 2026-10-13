# Proposal: Swarm Governor SSRF Defense, Factory Appraiser Body Draining, and OPTIONS Method Parity

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/swarm-governor/main.go`, `d2-signalloom/apps/swarm-governor/main_test.go`, `d2-signalloom/apps/swarm-governor/a2a/client.go`, `d2-signalloom/apps/swarm-governor/a2a/client_test.go`, `d2-signalloom/apps/factory-appraiser/main.go`, `d2-signalloom/apps/factory-appraiser/main_test.go`

## Executive Summary

This proposal hardens swarm task dispatch and promotion appraisal services against network and protocol vulnerabilities.
It introduces strict URL scheme and host validation for agent discovery targets.
It enforces RFC 9110 Section 9.3.7 OPTIONS method handling across all HTTP endpoints.
It ensures comprehensive HTTP request body closing and response body draining.
It expands contract and unit test suites across `swarm-governor` and `factory-appraiser`.

## Problem Statement

Security and protocol compliance reviews identified several input validation and HTTP lifecycle gaps:
1. In `swarm-governor`, `handleSubmit` accepts arbitrary `agent_urls` in task submission payloads.
These URLs are contacted without verifying that their schemes are HTTP or HTTPS.
Attackers can specify non-HTTP schemes or internal cloud metadata endpoints.
2. In `swarm-governor`, `handleSubmit` omits closing the request body.
3. In `swarm-governor`, all endpoints reject RFC 9110 OPTIONS requests with status 405.
4. In `factory-appraiser`, `newMux` registers method-prefixed routes that return status 405 for OPTIONS requests.
5. In `factory-appraiser`, `appraiseHandler` and promotion validation handlers omit closing request bodies.

## Technical Design

### Swarm Governor Hardening

In `d2-signalloom/apps/swarm-governor/main.go`:
1. In `handleSubmit`, validate each URL in `req.AgentURLs`.
Each URL must be parsed using standard URL parsing.
The scheme must be either `http` or `https`.
The host must not be empty.
Invalid URLs return status 400 Bad Request.
2. Defer closing `r.Body` upon reading submission requests.
3. In `handleSubmit`, respond to `OPTIONS` requests with status 204 No Content and `Allow: POST, OPTIONS`.
Update non-POST rejections to report `Allow: POST, OPTIONS`.
4. In `handleGetTask`, `handleAgentCard`, `handleHealthz`, and `handleReadyz`, respond to `OPTIONS` with status 204 No Content and `Allow: GET, HEAD, OPTIONS`.
Update non-GET/HEAD rejections to report `Allow: GET, HEAD, OPTIONS`.

In `d2-signalloom/apps/swarm-governor/a2a/client.go`:
1. Validate base and agent URLs before initiating HTTP requests.
2. Drain response bodies on error or unexpected status codes before closing.

### Factory Appraiser Hardening

In `d2-signalloom/apps/factory-appraiser/main.go`:
1. Register explicit OPTIONS route handlers on `/health`, `/healthz`, `/readyz`, `/api/v1/factory/appraise`, and `/api/v1/factory/validate-promotion`.
2. Respond with status 204 No Content and accurate `Allow` header values.
3. Defer closing `r.Body` across appraisal and promotion validation handlers.

### Test Suite Extensions

1. Expand `main_test.go` and `client_test.go` in `swarm-governor` with OPTIONS method and URL validation test coverage.
2. Expand `main_test.go` in `factory-appraiser` with OPTIONS method test coverage across all registered routes.

## Verification Strategy

1. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/swarm-governor/...`
2. `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v ./d2-signalloom/apps/factory-appraiser/...`
3. `bats test/docs-index-sync.bats`
4. `./scripts/docs-lint.sh "docs/Proposal — Swarm Governor SSRF Defense, Factory Appraiser Body Draining, and OPTIONS Method Parity (2026-Q4).md"`
