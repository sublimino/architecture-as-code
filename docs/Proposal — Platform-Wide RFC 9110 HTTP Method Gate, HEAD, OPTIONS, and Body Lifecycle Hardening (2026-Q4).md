# Proposal — Platform-Wide RFC 9110 HTTP Method Gate, HEAD, OPTIONS, and Body Lifecycle Hardening (2026-Q4)

| Attribute | Value |
| :--- | :--- |
| **Date** | 2026-10-13 |
| **Status** | Delivered |
| **Branch** | `integration/slsi-v0.1.0` |
| **Scope** | `d2-signalloom`, `d2-agent-trust`, `d2-platform-apps`, `d2-cpai`, `olly-replica`, `tools/harness-dash`, `test` |

## 1. Context and problem statement

Signal Loom, Agent Trust, CPAI, and Olly Sentinel expose HTTP services across Go, Python, and TypeScript runtimes.
Before this hardening wave, multiple services and test harnesses handled HTTP methods, headers, and request streams inconsistently.
Adversarial testing and protocol audits identified five systemic classes of defects across the platform.

### RFC 9110 Section 9.3.2 HEAD body suppression

Several handlers wrote JSON error payloads or health payloads directly to the socket during `HEAD` requests.
Writing a response body on `HEAD` violates RFC 9110 Section 9.3.2.
On persistent HTTP/1.1 connections, an unexpected `HEAD` payload corrupts the byte stream for the next pipelined request.

### RFC 9110 Section 9.3.7 OPTIONS parity

Multiple endpoints supported `GET`, `POST`, or `DELETE` without handling `OPTIONS`.
Clients and preflight probes that sent `OPTIONS` received `404 Not Found` or `405 Method Not Allowed` instead of `204 No Content`.
Authenticated routes also rejected preflight `OPTIONS` calls before returning route capability headers.

### RFC 9110 Section 15.5.6 405 Allow header completeness

When handlers rejected unsupported HTTP verbs with `405 Method Not Allowed`, many omitted the mandatory `Allow` header.
Other handlers advertised `GET` in `Allow` while omitting `HEAD` or `OPTIONS`.
Proxy routes in `d2-signalloom/apps/fe-signalloom` also dropped upstream `Allow`, `Location`, `ETag`, and `Retry-After` headers on empty-body responses.

### Bounded request body draining and HTTP/1.1 stream framing

Handlers that returned early on authentication or method checks left unread request bytes in the socket buffer.
Closing a connection with unread bytes triggers a TCP `RST` that can discard the client response.
Reusing a keep-alive connection without draining bounded input causes HTTP request smuggling or stream desynchronization.
Python `BaseHTTPRequestHandler` services also needed explicit `Transfer-Encoding` and `Content-Length` conflict rejection (`400 Bad Request`) and bounded chunked-stream draining.

### Boundary input, token, tenant, and URL sanitization

Service boundaries required stricter input hygiene across all slices.
Outbound webhook and ingest URLs, bearer tokens, and CLI helper arguments needed strict sanitization.
Task identifiers, multi-tenant defaults, and shared test caches also required boundary isolation.

## 2. Architecture and hardening design

Every HTTP server, proxy, and test harness stub across the monorepo now enforces five uniform invariants:

1. **Method gate and Allow header fidelity:** Every route checks the request verb against its explicit allowlist. Unsupported verbs return `405 Method Not Allowed` with a deterministic, comma-separated `Allow` header that includes `HEAD` and `OPTIONS` where applicable.
2. **HEAD response parity without body bytes:** Every route that supports `GET` also accepts `HEAD`. Handlers compute identical status codes, `Content-Type`, and metadata headers, then suppress the response body on both `2xx` and error statuses.
3. **OPTIONS preflight and capability discovery:** Every route accepts `OPTIONS` before bearer-token rejection. The handler drains any bounded request body, writes the route `Allow` header, and returns `204 No Content` with an empty body.
4. **Bounded body draining and TE.CL desync defense:** Before an early refusal or handler exit, servers drain up to `64 KiB` from the request stream. Requests with both `Transfer-Encoding` and `Content-Length`, or malformed chunk framing, return `400 Bad Request` and close the socket.
5. **Strict boundary sanitization and tenant isolation:** Outbound clients check URL schemes and hosts before connecting. Task, branch, and database identifiers reject path traversal and leading CLI hyphens. Multi-tenant endpoints enforce authenticated tenant scoping with zero fallback to demo fixtures.

