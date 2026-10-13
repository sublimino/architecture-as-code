# Proposal — Test Stub Route Method Gates, HEAD Suppression, and Socket Reuse (2026-Q4)

| Attribute | Value |
| :--- | :--- |
| **Status** | Proposed |
| **Date** | 2026-10-13 |
| **Author** | Antigravity AI Engine |
| **Scope** | `d2-signalloom/netassert-runner`, `d2-signalloom/apps/fe-signalloom/src/tests`, `scripts/jev-test-bot` |
| **Tag** | `STUBMETHODREUSE` |

## 1. Executive Summary

Test suites across the platform launch in-process HTTP servers to mock upstreams.
Multiple test handlers lack method gating and return 501 on unhandled verbs.
Handlers fail to suppress response bodies on HEAD requests.
Servers omit `allow_reuse_address = True`, risking bind collisions on re-runs.
This proposal remedies these issues across test fixtures and stubs.

## 2. Problem Statement

Adversarial exploration identified latent gaps across several test stubs:

1. **Netassert Test Resolver Stub (`test_resolve_agent_pod.py`)**:
   `ApiHandler` implemented only `do_GET`.
   Incoming HEAD requests leaked serialized JSON bodies.
   Unsupported methods returned HTTP 501 without RFC 9110 `Allow` headers.
   `ThreadingHTTPServer` omitted `allow_reuse_address`.

2. **Audit Anchor Archivista Stub (`test_audit_anchor_envelope.py`)**:
   `_StubArchivista` handled GET for `/download/` and POST for `/upload` and `/query`.
   It omitted `do_HEAD`, leaking payloads on HEAD requests.
   Unhandled methods on these endpoints returned 501 without `Allow` headers.
   `HTTPServer` omitted `allow_reuse_address`.

3. **EAP Recording Upstream Stub (`test_eap_default_deny.py`)**:
   `_RecordingUpstream` mirrored GET and POST to a single answer function.
   It lacked HEAD body suppression.
   Unhandled methods returned 501 without `Allow: GET, POST, HEAD`.
   `ThreadingHTTPServer` omitted `allow_reuse_address`.

4. **Jev Test Bot Stubs (`test_chaos_fuzzing.py`, `test_bot_coverage.py`)**:
   `_MockApiServer` and `_Shell` omitted HEAD body suppression.
   `_Shell` returned 501 on non-GET verbs without `Allow: GET, HEAD`.
   Both servers omitted `allow_reuse_address = True`.

5. **Teardown Test Fixtures (`test_environment_teardown.py`, `test_environment_teardown_review_regressions.py`)**:
   `_Handler` in teardown tests lacked `do_HEAD` body suppression.
   Servers lacked `allow_reuse_address = True`.

## 3. Architecture and Implementation Design

### 3.1 Method Validation and RFC 9110 Allow Headers

Test handlers return `405 Method Not Allowed` when receiving unsupported methods.
The response carries the `Allow` header listing permitted verbs:

```python
self.send_response(405)
self.send_header("Allow", "GET, HEAD")
self.send_header("Content-Type", "text/plain; charset=utf-8")
self.end_headers()
self.wfile.write(b"method not allowed")
```

### 3.2 HEAD Body Suppression

Handlers implement `do_HEAD` with identical response status and headers.
The response body write is omitted:

```python
def do_HEAD(self):
    self._serve(send_body=False)
```

### 3.3 Socket Address Reuse

Each server subclass sets `allow_reuse_address = True` on socket setup.
This prevents transient `EADDRINUSE` errors across concurrent or repeated test runs.

## 4. Verification Plan

1. Verify HEAD requests return status 200 with zero body bytes across all stubs.
2. Verify unsupported verbs return status 405 with valid RFC 9110 `Allow` headers.
3. Run existing pytest and unittest suites to ensure no regressions.
4. Verify documentation index sync with `test/docs-index-sync.bats`.
