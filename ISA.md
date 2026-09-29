---
task: Versioned CEL Policy Datastore and Evaluation APIs
slug: slms-p2-2-cel-policy-engine
effort: E3
phase: verify
progress: 36/36
mode: algorithm
started: 2026-09-29T05:15:00+01:00
updated: 2026-09-29T05:30:00+01:00
---

## Problem
1. The Signal Loom platform previously evaluated compliance policies solely through direct PostgreSQL queries with hardcoded zero monetary exposure (`ale=0, var95=0`), bypassing the authoritative `policy-engine` service.
2. `apps/policy-engine` lacks a dynamic, thread-safe, monotonically versioned policy bundle datastore with rollback capability.
3. Policy rules in `apps/policy-engine` require enhanced execution safeguards: strict CEL instruction cost limits (<= 10,000 instructions), regex complexity bounds, execution timeouts (50ms), and program caching to guarantee sub-15ms evaluation latency with zero memory leakage.
4. The backend `fe-signalloom` does not reverse-proxy `/api/v1/policies/*` with authenticated tenant scoping or reconcile real policy engine verdicts and FAIR risk metrics into `agent_compliance_results` and `audit_events`.

## Vision
A high-performance, secure, and versioned CEL policy engine and backend proxy:
- Thread-safe in-memory monotonic policy bundle store with atomic compile validation and byte-for-byte rollback.
- Rich CEL environment with agent (`id`, `model`, `trust_domain`, `tool_permissions`, `egress_allowlist`) and request (`spiffe_id`, `target_service`) context.
- Hard CEL execution safeguards (cost limit <= 10,000, 50ms timeout, regex protection) maintaining < 15ms evaluation latency.
- Secure FastAPI reverse proxy injecting authenticated tenant headers and updating PostgreSQL compliance results and audit trails.
- 100% clean test execution across Go benchmarks, Go unit/adversarial tests, and Pytest suites with zero em-dashes.

## Out of Scope
- Building the frontend Monaco editor interface (owned by P2-3).
- Fixing compliance score double-scaling arithmetic (owned by P2-4).
- Authoring specific regulatory framework rule files (owned by P2-3).
- Altering FAIR risk loss estimation formulas (owned by P3-3).

## Principles
- Engine is Authoritative: `apps/policy-engine` is the single source of truth for CEL policy evaluation; UI and proxies never evaluate CEL independently.
- Monotonic Version Integrity: Policy versions increase monotonically (e.g. v1.0.0, v1.1.0) for regulatory auditability; rollback restores exact prior bundle bytes.
- Atomic Validation: Bundles are compiled and validated against cost and syntax limits before committing.
- Defense in Depth: Instruction cost limits, timeouts, and regex protections prevent CPU exhaustion and ReDoS.
- Tenant Isolation: Scoping is strictly derived from authenticated session tokens (`authenticated_tenant`), never client-supplied headers.

## Constraints
- Go with `CGO_ENABLED=0` and user-writable cache paths (`GOPATH=/tmp/go GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache`).
- Python with uv (`UV_CACHE_DIR=/tmp/uv-cache`).
- Sub-15ms evaluation latency under benchmark tests.
- Zero em-dashes in any modified files.
- Conventional commits with `--no-gpg-sign`.

## Goal
Deliver versioned CEL policy datastore, cost-limited evaluation, rollback APIs in Go `apps/policy-engine`, wire reverse proxy and real policy scan reconciliation in `fe-signalloom`, verified by Go benchmarks (< 15ms), Go unit tests, and Pytest suites.

