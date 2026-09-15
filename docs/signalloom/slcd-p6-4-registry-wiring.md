# SLCD-P6-4: Acceptance Specification Registry, Playwright Config, and Makefile Wiring

## 1. Executive Summary

This document certifies the three-way wiring of the browser acceptance test suite for coding agent topology rendering (`coding-agent-topology.spec.ts`, delivered in `SLCD-P6-3`) into the Signal Loom test infrastructure in a single unified change (`SLCD-P6-4`).

The three-way contract guarantees that:
1. `test/acceptance/SPEC-REGISTRY.tsv` declares the spec, its execution runner (`make:demo-signalloom-coding-agent-topology`), and its exact runtime preconditions.
2. `test/acceptance/playwright.config.ts` declares a dedicated, non-opt-in Playwright project (`coding-agent-topology`) matching `coding-agent-topology.spec.ts`.
3. `Makefile` defines the standalone invocation target `demo-signalloom-coding-agent-topology` and integrates it into the `test-all-browser` aggregator target.
4. `test/acceptance-spec-coverage.bats` (CI Stage 1c) validates this three-way agreement bidirectionally, preventing silent test degradation.

---

## 2. Three-Way Wiring Declarations and Exact Line References

### 2.1. SPEC-REGISTRY.tsv Entry

- **File:** `test/acceptance/SPEC-REGISTRY.tsv`
- **Line:** `69`
- **Content:**
  ```tsv
  coding-agent-topology.spec.ts	make:demo-signalloom-coding-agent-topology	SLCD-P6-3 / P6-4. Needs NO cluster: it spawns `bun harness/coding-agents-server.ts` on --port 0 and drives the real CodingAgentsTab against it, so it runs on a laptop in well under a minute. Its precondition is bun on PATH, test/acceptance/node_modules (react + react-dom, already in package.json for the streaming harness), and a Chromium Playwright can launch — PW_CHANNEL=chromium if /opt/google/chrome/chrome is not executable in your shell. Target `make demo-signalloom-coding-agent-topology` executes this acceptance suite independently. Unlike docs and agentmaxxing-demo-console its project is NOT env-gated, because its precondition IS satisfied wherever `make acceptance-test` already runs; gating it would only hide it. Its project deliberately carries no storageState and no `setup` dependency, which would reintroduce the cluster requirement it exists to avoid.
  ```

### 2.2. Playwright Configuration Project

- **File:** `test/acceptance/playwright.config.ts`
- **Lines:** `236–299` (specifically `testMatch` at line `258`)
- **Content:**
  ```typescript
    {
      // Coding-agent topology rendering (SLCD-P6-3), against a cluster-free
      // harness — `bun harness/coding-agents-server.ts`, spawned per worker by
      // the spec on `--port 0`.
      name: "coding-agent-topology",
      testMatch: /coding-agent-topology\.spec\.ts/,
      timeout: 3 * 60_000,
      fullyParallel: false,
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        video: "off",
      },
    },
  ```

### 2.3. Makefile Target and Aggregator Integration

- **File:** `Makefile`
- **Target Definition (Lines 1066–1071):**
  ```makefile
  .PHONY: demo-signalloom-coding-agent-topology
  demo-signalloom-coding-agent-topology: ## Run browser acceptance tests for coding agent topology rendering (no cluster required).
  	cd test/acceptance && bun install --frozen-lockfile && \
  		bunx playwright test coding-agent-topology.spec.ts \
  			--project=coding-agent-topology
  ```
- **Aggregator Integration (Line 553):**
  ```makefile
  test-all-browser: ## Run all Playwright browser acceptance tests across all slices.
  	@echo "=== [Browser 1/3] Standalone Harness Browser Specs ==="
  	$(MAKE) demo-signalloom-supercred-stream-harness
  	$(MAKE) demo-signalloom-coding-agent-topology
  	@echo "=== [Browser 2/3] Core & Feature Browser Specs ==="
  ```

