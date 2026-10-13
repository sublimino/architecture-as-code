# Proposal — Tenant App Fault Parity, Mapping Stub Fidelity, Triage CI HEAD Gates, Node Guard Isolation, and Controller Reuse (2026-Q4)

## Abstract

This proposal hardens HTTP method validation and socket lifecycle semantics across platform services.
It eliminates response body leakage on HEAD requests returning HTTP 405 Method Not Allowed.
It isolates webhook server routing from the global DefaultServeMux.
It ensures socket address reuse across long-lived daemon listeners.

## Problem Statement

Adversarial testing revealed subtle HTTP specification violations and operational boundary risks.

1. **Tenant App Fault Route Body Leakage**:
   The `/fault` route in `olly-replica/apps/cmd/tenant-app/main.go` rejects HEAD requests with HTTP 405.
   It calls standard library `http.Error` directly.
   This writes error text into the response body on HEAD requests.
   RFC 9110 Section 9.3.2 strictly prohibits returning content on HEAD.

2. **Mapping Stub 405 and 404 Body Leakage**:
   The IO mapping stub in `olly-replica/apps/cmd/mapping-stub/main.go` provides `/incidents/`, `/incidents`, `/events`, `/metrics`, and `/health` endpoints.
   Route handlers call `http.Error` and `http.NotFound` on invalid methods and missing tickets.
   These calls leak error bodies on HEAD requests.

3. **ELK Search MCP Tool Route 405 Body Leakage**:
   In `olly-replica/apps/cmd/elk-search-mcp/main.go`, `mcp.go`, and `tools.go`, `/mcp` and tool endpoints reject non-POST requests with HTTP 405.
   They invoke `http.Error` which emits response bodies when processing HEAD requests.

4. **Triage CI Worker Root Endpoint HEAD Body Leakage**:
   The CloudEvent webhook in `d2-signalloom/apps/triage-ci-worker/main.go` rejects non-POST methods with HTTP 405.
   It invokes `http.Error` which writes body text on HEAD requests.

5. **Node Capability Guard Global Mux Leakage and Validate HEAD Suppression**:
   The admission guard in `d2-signalloom/apps/node-capability-guard/cmd/main.go` attaches route handlers to `http.DefaultServeMux`.
   This leaks routes into tests and third-party packages.
   Additionally, `HandleValidate` in `pkg/webhook/handler.go` emits a body on HEAD requests returning HTTP 405.
   `HandleMetrics` omits explicit `w.WriteHeader(http.StatusOK)` on HEAD requests.

6. **Netassert Controller Socket Address Reuse**:
   The scan controller in `d2-signalloom/apps/netassert-controller/server.py` creates a `ThreadingHTTPServer`.
   It does not configure `allow_reuse_address = True`.
   Service restarts risk immediate bind failures under TCP `TIME_WAIT`.

## Proposed Changes

1. **Tenant App**:
   Introduce a `methodNotAllowed` helper that sets RFC 9110 `Allow` headers and suppresses body bytes on HEAD.
   Update `/fault`, `/work`, `/topology`, and `/metrics` to use the helper.
   Add assertions in `main_test.go` verifying empty bodies on HEAD requests returning HTTP 405.

2. **Mapping Stub**:
   Introduce a uniform `methodNotAllowed` helper suppressing response bodies on HEAD.
   Ensure not-found responses on HEAD suppress body bytes.
   Add contract tests in `main_test.go` exercising `/incidents/<corr>`.

3. **ELK Search MCP**:
   Implement a `methodNotAllowed` helper suppressing bodies on HEAD for `/mcp` and `/tools/*`.
   Add HEAD contract tests in `mcp_test.go` asserting empty bodies on 405 responses.

4. **Triage CI Worker**:
   Suppress response bodies on HEAD requests returning HTTP 405 in `handleCheckRun`.
   Add HEAD assertion to `TestRootMethodNotAllowed` in `main_test.go`.

5. **Node Capability Guard**:
   Add an isolated `NewMux` constructor in `pkg/webhook/handler.go` and use it in `cmd/main.go`.
   Suppress response bodies on HEAD requests returning HTTP 405 in `HandleValidate`.
   Ensure `HandleMetrics` explicitly writes HTTP 200 on HEAD.
   Add unit tests in `pkg/webhook/handler_test.go`.

6. **Netassert Controller**:
   Configure `_ThreadingHTTPServer.allow_reuse_address = True` in `d2-signalloom/apps/netassert-controller/server.py`.
   Add unit test in `d2-signalloom/apps/netassert-controller/test/test_controller.py`.

## Verification Strategy

- Go unit and contract tests in `olly-replica/apps/cmd/tenant-app`.
- Go unit and contract tests in `olly-replica/apps/cmd/mapping-stub`.
- Go unit and contract tests in `olly-replica/apps/cmd/elk-search-mcp`.
- Go unit and contract tests in `d2-signalloom/apps/triage-ci-worker`.
- Go unit and admission tests in `d2-signalloom/apps/node-capability-guard`.
- Pytest suite in `d2-signalloom/apps/netassert-controller/test/test_controller.py`.
- Repository documentation lint via `scripts/docs-lint.sh`.
