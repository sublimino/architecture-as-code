# Proposal — HTTP Chunk Stream Deadlock Elimination, Test Runner Isolation, and Automated Branch Synchronization Recovery (2026-Q4)

## Context
Signal Loom coordinates agent trust boundaries and agentic SRE services across Kubernetes clusters.
The `d2-signalloom` slice provides `fake-integration-proxy`, `netassert-controller`, `fe-signalloom`, and `dashboard-signalloom`.
These services handle HTTP traffic across ingress proxies, health probes, agent telemetry ingestion, and user consoles.
A background synchronization daemon continuously propagates changes from `integration/slsi-v0.1.0` to `main`, `master`, and feature branches.

## Problem Statement
RFC 9112 Section 7 requires resilient parsing of chunked transfer encoding boundaries.
In `fake-integration-proxy` and `netassert-controller`, socket draining functions previously used `readline(4)` to read chunk delimiters.
When a client transmitted a chunk delimiter without a trailing newline, `readline(4)` blocked waiting indefinitely for incoming bytes.
This blocked socket operations, stalled server worker threads, and caused connection timeouts.

In `fe-signalloom`, the `probe_client` test fixture directly mutated the global Pydantic settings singleton.
This mutated `settings.api_superadmin_emails` and `settings.api_superadmin_subjects` without using `monkeypatch.setattr`.
Under parallel execution with `pytest-xdist`, this state leakage contaminated unrelated worker threads and failed compatibility tests.
Furthermore, `d2-signalloom/test/agents-redesign-evidence.bats` ran `uv run` without `--with respx`, causing 43 tests importing `respx` to fail.

In `dashboard-signalloom`, user interface source files and code comments contained disallowed em-dash characters.
This violated platform typography rules and caused ESLint and `d2-signalloom/test/lint-ui-typography.bats` to fail.

In database migrations, new migrations 062, 063, and 064 existed in `fe-signalloom/src/db/migrations` without regenerated SQL bootstrap files.
This caused `make -C d2-signalloom test` drift validation to fail.

In `scripts/sync_integration_branches.ts`, automated branch synchronization merged integration branches into `main` without handling conflicts on `deployment.yaml`.
Whenever image tags moved on the integration branch, merging into `main` failed.
The script also lacked conflict abort and reset logic in `ensureWorktree`, leaving worktrees locked in broken merge states.

## Proposed Changes

### 1. HTTP Chunk Delimiter Read Non-Blocking Hardening
We update `d2-signalloom/apps/fake-integration-proxy/server.py` and `d2-signalloom/apps/netassert-controller/server.py`.
We replace all occurrences of `readline(4)` for chunk delimiters with byte-by-byte `read(1)` inspection.
The reader consumes `\r` followed by `\n` or standalone `\n`.
If a non-newline byte appears, the server closes the connection immediately without blocking.
We add test cases in `test_proxy.py` and `test_controller.py` verifying that missing chunk CRLF delimiters close connections promptly.

### 2. Pytest Fixture Isolation and BATS Dependency Alignment
We update `d2-signalloom/apps/fe-signalloom/src/tests/test_eap_anonymous_surface.py` to use `monkeypatch.setattr`.
We update `d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py` to run a warm-up poll before measuring baseline heap allocation.
We update `d2-signalloom/test/agents-redesign-evidence.bats` to include `--with respx` in all `uv run` invocations.

### 3. Dashboard UI Typography Compliance
We update `d2-signalloom/apps/dashboard-signalloom`.
We replace all em-dash characters in user strings and comments with colons, commas, or parentheses.
We verify that `bun run lint` and `bats d2-signalloom/test/lint-ui-typography.bats` pass with zero warnings or errors.

### 4. Database Bootstrap Synchronization
We regenerate `discovery-portal-bootstrap.sql` across both contract and infra locations using `generate-bootstrap.py`.
We verify that `bash ./test/validate-dependencies.sh` passes with zero drift.

### 5. Automated Branch Synchronization Resilience
We update `scripts/sync_integration_branches.ts`.
We add automatic conflict resolution for `deployment.yaml` when merging integration branches into `main`.
We add `git merge --abort`, `git reset --hard HEAD`, and `git clean -fd` to `ensureWorktree` to guarantee recovery from dirty worktree states.

## Verification Plan
We run `python3 -m pytest test/` in `fake-integration-proxy`.
We run `python3 -m pytest test/` in `netassert-controller`.
We run `verify-cel.sh` across engine, conformance, and frontend suites.
We run `bats d2-signalloom/test/agents-redesign-evidence.bats`.
We run `bats d2-signalloom/test/lint-ui-typography.bats`.
We run `bats test/test-count-floor.bats`.
We run `bats test/docs-index-sync.bats`.
We run `./scripts/docs-lint.sh`.
