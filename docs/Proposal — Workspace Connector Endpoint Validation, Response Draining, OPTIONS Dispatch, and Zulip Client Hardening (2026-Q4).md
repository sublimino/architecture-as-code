# Proposal: Workspace Connector Endpoint Validation, Response Draining, OPTIONS Dispatch, and Zulip Client Hardening

**Status:** Proposed  
**Date:** 2026-10-13  
**Author:** Signal Loom Security Team  
**Scope:** `d2-signalloom/apps/workspace-connector`, `d2-signalloom/apps/zulip-chat-agent`

## Executive Summary

This proposal hardens two integration services against request forgery, connection leaks, and API contract discrepancies.
The first service is `workspace-connector`.
The second service is `zulip-chat-agent`.
The changes prevent server-side request forgery through strict URL parsing.
They guarantee HTTP connection reuse through body draining.
They add RFC 9110 Section 9.3.7 OPTIONS method handling to HTTP endpoints.
They enforce strict numeric bounds and credential safety on the Zulip client.

## Problem Statement

Security evaluations revealed four vulnerabilities across integration components:

1. `workspace-connector` sends observation batches to an unvalidated `ingestURL`.
Malicious configurations or command arguments can point to arbitrary schemas or internal metadata services.
2. In `workspace-connector`, `pollAndIngest` closes HTTP response bodies without reading remaining payload bytes.
Unconsumed TCP socket streams cannot return cleanly to the Go runtime connection pool.
3. In `workspace-connector`, probe and management HTTP routes reject RFC 9110 OPTIONS requests with status 405.
They lack explicit HTTP 204 No Content responses with appropriate Allow header definitions.
4. In `zulip-chat-agent`, `ZulipClient` accepts arbitrary strings as base URLs without protocol verification.
Credential strings can include carriage returns or newline characters that alter HTTP authorization headers.
Additionally, `editMessage` accepts non-positive or non-integer message identifiers such as negative numbers or NaN.

## Proposed Changes

### 1. Workspace Connector Ingestion Endpoint Validation

In `d2-signalloom/apps/workspace-connector/main.go`:
- Validate the ingestion endpoint using `url.Parse`.
- Require the URL scheme to equal `http` or `https`.
- Require a non-empty host string.
- Reject invalid endpoints before issuing outbound HTTP requests.

### 2. HTTP Connection Body Draining

In `d2-signalloom/apps/workspace-connector/main.go`:
- Read and discard up to 4096 bytes from `resp.Body` before calling `resp.Body.Close()`.
- Ensure HTTP keep-alive connections return to the idle transport pool.

### 3. RFC 9110 OPTIONS Method Handling

In `d2-signalloom/apps/workspace-connector/main.go`:
- Respond with HTTP 204 No Content on OPTIONS requests for `/health`, `/healthz`, and `/readyz`.
Set the `Allow` header to `GET, HEAD, OPTIONS`.
- Respond with HTTP 204 No Content on OPTIONS requests for `/api/v1/workspace/status`.
Set the `Allow` header to `GET, HEAD, OPTIONS`.
- Respond with HTTP 204 No Content on OPTIONS requests for `/api/v1/workspace/poll` and `/api/v1/workspace/stun`.
Set the `Allow` header to `POST, OPTIONS`.
- Preserve existing Allow header values on HTTP 405 Method Not Allowed responses.

### 4. Zulip Client Validation and Message ID Safety

In `d2-signalloom/apps/zulip-chat-agent/src/zulip-client.ts`:
- Validate `config.url` with the `URL` constructor.
Require `protocol` to be `http:` or `https:`.
- Ensure `config.email` and `config.apiKey` contain no control characters or newlines.
- Validate that `messageId` passed to `editMessage` is a strictly positive safe integer.
- Validate that `stream` and `topic` in `sendMessage` are non-empty strings.
- Add unit tests verifying invalid URLs, credential tampering, and illegal message identifiers.

## Verification Plan

Verify the changes with automated test suites:
- Run `go test -v .` in `d2-signalloom/apps/workspace-connector`.
- Run `bun test` in `d2-signalloom/apps/zulip-chat-agent`.
- Validate documentation sync using `bats test/docs-index-sync.bats`.
- Validate documentation style using `scripts/docs-lint.sh`.
