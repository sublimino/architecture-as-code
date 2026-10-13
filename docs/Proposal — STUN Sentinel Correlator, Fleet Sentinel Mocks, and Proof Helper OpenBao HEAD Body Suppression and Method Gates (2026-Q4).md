# Proposal — STUN Sentinel Correlator, Fleet Sentinel Mocks, and Proof Helper OpenBao HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/stun-sentinel`, `d2-signalloom/apps/signalloom-stun-sentinel`, `d2-signalloom/proof-helper`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP services, handlers, and test fixtures across the platform must comply with RFC 9110 Section 6.4.1.
A server must never emit a response body for HTTP HEAD requests.
When an unsupported HTTP method is received, the endpoint must return status 405 Method Not Allowed.
Every 405 response must include an RFC 9110 `Allow` header listing the permitted methods.
Any error response body must also be suppressed when requested via HEAD.

Adversarial discovery identified components in `stun-sentinel`, `signalloom-stun-sentinel`, and `proof-helper` with missing method gates or unhandled HEAD bodies:

1. **STUN Sentinel Ingest Mock Servers (`d2-signalloom/apps/stun-sentinel/pkg/correlator/`)**:
   Mock signal-ingest servers accepted arbitrary verbs without method gating or Allow headers.
   They wrote response bodies on HEAD requests across normal and error status paths.
   This affected batch chain verification, spool retention, replay tests, retry tests, and rate limiters.

2. **Signalloom STUN Sentinel Fleet Mocks (`d2-signalloom/apps/signalloom-stun-sentinel/`)**:
   Mock fleet stun-state, workload report registry, and fleet stunner servers accepted unexpected verbs.
   The fleet stun-state mock failed to support HEAD requests on GET routes.
   They lacked RFC 9110 `Allow` headers on non-matching verbs and leaked bodies on HEAD.

3. **Proof Helper OpenBao Login Mocks (`d2-signalloom/proof-helper/`)**:
   Mock OpenBao login servers accepted arbitrary HTTP verbs on `/v1/auth/jwt/login`.
   They failed to return status 405 with `Allow: POST` headers on non-POST requests.
   They also leaked JSON error responses and authentication tokens when probed with HEAD.

---

## 2. Proposed Architecture & Solution

To eliminate these vulnerabilities, we adopt a standardized approach across all affected components.

### 2.1 RFC 9110 Response Body Suppression

All mock servers wrap their handlers in `headBodySuppressingMiddleware`.
The middleware intercepts HTTP HEAD requests and delegates to a dedicated `headResponseWriter`.
This guarantees zero body bytes for any status code.
It preserves status codes, Content-Type headers, and Retry-After headers across all endpoints.

### 2.2 Strict HTTP Method Validation

Mock signal-ingest endpoints enforce HTTP POST and reject non-POST requests with status 405 Method Not Allowed.
The 405 response includes an `Allow: POST` header and a JSON error payload.
Fleet stun-state routes accept GET and HEAD while rejecting other methods with `Allow: GET, HEAD`.
Fleet stun ack, registry, and stunner endpoints enforce POST with `Allow: POST`.
Mock OpenBao login endpoints strictly require POST and set `Allow: POST` for invalid methods.

---

## 3. Verification & Validation Plan

### 3.1 Unit Testing and Method Gate Checks

1. **Correlator Head Tests (`pkg/correlator/head_test.go`)**:
   Verify that mock signal-ingest servers return 201 on POST and 405 on non-POST verbs.
   Assert that HEAD requests to POST-only routes receive 405 with `Allow: POST` and zero body bytes.
   Verify that error status codes (400, 401, 403, 404, 413, 429, 500, 503) emit zero body bytes on HEAD.

2. **Fleet Sentinel Mock Tests (`fleetpoll_test.go`, `fleetreport_test.go`, `fleetstun_test.go`)**:
   Assert that fleet stun-state endpoints handle HEAD requests with status 200, Content-Type, and zero body bytes.
   Verify that non-GET/HEAD verbs return 405 with `Allow: GET, HEAD`.
   Verify that registry and fleet endpoints return 405 with `Allow: POST` and zero body bytes on HEAD.

3. **Proof Helper OpenBao Tests (`proof-helper/main_test.go`)**:
   Assert that OpenBao login mocks return 405 with `Allow: POST` on GET, HEAD, PUT, and DELETE.
   Verify that simulated 500 internal server errors emit zero body bytes on HEAD.
   Confirm that all existing A2A identity and replay validation tests pass without regressions.

---

## 4. Implementation Details

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/head_test.go`**:
  Implements `headResponseWriter` and `headBodySuppressingMiddleware`.
  Adds comprehensive unit test coverage for method gates, Allow headers, and HEAD body suppression.

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/sender_test.go`**:
  Hardens ten mock signal-ingest servers with method validation and `headBodySuppressingMiddleware`.

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/ingest_contract_test.go`**:
  Hardens the observation dispatch contract mock server with POST checks and HEAD body suppression.

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/ingest_token_test.go`**:
  Hardens counting and failure mock servers with POST gates and HEAD body suppression.

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/stats_test.go`**:
  Hardens dispatch stats mock servers with POST gates and HEAD body suppression.

- **`d2-signalloom/apps/stun-sentinel/pkg/correlator/token_source_test.go`**:
  Hardens late token source mock server with POST checks and HEAD body suppression.

- **`d2-signalloom/apps/signalloom-stun-sentinel/fleetpoll_test.go`**:
  Updates `newFakeStunState` to handle HEAD on stun-state and enforce POST on ack.
  Adds `TestFleetStunStateHEADAndMethodGates`.

- **`d2-signalloom/apps/signalloom-stun-sentinel/fleetreport_test.go`**:
  Updates `newFakeRegistry` to enforce POST and suppress bodies on HEAD.
  Adds `TestFakeRegistryHEADAndMethodGates`.

- **`d2-signalloom/apps/signalloom-stun-sentinel/fleetstun_test.go`**:
  Updates `newFakeFleet` to enforce POST and suppress bodies on HEAD.
  Adds `TestFakeFleetHEADAndMethodGates`.

- **`d2-signalloom/proof-helper/main_test.go`**:
  Hardens mock OpenBao servers in JWT exchange and probe tests with POST gates and HEAD suppression.
  Adds `TestOpenBaoMockMethodGatesAndHEADBodySuppression`.

- **`d2-signalloom/proof-helper/main_adversarial_test.go`**:
  Hardens mock OpenBao server in `setupA2ATest` with POST method checks and HEAD body suppression.

---

## 5. Security & Protocol Compliance

This change aligns platform components and mock infrastructure with RFC 9110 Section 6.4.1.
Enforcing HTTP method gates prevents unintended request execution on test and runtime endpoints.
Including `Allow` headers ensures standardized discovery for HTTP clients and security scanners.
Suppressing response bodies on HEAD requests guarantees protocol consistency across both success and error responses.
