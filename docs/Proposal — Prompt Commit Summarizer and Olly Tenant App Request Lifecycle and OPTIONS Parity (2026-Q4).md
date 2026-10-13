# Proposal — Prompt Commit Summarizer and Olly Tenant App Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
Signal Loom operates prompt summarization and tenant replica services.
The prompt commit summarizer service condenses git commit diffs for LLM prompt context.
The Olly replica tenant application provides topology, telemetry, fault injection, and workload simulation.
Both microservices expose HTTP interfaces.
These interfaces handle health probes, operational metrics, and mutation commands.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
In prompt commit summarizer, 405 Method Not Allowed responses omit OPTIONS from Allow headers.
The health handler advertises `Allow: GET, HEAD` instead of `Allow: GET, HEAD, OPTIONS`.
The summarize handler advertises `Allow: POST` instead of `Allow: POST, OPTIONS`.
Furthermore, incoming mutating requests in `makeSummarizeHandler` omit deferred request body closure.
Early returns on unhandled CloudEvents, JSON decode errors, or LLM failures leave request bodies open.
In the Olly tenant application, routes reject RFC 9110 OPTIONS requests with 405 Method Not Allowed.
The tenant routes also return truncated Allow headers that omit OPTIONS.
Furthermore, mutating endpoints in tenant app omit deferred request body closure.
Under sustained traffic, unclosed bodies exhaust socket file descriptors.

## Proposed Changes

### 1. Prompt Commit Summarizer Hardening
We update `d2-signalloom/apps/prompt-commit-summarizer/main.go`.
We ensure `makeSummarizeHandler` defers `r.Body.Close()`.
We update 405 responses in health and summarize handlers to advertise `Allow: GET, HEAD, OPTIONS` and `Allow: POST, OPTIONS`.
This aligns health and summarize routes with RFC 9110.

### 2. Olly Tenant App Hardening
We update `olly-replica/apps/cmd/tenant-app/main.go`.
We add OPTIONS method handling returning 204 No Content across all registered routes.
We update `methodNotAllowed` calls to advertise `Allow: GET, HEAD, OPTIONS` or `Allow: GET, POST, OPTIONS`.
We ensure `faultHandler` defers `r.Body.Close()`.
This prevents socket leakage and ensures RFC 9110 compliance.

### 3. Test Suite Expansion
We expand tests in both microservices.
We verify Allow header parity across all routes.
We verify OPTIONS requests return 204 No Content.
We verify empty response bodies on OPTIONS responses.

## Verification Plan
We execute targeted unit tests for each package.
We run `go test` in `d2-signalloom/apps/prompt-commit-summarizer`.
We run `go test` in `olly-replica/apps/cmd/tenant-app`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
