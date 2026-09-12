---
created: 2026-09-12
reviewers:
  - "#stefan-prodan"
  - "#tom-cope"
capabilities:
  - "#cap-architecture"
  - "#cap-kubernetes"
  - "#cap-gitops"
  - "#cap-devops"
  - "#cap-threat-modelling"
practice:
  - GitOps & Continuous Delivery
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-09-signalloom-baseline-and-navigation-reconciliation/"
parentProposal: "[[Proposal — Signal Loom First User and Agent Onboarding (2026-Q3)]]"
enhancements:
  - "[[Proposal — Signal Loom Feeds & FrostDB Explorer (2026-Q3)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-signalloom-baseline-and-navigation-reconciliation
aliases:
  - "#proposal-2026-q3-signalloom-baseline-and-navigation-reconciliation"
---
# Proposal — Signal Loom Baseline Integration & 3-Tier Navigation Reconciliation (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-12) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

ControlPlane today announced the formal reconciliation and baseline integration of Signal Loom's First User & Agent Onboarding branch with the Signal Fusion & Actor Subsystem (SFAS) Phase 1–4 core, establishing a unified, drift-free platform baseline.

Autonomous agent governance requires rock-solid platform stability. When parallel innovation branches progress at high velocity—with user onboarding and navigation UX advancing on one track while multi-layer signal fusion and FrostDB columnar ingestion advance on another—the risk of integration divergence grows exponentially. A split navigation hierarchy is more than a visual annoyance; it fragments the operator's mental model, isolates critical governance controls from runtime telemetry, and creates blind spots during incident response.

Signal Loom resolves this divergence with an architectural merge down. By reconciling the 3-tier hierarchy (**View**, **Control**, **Design**) introduced in `SLON-P1-2` with the newly delivered SFAS surfaces (**The Weave**, **Signal Fusion**, **Distance Latency**, and **Signal Store**), the platform provides operators with a single, coherent pane of glass. Persistent onboarding anchors, single-digit hotkeys (1–9), and instant rail search now sit directly beside columnar signal exploration. Backed by verified Playwright acceptance tests and zero-drift GitOps contracts, Signal Loom establishes the authoritative baseline from which all future governance capabilities expand.

### Prior art, stated up front

| Source | What it already says |
| :---- | :---- |
| Trunk-Based Development | Branch lifetime must be bounded; long-running integration branches accumulate non-linear merge debt and hidden semantic conflicts |
| Cockpit / OpenShift Console | Administrative console navigation must partition operational telemetry (View) from state modification (Control) and environment setup (Design) |
| GitLab Incident Response Guidelines | UI configuration drift during rapid feature delivery obscures operational readiness and leads to false incident classifications |

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] product
- [x] services engineering
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):**

Enterprise security teams, AI platform engineers, and DevSecOps practitioners deploying autonomous agent swarms across hybrid cloud and Kubernetes estates.

|  |  |
| :---- | :---- |
| Our *operators and administrators* | Cloud Native Security Architects and Platform Engineers |
| Have the problem/opportunity *…* | The navigation sidebar is fragmented across divergent branches; newly landed SFAS telemetry surfaces are segregated from the core 3-tier UX, and worktree drift threatens testing velocity |
| When *…* | Navigating between agent onboarding, policy compliance, and real-time multi-layer signal fusion |

**What’s the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

**Urgent for Q3 2026.** We must merge down now to establish a correct, unified baseline. Adding new features (such as the Feeds & FrostDB Explorer) on top of divergent branches will compound technical debt and require complex retroactive rebases.

## Scope Summary

