# Proposal — Fleet Manager OpenBao Client, Token Accessor, Resume Governance, Combined Credential Plane, and Denial Matrix Mock Server HEAD Body Suppression and Method Gates (2026-Q4)

- **Date:** 2026-10-13
- **Author:** Antigravity Autonomous Security Engineer
- **Status:** Proposed
- **Tag:** `FLEETOPENBAOCLIENTTOKENSRESUME`
- **Scope:** `d2-signalloom/apps/fleet-manager/openbao_client_test.go`, `d2-signalloom/apps/fleet-manager/openbao_token_test.go`, `d2-signalloom/apps/fleet-manager/resume_governance_test.go`, `d2-signalloom/apps/fleet-manager/combined_credential_plane_test.go`, and `d2-signalloom/apps/fleet-manager/denial_matrix_test.go`

---

## 1. Problem Statement

Across Fleet Manager integration test suites, mock HTTP servers simulate OpenBao credential operations.
These operations include lease revocation, token enumeration, token revocation, token rotation, and multi-plane containment.
Currently, several mock HTTP test servers accept arbitrary HTTP verbs.
They do not set standard `Allow` headers on 405 Method Not Allowed responses.
Additionally, they emit response bodies on HTTP HEAD requests.
This violates RFC 9110 Section 6.4.1 compliance.
It also fails to catch contract regressions in client callers under adversarial HTTP traffic.

Five specific areas in Fleet Manager tests require hardening:

1. **OpenBao Client Test Mocks (`openbao_client_test.go`):**
   Mock servers for lease revocation, circuit breaking, context cancellation, audit logging, and latency tests lack method gates.
   They unconditionally write response bodies on HEAD requests.

2. **OpenBao Token Accessor and Token File Mocks (`openbao_token_test.go`):**
   `newFakeBaoAccessorServer` and token file test servers lack explicit method gates across token paths.
   They leak response bodies on HEAD requests across both success and error responses.

3. **Resume Governance Rotation Mock (`resume_governance_test.go`):**
   `newRotateBaoServer` accepts arbitrary HTTP methods without method gating.
   It emits JSON response bodies on HEAD requests across both 200 and 500 responses.

4. **Combined Credential Plane Mocks (`combined_credential_plane_test.go`):**
   `newBaoTestServer` and concurrent plane test servers accept arbitrary verbs.
   They leak JSON bodies on HEAD requests.

5. **Denial Matrix Containment Mocks (`denial_matrix_test.go`):**
   `baoServer` and `failingBaoServer` accept arbitrary verbs and leak error bodies on HEAD requests.

---

## 2. Proposed Architecture & Hardening

### 2.1 OpenBao Client Test Mocks

- Restrict endpoints to appropriate methods such as `POST` or `GET` with corresponding `Allow` headers.
- Return HTTP 405 Method Not Allowed when unexpected methods arrive.
- Suppress response bodies on HEAD requests across all test servers in `openbao_client_test.go`.
- Add test assertions verifying RFC 9110 HEAD response body suppression.

### 2.2 OpenBao Token Accessor and Token File Mocks

- Update `newFakeBaoAccessorServer` to enforce `GET, HEAD` on `/v1/auth/token/accessors`.
- Enforce `POST, HEAD` on `/v1/auth/token/lookup-accessor` and `/v1/auth/token/revoke-accessor`.
- Enforce `POST, PUT, HEAD` on `/v1/sys/leases/revoke`.
- Suppress response bodies on HEAD requests across both success and error cases.
- Add test assertions verifying HEAD parity and method rejection.

### 2.3 Resume Governance Rotation Mock

- Enforce `POST, GET, HEAD` method gating on `newRotateBaoServer`.
- Return HTTP 405 with `Allow: POST, GET, HEAD` when other verbs are used.
- Suppress response bodies on HEAD requests.
- Add test assertions verifying HEAD body suppression.

### 2.4 Combined Credential Plane Mocks

- Update `newBaoTestServer` and test servers to gate methods to `POST, PUT, GET, HEAD`.
- Set `Allow` headers on rejected methods.
- Suppress response bodies on HEAD requests.
- Add test assertions verifying HEAD body suppression.

### 2.5 Denial Matrix Containment Mocks

- Update `baoServer` and `failingBaoServer` to gate methods with `Allow` headers.
- Suppress response bodies on HEAD requests across 200, 204, 404, and 500 status codes.
- Add test assertions verifying HEAD body suppression.

---

## 3. Verification Plan

- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v -run TestOpenBaoClient .` in `d2-signalloom/apps/fleet-manager`
- `CGO_ENABLED=0 GOPATH=/tmp/gopath GOCACHE=/tmp/gocache go test -v -run "TestOpenBao|TestResume|TestCombined|TestDenial" .` in `d2-signalloom/apps/fleet-manager`
- `make docs-lint` and `bats test/docs-index-sync.bats`
