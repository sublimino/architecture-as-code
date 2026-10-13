# Proposal — Swarm Dispatch Resilience, HITL Gate Lifecycle, and Timing Defenses (2026-Q4)

**Status:** Proposed
**Author:** Antigravity Reliability Engineering
**Date:** 2026-10-13
**Scope:** d2-signalloom/apps (workspace-connector, prod-deploy-gate, triage-ci-worker, swarm-governor, cardvault, fe-signalloom)
**Tag:** DISPATCHGATE

## Context

The Signal Loom platform coordinates multi-agent swarms, human-in-the-loop (HITL) deployment enforcement, CI triage pipelines, and SaaS activity feeds.
These systems operate under multi-tenant isolation, concurrent background telemetry polling, cryptographic identity validation, and kernel execution constraints.
They must defend against unbounded memory exhaustion, goroutine data races, swallowed error cascades, Linux `MAX_ARG_STRLEN` `E2BIG` execve aborts, and side-channel timing leaks.

## Problem statement

Adversarial exploration, concurrent execution tracing, and static audit identified multiple vulnerabilities and operational risks across `d2-signalloom/apps`:

1. **Concurrent data race and swallowed ingest errors in `workspace-connector`**:
   - In `d2-signalloom/apps/workspace-connector/main.go`, `s.lastPolled` is written by the background polling goroutine (`pollAndIngest`) and concurrently read by incoming HTTP handlers (`handlePoll` and `handleStatus`) without a `sync.RWMutex`.
   - When `pollAndIngest` posts observations, HTTP error responses are ignored. The method logs nothing and returns `len(obsList)` as success.
   - Handlers `handlePoll` and `handleStun` decode request payloads without `http.MaxBytesReader`, exposing the process to unbounded memory exhaustion.

2. **Unbounded pending gate memory leak and anonymous approval in `prod-deploy-gate`**:
   - In `d2-signalloom/apps/prod-deploy-gate/main.go`, `s.pending` tracks in-flight deployment requests. Gates are only removed from the map when approved via `handleGateApprove`. If an approval is rejected, expired, or abandoned, the request remains in memory indefinitely without TTL-based cleanup.
   - `handleGateApprove` does not validate that `req.Approver` is non-empty, permitting anonymous approvals of production deployments and breaking HITL audit attribution.
   - No status query endpoint (`GET /gate/{id}` or `GET /gate/status`) exists, preventing orchestrators and operators from inspecting pending request state.
   - Mutating request bodies lack `http.MaxBytesReader` bounding.

3. **Linux `MAX_ARG_STRLEN` `E2BIG` exec failure and GitHub comment overflow in `triage-ci-worker`**:
   - In `d2-signalloom/apps/triage-ci-worker/main.go`, `postGitHubComment` executes `exec.Command("gh", "pr", "comment", ..., "--body", comment)` passing the full triage markdown text as a command-line argument.
   - Under Linux elf execution, kernel constant `MAX_ARG_STRLEN` limits any single argument to 128 KiB (131,072 bytes). When CI builds produce extensive test failure logs, passing `comment` directly on argv causes `execve: E2BIG (Argument list too long)`.
   - Furthermore, GitHub's API enforces a strict maximum comment limit of 65,536 characters. Passing large failure reports causes GitHub to reject comments with HTTP 422 Unprocessable Entity.
   - `FormatTriageComment` must cap entries with a truncation notice. `postGitHubComment` must pass the comment body through stdin via `--body-file -`.

4. **Masked HTTP error status and unbounded streams in `swarm-governor`**:
   - In `d2-signalloom/apps/swarm-governor/a2a/client.go`, `SendTask` and `GetTask` make HTTP requests to downstream agents but omit status code checks (`resp.StatusCode < 200 || resp.StatusCode >= 300`) before unmarshaling JSON-RPC responses.
   - When downstream proxies return HTTP error pages, `json.Unmarshal` fails with confusing syntax errors. This conceals the real upstream HTTP failure.
   - `io.ReadAll(resp.Body)` on agent card discovery, task dispatch, and task polling reads unbounded streams without `io.LimitReader`, risking OOM on malformed responses.
   - `handleSubmit` in `main.go` parses task submissions without `http.MaxBytesReader`.