Technology Readiness Level Focus: **3 (Beta)** transitioning to **4 (Production)**. The underlying components (`SLON-P1-2` and `SFAS-P1..4`) are individually certified; this proposal provides the authoritative integration, semantic reconciliation, and whole-suite verification.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| 1. Branch Merge & Conflict Resolution | Merge `integration/slon-v0.1.0` (`26eef1b9`) into `feat/signal-loop-and-bootstrap-refactor` | Specific: Cleanly resolve all conflicting files across `Sidebar.tsx`, `App.tsx`, and `SPEC-REGISTRY.tsv`<br/>Measurable: `git status` reports 0 untracked conflicts, 0 lingering commits<br/>Attainable: Both branches have verified merge bases and clean history<br/>Realistic: Retains 100% of both onboarding and SFAS functionality<br/>Time-Bound: Completed in Day 1 of sprint | Git merge run, diff audit, build check |
| 2. Reconciled 3-Tier Navigation Schema | Integrate SFAS routes into the 3-tier `Sidebar.tsx` navigation rail | Specific: Place `/weave` and `/feeds` under **View**, retain `/policies` and `/containment` under **Control**, and `/fleet` under **Design**; place deep labs under superadmin toggle<br/>Measurable: All 24 routes reachable, 0 glyph collisions, 84/84 tests pass in `Sidebar.test.tsx`<br/>Attainable: Extend existing `NAV` array and icon mappings<br/>Realistic: Matches SP-2 Invariant from SLON onboarding spec<br/>Time-Bound: Completed within Milestone 1 | Vitest component suite, Playwright `navigation.spec.ts` |
| 3. Route & Loading Guard Alignment | Update `App.tsx` routes, `EXTRA_ROUTE_LABELS`, and lazy-load wrappers | Specific: Ensure `/overview`, `/topology`, `/activity`, `/risk`, `/onboarding`, `/weave`, `/signal-store`, and `/feeds` load cleanly with single-loader semantics<br/>Measurable: No double-spinner regressions; 0 console routing errors<br/>Attainable: Update React Router configuration and context providers<br/>Realistic: Verified across cold-load and warm-navigation flows<br/>Time-Bound: Completed within Milestone 1 | Vitest `App.test.tsx`, Playwright smoke tests |
| 4. Test Suite & Registry Consolidation | Register and run all acceptance and BATS test suites | Specific: Reconcile `SPEC-REGISTRY.tsv` so all onboarding, navigation, and SFAS specs are registered and mapped<br/>Measurable: `test/acceptance-spec-coverage.bats` passes (7/7); full Playwright suite passes<br/>Attainable: Synchronize TSV registry with `playwright.config.ts`<br/>Realistic: CI pipeline requirement<br/>Time-Bound: Completed within Milestone 2 | `bats test/acceptance-spec-coverage.bats`, `make test` |

### Out of Scope

* Modifying the internal Go logic of `signal-ingest` or Python logic of `fe-signalloom`.
* Implementing the Feeds Explorer UI itself (governed by the companion proposal `[[Proposal — Signal Loom Feeds & FrostDB Explorer (2026-Q3)]]`).
* Modifying OpenBao or SPIRE infrastructure manifests.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Unintegrated Feature Commits | 105 commits on divergent branch | 0 (all merged into feature baseline) | `git log HEAD..integration/slon-v0.1.0` |
| Navigation Glyph Collisions | 0 | 0 (strictly enforced 1:1 icon-to-route) | `Sidebar.test.tsx` SVG validation |
| Acceptance Spec Registry Coverage | Broken / Diverged | 100% compliant (7/7 BATS guard pass) | `test/acceptance-spec-coverage.bats` |
| Navigation CLS (Layout Shift) | 0.00 | 0.00 | Lighthouse / DevTools layout shift audit |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Component Unit Tests | Vitest across `dashboard-signalloom` (`Sidebar.test.tsx`, `App.test.tsx`) | Services Engineering |
| Acceptance Spec Guard | BATS test checking `SPEC-REGISTRY.tsv` coverage against Playwright projects | Quality Assurance |
| End-to-End Navigation Test | Playwright spec `test/acceptance/navigation.spec.ts` exercising 1–9 shortcuts and rail collapse | DevSecOps Practice |
| Worktree Integrity Check | Falsification test confirming clean branch state across worktrees | GitOps Lead |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| TypeScript 5.6 & React 18 | SPA UI component architecture | Aligned with Signal Loom dashboard standard |
| Vite 5.4 & Bun | Lightning-fast build and bundling | Strictly compliant with Bun-only invariant |
| React Router 6 | Declarative client-side routing | Standard Signal Loom routing layer |
| Playwright | End-to-end browser automation & verification | Monorepo standard acceptance framework |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Signal Loom Monorepo | `github.com/controlplaneio-in-toto/osramp-demo` | Active work on `feat/signal-loop-and-bootstrap-refactor` |
| Dashboard SPA | `d2-signalloom/apps/dashboard-signalloom` | Primary UI target for navigation reconciliation |
| Integration Branch | `integration/slon-v0.1.0` | Source of `SLON-P1-2` onboarding navigation work |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Unauthenticated Access via Routing Glitch | Attacker accesses privileged configuration pages by bypassing protected route guards during routing restructuring | Every registered route is strictly wrapped with `<ProtectedRoute>` requiring valid OIDC Bearer tokens; superadmin routes require active MFA/superadmin session |
| Navigation Click-Jacking / Desync | Operator clicks a governance action (e.g. containment drop) but navigation desync triggers a different route | Active route coordinates tracked dynamically in React state (`selectionBox.to`); unit tests assert route URL matches DOM active element |
| Accidental Regression of SFAS Controls | Merging divergent branch overwrites or drops Signal Fusion / Weave links | Explicit 3-tier categorization preserves `/weave`, `/signal-store`, `/signal-fusion`, and `/distance-latency` |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Solid prior certification of both branches in isolation; comprehensive BATS and Playwright suites | High commit divergence (105+ commits) requires careful semantic review of overlapping files |

