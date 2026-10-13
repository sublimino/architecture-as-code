# Proposal — CEL Framework Verification Cache Isolation and RFC 9110 Proxy Allow Header Parity (2026-Q4)

## Context
CEL policy verification validates regulatory frameworks across Kubernetes resources and governance contexts.
The test script `scripts/verify-cel.sh` runs five tiers spanning engine unit tests, conformance fixtures, and database integration.
The API gateway `fe-signalloom` proxies compliance requests to the policy engine service.

## Problem Statement
The runner script `scripts/verify-cel.sh` invokes Go test commands without build or module cache isolation.
In restricted or sandboxed environments, Go defaults to global directories like `/usr/local/src/gocode`.
This results in permission denied errors during conformance and engine verification.
Similarly, `test/cel-frameworks-api-e2e.py` builds the policy engine binary without cache isolation environment variables.
In `d2-signalloom/apps/fe-signalloom/src/request_lifecycle.py`, `RequestLifecycleMiddleware` intercepts 405 responses.
It unconditionally overwrites the `Allow` header using local route definitions.
When `proxy_policy_engine` forwards an upstream 405 response, the upstream header is erased.
RFC 9110 Section 15.5.6 prohibits proxies from modifying forwarded `Allow` headers.
This defect causes `test_policy_engine_proxy_propagates_allow_header_on_405` to fail.

## Objectives
1. Provide Go cache and module isolation environment variables in `scripts/verify-cel.sh` `go_tier`.
2. Configure Go environment isolation in `test/cel-frameworks-api-e2e.py` during engine compilation.
3. Preserve forwarded upstream `Allow` headers on 405 responses in `RequestLifecycleMiddleware`.
4. Synthesize local `Allow` headers only when the server originates the 405 response.
5. Verify clean execution across `verify-cel.bats` and FastAPI test batteries.

## Proposed Changes

### 1. Go Cache Isolation in CEL Verification
In `scripts/verify-cel.sh`, update function `go_tier`.
Pass `GOPATH`, `GOCACHE`, `GOMODCACHE`, and `CGO_ENABLED=0` to `go test`.
In `test/cel-frameworks-api-e2e.py`, pass isolated cache variables to `subprocess.run`.

### 2. RFC 9110 Allow Header Preservation
In `d2-signalloom/apps/fe-signalloom/src/request_lifecycle.py`, update `wrapped_send`.
Inspect the request method against allowed route methods for the path.
If the method is allowed locally, preserve the forwarded upstream `Allow` header without modification.
Only synthesize local route methods when the request method is not supported locally.

## Verification Plan
1. Run `bats test/verify-cel.bats` to confirm all 14 tests pass.
2. Run pytest on `test_policy_engine.py` and `test_head_response_suppression.py`.
3. Check documentation index synchronization with `bats test/docs-index-sync.bats`.
4. Verify documentation style rules using `scripts/docs-lint.sh`.
5. Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh`.
