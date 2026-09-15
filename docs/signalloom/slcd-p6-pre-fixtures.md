# SLCD-P6-PRE — Acceptance Fixture Harnesses, Test Runners, and SPEC-REGISTRY Preflight

**Status:** Complete · **Role:** Preflight · **Date:** 2026-09-15 · **Author:** SLCD-P6-PRE · **Base Ref:** `integration/slcd-v0.1.0`

---

## Executive Summary

This preflight evaluation validates the end-to-end fixture harnesses, test runner configurations, and `SPEC-REGISTRY.tsv` contracts for Phase 6 (Acceptance & Wiring) of the Signal Loom Coding Agent & Harness Detective Telemetry (`SLCD`) project. It audits the monorepo baseline against `integration/slcd-v0.1.0` (commit `c2f43598`), verifies the strict cross-check logic of CI Stage 1c (`test/acceptance-spec-coverage.bats`), analyzes the Playwright project topology in `test/acceptance/playwright.config.ts`, confirms zero pre-existing SLCD acceptance rows in `SPEC-REGISTRY.tsv`, and establishes unambiguous wiring rules for tasks P6-1 through P6-4 before P6-GOV certification.

---

## 1. Acceptance Suite & `SPEC-REGISTRY.tsv` Contract Verification

### 1.1 `SPEC-REGISTRY.tsv` Purpose and Strict Invariants
`test/acceptance/SPEC-REGISTRY.tsv` is the single source of truth for where every acceptance specification in `test/acceptance/` executes. It was instituted to prevent silent acceptance coverage loss (where specs placed in `test/acceptance/` fail to match any `testMatch` in `playwright.config.ts` or fail to be wired into CI/Make targets, causing test runners to report clean green passes with degraded test counts).

### 1.2 TSV Column Schema & Contract Rules

The file is tab-separated (`\t`), comments begin with `#`, and rows are strictly ordered alphabetically by spec filename (`LC_ALL=C sort`).

| Column | Name | Format & Allowed Values | Enforcement Rules |
| :--- | :--- | :--- | :--- |
| 1 | `spec` | Filename matching `*.spec.ts` | Must exist on disk in `test/acceptance/`. Every spec file on disk must appear exactly once. |
| 2 | `runner` | `ci:stage8`<br/>`ci:stage8b`<br/>`make:<target>`<br/>`suite-only`<br/>`unwired` | Must be a known runner kind. If `ci:*`, must match an active `run_stage` command in `scripts/ci/vm-pipeline.sh`. If `make:<target>`, target must exist in root `Makefile` and recipe must name `<spec>`. If `suite-only`, must match a `testMatch` project in `playwright.config.ts`. If `unwired`, must match NO project in `playwright.config.ts`. |
| 3 | `reason` | Non-empty string (mandatory for non-`ci:*`) | Explains the blocking precondition keeping the spec out of a default CI lane. Prose like "it just isn't" is forbidden; must state the exact technical precondition. |

### 1.3 Current Inventory & SLCD Gap Confirmation
Inspection of the current filesystem and `SPEC-REGISTRY.tsv` confirms:
- **Total Specs on Disk:** Exactly 34 specification files in `test/acceptance/*.spec.ts`.
- **Total Registry Rows:** Exactly 34 entries registered in `test/acceptance/SPEC-REGISTRY.tsv` (lines 61–94).
- **SLCD Spec Count:** **Zero (0) SLCD rows exist today.** No `coding-agent-telemetry.spec.ts` or related SLCD acceptance spec exists on disk or in the registry.
- **The Gap:** P6-3 must author the browser acceptance spec (e.g. `coding-agent-telemetry.spec.ts`), and P6-4 must add its registered row and test runner wiring.

---

## 2. CI Stage 1c (`test/acceptance-spec-coverage.bats`) Enforcement Logic

