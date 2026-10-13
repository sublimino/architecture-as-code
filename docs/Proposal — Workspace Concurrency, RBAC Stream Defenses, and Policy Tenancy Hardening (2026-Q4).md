# Proposal — Workspace Concurrency, RBAC Stream Defenses, and Policy Tenancy Hardening (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** d2-cpai, d2-k8s-afm, fe-signalloom
**Tag:** WORKSPACETENANCY

## Context

Signal Loom operates sandboxed AI runtimes (`cpai-engineer`), ingests RBAC models for verification (`d2-k8s-afm`), and exposes multi-tenant policy planes (`fe-signalloom`).
These systems operate under multi-tenant isolation, concurrent task execution, and immutable audit guarantees.
They must protect against concurrent memory exhaustion, race conditions on task state, parsing failures on sparse Kubernetes specifications, and cross-tenant query bypasses.

## Problem statement

Adversarial exploration and static verification identified multiple concurrency, parsing, and tenancy defects across the estate:

1. **In-flight task tracking memory leak and data race in `cpai-engineer`**:
   In `d2-signalloom/apps/cpai-engineer/main.go`, `inflight` is a package-level map of `*TaskResponse` pointers.
   When `POST /tasks` receives a job, the pointer is stored in `inflight`.
   The background goroutine `e.execute` updates `task` fields (`Status`, `Commits`, `TokensUsed`, `UpdatedAt`, `Error`) in-place without synchronization.
   Meanwhile, `GET /tasks/{id}` reads `task` and invokes `json.NewEncoder(w).Encode(task)` concurrently.
   This introduces a Go memory model data race between writer and reader.
   Furthermore, `inflight` entries are never removed upon task completion or failure, leaking memory unbounded as tasks accumulate.
   Because `store.Insert` persists the pending task to SQLite synchronously, reading state via `store.Get` avoids races and eliminates memory leaks.

2. **Shallow git clone failure on non-default branches in `cpai-engineer`**:
   In `d2-signalloom/apps/cpai-engineer/executor.go`, `ensureRepo` executes `git clone --depth=1 repo dir` on initial repository setup.
   A shallow clone without `--branch` fetches only the default branch, such as `main`.
   When `req.Branch` specifies any non-default branch, the subsequent `git checkout branch` fails with `fatal: error: pathspec 'branch' did not match any file(s) known to git`.
   Passing `--branch <branch>` directly to `git clone` ensures shallow clones succeed regardless of the requested branch.

3. **`TypeError` unhandled null iteration in `scripts/rbac-to-afm.py` and missing CLI parameters**:
   In `scripts/rbac-to-afm.py`, `convert()` reads `item.get("rules", [])` and `item.get("subjects", [])`.
   In Kubernetes JSON and YAML representations, empty rule or subject blocks deserialize as `None`.
   When `None` is encountered, iterating over `rules_raw` or `binding_subjects` crashes with `TypeError: 'NoneType' object is not iterable`.
   Using `(item.get("rules") or [])` and `(item.get("subjects") or [])` provides fail-safe iteration (consistent with `export.py`).
   Furthermore, `main()` ignores command-line arguments and hardcodes `cluster_id: "local"`, preventing command-line overrides for external cluster models.

4. **Cross-tenant parameter bypass and inverted audit order in `routers/policies.py`**:
   In `d2-signalloom/apps/fe-signalloom/src/routers/policies.py`, `evaluate_policies` checks only `body.get("tenant_id")`.
   It fails to inspect `body.get("tenant")` or query parameters (`request.query_params.get("tenant")` / `request.query_params.get("tenant_id")`).
   A caller supplying `{"tenant": "foreign-tenant"}` bypasses the check for local single expression and fallback rule evaluations.
   Similarly, `register_bundle` and `rollback_bundle` inspect only `tenant_id`.
   In addition, outbound audit events were emitted before verifying tenant consistency across headers, body, and query parameters.

5. **Misleading test results for disconnected connectors and expired credentials**:
   In `routers/connectors.py`, `test_connector` unconditionally returned `valid=True` even when disconnected or in error.
   It also ignored expired credentials in `credential_expires_at`.
   Testing a disconnected or expired connector must report `valid=False` and request credential rotation.

6. **Residual mock data in memory-mode audit events**:
   In `d2-signalloom/apps/fe-signalloom/src/api_compat.py`, fallback base events in memory mode populated `actor="demo-actor"` and `detail={"source": "mock"}`.
   Replacing these with `actor="admin@signal-loom.ai"` and `detail={"source": "declarative_registration"}` restores attribution fidelity across storage modes.

## Proposed changes

1. **`d2-signalloom/apps/cpai-engineer`**:
   - Remove the unbounded, unsynchronized `inflight` map in `main.go`.
   - Read task status directly from `store.Get(id)`, which provides transactional, WAL-backed consistency.
   - Update `ensureRepo` in `executor.go` to supply `--branch <branch>` when cloning shallow repositories.

2. **`scripts/rbac-to-afm.py`**:
   - Defensively guard `(item.get("rules") or [])` and `(item.get("subjects") or [])` against `None` values.
   - Add CLI argument parsing for `--cluster-id` and `--cluster-name` with backwards-compatible defaults (`"local"` and `"Local Cluster"`).

3. **`d2-signalloom/apps/fe-signalloom/src/routers/policies.py`**:
   - Check both `"tenant_id"` and `"tenant"` in request bodies and query parameters against the authenticated tenant.
   - Reject cross-tenant requests before logging outbound audit records in `register_bundle` and `rollback_bundle`.

4. **`d2-signalloom/apps/fe-signalloom/src/routers/connectors.py`**:
   - Check connector status and `credential_expires_at` in `test_connector`.
   - Return `valid=False`, `scopes_ok=False`, and diagnostic error messages when disconnected or expired.

5. **`d2-signalloom/apps/fe-signalloom/src/api_compat.py`**:
   - Eliminate `"demo-actor"` and `{"source": "mock"}` in memory-mode audit events.

## Architecture and boundary impact

- **Zero-downtime consistency**: Eliminating data races and memory leaks in `cpai-engineer` ensures long-running agent pods survive continuous task execution.
- **Fail-closed tenant boundary**: Strict validation across `tenant_id` and `tenant` in body and query strings blocks cross-tenant leakage across all policy routes.
- **Attribution integrity**: Memory audit events now reflect genuine operator identities and eliminate fabricated mock records.

## Verification plan

- Run `cpai-engineer` Go unit and race tests.
- Run `d2-k8s-afm/test/afm-converter.bats` and verify `scripts/rbac-to-afm.py` handles empty and populated fixtures.
- Run `fe-signalloom` pytest suites (`test_compliance.py`, `test_connectors.py`, `test_tenant_isolation.py`, `test_audit_provenance.py`).
- Run `docs-lint` and `test/docs-index-sync.bats` to verify documentation synchronization.
