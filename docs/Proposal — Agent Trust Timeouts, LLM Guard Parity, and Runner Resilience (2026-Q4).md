# Proposal — Agent Trust Timeouts, LLM Guard Parity, and Runner Resilience (2026-Q4)

## Abstract

This proposal establishes execution timeouts and probe parity across agent trust services, LLM guardrails, demo runners, and CI workers.
Six areas are fortified:
- `a2a`: subprocess timeout bounds on cryptographic signing and verification.
- `llm-guard`: probe parity with `/health` route registration.
- `fe-signalloom` demo runner: `/healthz` liveness probe endpoint.
- `user-surface-gate` stub server: standard `/health`, `/healthz`, and `/readyz` probes.
- `cardvault-agent`: bounded context timeout for SPIRE subprocess execution.
- `triage-ci-worker`: bounded context timeout for GitHub CLI comment commands.

## Problem Statement

### 1. Agent Trust Unbounded Subprocess Execution (`d2-agent-trust`)
The `d2-agent-trust/a2a/service.py` module verifies platform authorization contexts.
It invoked `subprocess.run` with `openssl` without a timeout.
Stalled or hanging OpenSSL subprocesses blocked the request handler indefinitely.
Additionally, unstripped Content-Length strings risked unexpected type errors.

### 2. LLM Guard Liveness Probe Route Gaps (`olly-replica`)
The `olly-replica/apps/llm-guard/app/app.py` service scans model inputs and outputs.
Its FastAPI application registered `/healthz` and `/readyz` probes.
It omitted standard `/health`, returning 404 to cluster probes.

### 3. Standalone Demo Runner Probe Parity (`fe-signalloom`)
The `d2-signalloom/apps/fe-signalloom/src/demo_runner_main.py` entrypoint serves demo runners.
It mapped `/health` and `/readyz` but omitted standard `/healthz`.
Kubernetes deployments configured with `/healthz` liveness probes received 404 errors.

### 4. User Surface Gate Stub Server Missing Probes (`test/fixtures`)
The `test/fixtures/user-surface-gate/stub-surface-server.py` simulates external surfaces.
Its HTTP handler omitted `/health`, `/healthz`, and `/readyz` endpoints.
Health checkers probing the stub server received 404 responses.

### 5. Cardvault Agent Unbounded Process Execution (`cardvault-agent`)
The `d2-signalloom/apps/cardvault-agent/main.go` binary retrieves identity tokens.
Its `combinedOutput` helper invoked bare `exec.Command` without a context timeout.
A hung `spire-agent` binary blocked agent lifecycle indefinitely.

### 6. CI Worker Unbounded GitHub CLI Invocations (`triage-ci-worker`)
The `d2-signalloom/apps/triage-ci-worker/main.go` parses CI check runs.
Its `postGitHubComment` function ran bare `exec.Command` for GitHub CLI calls.
Network hangs during comment submission froze the event handler.

## Proposed Remediation

1. **`d2-agent-trust/a2a`:**
   - Add `timeout=5.0` to `subprocess.run` calls in `d2-agent-trust/a2a/service.py`.
   - Strip whitespace from `Content-Length` header values before integer conversion.

2. **`olly-replica/apps/llm-guard`:**
   - Register `@app.get("/health")` in `olly-replica/apps/llm-guard/app/app.py`.

3. **`d2-signalloom/apps/fe-signalloom`:**
   - Register `@app.get("/healthz")` in `d2-signalloom/apps/fe-signalloom/src/demo_runner_main.py`.
   - Update `d2-signalloom/apps/fe-signalloom/src/tests/test_demo_runner_main.py` to assert `/healthz`.

4. **`test/fixtures/user-surface-gate`:**
   - Add `/health`, `/healthz`, and `/readyz` probe handling in `test/fixtures/user-surface-gate/stub-surface-server.py`.
   - Add test coverage in `test/user-surface-gate.bats`.

5. **`d2-signalloom/apps/cardvault-agent`:**
   - Update `combinedOutput` in `d2-signalloom/apps/cardvault-agent/main.go` to use `context.WithTimeout`.
   - Add `TestCombinedOutputExecution` in `d2-signalloom/apps/cardvault-agent/main_test.go`.

6. **`d2-signalloom/apps/triage-ci-worker`:**
   - Update `postGitHubComment` in `d2-signalloom/apps/triage-ci-worker/main.go` to use `context.WithTimeout`.
   - Add `TestPostGitHubCommentExecution` in `d2-signalloom/apps/triage-ci-worker/parser_test.go`.

## Verification Plan

- Pytest contract suite in `d2-agent-trust/test/test_contracts.py`.
- Python syntax compilation check on `olly-replica/apps/llm-guard/app/app.py`.
- Pytest suite in `d2-signalloom/apps/fe-signalloom/src/tests/test_demo_runner_main.py`.
- BATS test suite in `test/user-surface-gate.bats`.
- Go test suite in `d2-signalloom/apps/cardvault-agent`.
- Go test suite in `d2-signalloom/apps/triage-ci-worker`.
- Documentation linting via `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
