# Proposal — Signal Ingest Audit Webhooks, GKE Adapter, Demo Console Terminal, Stun Traffic Control, and Archivista Stub HEAD Body Suppression and Method Gates (2026-Q4)

## Context

RFC 9110 Section 6.4.1 defines the semantics of HTTP HEAD requests.
A server must not return a message body in response to a HEAD request.
The response headers must match those returned for an equivalent GET request.
Previous hardening milestones eliminated body leakage across primary service endpoints.
However, gaps remain in audit intake webhooks, console terminal bridges, and attestation test stubs.

## Problem Statement

Adversarial exploration identified response body leakage on HEAD requests across five platform components.

First, `d2-signalloom/apps/signal-ingest/api/audit/receiver.go` provides the `HandleAuditWebhook` endpoint.
In `HandleAuditWebhook`, non-POST requests return 405 Method Not Allowed with an `Allow: POST` header.
The handler invokes `http.Error` with plaintext.
It also invokes `http.Error` on read and unmarshal errors.
On successful ingest, it encodes a JSON response without checking for HEAD.
This leaks response bytes when a client sends a HEAD request.

Second, `d2-signalloom/apps/signal-ingest/api/audit/gke_adapter.go` provides `HandleGKECloudLogging`.
In `HandleGKECloudLogging`, non-POST requests invoke `http.Error` with plaintext.
On successful ingest, it unconditionally encodes JSON to the response writer.
HEAD requests receive error text or response body bytes.

Third, `tools/demo-console/main.go` exposes `/ws/term` via `handleTerm`.
The endpoint accepts any HTTP verb without method gating.
It lacks an `Allow: GET, HEAD` header on unsupported methods.
In `handleTerm`, cross-origin rejections call `http.Error`.
In `wsUpgrade`, invalid Upgrade headers and hijacking failures call `http.Error`.
These calls leak plaintext bodies on HEAD requests.

Fourth, `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main.go` controls traffic shaping.
In `healthHandler` and `/metrics`, unsupported verbs invoke `http.Error`.
In `triggerHandler`, missing interface parameters return plaintext rather than structured JSON.
These paths leak error bytes on HEAD requests.

Fifth, `d2-signalloom/apps/fe-signalloom/src/tests/test_audit_anchor_envelope.py` implements `_StubArchivista`.
`_StubArchivista` provides a local in-toto attestation registry for test fixtures.
In `send_error`, unsupported verbs invoke `self.wfile.write` unconditionally without checking for HEAD.
It also delegates other error codes to `BaseHTTPRequestHandler.send_error`.
This emits default HTML error documents and leaks response bytes on HEAD.

## Proposed Changes

### Signal Ingest Audit Webhook Method Gates

Update `HandleAuditWebhook` in `receiver.go`.
Replace `http.Error` calls with explicit status codes and headers.
Suppress plaintext error text and 200 JSON payloads on HEAD requests.

### Signal Ingest GKE Adapter Method Gates

Update `HandleGKECloudLogging` in `gke_adapter.go`.
Replace `http.Error` calls with explicit status codes and headers.
Suppress error text and JSON bodies on HEAD requests.

### Demo Console Terminal WebSocket Guard

Update `handleTerm` and `wsUpgrade` in `tools/demo-console/main.go`.
Add method gating requiring GET or HEAD with `Allow: GET, HEAD`.
Suppress error bodies on HEAD requests.

### Stun Traffic Control Error Parity

Update `stun-tcctl/main.go`.
Replace `http.Error` calls in `healthHandler` and `/metrics` with explicit status codes.
Update `triggerHandler` to return structured JSON errors with HEAD suppression.

### Archivista Stub Error Fidelity and HEAD Suppression

Update `_StubArchivista` in `test_audit_anchor_envelope.py`.
Suppress response bodies on HEAD requests.
Include explicit `Content-Length` headers across all responses.
Emit structured JSON error payloads instead of HTML templates.

## Verification Plan

### Automated Unit and Integration Tests

Run unit tests across all affected components:
1. `go test -v ./api/audit` in `d2-signalloom/apps/signal-ingest`
2. `go test -v .` in `tools/demo-console`
3. `go test -v .` in `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl`
4. `pytest test_audit_anchor_envelope.py` in `d2-signalloom/apps/fe-signalloom/src/tests`

### Documentation and Sync Verification

Run `./scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
Verify all lint rules pass with zero errors.
