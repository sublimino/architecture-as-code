# Proposal — Olly ELK Search MCP and Mapping Stub Request Lifecycle and OPTIONS Parity (2026-Q4)

## Context
The Olly Sentinel replica includes observability MCP tools and the mapping stub service.
The ELK search MCP tool queries Elasticsearch logs, metrics, traces, and drift changes.
The mapping stub service manages ServiceNow incident simulation, event streams, and Prometheus metrics.
Both services expose HTTP interfaces.
These interfaces handle health probes, MCP JSON-RPC transports, and REST queries.

## Problem Statement
RFC 9110 Section 9.3.7 requires uniform OPTIONS handling.
Servers advertising supported methods must include OPTIONS in Allow headers.
In ELK search MCP, incoming OPTIONS requests receive 405 Method Not Allowed responses.
The routes advertise `Allow: POST` or `Allow: GET, HEAD` instead of including OPTIONS.
Furthermore, incoming mutating requests in `search`, `handleMCP`, and `decodeReq` omit deferred request body closure.
When JSON payloads fail validation or decode, open sockets leak file descriptors.
In mapping stub, endpoints reject OPTIONS requests with 405 Method Not Allowed.
The mapping stub also truncates Allow headers to `GET, HEAD`.
Under sustained scraping or probe checks, lack of uniform OPTIONS handling causes client errors.

## Proposed Changes

### 1. ELK Search MCP Hardening
We update `olly-replica/apps/cmd/elk-search-mcp/main.go`.
We add OPTIONS method handling returning 204 No Content for probe routes and log search.
We update `mcp.go` to support OPTIONS on `/mcp`.
We update `tools.go` to support OPTIONS across `/tools` and individual tool invocations.
We ensure `search`, `handleMCP`, and `decodeReq` defer `r.Body.Close()`.
We update all 405 responses to advertise `Allow: POST, OPTIONS` or `Allow: GET, HEAD, OPTIONS`.

### 2. Mapping Stub Hardening
We update `olly-replica/apps/cmd/mapping-stub/main.go`.
We add OPTIONS method handling returning 204 No Content across all registered endpoints.
We update `methodNotAllowed` calls to advertise `Allow: GET, HEAD, OPTIONS`.
This aligns incident, event, metric, and health routes with RFC 9110.

### 3. Test Suite Expansion
We expand tests in both microservices.
We verify Allow header parity across all routes.
We verify OPTIONS requests return 204 No Content.
We verify deferred request body closure on decode errors.

## Verification Plan
We execute targeted unit tests for each package.
We run `go test` in `olly-replica/apps/cmd/elk-search-mcp`.
We run `go test` in `olly-replica/apps/cmd/mapping-stub`.
We run `bats test/docs-index-sync.bats` to verify documentation indexing.
We run `./scripts/docs-lint.sh` to confirm prose compliance.
