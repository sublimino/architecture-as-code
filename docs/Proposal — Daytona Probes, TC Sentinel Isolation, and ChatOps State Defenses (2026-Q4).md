# Proposal — Daytona Probes, TC Sentinel Isolation, and ChatOps State Defenses (2026-Q4)

## Abstract

This proposal establishes probe parity and memory bounds across developer workspaces, kernel packet controls, identity helpers, and chat agents.
Six areas are fortified:
- `hosted-daytona-coder`: `/healthz` and `/readyz` probe routes.
- `stun-tcctl`: `/health` and `/readyz` probe routes and unit test suite.
- `proof-helper`: `/health` and `/healthz` probe routes on A2A server.
- `fake-integration-proxy`: `/readyz` probe route.
- `zulip-chat-agent`: session task memory bounding and eviction.
- `fe-signalloom`: `/healthz` probe test verification.

## Problem Statement

### 1. Hosted Daytona Coder Probe Route Gaps (`hosted-daytona-coder`)
The `hosted-daytona-coder` manages ephemeral coding workspaces.
Its HTTP server registered `GET /health` but omitted `/healthz` and `/readyz`.
Standard Kubernetes liveness and readiness probes received 404 Not Found.

### 2. TC Sentinel Daemon Probe Route Parity and Testing (`stun-tcctl`)
The `stun-tcctl` binary controls traffic control BPF filters for network containment.
Its server registered `/healthz` but omitted `/health` and `/readyz`.
In addition, the binary lacked unit tests verifying HTTP endpoints.

### 3. Proof Helper A2A Server Probe Parity (`proof-helper`)
The `proof-helper` serves SPIFFE JWT and A2A challenge exchanges.
The A2A HTTP server registered only `/readyz`.
It omitted standard `/health` and `/healthz` probes, returning 404.

### 4. Integration Proxy Readiness Probe Parity (`fake-integration-proxy`)
The `fake-integration-proxy` mocks external integrations for demonstration environments.
Its request dispatcher handled `/health` and `/healthz`.
It omitted `/readyz`, causing cluster readiness checks to fail.

### 5. ChatOps Bot Unbounded Session Task Accumulation (`zulip-chat-agent`)
The `zulip-chat-agent` bridges ChatOps commands from Zulip topics into agent tasks.
Its `TaskMapper.createTask` pushed new task records into `session.tasks` indefinitely.
Active, long-lived topics accumulated unbounded task objects in memory.

### 6. Discovery Portal Healthz Test Coverage Gap (`fe-signalloom`)
The `fe-signalloom` FastAPI discovery portal serves health and discovery endpoints.
While `/healthz` was added to the server routes, `test_health.py` only asserted `/health` and `/livez`.
The `/healthz` path lacked dedicated test assertion coverage.

## Proposed Remediation

1. **`d2-signalloom/apps/hosted-daytona-coder`:**
   - Register `GET /healthz` and `GET /readyz` in `newServer()`.
   - Update `TestHealth` in `workspace_manager_test.go` to test all three probe paths.

2. **`d2-signalloom/apps/stun-sentinel` (`cmd/stun-tcctl`):**
   - Extract `newMux(l, reg)` to decouple route registration from BPF device loading.
   - Register `/health` and `/readyz` handlers alongside `/healthz`.
   - Add `d2-signalloom/apps/stun-sentinel/cmd/stun-tcctl/main_test.go` testing probe endpoints.

3. **`d2-signalloom/proof-helper`:**
   - Register `/health` and `/healthz` handlers alongside `/readyz` in `newA2AHandlerWithInstance`.
   - Update `TestReadyzEndpoint` in `main_adversarial_test.go` to verify `/health`, `/healthz`, and `/readyz`.

4. **`d2-signalloom/apps/fake-integration-proxy`:**
   - Add `"/readyz"` to supported GET probe paths in `server.py`.
   - Update `test_health_and_healthz_return_ok` in `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py` to assert `/readyz`.

5. **`d2-signalloom/apps/zulip-chat-agent`:**
   - Define `MAX_TASKS_PER_SESSION = 100` in `src/task-mapper.ts`.
   - Enforce task array bounding in `createTask`, evicting completed tasks when limit is reached.
   - Add unit test in `src/task-mapper.test.ts`.

6. **`d2-signalloom/apps/fe-signalloom`:**
   - Add `assert client.get("/healthz").json() == {"status": "ok"}` in `src/tests/test_health.py`.

## Verification Plan

- Go unit tests in `hosted-daytona-coder` verifying `/health`, `/healthz`, and `/readyz`.
- Go unit tests in `stun-tcctl` verifying `/health`, `/healthz`, and `/readyz`.
- Go unit tests in `proof-helper` verifying A2A probe endpoints.
- Python unittest suite in `fake-integration-proxy` verifying `/readyz`.
- Bun test suite in `zulip-chat-agent` verifying task bounding.
- Pytest suite in `fe-signalloom` verifying `/healthz`.
- Documentation linting via `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
