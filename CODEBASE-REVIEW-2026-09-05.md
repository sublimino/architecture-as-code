# Codebase review — 5 September 2026

## Scope and verdict

Reviewed `feat/signal-loop-and-bootstrap-refactor` at `76b439c00a41fef08e535831b6656fd7b7ba66cf`, including the existing uncommitted dashboard and build-script changes. This was a risk-focused review, not an exhaustive certification of this large monorepo.

**Prioritise correctness and deployment completeness before cosmetic cleanup.** The main risks are missing tenant isolation, unsynchronised shared state, successful mutations without durable audit evidence, and new collectors that are not connected to the running service. Some tests currently pass while preserving these limitations.

No application code was changed, no commits were made, and no deployments or cloud operations were performed. This report is the only file added by the review.

Severity: **High** warrants correction before relying on the affected feature; **Medium** is an actionable reliability or presentation defect. Security impact depends on deployment exposure. Findings labelled **working tree** concern uncommitted work, not necessarily the committed baseline.

## Findings

### 1. High — Signal Fusion drops authenticated tenant context

**Committed code:** `d2-signalloom/apps/fe-signalloom/src/signal_fusion.py:52-120`; `d2-signalloom/apps/signal-ingest/model/signal.go:99-111`; `d2-signalloom/apps/signal-ingest/store/store.go:19-26`.

The FastAPI routes authenticate a tenant or principal but do not forward that identity to signal-ingest. The downstream observation/query contracts and actor map have no tenant dimension. Observation listing, actor reads, correlation, and promotion consequently operate on shared state.

**Trigger and impact:** with multiple tenants using this service, one tenant can read another's observations or actors and invoke promotion against shared actors. Audit events use hardcoded `tenant-demo`, further obscuring attribution. This is a release blocker for multi-tenant use, even if a single-tenant demo does not expose the boundary.

**Recommendation:** introduce server-derived tenant context at ingestion and preserve it through models, queries, correlation, actor operations and audit events. Authenticate the internal propagation mechanism; do not simply trust an arbitrary client tenant header. Add two-tenant tests that assert disjoint results and reject cross-tenant mutation.

**Evidence:** source/caller tracing; `src/tests/test_signal_fusion_adversarial.py:122-195` already documents the missing boundary. Passing current tests is not proof of isolation.

### 2. High — Concurrent actor requests access an unprotected Go map

**Committed code:** `d2-signalloom/apps/signal-ingest/correlation/engine.go:18-23,94-175,221-256`; HTTP callers in `api/handlers.go:225-244,321-347`.

`Engine.actors` is a plain map. Correlation writes it, read methods iterate it, and promotion changes the actor pointers returned by those methods. HTTP handlers can execute concurrently, with no mutex or equivalent serialization.

**Trigger and impact:** overlapping correlation, actor listing, statistics, or promotion requests can race, return inconsistent actor state, or terminate the service with a concurrent-map runtime error.

**Recommendation:** synchronize writes and reads, and return deep-copy snapshots rather than exposing mutable pointers after unlocking. Test concurrent correlation, reads and promotion under the race detector.

**Evidence:** confirmed shared-map and handler paths by inspection. Existing `go test -race ./...` passed, but does not exercise this overlap. No runtime crash was induced during this review.

### 3. High — Promotion reports success when its audit write fails

**Committed code:** `d2-signalloom/apps/signal-ingest/api/promote.go:16-48`; `correlation/engine.go:243-256`.

The actor is marked promoted before `WriteAuditEvent` runs. An audit error is only logged; the handler still returns HTTP 200 with `promoted: true`.

**Trigger and impact:** a database failure leaves a successful security-relevant state transition without the required audit record. `api/promote_test.go:95-124` explicitly preserves this fail-open behavior. The in-memory promotion itself is described as a PoC, not a durable registry registration, so the endpoint should not be presented as stronger evidence than it provides.

**Recommendation:** make promotion and its audit event atomic, ideally through durable transactional state plus an outbox. A temporary rollback design must synchronize concurrent access and handle ambiguous database outcomes; simply changing the response status after mutation is insufficient.

### 4. High — New collectors are not connected to the deployed service

**Committed code:** `d2-signalloom/apps/signal-ingest/main.go:16-20,114-123`; `api/handlers.go:52-67`; `base/deployment.yaml:66-111`.

The entrypoint constructs the store, engine, audit writer and existing API handlers. It does not construct/start the new OpenBao, SPIRE, GCP or eBPF collectors, or register the Kubernetes audit receiver. There is no production store-backed ingestion adapter connecting these packages to the running service.