5. **Timing attack on Basic Authentication in `cardvault`**:
   - In `d2-signalloom/apps/cardvault/main.go`, `requireAuth` verifies username and password using standard Go string comparisons (`u != username || p != password`).
   - Standard string comparisons exit early on the first mismatched byte, creating a timing side-channel that allows attackers to reconstruct credentials through latency variance.
   - Basic Auth verification must use `crypto/subtle.ConstantTimeCompare`.

6. **Untrimmed tenant whitespace in `fe-signalloom/routers/policy_engine.py`**:
   - In `d2-signalloom/apps/fe-signalloom/src/routers/policy_engine.py`, `proxy_policy_engine` validates `tenant_id` and `tenant` in JSON request bodies against the authenticated tenant.
   - Unlike query parameter validation (which applies `.strip()`), body values were checked with exact equality (`val != tenant_id`). A request with `"tenant": "acme "` resulted in a false 403 Forbidden.

## Proposed changes

1. **`d2-signalloom/apps/workspace-connector`**:
   - Protect `s.lastPolled` with `sync.RWMutex` (`RLock` in `handleStatus` and `handlePoll`, `Lock` in `pollAndIngest`).
   - Validate `resp.StatusCode` in `pollAndIngest`. Log warnings and return descriptive errors on failure.
   - Wrap request bodies with `http.MaxBytesReader(w, r.Body, 1<<20)`.

2. **`d2-signalloom/apps/prod-deploy-gate`**:
   - Add a background reaper goroutine (`startJanitor`) and prune method that purges expired pending gates from `s.pending`.
   - Require non-empty `req.Approver` in `handleGateApprove`, returning HTTP 400 Bad Request if missing or whitespace-only.
   - Implement `GET /gate/{id}` to allow querying status and expiry of pending gates.
   - Enforce `http.MaxBytesReader(w, r.Body, 1<<20)`.

3. **`d2-signalloom/apps/triage-ci-worker`**:
   - In `parser.go`, cap failure listings to 50 items. Enforce an overall length budget below 60,000 characters with a truncation banner.
   - In `main.go`, execute `gh pr comment <pr> --repo <repo> --body-file -` with `cmd.Stdin = strings.NewReader(comment)`, keeping bulk data off argv.

4. **`d2-signalloom/apps/swarm-governor`**:
   - In `a2a/client.go`, check `resp.StatusCode` in `SendTask` and `GetTask`, returning structured errors indicating the HTTP status code before attempting JSON decode.
   - Bound all `resp.Body` reads with `io.LimitReader(resp.Body, 10<<20)`.
   - Add `http.MaxBytesReader(w, r.Body, 4<<20)` on `handleSubmit`.

5. **`d2-signalloom/apps/cardvault`**:
   - Replace standard string comparisons in `requireAuth` with `subtle.ConstantTimeCompare([]byte(u), []byte(username)) == 1` and `subtle.ConstantTimeCompare([]byte(p), []byte(password)) == 1`.

6. **`d2-signalloom/apps/fe-signalloom`**:
   - In `routers/policy_engine.py`, strip whitespace from JSON body tenant fields before comparison, matching query parameter normalization.

## Verification plan

- `workspace-connector`: Unit and route tests verifying mutex concurrency, HTTP error status propagation, and body bounds.
- `prod-deploy-gate`: Unit and integration tests covering gate expiry reaping, approver validation, and `GET /gate/{id}` route.
- `triage-ci-worker`: Parser tests with >100 failures ensuring truncation within 60k chars and execution test with stdin payload.
- `swarm-governor`: Tests verifying non-200 HTTP responses in `SendTask` and `GetTask`, and payload bounding.
- `cardvault`: Unit and adversarial tests verifying constant-time authentication.
- `fe-signalloom`: Pytest suites verifying `policy_engine.py` whitespace handling.
- `docs-lint` / `docs-index-sync`: Validate markdown style and index registration.