| Opportunities | Threats |
| :---- | :---- |
| Establishes a singular, unassailable platform baseline for Q3 customer demos and product pilots | Potential flakiness if spec registry or route timeouts are misconfigured |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Branch Merge, Semantic Conflict Resolution, and 3-Tier Sidebar Unification |  |  |  |  | #cap-architecture, #cap-gitops |
| Mid-project review: demo of unified navigation, evaluation of route integrity, verification of 0 lingering commits | 0.25 | 2 | 0.5 |  | #cap-project-management |
| M2: Whole-Suite Test Verification (BATS, Vitest, Playwright) & Branch Baseline Signoff |  |  |  |  | #cap-devops, #cap-threat-modelling |
| Signoff |  |  |  |  | #cap-architecture |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**
* `integration/slon-v0.1.0` merged cleanly into `feat/signal-loop-and-bootstrap-refactor`.
* `Sidebar.tsx` adheres strictly to the SP-2 3-tier hierarchy (`View`, `Control`, `Design`) with all SFAS routes preserved.
* `bun run test` (Vitest) passes 100% across all dashboard test suites.
* `bats test/acceptance-spec-coverage.bats` passes 7/7.
* Playwright `navigation.spec.ts` passes with 0 regressions.
* 0 lingering commits and 0 worktree divergence.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Platform Engineering Lead |
| Responsible | Dashboard & Frontend Working Group |
| Consulted | Stefan Prodan, Tom Cope |
| Informed | [Andrew Martin](mailto:andy@control-plane.io), [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| CI runner minutes (local Kind / GCP VM) | £0 (existing infrastructure) | Recurring | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-12 | AJM, Architecture Team | Merge integration branch before building Feeds Explorer | Establish clean platform baseline and avoid downstream merge conflicts | Eliminates integration drift |
| 2026-09-12 | AJM, Frontend Team | Reconcile SFAS routes into 3-tier hierarchy (View: Weave, Feeds; Control: Governance; Design: Config) | Unifies operator mental model while adhering to SP-2 Invariant | Clean, intuitive information architecture |

## Appendix

### A. Useful Links
* [`Sidebar.tsx`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/dashboard-signalloom/src/components/Sidebar.tsx)
* [`App.tsx`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/dashboard-signalloom/src/App.tsx)
* [`docs/signalloom/slon-p1-2-evidence.md`](file:///home/andy/src/cp/osramp-demo/docs/signalloom/slon-p1-2-evidence.md)
* [`test/acceptance/SPEC-REGISTRY.tsv`](file:///home/andy/src/cp/osramp-demo/test/acceptance/SPEC-REGISTRY.tsv)

## Auto Kanban Mission Specifications

### Spec: Shared Patterns — Phase 1

* **SP-1: 3-Tier Hierarchical Information Architecture (`Sidebar.tsx`)**
  The navigation model adheres strictly to the SP-2 3-tier hierarchy: `'View' | 'Control' | 'Design' | 'Superadmin'`. Operational telemetry and observability belong in **View** (`/overview`, `/agents`, `/topology`, `/weave`, `/feeds`, `/activity`, `/compliance/risk`); governance controls and state policies belong in **Control** (`/policies`, `/containment`, `/approvals`, `/audit`, `/network-test`, `/collusion-access`, `/rbac-analysis`, `/rbac-explorer`); configuration and infrastructure belong in **Design** (`/workspaces`, `/connectors`, `/fleet`, `/settings`, `/design-system`); deep diagnostics belong under **Superadmin** (`/distance-latency`, `/signal-fusion`, `/signal-store`).

* **SP-2: 1:1 Glyph-to-Route Invariant**
  Every destination in `Sidebar.tsx` must declare a distinct, collision-free SVG icon. No duplicate glyphs are permitted. In collapsed rail mode, each icon represents exactly one unambiguous route destination.

* **SP-3: Hotkey 1–9 Preservation**
  The primary top 9 operational routes in the rail are bound to single-digit hotkeys (1–9) with visual number badges:
  1: Overview (`/overview`)
  2: Agents (`/agents`)
  3: Topology (`/topology`)
  4: The Weave (`/weave`)
  5: Feeds Explorer (`/feeds`)
  6: Activity (`/activity`)
  7: FAIR Risk (`/compliance/risk`)
  8: Policies (`/policies`)
  9: Containment (`/containment`)

* **SP-4: Strict Acceptance Spec Registry Synchronization**
  Every Playwright spec in `test/acceptance/*.spec.ts` must be declared exactly once in `test/acceptance/SPEC-REGISTRY.tsv` with correct runner and reason columns in strict ASCII collation (`LC_ALL=C sort`), matching `playwright.config.ts`. The BATS guard `test/acceptance-spec-coverage.bats` must pass 7/7 checks without error or drift.

* **SP-5: Bun-Only Execution & Zero Clashing Privileges**
  All frontend build, test, and verification commands must be executed via `bun` / `bun test` (never `npm`/`npx`). Testing and verification scripts must respect sandbox constraints (`CLAUDECODE` protection).

### Spec: Capability Plan

| Card ID | Title | Primary Skill | Role | Size | Ceiling | Dependencies |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SLBR-P1-PRE` | Preflight Verification & Dependency Audit | `skills/cp-platform` | Platform Engineer | XS | 15m | None |
| `SLBR-P1-1` | Semantic Merge & Diff Reconciliation | `skills/cp-gitops` | GitOps Engineer | M | 45m | `SLBR-P1-PRE` |
| `SLBR-P1-2` | 3-Tier Sidebar.tsx & Vitest Test Alignment | `skills/cp-frontend` | Frontend Architect | M | 45m | `SLBR-P1-1` |
| `SLBR-P1-3` | App.tsx Routes, Route Labels & Protection Guards | `skills/cp-frontend` | Frontend Engineer | S | 30m | `SLBR-P1-1` |
| `SLBR-P1-4` | Acceptance Spec Registry & Playwright Synchronization | `skills/cp-qa` | QA Automation Lead | S | 30m | `SLBR-P1-2`, `SLBR-P1-3` |
| `SLBR-P1-GOV` | Whole-Suite Acceptance & Baseline Certification | `skills/cp-governor` | Quality Governor | S | 30m | `SLBR-P1-4` |

### Spec: Work Decomposition

| ID | Title | Depends on | Tests / evidence | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :--- |
| SLBR-P1-PRE | Preflight Verification & Dependency Audit | | `git status` clean; merge base confirmed at `47359d52` with `integration/slon-v0.1.0` (`9c65fa3e`) | XS | antigravity | | | | | |
| SLBR-P1-1 | Semantic Merge & Diff Reconciliation | SLBR-P1-PRE | Merge completes cleanly with zero unresolved conflicts; both SLON and SFAS commits retained | M | antigravity | | | | | |
| SLBR-P1-2 | 3-Tier Sidebar.tsx & Vitest Test Alignment | SLBR-P1-1 | 84/84 tests pass in `bun test src/components/Sidebar.test.tsx`; 0 glyph collisions; 1–9 hotkeys intact | M | antigravity | | | | | |
| SLBR-P1-3 | App.tsx Routes, Route Labels & Protection Guards | SLBR-P1-1 | `bun test src/App.test.tsx` passes; cold-load and warm-navigation render without double spinners | S | antigravity | | | | | |
| SLBR-P1-4 | Acceptance Spec Registry & Playwright Synchronization | SLBR-P1-2, SLBR-P1-3 | `bats test/acceptance-spec-coverage.bats` passes all 7 checks | S | antigravity | | | | | |
| SLBR-P1-GOV | Whole-Suite Acceptance & Baseline Certification | SLBR-P1-4 | 100% test pass rate across all suites; governor sign-off ledger recorded in `docs/signalloom/slbr-governor-log.md` | S | antigravity | | | | | |

### Spec: Errata

*(Append-only record of completed cards, deviations, and governor certifications)*

#### Governor Dispatch — SLBR-GOV-INIT
- **Timestamp**: 2026-09-12T13:28:00Z
- **Actor**: Governor (Mission Initialization)
- **Status**: active
- **Digest**: `slbr-baseline-reconciliation-init`
- **Inter-Agent Directive**: Reconcile baseline before branching Feeds Explorer. All task completions, deviations, and blockers must be recorded in this errata ledger.


