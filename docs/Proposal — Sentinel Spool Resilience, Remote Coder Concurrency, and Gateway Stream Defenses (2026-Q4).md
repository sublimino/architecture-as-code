# Proposal — Sentinel Spool Resilience, Remote Coder Concurrency, and Gateway Stream Defenses (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** d2-signalloom/apps (stun-sentinel, hosted-daytona-coder, factory-appraiser, netassert-controller, prompt-commit-summarizer, zulip-chat-agent)
**Tag:** SENTINELCODER

## Context

Signal Loom captures network and process telemetry via eBPF sentinels.
It also runs remote developer workspaces, artifact appraisers, and network assertion controllers.
These microservices handle untrusted HTTP requests, high-frequency telemetry spools, concurrent background tasks, and asynchronous lifecycle state.
They must defend against clock drift, goroutine data races, memory exhaustion from unbounded requests, and silent probe rejections.

## Problem statement

Adversarial exploration, concurrent execution tracing, and static audit identified multiple vulnerabilities and operational risks across `d2-signalloom/apps`:

1. **Clock drift and fsync race in `stun-sentinel/pkg/correlator`**:
   - In `d2-signalloom/apps/stun-sentinel/pkg/correlator/sender_test.go`, `TestSpoolHonoursRetryAfter` evaluated `http_date` at table declaration. By execution time, clock drift caused `parseRetryAfter` to compute a zero wait.
   - In `token_source_test.go`, `TestObservationsSpoolUntilTheTokenSourceProducesAKey` used an aggressive 500ms timeout. Heavy directory `fsync` operations during parallel test execution caused false timeouts.
   - Dynamic evaluation of HTTP date headers against `clk.Now()` and bounded poll extensions eliminate timing fragility.

2. **Data race on workspace status and untrimmed tenant whitespace in `hosted-daytona-coder`**:
   - In `d2-signalloom/apps/hosted-daytona-coder/workspace-manager.go`, `Create()` spins up a background goroutine that updates `ws.Status = "running"` after a two-second delay. Callers of `Get()` and `List()` receive the exact pointer `*WorkspaceResponse`. When concurrent HTTP handlers encode `ws` to JSON via `json.NewEncoder(w).Encode(ws)`, the read occurs without synchronization against the background write, causing a data race.
   - Returning a shallow clone (`*ws` copy under `m.mu.RLock()`) ensures that concurrent readers never race with the background status updater.
   - `extractTenant` and `POST /workspaces` do not strip whitespace from `req.TenantID` in the request body. If a caller submits `"tenant_id": "tenant-1 "`, `req.TenantID != tenant` evaluates to true, resulting in a false 403 Forbidden.
   - Active workspaces accumulate in `m.workspaces` indefinitely without capacity limits or stale workspace pruning.

3. **Unbounded request body streams in `factory-appraiser`**:
   - In `d2-signalloom/apps/factory-appraiser/main.go`, `appraiseHandler` and `validate-promotion` decode JSON directly from `r.Body` without `http.MaxBytesReader`. An oversized or streaming HTTP body can exhaust server memory.
   - The server registers `GET /healthz` but does not register `GET /readyz` or `GET /health`, risking probe failures on standard Kubernetes ingress or cluster checks.

4. **Unhandled `ValueError` crash and unconstrained draining in `netassert-controller`**:
   - In `d2-signalloom/apps/netassert-controller/server.py`, `_drain_body` executes `int(self.headers.get("Content-Length", "0"))`. If an HTTP client supplies a non-numeric `Content-Length` header (e.g. `"chunked"` or malformed text), Python raises an unhandled `ValueError`, crashing the request handler and returning HTTP 500.
   - If `length` is negative, `self.rfile.read(-1)` hangs indefinitely reading until socket EOF. If `length` is excessively large, reading without a cap risks memory exhaustion.
   - The server only serves `GET /health` and lacks `GET /healthz`.

