# Proposal — Demo Console Method Gates, Orbit Endpoints, and Telemetry Response Parity (2026-Q4)

| Attribute | Value |
| :--- | :--- |
| **Status** | Proposed |
| **Short Name** | `DEMOCONSOLEPARITY` |
| **Author** | Antigravity Engine |
| **Date** | 2026-10-13 |
| **Target Slices** | `tools/demo-console/` |

---

## 1. Executive Summary

This proposal addresses HTTP method validation and RFC 9110 response parity across the Estate 95 demo console.
Several operational endpoints previously lacked HTTP method restrictions.
Non-mutating handlers accepted mutating verbs without returning 405 Method Not Allowed.
Mutating endpoints leaked error messages on HEAD requests.
This specification defines strict method validation and body suppression across console endpoints.

---

## 2. Problem Statement

The demo console exposes key control-plane endpoints for cluster operators.
Previously, endpoints such as `/api/orbit/proposals` and `/api/metrics/query` accepted any HTTP verb.
Mutating endpoints like `/api/runs` and `/api/orbit/approve` returned 405 with message bodies on HEAD.
Standard library file servers leaked error bodies on HEAD requests when target contract files were missing.
Additionally, process failure in port-forwarding blocked callers for twelve seconds due to unhandled standard output termination.

---

## 3. Scope of Impact

The changes harden five core files within the console tool directory:
1. `tools/demo-console/main.go`: Method gates, isolated mux constructor, safe file checks, and port-forward unblocking.
2. `tools/demo-console/orbit.go`: Method gate on proposals and HEAD body suppression on approval endpoints.
3. `tools/demo-console/security.go`: Method gate on status and HEAD body suppression on scan probes.
4. `tools/demo-console/metrics.go`: Method check on query endpoint and HEAD response body suppression.
5. `tools/demo-console/main_test.go`: Contract tests asserting 405 Allow headers and HEAD body suppression.

---

## 4. Proposed Architecture and Changes

### 4.1 Strict HTTP Method Verification

All read and query endpoints restrict incoming requests to GET and HEAD verbs.
Calls with mutating methods return 405 Method Not Allowed.
Every 405 response includes an RFC 9110 compliant `Allow` header.
Mutating endpoints reject GET or HEAD requests with `Allow: POST`.

### 4.2 RFC 9110 HEAD Body Suppression

Every endpoint handler verifies request method before writing response payloads.
On HEAD requests, handlers write status headers and suppress body output.
The `writeJSON` and `writeError` helpers explicitly omit body content on HEAD calls.
File-serving routes inspect file presence before dispatching to prevent 404 body leaks on HEAD.

### 4.3 Port-Forward Unblocking

The port-forwarding manager closes its completion channel when standard output encounters EOF.
This prevents twelve-second blocking timeouts when subprocesses terminate unexpectedly.

---

## 5. Verification Strategy

Verification runs through unit and contract suites in `tools/demo-console/main_test.go`.
Tests assert 405 status codes and `Allow` headers across all endpoints.
Tests verify zero body length on all HEAD invocations.
Mock commands ensure fast sub-second test execution without requiring a live cluster.

---

## 6. Migration and Rollback Plan

The change is purely internal to `tools/demo-console/`.
No external API contracts or wire formats are altered.
If regressions arise, the changes can be rolled back without impacting database state.