The coverage guard `test/acceptance-spec-coverage.bats` executes in CI Stage 1c (requiring no Kubernetes cluster, no network, and no `node_modules`). It performs seven independent mathematical set-difference and parsing checks:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 test/acceptance-spec-coverage.bats (7 Guards)               │
├────────────────────────────────┬────────────────────────────────────────────┤
│ Guard 1: AST Config Parser     │ Parses playwright.config.ts for testMatch  │
│                                │ regexes/globs; validates negative probe    │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 2: Bi-directional Set    │ comm -23 <(specs_on_disk) <(registry_specs)│
│          Difference Check      │ comm -13 <(specs_on_disk) <(registry_specs)│
│                                │ Catches unrecorded orphans & stale rows    │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 3: Runner Kind & Reason  │ Asserts runner enum and non-empty reason   │
│          Validator             │ for all make:*, suite-only, unwired rows   │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 4: Playwright Project    │ Cross-checks classified status against     │
│          Wired/Unwired Parity  │ registry (wired != unwired)                │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 5: CI Stage Execution    │ Verifies vm-pipeline.sh run_stage command  │
│          Proof                 │ actually invokes the registered spec file  │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 6: Pipeline-to-Registry  │ Asserts any spec named in vm-pipeline.sh   │
│          Completeness          │ is registered with a ci:* runner           │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Guard 7: Makefile Recipe       │ Extracts make target recipe via awk;       │
│          Verification          │ asserts spec filename is present in recipe │
└────────────────────────────────┴────────────────────────────────────────────┘
```

### 2.1 The Seven Guard Invariants
1. **`the guard can read every project in playwright.config.ts`**: Strips `//` line comments, parses all `testMatch` string literals and regexes. Asserts positive control (`signalloom-test-1.spec.ts` is wired) and negative control (`__spec-coverage-guard-probe__.spec.ts` is unwired).
2. **`every spec on disk has exactly one registry row, and every row has a spec`**: Uses `LC_ALL=C comm` to assert zero set difference between `specs_on_disk` and `registry_specs`. Zero orphan specs, zero stale rows, zero duplicate rows permitted.
3. **`every registry runner is a known kind, and every non-CI row gives a reason`**: Validates runner prefix and enforces non-whitespace `reason` string on all non-CI rows.
4. **`a spec matches a playwright project if and only if the registry says so`**: Proves bi-directional wiring consistency. If `playwright.config.ts` claims a spec, registry cannot mark it `unwired`. If no project claims a spec, registry cannot mark it `suite-only`, `make:*`, or `ci:*`.
5. **`every ci: row names a stage that really runs that spec`**: Scans `vm-pipeline.sh` for `run_stage <desc> <stage-id>-* <command>` and asserts the command contains the spec filename.
6. **`every spec a CI stage runs is registered as ci:`**: Parses all `*.spec.ts` tokens from `vm-pipeline.sh` and ensures each has a `ci:<stage>` runner in `SPEC-REGISTRY.tsv`.
7. **`every make: row names a target whose recipe runs that spec`**: Extracts the target recipe from `Makefile` using `awk` prefix matching (`index($0, t) == 1`) and asserts the spec filename is present in the recipe body.

---

## 3. Playwright Project Topology & P6-3 Spec Wiring Determination

### 3.1 Existing `playwright.config.ts` Projects

`test/acceptance/playwright.config.ts` declares the following projects:
1. `setup`: Authenticates against Dex via Envoy Gateway (`auth.setup.ts`).
2. `chromium`: Runs Stage 8 CI journey (`signalloom-test-1.spec.ts`) with pre-authenticated `storageState`.
3. `supercred-two-window`: Multi-context SuperCred demo tests (15m timeout).
4. `supercred-ui-lifecycle`: 5-phase SuperCred UI lifecycle (30m timeout).
5. `supercred-evidence-lifecycle`: SuperCred credential evidence assertions (30m timeout).
6. `supercred-log-streaming`: Progressive log streaming tests (15m timeout).
7. `supercred-log-streaming-harness`: Scripted runner streaming tests without cluster (3m timeout).
8. `smoke`: Multi-spec project using explicit regex alternation `testMatch: /smoke\.spec\.ts|navigation\.spec\.ts|...|feeds-explorer\.spec\.ts/` (30s timeout, self-authenticating via `login()`).
9. `docs` (conditional on `DOCS_BASE_URL`): Standalone unauthenticated documentation renderer.
10. `agentmaxxing-demo-console` (conditional on `AMXD_DEMO_CONSOLE`): Standalone interactive console test suite.

### 3.2 Critical Structural Finding: No Wildcard Catch-All Exists
`playwright.config.ts` does **not** use a glob like `testMatch: "*.spec.ts"` or `/.*\.spec\.ts/`. Every single spec matching the `smoke` project is explicitly enumerated by filename within the regex.

### 3.3 Architectural Wiring Options for P6-3 / P6-4

| Strategy | Implementation Details | Runner in `SPEC-REGISTRY.tsv` | Makefile Target | When to Use |
| :--- | :--- | :--- | :--- | :--- |
| **Option A: `smoke` project inclusion** | Append `|coding-agent-telemetry\.spec\.ts` to `testMatch` in `smoke` project. | `suite-only` | N/A (runs under `make acceptance-test`) | If test authenticates via `helpers.ts:login()` and runs inside standard 30s timeout against live demo cluster. |
| **Option B: Dedicated Make Target & Project** | Define opt-in project in `playwright.config.ts` gated on env var (e.g. `SLCD_DEMO_CONSOLE` / `CODINGAGENT_TEST`), plus Makefile target `demo-signalloom-codingagent-ui-test`. | `make:demo-signalloom-codingagent-ui-test` | `demo-signalloom-codingagent-ui-test: ... coding-agent-telemetry.spec.ts` | If test requires dedicated mock harness server, custom timeout, or avoids polluting default `make acceptance-test`. |
| **Option C: Direct `smoke` with dedicated Make Target** | Add to `smoke` project `testMatch` AND provide explicit make target `demo-signalloom-codingagent-test: ... coding-agent-telemetry.spec.ts`. | `make:demo-signalloom-codingagent-test` | Recipe names spec filename explicitly. | Recommended: Gives dedicated Make execution while running under standard browser configuration. |

---

## 4. Test Runner & Fixture Baseline Verification