The Kubernetes audit policy at `d2-signalloom/infra/audit-policy.yaml:1-38` is also not activated through the Kind API-server configuration in `create-kind-cluster.sh:59-106`. OpenBao/SPIRE transport configuration is absent from the signal-ingest deployment.

**Trigger and impact:** building and deploying the current image does not cause these new sources to deliver real observations. Package-level correctness does not close the deployment gap.

**Recommendation:** explicitly configure and start each supported source, connect its ingestion sink, register/expose receivers, and drain/stop collectors on shutdown. Derive coverage/readiness from actual configured source state. Add a deployment-level test that sends a fresh event through the real source and observes it downstream.

**Evidence:** independent backend and deployment reviews agreed on missing entrypoint/manifests wiring. No live deployment probe was performed.

### 5. Medium — Identity audit panel displays fixtures without a live-data input

**Committed code:** `d2-signalloom/apps/dashboard-signalloom/src/components/IdentityAuditPanel.tsx:26-65`; `src/pages/WeavePage.tsx:255`; `test/acceptance/signal-loom-baoaudit.spec.ts:17-27`.

`WeavePage` renders `<IdentityAuditPanel />` without events. The component defaults to three fixed audit events and an active-lease count of four. The acceptance spec asserts the fixed event IDs rather than proving ingestion.

**Impact:** the panel can display plausible audit activity regardless of whether the collectors are connected. It does not constitute live collection evidence.

**Recommendation:** make fixtures an explicit demo-only input, label their provenance, and render an empty/unavailable state without a live source. Separate fixture rendering tests from a real source-to-panel acceptance test.

### 6. High — Raw policy totals reach a chart expecting Money objects

**Working tree:** `d2-signalloom/apps/dashboard-signalloom/src/api/client.ts:541-553`; `src/pages/RiskExposurePage.tsx:68-71`.

**Backend contract:** `d2-signalloom/apps/fe-signalloom/src/api_compat.py:538-553` declares `totalAle`, `totalVar95` and `totalTvar` as integers. The current frontend expects denominated objects, but the compliance API methods return `req<PostureSummary>` without applying the newly introduced normalization helpers.

**Trigger and impact:** an ordinary backend response reaches `buildExceedanceCurve(summary.totalAle.amount, summary.totalTvar.amount)`. Both arguments are undefined for numeric wire values, producing invalid loss values and an empty or invalid curve. TypeScript's generic response assertion hides the contract mismatch.

**Recommendation:** normalize frameworks, summary and scan responses once at the API boundary. Model wire types separately from domain types. Add a raw-response test that checks finite chart values, not just visible section headings. Verify with demo projection disabled so projection cannot accidentally mask the missing normalization.

**Evidence:** verified backend response schema and frontend call path. This is a static contract finding; no browser rendering claim is made.

### 7. High — Nine root BATS suites are unregistered and fail the registry gate

**Committed code:** `d2-signalloom/test/bats-registry-coverage.bats:567-671`; pipeline ownership in `scripts/ci/vm-pipeline.sh` and `scripts/gcp-tf/demo-pipeline.sh`.

The following suites are not invoked by either recognized pipeline:

- `test/baoaudit-p2-preflight.bats`
- `test/baoaudit-preflight.bats`
- `test/cloudaudit-e2e.bats`
- `test/cloudaudit-negative-mutations.bats`
- `test/cloudaudit-p2-preflight.bats`
- `test/cloudaudit-preflight.bats`
- `test/netebpf-adversarial.bats`
- `test/netebpf-p2-preflight.bats`
- `test/netebpf-preflight.bats`

**Reproduction:**

```sh
bats --filter '^every repo-root bats suite is invoked by the CI pipeline$' \
  d2-signalloom/test/bats-registry-coverage.bats
```

Result: `not ok 1`, failing at line 671 and printing all nine names above. The selected test and its setup only inspect files; unrelated tests that execute `make -n` were not run.

**Impact:** the registry gate is currently red. Independently running the new suites does not provide ongoing pipeline coverage.

**Recommendation:** give each suite an explicit owner in the appropriate supported pipeline or a justified alternative registration. Classify live/e2e suites separately from static preflights; do not blindly insert live tests before their prerequisites. Respect the repository's frozen legacy-pipeline policy.

### 8. High — Ambient temporary kubeconfig can send the build to another cluster

**Working tree:** `scripts/build-sign-dashboard.sh:14-16,83-91,202-203`; callers at `Makefile:276-278,329-330`.

When `KUBECONFIG` is unset, the script prefers `/tmp/osramp.kubeconfig` whenever it exists, even if the normal user kubeconfig is valid. Registry port-forwarding follows this temporary file, while `kind load` independently targets `CLUSTER_NAME`.

**Trigger and impact:** a stale or foreign temporary kubeconfig can cause registry access and Kind image loading to target different clusters in one build. The resulting errors can look like image freshness, digest or signing problems rather than a context mismatch.

