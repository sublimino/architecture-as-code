# Proposal — Signal Ingest Policy Routes and Actor Promotion, Stun Probe Preservers, and Swarm Governor A2A HEAD Body Suppression and Method Gates (2026-Q4)

## Metadata

- **Author**: Platform Security & Adversarial Discovery Team
- **Date**: 2026-10-13
- **Status**: Proposed
- **Target Release**: 2026-Q4
- **Impact Area**: `d2-signalloom/apps/signal-ingest`, `d2-signalloom/apps/stun-sentinel`, `d2-signalloom/apps/signalloom-stun-sentinel`, `d2-signalloom/apps/swarm-governor`
- **Related Issues / Work items**: Platform HTTP Compliance, RFC 9110 Section 6.4.1, SLSI Protocol Conformance

---

## 1. Problem Statement

HTTP services, handlers, and test fixtures across the platform must comply with RFC 9110 Section 6.4.1.
A server must never emit a response body for HTTP HEAD requests.
When an unsupported HTTP method is received, the endpoint must return status 405 Method Not Allowed.
Every 405 response must include an RFC 9110 `Allow` header listing the permitted methods.
Any 405 error response body must also be suppressed when requested via HEAD.

Adversarial discovery identified five components with missing method gates, response body leaks, or unreachable code:

1. **Signal Ingest Policy Routes (`d2-signalloom/apps/signal-ingest/api/policy_routes.go`)**:
   `handlePolicyFindings`, `handlePolicyDecisions`, and `handlePolicyRates` omitted HTTP method gates.
   They accepted unhandled verbs such as POST, PUT, and DELETE without returning 405 with `Allow: GET, HEAD`.
   Similarly, `handlePolicyReview` omitted a method gate and accepted GET, PUT, and DELETE without returning 405 with `Allow: POST`.

2. **Signal Ingest Actor Promotion (`d2-signalloom/apps/signal-ingest/api/promote.go`)**:
   `handlePromoteActor` handled actor promotion without checking the HTTP request method.
   It accepted GET, PUT, and DELETE verbs without returning 405 Method Not Allowed and `Allow: POST`.

3. **Signal Ingest Naked Test Mux (`d2-signalloom/apps/signal-ingest/api/export_test.go`)**:
   `RegisterRoutes` mounted handlers on a raw `http.ServeMux` without wrapping `ResponseWriter` on HEAD requests.
   Direct test callers executing HEAD requests against the test mux leaked response bodies.

4. **Stun Sentinel Probe Preservers (`d2-signalloom/apps/stun-sentinel/pkg/probe` and `d2-signalloom/apps/signalloom-stun-sentinel`)**:
   In both probe packages, synthetic probe handlers contained unreachable dead code checking for HEAD inside non-GET/HEAD branches.
   Test suites failed on TRACE methods because `headErrReq.Method = "TRACE"` was assigned instead of exercising middleware with real error paths.

5. **Swarm Governor A2A Test Harness (`d2-signalloom/apps/swarm-governor/a2a/client_test.go`)**:
   Mock servers for agent card discovery and task dispatch accepted arbitrary HTTP verbs without method gating.
   The mock servers lacked HEAD response body suppression, encoding JSON bodies unconditionally on HEAD requests.

---

## 2. Proposed Architecture & Remediation

### 2.1 Signal Ingest Policy Routes Hardening

In `d2-signalloom/apps/signal-ingest/api/policy_routes.go`:
- Gate `handlePolicyFindings` to GET and HEAD only. Return 405 with `Allow: GET, HEAD` on other verbs.
- Gate `handlePolicyDecisions` to GET and HEAD only. Return 405 with `Allow: GET, HEAD` on other verbs.
- Gate `handlePolicyRates` to GET and HEAD only. Return 405 with `Allow: GET, HEAD` on other verbs.
- Gate `handlePolicyReview` to POST only. Return 405 with `Allow: POST` on other verbs.

### 2.2 Signal Ingest Actor Promotion Hardening

In `d2-signalloom/apps/signal-ingest/api/promote.go`:
- Gate `handlePromoteActor` to POST only. Return 405 with `Allow: POST` on other verbs.

### 2.3 Signal Ingest Test Mux HEAD Body Suppression

In `d2-signalloom/apps/signal-ingest/api/export_test.go`:
- Wrap `w` with `&headResponseWriter{ResponseWriter: w}` on `r.Method == http.MethodHead` in `RegisterRoutes`.
- Ensure all test invocations against the naked test mux suppress response bodies on HEAD requests.

### 2.4 Stun Sentinel Probe Preserver Clean-Up

In `d2-signalloom/apps/stun-sentinel/pkg/probe` and `d2-signalloom/apps/signalloom-stun-sentinel`:
- Remove unreachable dead code `if r.Method == http.MethodHead` inside the non-GET/HEAD branch in probe handlers.
- Add TRACE to the unsupported method list in probe tests.
- Verify `headBodySuppressingMiddleware` suppresses 404 and 405 error bodies on HEAD requests.

### 2.5 Swarm Governor A2A Test Server Hardening

In `d2-signalloom/apps/swarm-governor/a2a/client_test.go`:
- Implement `headResponseWriter` and `headBodySuppressingMiddleware`.
- In `TestClient_DiscoverCard`, gate on GET and HEAD, set `Allow: GET, HEAD`, and suppress body on HEAD.
- In `TestClient_SendTask_Success`, gate on POST, set `Allow: POST`, and suppress body on HEAD.
- Add unit tests verifying 200 on HEAD with 0-byte body and 405 with Allow headers on rejected methods.

---

## 3. Verification Plan

- Run `signal-ingest` API test suite: `go test -v ./api` in `d2-signalloom/apps/signal-ingest`.
- Run `stun-sentinel` probe test suite: `go test -v ./pkg/probe` in `d2-signalloom/apps/stun-sentinel`.
- Run `signalloom-stun-sentinel` test suite: `go test -v .` in `d2-signalloom/apps/signalloom-stun-sentinel`.
- Run `swarm-governor` A2A test suite: `go test -v ./a2a` in `d2-signalloom/apps/swarm-governor`.
- Run documentation link and index synchronization: `bats test/docs-index-sync.bats`.
- Run documentation style and sentence length audit: `./scripts/docs-lint.sh`.
