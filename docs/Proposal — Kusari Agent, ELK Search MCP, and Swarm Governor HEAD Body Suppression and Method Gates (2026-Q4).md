# Proposal — Kusari Agent, ELK Search MCP, and Swarm Governor HEAD Body Suppression and Method Gates (2026-Q4)

**Status:** Proposed  
**Author:** Antigravity Engineering  
**Date:** 2026-10-13  
**Tag:** `KUSARIELKSWARMGOVHEAD`  

## Executive Summary

Platform HTTP services and test harnesses must enforce RFC 9110 compliance across every route.
Disallowed HTTP methods must receive status 405 Method Not Allowed with explicit Allow headers.
Responses to HEAD requests must never write response body bytes.
This proposal hardens kusari-agent, elk-search-mcp, and swarm-governor test suites and method matrices.

## Background and Context

The kusari-agent service emulates adversarial triggers across eight action routes.
Earlier test coverage verified write rejections on read-only routes with POST, PUT, and DELETE methods.
The read-only routes omitted explicit PATCH method rejection checks.
The action endpoints tested HEAD response body suppression but omitted non-POST method matrix tests.
Upstream quote mock verification lacked coverage for PUT, DELETE, and PATCH methods.

The elk-search-mcp service bridges Elasticsearch log querying and Grafana metrics to MCP clients.
Its test suite previously tested GET and HEAD on probes, and POST on tools.
The suite omitted PUT, DELETE, and PATCH method matrix verification across probe, tool, and MCP endpoints.
Direct invocations of methodNotAllowed error handlers lacked dedicated unit tests.

The swarm-governor service orchestrates multi-agent task dispatch and complexity analysis.
Its test suite tested GET, HEAD, and POST on probes, and DELETE on agent card endpoints.
The test harness lacked coverage for PUT, DELETE, and PATCH on probes and tasks endpoints.
Direct writeJSON invocations across varied HTTP status codes lacked dedicated HEAD body suppression unit tests.

## Problem Statement

1. Kusari-agent read-only routes omitted PATCH rejection in test matrices.
2. Kusari-agent provocation routes lacked non-POST method matrix assertions with Allow headers.
3. Kusari-agent upstream quote mock omitted PUT, DELETE, and PATCH method checks.
4. Kusari-agent postOnly middleware lacked direct unit tests across all HTTP verbs.
5. Elk-search-mcp probes omitted PUT, DELETE, and PATCH method checks.
6. Elk-search-mcp tool routes omitted PUT, DELETE, and PATCH method checks.
7. Elk-search-mcp direct methodNotAllowed handler invocations lacked unit test coverage.
8. Swarm-governor probes omitted PUT, DELETE, and PATCH rejection tests.
9. Swarm-governor agent card omitted POST, PUT, and PATCH method rejection checks.
10. Swarm-governor task submission and task query endpoints omitted PUT, DELETE, and PATCH method tests.
11. Swarm-governor direct writeJSON handler calls lacked unit test verification.

## Proposed Changes

### 1. Kusari Agent Test Suite Hardening

Harden `TestReadOnlyRoutesRejectWritesWithAllowHeader` with PATCH method coverage.
Assert status 405 Method Not Allowed with `Allow: GET, HEAD` and non-empty JSON error body.
Add `TestActRoutesRejectNonPostMethodsWithAllowHeader` across all eight provocation routes.
Iterate over GET, PUT, DELETE, and PATCH methods.
Assert status 405 Method Not Allowed with `Allow: POST` and JSON error body.
Update `TestUpstreamMockMethodGatesAndHEADBodySuppression` with PUT, DELETE, and PATCH tests.
Add `TestPostOnlyDirectMethodGatingAndHEAD` for direct postOnly middleware verification.

### 2. ELK Search MCP Test Suite Hardening

Update `TestHealthAndReadyzEndpoints` with a comprehensive method matrix.
Iterate over POST, PUT, DELETE, and PATCH on `/health`, `/healthz`, and `/readyz`.
Assert status 405 with `Allow: GET, HEAD` and non-empty error message body.
Iterate over GET, PUT, DELETE, and PATCH on registered tool endpoints and `/mcp`.
Assert status 405 with `Allow: POST` and non-empty error message body.
Iterate over POST, PUT, DELETE, and PATCH on `/tools` discovery endpoint.
Assert status 405 with `Allow: GET, HEAD` and non-empty error message body.
Add `TestElkSearchMethodNotAllowedDirect` for direct handler verification.

### 3. Swarm Governor Test Suite Hardening

Update `TestSwarmGovernorHTTPContracts` with PUT, DELETE, and PATCH checks on probes.
Assert status 405 with `Allow: GET, HEAD` and JSON error body.
Add POST, PUT, and PATCH checks on `/.well-known/agent-card.json`.
Assert status 405 with `Allow: GET, HEAD` and JSON error body.
Add PUT, DELETE, and PATCH checks on `/tasks/submit`.
Assert status 405 with `Allow: POST` and JSON error body.
Update task query test in `TestSwarmGovernor_SubmitTaskLifecycleAndEdgeCases`.
Assert status 405 with `Allow: GET, HEAD` for POST, PUT, DELETE, and PATCH on `/tasks/{id}`.
Add `TestSwarmGovernorWriteJSONDirectAndHEAD` for direct writeJSON verification.

## Verification Plan

1. Run `go test -v ./...` in `d2-signalloom/apps/kusari-agent`.
2. Run `go test -v ./...` in `olly-replica/apps/cmd/elk-search-mcp`.
3. Run `go test -v ./...` in `d2-signalloom/apps/swarm-governor`.
4. Run `bats test/docs-index-sync.bats` to verify documentation indexing.