**Recommendation:** remove ambient temporary-file discovery. Require an explicit kubeconfig or derive a private one from the selected Kind cluster, then verify that the registry and load paths target the same cluster. Also replace the shared `/tmp/.docker` fallback with a private, explicitly managed directory.

**Evidence:** inspected the dirty diff, callers and independent cluster-selection mechanisms. `bash -n`, ShellCheck and whitespace checks passed; these tools do not detect this semantic failure.

### 9. Medium — Older policy scans can overwrite the current version's results

**Current working tree; introduction not established:** `d2-signalloom/apps/dashboard-signalloom/src/pages/RiskExposurePage.tsx:48-75`.

Each version change launches `loadSummary`, but neither effect cleanup nor a request-generation check cancels or disregards earlier requests. The API method already accepts an optional AbortSignal, which this caller does not pass.

**Trigger and impact:** switching policy versions before a scan completes permits the older response to arrive last. The selector displays the new version while the summary belongs to the old one. An earlier request can also clear the loading state prematurely.

**Recommendation:** cancel superseded requests and guard all state updates, including loading/error updates, by the current request generation. Add a deferred-promise test that resolves requests in reverse order.

## Additional cleanup and follow-ups

- **Restore the lint gate:** the dashboard reviewer ran the full lint command and reported 43 errors and two warnings. Ten errors were explicit `any` uses in changed raw-wire test assertions. Triage the exact output before attributing the remainder to this change; focused production-file lint and typecheck passed.
- **Keep legacy money twins consistent while supported:** `supercredProjection.ts:273-326` updates denominated exposure/carried fields while spreading through old `totalExposureGbp` and `totalCarriedGbp` values unchanged. Either update GBP twins consistently or finish removing legacy consumers. Add a compatibility test; this review did not establish a currently visible legacy-consumer failure.
- **Check narrow-screen controls in a real browser:** the new WidthToggle uses a fixed `right: 250px` offset (`WidthToggle.tsx:13-15,33-55`, `App.tsx:308-311`). At 320px width that leaves only 70px to its left. This is a strong clipping risk, not a browser-verified defect. Verify all corner controls together at 320px and 375px.
- **Separate truthful evidence from fixture tests:** collector package tests, static deployment assertions, and UI fixture rendering each prove different things. Keep all three, but add an actual source-to-storage-to-UI event test rather than treating their separate green results as equivalent.
- **Address React test warnings:** focused frontend tests emitted `act(...)` warnings. Fix test synchronization where warnings originate rather than suppressing them globally.

## Verification and limits

Checks reported by the delegated reviewers:

| Check | Result | What it does not establish |
|---|---|---|
| signal-ingest `go test -race ./...` | Passed | Missing concurrent actor-map scenarios; live sources |
| signal-ingest `go vet ./...` | Passed | Tenant isolation or deployment wiring |
| Two Signal Fusion backend suites, pinned Python 3.12 environment | 45 passed | Their current tests preserve some known limitations |
| Focused dashboard Vitest run | 5 files, 82 tests passed | Live browser behavior or all wire-format chart paths |
| Dashboard `bun run typecheck` | Passed | Runtime correctness of asserted API response types |
| Focused production-file ESLint | Passed | Full-repository lint health |
| Dashboard `bun run lint` | Failed: 43 errors, 2 warnings | No complete lint remediation attempted |
| Build script syntax, ShellCheck, diff whitespace | Passed | Correct cluster selection |

Primary-reviewer verification:

- Read the implicated schema, proxy, entrypoint, map, promotion, chart, panel and build-script paths independently.
- Ran the narrowly filtered BATS registration test: failed with nine named unregistered suites.
- Rechecked HEAD and working-tree status: the review added no application changes and HEAD remained `76b439c0`.

Automated roborev review was unavailable because the reviewer reported the binary was not installed. No installation or hook/config mutation was attempted.

Not performed: full monorepo test execution, real database integration, FrostDB build-tag tests, browser verification, cluster bring-up, cloud provisioning, or live ingestion. Other slices were not exhaustively audited. Findings are grounded in source contracts and targeted checks, not a claim that all remaining code is correct.

## Suggested order of work

1. Repair the registry/lint gates and the working-tree policy normalization before merging the current dashboard work.
2. Fix tenant isolation, shared actor concurrency and mutation/audit semantics before multi-tenant or security-sensitive use.
3. Wire collectors through actual source transports and remove implicit live-looking fixtures.
4. Make build cluster selection explicit, then fix request ordering and verify responsive controls.

The highest-value improvement is not fewer lines of code: it is making the deployed behavior and the evidence claimed by tests agree.
