# Proposal — A2A Conformance, Cockpit Telemetry, Coding Agents, User Admin Flags, and Acceptance Harness Servers HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/test/fixtures`, `test/acceptance/harness`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, Acceptance Testing Harness Conformance

---

## 1. Problem Statement

Test harness servers and protocol conformance doubles must strictly adhere to RFC 9110 Section 6.4.1.
A server must never send a message body in response to a HEAD request.
Endpoints must return status 405 with an `Allow` header when an unsupported HTTP method is received.
Error responses must maintain uniform format and set matching headers across all status codes.

Adversarial exploration identified five test harness servers with body leaks or missing method error gates:

1. **A2A Conformance Server (`d2-signalloom/test/fixtures/a2a-conformance-server.ts`)**:
   The fetch handler lacked method gating on `/.well-known/agent.json`, permitting arbitrary HTTP methods.
   It also leaked bodies on HEAD requests across both agent cards and task invocation routes.

2. **Cockpit Telemetry Test Harness (`test/acceptance/harness/cockpit-telemetry-server.ts`)**:
   The server fell through to 404 instead of returning 405 on unsupported methods for control plane routes.
   It also leaked HTML, script, and JSON bodies on HEAD requests.

3. **Coding Agents Acceptance Test Harness (`test/acceptance/harness/coding-agents-server.ts`)**:
   Control plane routes returned 404 rather than 405 with `Allow` headers on invalid HTTP methods.
   Responses to HEAD requests leaked response bodies across telemetry and status endpoints.

4. **User Administration and Feature Flags Harness (`test/acceptance/harness/user-admin-flags-server.ts`)**:
   API and control endpoints lacked 405 method gates with `Allow` headers for unsupported verbs.
   Responses on HEAD requests emitted complete JSON payloads instead of suppressing body bytes.

5. **Demo Acceptance Harness Server (`test/acceptance/harness/server.ts`)**:
   Endpoints answered non-matching verbs with unexpected codes or absorbed them into fallback handlers.
   HEAD requests across demo runs, logs, streams, and steps leaked response body bytes.

---

## 2. Proposed Architecture & Remediation

### 2.1 A2A Conformance Server Hardening

In `d2-signalloom/test/fixtures/a2a-conformance-server.ts`:
- Introduce `jsonReply` and `methodNotAllowed` response helpers.
- Restrict `/.well-known/agent.json` to `GET` and `HEAD` methods, returning 405 with `Allow: GET, HEAD` on other methods.
- Restrict `/api/a2a/:namespace/:agent/` to `POST`, returning 405 with `Allow: POST` on invalid methods.
- Ensure all HEAD responses return a null body with correct content headers.

### 2.2 Cockpit Telemetry Harness Server Hardening

In `test/acceptance/harness/cockpit-telemetry-server.ts`:
- Update `json` helper to accept `req?: Request` and suppress body bytes on HEAD.
- Add method gates for `/harness/reset`, `/harness/phase`, and `/harness/drop`, allowing only `POST`.
- Gate `/harness/state` and `/harness/requests` to `GET` and `HEAD`.
- Suppress body bytes for static assets on HEAD requests.

### 2.3 Coding Agents Acceptance Harness Server Hardening

In `test/acceptance/harness/coding-agents-server.ts`:
- Update `json` helper to support `req?: Request` and suppress body on HEAD.
- Enforce `POST` on `/harness/reset`, returning 405 with `Allow: POST` on non-POST methods.
- Enforce `GET`, `HEAD`, and `POST` on `/harness/state`, returning 405 with `Allow: GET, HEAD, POST` on unsupported methods.
- Enforce `GET` and `HEAD` on `/harness/requests` and telemetry routes.
- Suppress body bytes on all HEAD requests.

### 2.4 User Admin and Flags Harness Server Hardening

In `test/acceptance/harness/user-admin-flags-server.ts`:
- Update `json` helper to accept `req?: Request` and suppress body bytes on HEAD requests.
- Restrict static assets, identity (`/api/v1/me`), feature flags (`/api/v1/features`), and tenants to `GET` and `HEAD`.
- Restrict `/harness/reset` and `/api/v1/admin/users/invite` to `POST`.
- Restrict user item operations to `PATCH` and `DELETE`, returning 405 with `Allow: PATCH, DELETE`.
- Suppress body on all HEAD requests.

### 2.5 Demo Acceptance Harness Server Hardening

In `test/acceptance/harness/server.ts`:
- Update `json` helper to support `req?: Request` and suppress body bytes on HEAD requests.
- Restrict `/demo-api/steps` and `/demo-api/status` to `GET` and `HEAD`.
- Restrict `/demo-api/runs` and `/demo-api/reset` to `POST`, returning 405 with `Allow: POST` on other methods.
- Restrict `/api/agents/agent-cardvault/stun` to `POST`.
- Restrict run subroutes (`/log` and `/stream`) to `GET` and `HEAD`.
- Suppress body bytes on all HEAD requests across all routes.

---

## 3. Implementation Plan

1. **Update Helpers and Server Routes**:
   Refactor `json` helpers in each harness to accept the incoming `Request` and return empty bodies on HEAD.
   Add explicit method checks with RFC 9110 compliant `Allow` headers.

2. **Automated Verification**:
   Execute `test/unit/acceptance-harnesses-head-contracts.test.ts` covering all four harness servers.
   Execute `bats d2-signalloom/test/kagent-invoke-http.bats` verifying A2A conformance server behavior.

---

## 4. Verification Record

- **Acceptance Harness Contracts**: Ran `bun test test/unit/acceptance-harnesses-head-contracts.test.ts`. 32 tests passed cleanly.
- **Kagent Invoke HTTP Conformance**: Ran `bats d2-signalloom/test/kagent-invoke-http.bats`. 10 tests passed cleanly.
- **Documentation Linting**: Ran `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