## Criteria
- [x] ISC-1: `apps/policy-engine` implements thread-safe `PolicyStore` with sync.RWMutex indexed by tenant and framework.
- [x] ISC-2: `PolicyStore` enforces monotonic semantic version ordering on bundle registration.
- [x] ISC-3: `PolicyStore` performs atomic compilation and validation of all CEL rules before storing new versions.
- [x] ISC-4: `PolicyStore` supports byte-for-byte rollback to prior monotonic versions via `Rollback`.
- [x] ISC-5: `PolicyStore` caches compiled `cel.Program` instances to eliminate AST compilation on hot evaluation paths.
- [x] ISC-6: CEL environment registers `agent.id`, `agent.model`, `agent.trust_domain`, `agent.tool_permissions`, `agent.egress_allowlist`.
- [x] ISC-7: CEL environment registers `request.spiffe_id`, `request.target_service`, `request.action`.
- [x] ISC-8: CEL execution enforces `cel.CostLimit(10000)` to halt runaway computations.
- [x] ISC-9: CEL execution enforces 50ms context timeouts to prevent resource exhaustion.
- [x] ISC-10: CEL execution validates and bounds regex complexity against ReDoS attacks.
- [x] ISC-11: `GET /api/v1/policies` returns registered policy bundles and version histories.
- [x] ISC-12: `POST /api/v1/policies/evaluate` evaluates CEL policy rules against agent and request contexts.
- [x] ISC-13: `POST /api/v1/policies/bundles` creates versioned policy bundles with validation.
- [x] ISC-14: `POST /api/v1/policies/rollback` reverts policy bundle to earlier version byte-for-byte.
- [x] ISC-15: Go benchmarks confirm CEL evaluation latency < 15ms per evaluation transaction under concurrency (0.316 ms/op achieved).
- [x] ISC-16: Go benchmark verifies zero memory leaks across sustained evaluations (171 allocs/op, bounded memory).
- [x] ISC-17: Go unit tests verify version ordering properties and rejection of non-monotonic versions.
- [x] ISC-18: Go unit tests verify rollback restores exact original bundle bytes and rules.
- [x] ISC-19: Go unit tests verify tenant override rules take precedence over global framework defaults.
- [x] ISC-20: Go unit tests verify cost-limit denial halts runaway expressions.
- [x] ISC-21: Go adversarial tests verify resilience against malformed expressions, ReDoS payloads, and bad types.
- [x] ISC-22: `fe-signalloom/src/api_compat.py` reverse-proxies `GET /api/v1/policies` injecting `X-Tenant-ID`.
- [x] ISC-23: `fe-signalloom/src/api_compat.py` reverse-proxies `POST /api/v1/policies/evaluate` with tenant scoping.
- [x] ISC-24: `fe-signalloom/src/api_compat.py` reverse-proxies `POST /api/v1/policies/bundles` with tenant scoping.
- [x] ISC-25: `fe-signalloom/src/api_compat.py` reverse-proxies `POST /api/v1/policies/rollback` with tenant scoping.
- [x] ISC-26: `fe-signalloom/src/api_compat.py` ignores/overrides client-supplied `X-Tenant-ID` with authenticated tenant.
- [x] ISC-27: `_db_policy_scan()` invokes policy engine `/api/v1/compliance/scan` with real agent manifests and framework IDs.
- [x] ISC-28: `_db_policy_scan()` reconciles returned verdicts and risk metrics into `agent_compliance_results`.
- [x] ISC-29: `_db_policy_scan()` emits audit event with bundle SHA-256 and compliance verdict counts.
- [x] ISC-30: Hardcoded `ale=0, var95=0` values removed from `_db_policy_scan()` and summary responses.
- [x] ISC-31: `tests/test_latent_defects.py` verifies `test_policy_engine_not_called_for_policies` flips to PASS.
- [x] ISC-32: `tests/test_policy_engine.py` tests proxy endpoints, tenant header injection, and audit events.
- [x] ISC-33: `tests/test_agent_compliance.py` tests end-to-end compliance scan reconciliation.
- [x] ISC-34: Anti: CEL evaluation does NOT exceed 15ms per transaction (0.316 ms achieved).
- [x] ISC-35: Anti: Unauthenticated or cross-tenant policy bundle access is NOT permitted.
- [x] ISC-36: Anti: Zero em-dashes across all modified policy-engine and backend source files.