All test runners across the merged tree `integration/slcd-v0.1.0` were executed and verified:

### 4.1 CI Stage 1c (`test/acceptance-spec-coverage.bats`)
```bash
bats test/acceptance-spec-coverage.bats
```
- **Result:** **PASS (7 tests, 0 failures)**.
- **Latency:** 1.2s.
- **Verification:** All 34 existing specs and registry rows pass bidirectional validation.

### 4.2 Signal Ingest Test Suite (`make test-signal-ingest`)
```bash
make test-signal-ingest
```
- **Result:** **PASS (exit code 0)**.
- **Scope:** All unit, crypto, and contract suites in `d2-signalloom/apps/signal-ingest/`:
  - `collectors/codingagent`: Unit & OpenAPI wire codecs.
  - `subjectkey`: RFC 5869 HKDF-SHA256 & HMAC-SHA256 pseudonym generators.
  - `transform`: Zero-payload secret redactor and scrubber.
  - `api`: Protected router and end-to-end HTTP ingestion harness (`e2e_harness_test.go`).

### 4.3 Documentation Astro Portal (`apps/docs-signalloom`)
```bash
cd d2-signalloom/apps/docs-signalloom && ASTRO_TELEMETRY_DISABLED=1 bun run check && ASTRO_TELEMETRY_DISABLED=1 bun run build
```
- **Result:** **PASS (0 errors, 0 warnings)**.
- **Output:** 23 static HTML routes compiled into `dist/`, Starlight search index generated across 23 pages, sitemap generated.
- **Preflight Requirement Identified:** Sandboxed environments require `ASTRO_TELEMETRY_DISABLED=1` to prevent `EACCES` on `~/.config/astro/config.json`. P6-2 documentation updates can build cleanly against this baseline.

### 4.4 Dashboard Vitest Suite (`apps/dashboard-signalloom`)
```bash
cd d2-signalloom/apps/dashboard-signalloom && bunx vitest run
```
- **Result:** **PASS (182 test files passed, 3,389 tests passed, 3 skipped, 0 failures)**.
- **Scope:** `CodingAgentsTab.test.tsx` and `CodingAgentsTab.e2e.test.tsx` pass 100%.

### 4.5 AgentMaxxing Host Sensor Test Suite (`make demo-agentmaxxing-host-test`)
- **Pytest Suite:** 6/6 tests passed (`test_audit_ingest.py`).
- **BATS Confinement & Hasher Suites:**
  - `agentmaxxing-host-confinement.bats`: 11/11 passed.
  - `file-validator-anti-escape.bats`: 9/9 passed.
  - `hasher-toctou.bats`: 6/6 passed.
- **Python Host Sensor Discovery:** 429 tests passed, 3 expected failures (`@unittest.expectedFailure` in `test_p2_governor_integration.py`), and 2 pre-existing benchmark assertions on live host load (`test_combined_engines_within_cpu_and_rss_budget` and `test_four_subsystem_overhead_against_kpi`). These 2 overhead failures are documented in SLCD-P4-2 and SLCD-P5-GOV errata as resulting from unmocked live `/proc` process table scanning and 7,200+ local kanban task files on host `andy`.

---

## 5. Downstream Phase 6 Hand-Off Matrix

| Card | Role | Core Responsibility | Preflight Dependency & Constraints |
| :--- | :--- | :--- | :--- |
| **SLCD-P6-1** | Unit, Integration & Security Tests | Expand comprehensive test suites covering detective process discovery, kanban watchers, socket correlation, and zero-payload leak injection. | Consumes baseline Python and Go test suites; must enforce zero prompt/code leakage. |
| **SLCD-P6-2** | Documentation & Runbook | Create user-facing documentation and detection runbook in `d2-signalloom/apps/docs-signalloom`. | Must run with `ASTRO_TELEMETRY_DISABLED=1`; must pass `bun run check && bun run build`. |
| **SLCD-P6-3** | Acceptance Browser Test | Build Playwright browser acceptance spec (`test/acceptance/coding-agent-telemetry.spec.ts`) asserting live coding agent topology, metrics, and badges. | Must authenticate via `login()` or mock harness; must assert live DOM nodes without fixed timeouts (`page.waitForTimeout` banned). |
| **SLCD-P6-4** | Acceptance Wiring & Registry | Add `coding-agent-telemetry.spec.ts` row to `test/acceptance/SPEC-REGISTRY.tsv`, update `playwright.config.ts` `testMatch`, and add Makefile target. | Must satisfy all 7 guards in `bats test/acceptance-spec-coverage.bats`. TSV row must be alphabetically ordered (`LC_ALL=C`). |
| **SLCD-P6-GOV** | Phase Governor Certification | Reconcile all Phase 6 deliverables, run full acceptance suite, and certify end-to-end SLCD mission readiness. | Verifies all Phase 6 tests, documentation, and wire contracts on `integration/slcd-v0.1.0`. |

---

## 6. Preflight Conclusion

Phase 6 acceptance fixture harnesses, test runners, and registry contracts are verified and ready for execution. All gating rules for P6-1 through P6-4 are established with zero ambiguity.
