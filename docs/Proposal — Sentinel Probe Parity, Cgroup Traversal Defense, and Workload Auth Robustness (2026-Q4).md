# Proposal — Sentinel Probe Parity, Cgroup Traversal Defense, and Workload Auth Robustness (2026-Q4)

## Context and Motivation

Autonomous agent systems require strict resilience guarantees across container orchestrators.
Microservices must respond consistently to orchestrator health and readiness probes.
Missing probes cause false-negative restarts and deployment gate timeouts.
Subprocess adapters must guard against unexpected execution errors.
Cgroup inspectors must enforce boundary containment against malicious path traversal inputs.
Token decoders must validate payload structures before property access.
HTTP endpoints must reject invalid HTTP verbs with appropriate status codes.

## Proposed Architectural Hardening

This proposal hardens six architectural components across the platform.

First, Olly Sentinel registers standard probe routes.
Both `/health` and `/readyz` join `/healthz` on the main HTTP surface.

Second, the AgentMaxxing host sensor prevents cgroup path traversal escapes.
The cgroup resolver checks that canonicalized paths remain within the cgroup root hierarchy.

Third, the host sensor openat2 wrapper rejects invalid and malicious relative paths.
Empty paths and embedded null bytes raise clean value errors before syscall dispatch.

Fourth, SPIRE Workload API adapters guard against subprocess execution errors.
Process timeouts and execution errors convert cleanly into documented runtime errors.

Fifth, Olly Sentinel authz token decoding validates payload structure.
Malformed base64 and non-dictionary payloads raise clean value errors.

Sixth, Cardvault endpoints enforce HTTP method constraints.
Requests using verbs other than GET or HEAD return 405 Method Not Allowed.

## Target Components and Concrete Changes

### 1. Olly Sentinel Probe Parity

Component path: `olly-replica/apps/sentinel/olly_sentinel/main.py`.
The server registers `/health` and `/readyz` alongside `/healthz`.
Orchestrators probing any standard liveness or readiness endpoint receive a 200 OK response.
Unit tests in `olly-replica/apps/sentinel/tests/test_a2a_app.py` verify all three probe routes.

### 2. Host Sensor Cgroup Traversal Defense

Component path: `d2-signalloom/apps/agentmaxxing-host-sensor/cgroups.py`.
The method `resolve_cgroup_path_for_pid` canonicalizes candidate paths.
It verifies that the resolved path stays within the cgroup root directory.
Paths attempting traversal outside the root return None.
Unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_cgroups.py` verify traversal rejection.

### 3. Descriptor-Relative openat2 Path Guard

Component path: `d2-signalloom/apps/agentmaxxing-host-sensor/openat2.py`.
The function `open_beneath` guards descriptor-relative opens.
Empty relative paths and paths with embedded null bytes raise `ValueError`.
Unit tests in `d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py` verify rejection of empty and null-byte paths.

### 4. SPIRE Workload API Subprocess Error Handling

Component path: `d2-agent-trust/adapters/spire_workload_api.py`.
Subprocess execution wraps in a try-except block handling `subprocess.SubprocessError` and `OSError`.
Subprocess failures fail closed by raising `RuntimeError`.
Unit tests in `d2-agent-trust/test/test_contracts.py` verify that timeouts raise `RuntimeError`.

### 5. Sentinel AuthZ Token Decoding Robustness

Component path: `olly-replica/apps/sentinel/olly_sentinel/authz.py`.
The `decode` function handles base64 decode errors and non-dictionary payloads safely.
Malformed inputs raise `ValueError` rather than leaking internal errors.
Unit tests in `olly-replica/apps/sentinel/tests/test_authz_ctx.py` verify malformed input rejection.

### 6. Cardvault HTTP Method Gate

Component path: `d2-signalloom/apps/cardvault/main.go`.
Handlers for `/api/v1/cards`, `/healthz`, and `/readyz` verify request methods.
Non-GET and non-HEAD requests return 405 Method Not Allowed with JSON error bodies.
Unit tests in `d2-signalloom/apps/cardvault/main_test.go` verify method rejection.

## Verification Plan

Every hardened component is validated by automated tests.

1. Run `python3 -m py_compile olly-replica/apps/sentinel/olly_sentinel/main.py`.
2. Run `python3 -m unittest d2-signalloom/apps/agentmaxxing-host-sensor/test_cgroups.py`.
3. Run `pytest d2-signalloom/apps/agentmaxxing-host-sensor/test_hasher.py`.
4. Run `pytest d2-agent-trust/test/test_contracts.py`.
5. Run `python3 -m py_compile olly-replica/apps/sentinel/olly_sentinel/authz.py`.
6. Run `go test ./...` in `d2-signalloom/apps/cardvault`.
7. Verify documentation indexing and linting with `make docs-lint`.