---

## 3. Precondition & Architectural Boundary Analysis

1. **Cluster-Free Execution**: `coding-agent-topology.spec.ts` spawns a dedicated Bun harness (`harness/coding-agents-server.ts`) on `--port 0` and mounts the actual React `CodingAgentsTab` component via Vite/Bun bundling. No Kind cluster, Envoy Ingress Gateway, or port-forwards are required.
2. **Unauthenticated Isolation**: Unlike specs that require Dex authentication and inherit `dependencies: ["setup"]` or `storageState`, this project has zero external auth dependencies. It initializes its own scoped browser contexts and tests cross-tenant boundaries without shared session leakage.
3. **Deterministic Clean State**: Each test execution performs a synchronous reset of the ephemeral in-memory fixture store before driving DOM interactions.

---

## 4. Verification Evidence

### 4.1. Acceptance Specification Coverage Guard (`test/acceptance-spec-coverage.bats`)

Executing `bats test/acceptance-spec-coverage.bats` validates all 7 directional checks:

```
acceptance-spec-coverage.bats
   the guard can read every project in playwright.config.ts1/7 ✓ the guard can read every project in playwright.config.ts
   every spec on disk has exactly one registry row, and every row has a...2/7 ✓ every spec on disk has exactly one registry row, and every row has a spec
   every registry runner is a known kind, and every non-CI row gives a ...3/7 ✓ every registry runner is a known kind, and every non-CI row gives a reason
   a spec matches a playwright project if and only if the registry says so4/7 ✓ a spec matches a playwright project if and only if the registry says so
   every ci: row names a stage that really runs that spec5/7 ✓ every ci: row names a stage that really runs that spec
   every spec a CI stage runs is registered as ci:6/7 ✓ every spec a CI stage runs is registered as ci:
   every make: row names a target whose recipe runs that spec7/7 ✓ every make: row names a target whose recipe runs that spec

7 tests, 0 failures
```

### 4.2. Wiring Cross-Reference Verification

```bash
$ rg -n 'coding-agent-topology' test/acceptance/SPEC-REGISTRY.tsv test/acceptance/playwright.config.ts Makefile
test/acceptance/playwright.config.ts
257:      name: "coding-agent-topology",
258:      testMatch: /coding-agent-topology\.spec\.ts/,

Makefile
553:	$(MAKE) demo-signalloom-coding-agent-topology
1066:.PHONY: demo-signalloom-coding-agent-topology
1067:demo-signalloom-coding-agent-topology: ## Run browser acceptance tests for coding agent topology rendering (no cluster required).
1069:		bunx playwright test coding-agent-topology.spec.ts \
1070:			--project=coding-agent-topology

test/acceptance/SPEC-REGISTRY.tsv
69:coding-agent-topology.spec.ts	make:demo-signalloom-coding-agent-topology	SLCD-P6-3 / P6-4. Needs NO cluster: it spawns `bun harness/coding-agents-server.ts` on --port 0 and drives the real CodingAgentsTab against it, so it runs on a laptop in well under a minute. Its precondition is bun on PATH, test/acceptance/node_modules (react + react-dom, already in package.json for the streaming harness), and a Chromium Playwright can launch — PW_CHANNEL=chromium if /opt/google/chrome/chrome is not executable in your shell. Target `make demo-signalloom-coding-agent-topology` executes this acceptance suite independently. Unlike docs and agentmaxxing-demo-console its project is NOT env-gated, because its precondition IS satisfied wherever `make acceptance-test` already runs; gating it would only hide it. Its project deliberately carries no storageState and no `setup` dependency, which would reintroduce the cluster requirement it exists to avoid.
```

---

## 5. Certification

All deliverables for card `SLCD-P6-4` have been implemented and verified. The acceptance test suite is properly wired into the registry, the Playwright project definitions, and the Makefile target hierarchy.