5. **Probe interception by catch-all handler in `prompt-commit-summarizer`**:
   - In `d2-signalloom/apps/prompt-commit-summarizer/main.go`, `mux.HandleFunc("/", makeSummarizeHandler(...))` matches all paths. Kubernetes probes to `/healthz` or `/readyz` receive HTTP 405 because the handler requires POST.
   - Header `Ce-Type` is checked without trimming leading and trailing whitespace.

6. **Unbounded session map and hanging HTTP calls in `zulip-chat-agent`**:
   - In `d2-signalloom/apps/zulip-chat-agent/src/task-mapper.ts`, `this.sessions` is an unbounded `Map<string, TaskSession>()`. Over long-running operational lifetimes, chat topics and task entries accumulate monotonically without eviction.
   - In `zulip-client.ts`, `fetch()` calls lack an `AbortSignal` timeout, causing goroutines and event loops to hang indefinitely if the upstream Zulip server stalls.

## Proposed changes

### 1. Hardening `stun-sentinel/pkg/correlator` retry timing and test resilience
- In `sender_test.go`: Convert `headerVal` in `testCases` to a function `headerValFn func(clk Clock) string` evaluated dynamically inside the subtest relative to `clk.Now()`. Extend polling loop timeout from 500ms to 1500ms.
- In `token_source_test.go`: Increase loop duration to 2000ms (200 iterations at 10ms) to accommodate disk writes and directory syncs during parallel execution.

### 2. Eliminating data race and normalizing tenant in `hosted-daytona-coder`
- In `workspace-manager.go`:
  - In `Get()` and `List()`, return copies (`cloneWorkspace(ws)`) rather than direct pointers, preventing data races between concurrent JSON serialization and the background transition goroutine.
  - In `POST /workspaces`: Normalize `req.TenantID = strings.TrimSpace(req.TenantID)` before cross-tenant comparison and persistence.
  - Add capacity bounds and `PruneExpired` helper.

### 3. Capping request bodies and probe routing in `factory-appraiser`
- In `main.go`:
  - Add `r.Body = http.MaxBytesReader(w, r.Body, 4<<20)` to `appraiseHandler` and `validate-promotion`.
  - Register `GET /readyz` and `GET /health` alongside `GET /healthz`.

### 4. Hardening `_drain_body` and probe paths in `netassert-controller`
- In `server.py`:
  - Wrap `Content-Length` parsing in a `try...except (ValueError, TypeError)` block.
  - Clamp draining length to `0 <= length <= 1<<20` (1 MiB maximum drain) to prevent hangs and OOM.
  - Register `GET /healthz` alongside `GET /health`.

### 5. Registering standard probe endpoints in `prompt-commit-summarizer`
- In `main.go`:
  - Register `GET /healthz` and `GET /readyz` alongside `GET /health`.
  - Trim `Ce-Type` header: `strings.TrimSpace(r.Header.Get("Ce-Type"))`.

### 6. Bounding sessions and adding fetch timeouts in `zulip-chat-agent`
- In `task-mapper.ts`:
  - Implement LRU or capacity-based pruning in `TaskMapper` when `this.sessions.size > MAX_SESSIONS` (1000).
- In `zulip-client.ts`:
  - Add `signal: AbortSignal.timeout(15000)` to all `fetch` calls.
- Add unit test coverage for `TaskMapper` command parsing and session lifecycle.

## Verification plan

### Automated verification
1. `stun-sentinel`: Run `go test -v ./pkg/correlator/...` and `go test ./...`.
2. `hosted-daytona-coder`: Run `go test -v ./...` verifying workspace cloning, isolation, and whitespace normalization.
3. `factory-appraiser`: Run `go test -v ./...` verifying request size limiting and probe endpoints.
4. `netassert-controller`: Run `pytest test/test_controller.py` including new tests for malformed `Content-Length` and `/healthz`.
5. `prompt-commit-summarizer`: Run `go test -v ./...` verifying `/healthz` and `/readyz` probe responses.
6. `zulip-chat-agent`: Run `bun test` or TypeScript compilation verifying bounded session handling.
7. Documentation: Run `scripts/docs-lint.sh` and `bats test/docs-index-sync.bats`.