## 3. Inventory of hardened slices and components

This proposal consolidates 137 micro-proposals delivered on `integration/slsi-v0.1.0` into one platform record.
The table below summarizes the hardened slices, services, and key changes.

| Slice or directory | Hardened components | Key changes delivered |
| :--- | :--- | :--- |
| `d2-signalloom/apps/signal-ingest` | Ingest API, audit webhooks, GKE/GCP adapters, policy routes, subject rights, export, delegations, store stats | Enforced `GET`/`HEAD`/`POST`/`DELETE`/`OPTIONS` method gates, `Allow` headers, `HEAD` error body suppression, bounded body draining, HTTP/1.1 keep-alive framing checks, and authenticated tenant audit provenance. |
| `d2-signalloom/apps/fleet-manager` | Fleet API, consistency routes, policy routes, OpenBao client and token mocks, caller auth | Added RFC 9110 `OPTIONS` dispatch, `HEAD` body suppression, `405` `Allow` header parity across production routes and test mock servers, and bounded request draining. |
| `d2-signalloom/apps/policy-engine` | Evaluation API, compliance routes, fleet scan, observations, health probes | Enforced route method gates, `HEAD` parity, `OPTIONS` preflight handling, `Allow` headers, read header timeouts, and strict cross-tenant query/body validation. |
| `d2-signalloom/apps/fe-signalloom` | Discovery portal ASGI, demo runner, policy/federation/risk/fleet/fusion/telemetry proxies, salt OpenBao mocks | Preserved `204 No Content` empty bodies and upstream `Allow`, `Location`, `ETag`, and `Retry-After` headers across all proxy routes. Eliminated mutable `Response` defaults and hardened `HEAD`/`OPTIONS` routing. |
| tools/demo-console (removed after this record, in 936db4d93) | Main console, orbit approval, security, steps, metrics, terminal, proxy routes | Added Slowloris header timeouts, `GET`/`HEAD`/`OPTIONS` parity, `405` `Allow` headers, and `HEAD` error body suppression across all console endpoints. |
| `d2-signalloom/apps/cpai-engineer` | In-cluster coding agent harness and executor | Enforced `HEAD`/`OPTIONS` parity, bounded body draining, HTTP keep-alive timeouts, git flag-injection validation, remote protocol allowlists, and `nono.real` binary staging. |
| `d2-signalloom/apps/hosted-daytona-coder` | Hosted remote workspace coder | Added thread-safe workspace cloning, tenant confinement, git branch injection defense, workspace prune lifecycle bounds, `HEAD`/`OPTIONS` parity, and socket leak prevention. |
| `d2-signalloom/apps/stun-sentinel` & `d2-signalloom/apps/signalloom-stun-sentinel` | eBPF/TC stun sentinel daemon, `stun-tcctl`, correlator, probe preservers | Hardened `/healthz`, `/readyz`, `/status`, and `/snapshot` with `GET`/`HEAD`/`OPTIONS` parity, preflight auth bypass, `Allow` headers, bounded body draining, and resilient eBPF spool backoff. |
| `d2-signalloom/apps/swarm-governor` | Swarm coordinator, A2A client, task lifecycle endpoints | Added SSRF agent URL validation, outbound response draining, constant-time bearer auth, and `HEAD`/`OPTIONS`/`Allow` compliance across `/healthz`, `/readyz`, and `/tasks`. |
| `d2-signalloom/apps/cardvault` & `d2-signalloom/apps/cardvault-agent` | Cardvault server, auto-claim agent, OpenBao/claim mocks | Decoupled Kubernetes Secret credentials, enforced fail-closed auth, added preflight `OPTIONS` support, validated outbound URLs, and suppressed `HEAD` error bodies. |
| `d2-signalloom/apps/prod-deploy-gate` | HITL deployment gate and webhook dispatcher | Added HMAC token bounds, webhook SSRF validation, bounded gate reaper lifecycle, requester audit checks, and RFC 9110 `HEAD`/`OPTIONS`/`Allow` parity. |
| `d2-signalloom/apps/node-capability-guard` | Kubernetes admission webhook and probe server | Enforced `POST`-only `/validate` admission gates with `MaxBytesReader`, isolated ServeMux instances, `AdmissionReview` UID validation, and `GET`/`HEAD`/`OPTIONS` probe parity. |
| `d2-signalloom/apps/factory-appraiser` & `d2-signalloom/apps/kusari-agent` | Factory appraiser and Kusari agent | Added stream-bounded request readers, upstream quote URL validation, `getOnly` `HEAD` short-circuiting, `OPTIONS` parity, and `Allow` headers. |
| `d2-signalloom/apps/workspace-connector` & d2-signalloom/apps/zulip-chat-agent (removed after this record, in cfc60347e) | Workspace connector and Zulip ChatOps agent | Validated ingest and Zulip URLs, bounded ChatOps session memory, drained outbound HTTP responses, and enforced `HEAD`/`OPTIONS`/`Allow` parity. |
| `d2-signalloom/apps/prompt-commit-summarizer` & `d2-signalloom/apps/triage-ci-worker` | Commit summarizer and CI triage worker | Prevented `gh` CLI flag injection, avoided kernel `MAX_ARG_STRLEN` (`E2BIG`) limits, validated LLM endpoints, and enforced `HEAD`/`OPTIONS`/`Allow` parity. |
| `d2-signalloom/apps/netassert-controller` & `d2-signalloom/proof-helper` | Network assertion controller and proof helper | Enabled socket reuse, bounded controller body draining, added `/livez` and `/readyz` probe parity, and enforced `HEAD`/`OPTIONS`/`Allow` headers. |
| `d2-signalloom/apps/agentmaxxing-host-sensor` | Workstation host sensor | Hardened cgroup path traversal checks, `openat2` relative path validation, pseudonym epoch bounds, and rate-limit token bucket scalar validation. |
| `d2-agent-trust` | SPIFFE A2A receiver, `spire_workload_api`, `fake-integration-proxy`, netassert runner | Enabled HTTP/1.1 keep-alive persistence, rejected `TE.CL` framing desync with `400 Bad Request`, bounded chunk/trailer reads, enforced JWT timestamp bounds, and added `HEAD`/`OPTIONS`/`Allow` parity. |
| `d2-platform-apps` | `listener`, `processor`, and `archiver` | Sanitized task identifiers against path traversal and shell wildcards, streamed large SBOM payloads without `E2BIG` truncation, purged demo database defaults, and hardened HTTP chunk framing. |
| `d2-cpai` | CPAI runtime proxy and contract suite | Externalized GCP project configuration, enforced dynamic session attributes, drained chunked bodies, and aligned `HEAD`/`OPTIONS`/`Allow` semantics. |
| `olly-replica` | Olly Sentinel A2A app, `olly-authz`, `elk-search-mcp`, `tenant-app`, `mapping-stub` | Enabled HTTP/1.1 persistent connections, rejected malformed chunk framing, decoupled staging/production/Grafana secrets, verified JWT algorithms, and enforced `HEAD`/`OPTIONS`/`Allow` parity. |
| `tools/harness-dash` & `test/acceptance/harness` | Harness dashboard, Jev SPA server, user-surface stub, A2A conformance, SLSI mocks | Eliminated chunk delimiter `readline` deadlocks, suppressed `HEAD` error bodies, added `OPTIONS` and `Allow` parity, and prevented test socket descriptor leaks. |
| `test` & `scripts` | BATS suites, mutation sentinel rails, Go toolchain/cache isolation, docs and hygiene guards | Isolated `GOCACHE` and `GOMODCACHE` across BATS runners, wired shared mutation sentinels, removed `pipefail` `grep -q` hazards, and aligned Kyverno-to-CEL admission suites. |

## 4. Verification plan

1. Run the documentation index synchronization suite:

```bash
bats test/docs-index-sync.bats
```

2. Run the documentation style and link lint across the repository and on this proposal directly:

```bash
make docs-lint
scripts/docs-lint.sh "docs/Proposal — Platform-Wide RFC 9110 HTTP Method Gate, HEAD, OPTIONS, and Body Lifecycle Hardening (2026-Q4).md"
```

3. Run the documentation lint BATS test suite:

```bash
bats test/docs-lint.bats
```

4. Check that all 7 tests in `test/docs-index-sync.bats` and all 28 tests in `test/docs-lint.bats` pass with zero findings.
