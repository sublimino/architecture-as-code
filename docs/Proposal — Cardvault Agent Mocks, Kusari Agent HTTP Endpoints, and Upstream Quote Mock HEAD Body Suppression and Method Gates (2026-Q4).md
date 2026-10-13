# Proposal — Cardvault Agent Mocks, Kusari Agent HTTP Endpoints, and Upstream Quote Mock HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/cardvault-agent`, `d2-signalloom/apps/kusari-agent`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP services, handlers, and test fixtures across the platform must comply with RFC 9110 Section 6.4.1.
A server must never emit a response body for HTTP HEAD requests.
When an unsupported HTTP method is received, the endpoint must return status 405 Method Not Allowed.
Every 405 response must include an RFC 9110 `Allow` header listing the permitted methods.
Any error response body must also be suppressed when requested via HEAD.

Adversarial discovery identified components in `cardvault-agent` and `kusari-agent` with missing method gates or unhandled HEAD bodies:

1. **Cardvault Agent Core Test Mocks (`d2-signalloom/apps/cardvault-agent/main_test.go`)**:
   Mock OpenBao and Cardvault servers lacked method gates and Allow headers.
   They accepted unhandled verbs and emitted response bodies on HEAD requests.

2. **Cardvault Agent Auto-Claim Mocks (`d2-signalloom/apps/cardvault-agent/autoclaim_test.go`)**:
   Mock auto-claim servers accepted any HTTP verb without method gating or Allow headers.
   They wrote 201, 409, and 500 response bodies on HEAD requests.

3. **Cardvault Agent Token Reuse Mocks (`d2-signalloom/apps/cardvault-agent/token_reuse_test.go`)**:
   Mock fake OpenBao and Cardvault servers accepted unexpected verbs and lacked HEAD body suppression.

4. **Cardvault Agent Adversarial Mocks (`d2-signalloom/apps/cardvault-agent/main_adversarial_test.go`)**:
   Mock error-handling servers accepted unvalidated verbs without method checks or Allow headers.

5. **Kusari Agent Upstream Quote Mock (`d2-signalloom/apps/kusari-agent/main_test.go`)**:
   Mock upstream quote servers accepted unexpected HTTP verbs and emitted response bodies on HEAD.

6. **Kusari Agent Method Verification Coverage (`d2-signalloom/apps/kusari-agent/methods_test.go`)**:
   Test coverage was missing for 404 HEAD body suppression and upstream mock method gating.

---

## 2. Proposed Architecture & Remediation

### 2.1 Cardvault Agent Test Harness Hardening

A new test helper `head_test.go` defines `headResponseWriter` and `headBodySuppressingMiddleware` for `cardvault-agent`.
It adds unit tests verifying method gates and HEAD body suppression across OpenBao, Cardvault, and claim mock servers.

In `d2-signalloom/apps/cardvault-agent/main_test.go`:
- Wrap mock OpenBao and Cardvault servers with `headBodySuppressingMiddleware`.
- Gate login endpoints on POST with `Allow: POST`.
- Gate KV and card endpoints on GET and HEAD with `Allow: GET, HEAD`.
- Suppress response bodies on HEAD requests across all mock endpoints.

In `d2-signalloom/apps/cardvault-agent/autoclaim_test.go`:
- Gate claim mock servers on POST with `Allow: POST`.
- Wrap claim mock servers with `headBodySuppressingMiddleware`.

In `d2-signalloom/apps/cardvault-agent/token_reuse_test.go`:
- Gate `newBaoFake` on POST for login and GET/HEAD for KV and cardvault.
- Wrap mock servers with `headBodySuppressingMiddleware`.

In `d2-signalloom/apps/cardvault-agent/main_adversarial_test.go`:
- Gate all test servers on their expected verbs and wrap with `headBodySuppressingMiddleware`.

### 2.2 Kusari Agent Upstream Mock and Route Verification

In `d2-signalloom/apps/kusari-agent/main_test.go`:
- Wrap `upstream` and `up` mock servers with `headBodySuppressingMiddleware`.
- Validate GET and HEAD methods and return 405 with `Allow: GET, HEAD` on unsupported verbs.

In `d2-signalloom/apps/kusari-agent/methods_test.go`:
- Add unit tests verifying 404 routes return 0-byte bodies on HEAD.
- Add unit tests verifying upstream quote mock method gates and HEAD body suppression.

---

## 3. Verification Plan

- Run `cardvault-agent` test suite: `go test -v .` in `d2-signalloom/apps/cardvault-agent`.
- Run `kusari-agent` test suite: `go test -v .` in `d2-signalloom/apps/kusari-agent`.
- Run documentation link and index synchronization: `bats test/docs-index-sync.bats`.
- Run documentation style and sentence length audit: `./scripts/docs-lint.sh`.