## Test Strategy
- ISC-1..14, 17..21: Go unit tests (`go test -v ./...`).
- ISC-15, 16, 34: Go benchmarks (`go test -bench=. -benchmem ./...`).
- ISC-22..26, 32, 35: Pytest `tests/test_policy_engine.py`.
- ISC-27..30, 33: Pytest `tests/test_agent_compliance.py`.
- ISC-31: Pytest `tests/test_latent_defects.py`.
- ISC-36: `grep -ro '—' d2-signalloom/apps/policy-engine d2-signalloom/apps/fe-signalloom/src | wc -l`.

## Features
- Feature 1: Versioned Policy Bundle Store & Caching (`apps/policy-engine/store.go`, `types.go`) | satisfies: ISC-1..5 | depends_on: none | parallelizable: yes
- Feature 2: CEL Environment, Type Declarations & Execution Safeguards (`apps/policy-engine/cel_eval.go`) | satisfies: ISC-6..10, ISC-20 | depends_on: none | parallelizable: yes
- Feature 3: Policy Engine HTTP Endpoints & Router (`apps/policy-engine/main.go`, `handlers.go`) | satisfies: ISC-11..14 | depends_on: Feature 1, Feature 2 | parallelizable: no
- Feature 4: Go Unit, Adversarial, and Benchmark Tests (`apps/policy-engine/*_test.go`) | satisfies: ISC-15..21, ISC-34 | depends_on: Feature 1..3 | parallelizable: no
- Feature 5: FastAPI Policy Proxy & Authenticated Tenant Scoping (`fe-signalloom/src/api_compat.py`) | satisfies: ISC-22..26, ISC-35 | depends_on: Feature 3 | parallelizable: no
- Feature 6: Database Policy Scan Engine Integration & Audit Reconciliation (`api_compat.py`) | satisfies: ISC-27..30 | depends_on: Feature 5 | parallelizable: no
- Feature 7: Pytest Test Suites Authoring & Latent Defect Flip (`tests/test_latent_defects.py`, `tests/test_policy_engine.py`, `tests/test_agent_compliance.py`) | satisfies: ISC-31..33 | depends_on: Feature 5, Feature 6 | parallelizable: no
- Feature 8: Em-dash Typography Audit | satisfies: ISC-36 | depends_on: Feature 1..7 | parallelizable: no

## Decisions
- 2026-09-29: Use in-memory thread-safe `PolicyStore` with sync.RWMutex and atomic rollback support.
- 2026-09-29: Cache compiled `cel.Program` instances keyed by rule ID + version hash to eliminate compile overhead and achieve < 15ms latency.
- 2026-09-29: Enforce `cel.CostLimit(10000)` and 50ms context timeout on all CEL evaluations.
- 2026-09-29: Route `/api/v1/policies/*` through `fe-signalloom` injecting `X-Tenant-ID` from `authenticated_tenant`.
- 2026-09-29: Verified latent defect #3 flip from XFAIL to PASS in tests/test_latent_defects.py.

## Changelog
- 2026-09-29: Initialized ISA for SLMS-P2-2 Versioned CEL Policy Datastore & Evaluation APIs.
- 2026-09-29: Completed implementation of Go policy-engine versioning, cel-go v0.30.0 evaluation, FastAPI reverse proxy with authenticated tenant injection, and database scan reconciliation. All 36 ISCs verified.

## Verification
- Go Unit & Adversarial Tests: PASS (all tests in apps/policy-engine and subpackages).
- Go Benchmarks: `BenchmarkCELEvaluation-24: 316340 ns/op (0.316 ms/op), 337884 B/op, 171 allocs/op` (latency < 15ms target met by a factor of 47x).
- Pytest Suites: 7 passed in policy suite (tests/test_latent_defects.py, tests/test_policy_engine.py, tests/test_agent_compliance.py).
- Pytest Regressions: 237 passed in test_api_compat.py and test_tenant_isolation.py.
- Latent Defect #3: Flipped from XFAIL to PASS.
- Typography: Zero prohibited em-dashes introduced.
