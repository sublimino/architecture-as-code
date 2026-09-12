---
created: 2026-09-09T19:13:46+01:00
reviewers:
  - "#stefan-prodan"
  - "#fabian-kammel"
capabilities:
  - "#cap-architecture"
  - "#cap-frontend"
  - "#cap-golang"
  - "#cap-kubernetes"
  - "#cap-documentation"
  - "#cap-testing-pyramid"
  - "#cap-spiffe-openbao"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: 1. Projects/2026-09-2026-09-signalloom-first-user-onboarding/
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q3-signal-loom-first-user-and-agent-onboarding
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q3-signal-loom-first-user-and-agent-onboarding"
updated: 2026-09-10T09:39
shortcode: SLON
---
# Proposal — Signal Loom First User and Agent Onboarding (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-09) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

**Signal Loom today delivered its first end-to-end user and dual-agent onboarding experience, bridging kernel-level confinement, optional Nono cryptographic evidence gathering, and real-time telemetry into an intuitive, zero-friction operator workflow.**

Following the successful completion of the Signal Fusion Delivery Plan (SFDP) and Runtime Confinement (CRKC), the Signal Loom platform possesses world-class runtime observability and sub-second execution halt capabilities. However, enterprise design partners and platform operators faced structural friction when first accessing the platform: navigation hierarchy lacked clarity, onboarding wizard state relied on ephemeral mocks, and claiming a newly scheduled autonomous agent required manual API interaction.

Furthermore, enterprise operators require proof that Signal Loom can govern heterogeneous agent workloads: both cutting-edge workloads sandboxed under Linux Landlock with hash-chained `nono audit` evidence gathering, and standard containerized workloads operating without Nono.

This delivery programme establishes an end-to-end onboarding journey across three focused phases:
* **First User Journey & Information Architecture:** Reorders the primary dashboard sidebar into intuitive View, Control, and Design categories, fixes the onboarding wizard with persistent database-backed status (`/api/onboarding/*`), and guides the user through workspace identity configuration.
* **Dual Demo Agent Onboarding (Optional Nono & Baseline):** Deploys two complementary in-cluster demo agents—one instrumented with optional `nono` Landlock confinement and SPIFFE-signed audit session logging, and one standard baseline containerized agent. Proves that both agents are discovered, claimed, and governed reliably side-by-side.
* **Comprehensive Operator Documentation & Demo Test Isolation:** Publishes complete user and agent onboarding runbooks in `docs-signalloom` and establishes a lightweight, isolated demo test suite enabling reproducible partner walkthroughs without monolithic test overhead.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [x] cost avoidance
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers:**
Enterprise platform operators, security engineers, and partner design teams (including Vultr, Citi, and NatWest) evaluating Signal Loom for autonomous AI agent governance.

|  |  |
| :---- | :---- |
| Our *enterprise operators and partners…* | need a clear, guided path to onboard organizations, configure access policies, and claim both standard and sandbox-evidenced AI agents. |
| Have the problem/opportunity *…* | the user onboarding state fell back to client mock memory, navigation between View, Control, and Design was unsegmented, and newly deployed agents lacked an end-to-end claim and dual-agent evidence verification demo. |
| When *…* | initiating a fresh demonstration, technical evaluation, or customer POC on Signal Loom. |

**What’s the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**
2026-Q3. Directly requested following recent partner demonstrations (Piyush Shukla, Vultr) and scheduled as a primary focus on the 2026-09-10 morning partner agenda. Bridges the completed SFDP and CRKC platforms to end-user usability and validates multi-workload evidence collection.

## Scope Summary

**Technology Readiness Level:** 2 (Alpha) -> 4 (Production Ready).

### In Scope Activities

*Within project delivery and managed by the project team*

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Onboarding State Persistence | Connect `onboardingClient.ts` to live backend database endpoints (`/api/onboarding/status`, `/skip`, `/complete`, `/state`). | Specific: Wizard state and skip status persist in PostgreSQL across browser refreshes.<br/>Measurable: 0 regressions to MOCK_MODE; skip/complete status survives reload.<br/>Attainable: Backed by existing `tenant_onboarding` schema.<br/>Realistic: Standard REST API integration.<br/>Time-Bound: Phase 1. | Vitest and Pytest integration tests asserting DB roundtrips. |
| Sidebar Navigation Reorder | Restructure `dashboard-signalloom` left-hand navigation into categorized sections (View, Control, Design) with prominent Onboarding and Help anchors. | Specific: Navigation items cleanly grouped; active route highlighting intact.<br/>Measurable: 100% route link accessibility; no broken links or layout shifts.<br/>Attainable: React sidebar component refactor.<br/>Realistic: Improves UI ergonomics immediately.<br/>Time-Bound: Phase 1. | Component render tests and Playwright navigation assertions. |
| First User Onboarding Wizard | Deliver interactive 3-step wizard (Tenant Setup, Identity Provider Link, Policy Confirmation) with consent handling. | Specific: Complete flow transitions tenant status to `completed` and redirects to dashboard.<br/>Measurable: Full flow completes in < 60 seconds; audit event recorded.<br/>Attainable: React component tree in `dashboard-signalloom`.<br/>Realistic: Validated UX flow.<br/>Time-Bound: Phase 1. | Playwright e2e onboarding spec. |
| Dual Demo Agent Fleet Deployment | Deploy two functional demo agent workloads in `fe-signalloom-agents`: `agent-nono-evidenced` (with optional Nono Landlock + audit session logging) and `agent-standard-baseline` (standard containerized runtime). | Specific: Both agents register SPIFFE identities, declare discovery labels, and run concurrently.<br/>Measurable: 100% discovery rate for both pods in inventory within 5s.<br/>Attainable: Declarative Kubernetes manifests in fleet.<br/>Realistic: Reuses established agent trust baseline.<br/>Time-Bound: Phase 2. | BATS test verifying both pods running and discovered. |
| Dynamic Nono Optionality & Telemetry Ingest | Implement dynamic capability probe: if Nono exists on node, `agent-nono-evidenced` gathers and signs hash-chained audit sessions; if absent, gracefully falls back without failure. | Specific: Probe detects Nono presence; ingest records signed evidence for Agent 1 and standard telemetry for Agent 2.<br/>Measurable: 0 crashes or pod evictions on Nono-absent environments; signed sessions verified when present.<br/>Attainable: Dynamic probe script in agent entrypoint.<br/>Realistic: Ensures environment portability.<br/>Time-Bound: Phase 2. | BATS test asserting probe exit codes and fallback telemetry. |
| Operator Dual-Agent Claim & Activity Capture | Provide operator claim action in UI supporting both agents, displaying signed audit logs for Agent 1 and live Tetragon flow events for Agent 2. | Specific: Both agents successfully claimed; activity tab renders distinct telemetry streams.<br/>Measurable: Claim latency < 500ms per agent; claims persist across ingress restarts.<br/>Attainable: Signal Ingest claim API and WebSocket stream.<br/>Realistic: Validated in partner demo walkthrough.<br/>Time-Bound: Phase 2. | Playwright claim and activity capture assertion. |
| Isolated Demo Test Suite | Create dedicated test target (`make demo-signalloom-smoke`) running exclusively the user onboarding and dual-agent claim flows. | Specific: Fast-running suite verifying demo readiness without executing monolithic test pyramid.<br/>Measurable: Execution time < 90 seconds; 100% pass rate.<br/>Attainable: Makefile target wrapping targeted Playwright spec.<br/>Realistic: High developer ergonomics for demo prep.<br/>Time-Bound: Phase 2. | `make demo-signalloom-smoke` test run. |
| Onboarding & Operator Docs | Author step-by-step guides in `docs-signalloom` detailing user onboarding, dual-agent claim workflows, and Nono optionality. | Specific: Markdown documentation published under `/docs/onboarding` and `/docs/agents`.<br/>Measurable: 0 broken internal links; clean Astro build.<br/>Attainable: Astro Starlight markdown content.<br/>Realistic: Standard documentation pipeline.<br/>Time-Bound: Phase 3. | `bun run build` in `docs-signalloom`. |
| Adversarial Boundary Checks | Execute negative security checks verifying tenant isolation during onboarding, invalid claim rejection, and Nono tamper detection. | Specific: Cross-tenant claim tampering rejected with HTTP 403; unauthenticated wizard bypass denied; tampered Nono audit session fails verification.<br/>Measurable: 100% of negative security probes rejected.<br/>Attainable: Adversarial integration tests.<br/>Realistic: Essential zero-trust assurance.<br/>Time-Bound: Phase 3. | BATS/Pytest adversarial suite. |

### Out of Scope

* Mandating Nono as a hard prerequisite on environments lacking Landlock kernel support (optionality enforced).
* Modifying underlying kernel containment primitives (cgroup freeze, eBPF TC drop — delivered in CRKC).
* Production multi-region cloud identity synchronization (confined to Kind cluster and GCP demo estate).
* Custom OAuth2 identity provider implementations (utilizes mock/OIDC standard providers).

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Onboarding wizard state persistence | 0% (in-memory mock lost on reload) | 100% (persisted in PostgreSQL) | Page refresh test during wizard progress |
| Time to complete first user onboarding | Unmeasured / Fragmented | < 60 seconds | Automated Playwright scenario timer |
| Dual-agent discovery and claim rate | 0% (only single manual agent) | 100% (both Nono and baseline claimed) | UI telemetry for both agent IDs |
| Nono graceful fallback rate | Unenforced (hard crash if missing) | 100% (clean execution if Nono absent) | Synthetic probe test without Nono binary |
| Agent claim persistence under ingress cycles | Intermittent / unverified | 100% (survives proxy/session reset) | Post-claim ingress restart assertion |
| Demo test suite execution time | ~12 minutes (monolithic test suite) | < 90 seconds (isolated smoke suite) | `make demo-signalloom-smoke` runtime |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| React 18 / TypeScript / Vite | Frontend dashboard, navigation sidebar, and onboarding wizard. | Standard Signal Loom UI stack. |
| Python 3.12 / FastAPI | Backend onboarding API and tenant state endpoints. | Standard `fe-signalloom` backend. |
| PostgreSQL / asyncpg | Persistent storage for wizard state and audit events. | Production database substrate. |
| Astro Starlight | Static documentation site at `/docs`. | Standard Signal Loom documentation stack. |
| Linux Landlock / `nono` | Optional unprivileged host filesystem and network sandboxing + signed audit logging. | ControlPlane agent containment standard. |
| SPIRE / OpenBao | Cryptographic workload identity for onboarding agents. | Standard Agent Trust infrastructure. |
| Playwright / Vitest / BATS | End-to-end, component, and integration test verification. | Repository testing standards. |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Monorepo | `/home/andy/src/cp/osramp-demo` | Main repository. |
| Dashboard App | `d2-signalloom/apps/dashboard-signalloom` | React SPA console. |
| Backend API | `d2-signalloom/apps/fe-signalloom` | FastAPI service with onboarding routes. |
| Documentation | `d2-signalloom/apps/docs-signalloom` | Astro documentation portal. |
| Fleet Manifests | `d2-osramp-fleet/` | Kubernetes manifests for dual demo agents. |

#### Security and Risk

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Tenant IDOR during onboarding | Tenant A alters Tenant B wizard state or claims foreign agent. | Enforce strict `tenant_id` scoping from authenticated JWT on all `/api/onboarding/*` and claim routes. |
| Unauthenticated wizard bypass | User accesses protected dashboard routes without completing setup or consent. | `ProtectedRoute` validates server-side onboarding status before rendering operational views. |
| Nono execution failure on non-Landlock host | Pod crashes on startup if Nono binary or Landlock LSM is missing. | Dynamic pre-flight probe: agent detects environment and switches to unconfined baseline with recorded telemetry. |
| Tampered audit session acceptance | Malicious agent fabricates execution evidence. | Signal Ingest verifies cryptographic signature and hash-chain integrity via `nono audit verify` against agent SPIFFE SVID. |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: First User Onboarding & Navigation Hierarchy (API Persistence + Sidebar Reorder + Wizard Flow) |  |  |  |  | #cap-frontend, #cap-golang, #cap-testing-pyramid |
| M2: Dual Agent Onboarding & Live Demo (Nono Optionality + In-Cluster Agents + Smoke Suite) |  |  |  |  | #cap-kubernetes, #cap-spiffe-openbao, #cap-frontend, #cap-security |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| M3: Documentation & Programme Acceptance (Operator Runbooks + Adversarial Verification + Mission Signoff) |  |  |  |  | #cap-documentation, #cap-testing-pyramid, #cap-security |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**
* 100% of unit, integration, and Playwright tests passing.
* Onboarding state proven persistent across browser reloads without falling back to mock mode.
* Left-hand navigation sidebar cleanly reordered into View, Control, and Design groups.
* Two demo agents deployed and claimable: `agent-nono-evidenced` (signed sessions) and `agent-standard-baseline` (standard).
* Nono optionality probe verified: functions with Landlock, gracefully degrades when absent.
* `make demo-signalloom-smoke` executes and passes in < 90 seconds.
* Documentation published in `docs-signalloom` with zero broken links.
* `SLON-P1` through `SLON-P3` governor certifications signed off and recorded in Errata.

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-10 | AJM | Select Signal Loom First User and Agent Onboarding as the immediate next build. | Bridges completed kernel/telemetry platforms (CRKC, SFDP) into partner-ready product usability. | Prioritizes user experience and partner walk-through reliability. |
| 2026-09-10 | AJM | Standardize card execution on the Antigravity engine (`--agent antigravity`). | Leverages Google Antigravity CLI and Gemini models for high-speed, tool-augmented autonomous execution. | Unified harness execution across all board phases. |
| 2026-09-10 | AJM | Integrate Nono as an optional capability; deploy dual demo agents (one with Nono, one baseline). | Demonstrates heterogeneous fleet governance: rich signed audit trails where Nono exists, seamless standard governance where it does not. | Proves platform robustness across varying host environments. |
| 2026-09-10 | AJM | Create dedicated `make demo-signalloom-smoke` target. | Prevents running 12-minute test suite when only validating demo user journeys. | Dramatic acceleration of demo validation cycles. |

## Appendix

### Spec: Shared Patterns

#### SP-1: Strict Server-Side Onboarding State
Client code in `dashboard-signalloom` must never maintain authoritative onboarding state in module memory or localStorage. All status checks must resolve through `GET /api/onboarding/status` and persist transitions via explicit POST/PUT mutations.

#### SP-2: Navigation Grouping Invariant
The left-hand navigation sidebar follows a strict 3-tier hierarchy:
1. **View:** Overview, Agents, Topology, Activity, FAIR Risk.
2. **Control:** Policies, Containment, Approvals, Audit Trail.
3. **Design:** Workspaces, Connectors, Fleet Config, Settings.
Onboarding and Documentation must remain persistently accessible anchors.

#### SP-3: Antigravity Engine Execution Mandate
All autonomous tasks must execute under the Antigravity engine (`agy`), using context-mode search and structured tool workflows. Every task enforces a minimum 100k token budget and 180-minute ceiling with algorithm mode verification.

#### SP-4: Human Governor Gate
Governor cards (`SLON-P1-GOV`, `SLON-P2-GOV`, `SLON-P3-GOV`) must halt in `Review` and require human operator confirmation before advancing to `Done` and merging into `integration/slon-v0.1.0`.

#### SP-5: Optional Nono Capability Detection & Fallback Invariant
Nono is an optional capability. Workloads instrumented for Nono must run a pre-execution probe (`which nono` and Landlock ABI check). If Nono is present, execute under `nono run` with hash-chained audit logging and SPIFFE detached signing. If Nono is absent, log a structured warning (`nono_capability_available: false`) and execute unconfined without crashing or blocking pod scheduling.

### Spec: Capability Plan

| Logical ID | Role | Skills Required | Size Band | Ceiling (Min) | Agent Model | Task Summary |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SLON-P1-PRE` | preflight | #cap-frontend · #cap-golang · #cap-kubernetes | S | 30 | antigravity | Preflight verification of repo base, Kind cluster, Envoy Gateway, and fe-signalloom build. |
| `SLON-P1-1` | implementation | #cap-golang · #cap-frontend · #cap-testing-pyramid | M | 60 | antigravity | Wire onboarding API client to live database endpoints and eliminate mock mode fallback. |
| `SLON-P1-2` | implementation | #cap-frontend · #cap-architecture · #cap-testing-pyramid | M | 60 | antigravity | Reorder dashboard left-hand sidebar navigation into View, Control, Design categories. |
| `SLON-P1-3` | implementation | #cap-frontend · #cap-testing-pyramid | M | 60 | antigravity | Implement first user onboarding wizard flow with persistent organization setup and consent. |
| `SLON-P1-GOV` | governor | #cap-architecture · #cap-frontend · #cap-testing-pyramid | M | 60 | antigravity | Phase 1 Governor reconciliation, merge into integration branch, and user flow verification. |
| `SLON-P2-PRE` | preflight | #cap-kubernetes · #cap-spiffe-openbao · #cap-golang | S | 30 | antigravity | Preflight verification of agent claim API, SPIFFE provider, and Nono optionality probe. |
| `SLON-P2-1` | implementation | #cap-kubernetes · #cap-spiffe-openbao · #cap-golang | M | 60 | antigravity | Deploy dual demo agents: agent-nono-evidenced and agent-standard-baseline with discovery labels. |
| `SLON-P2-2` | implementation | #cap-security · #cap-linux · #cap-golang | M | 60 | antigravity | Implement dynamic Nono optionality detection and signed audit session telemetry ingest. |
| `SLON-P2-3` | implementation | #cap-frontend · #cap-golang · #cap-testing-pyramid | M | 60 | antigravity | Implement operator dual-agent claim flow in dashboard and wire comparative activity telemetry. |
| `SLON-P2-4` | implementation | #cap-testing-pyramid · #cap-frontend · #cap-devops | S | 45 | antigravity | Create isolated demo smoke test suite (`make demo-signalloom-smoke`) for rapid dual-agent validation. |
| `SLON-P2-GOV` | governor | #cap-architecture · #cap-kubernetes · #cap-testing-pyramid | M | 60 | antigravity | Phase 2 Governor reconciliation, merge into integration branch, and dual-agent claim verification. |
| `SLON-P3-PRE` | preflight | #cap-documentation · #cap-frontend | S | 30 | antigravity | Preflight verification of docs-signalloom Astro build and documentation routes. |
| `SLON-P3-1` | implementation | #cap-documentation · #cap-frontend | M | 60 | antigravity | Author complete user and dual-agent onboarding guides and operator runbooks in docs portal. |
| `SLON-P3-2` | implementation | #cap-security · #cap-testing-pyramid · #cap-red-team | M | 60 | antigravity | Execute adversarial tests asserting tenant isolation during onboarding and claim tampering rejection. |
| `SLON-P3-GOV` | governor | #cap-architecture · #cap-project-management | M | 60 | antigravity | Final Programme Governor certification, mission verification, and sign-off. |

### Spec: Work Decomposition

| ID | Title | Depends on | Tests / evidence | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :--- |
| SLON-P1-PRE | Preflight verification of repo base, Kind cluster, Envoy Gateway, and fe-signalloom build | | Preflight proof recorded in `docs/signalloom/slon-p1-preflight-proof.md`; base confirmed | S | antigravity | pass | | | | |
| SLON-P1-1 | Wire onboarding API client to live database endpoints and eliminate mock mode fallback | SLON-P1-PRE | Vitest and Pytest asserting database roundtrips; skip/complete status survives reload | M | antigravity | pass — delivered: ad2fec79d26dc3445efd50bc37351663c7e91867 (see Errata — SLON-P1-1) | | | | |
| SLON-P1-2 | Reorder dashboard left-hand sidebar navigation into View, Control, Design categories | SLON-P1-PRE | Vitest component tests and Playwright navigation test asserting route links | M | antigravity | pass — delivered: 26eef1b933655d0f6eb3427283b645e3db0dfc26 (see Errata — SLON-P1-2) | | | | |
| SLON-P1-3 | Implement first user onboarding wizard flow with persistent organization setup and consent | SLON-P1-1, SLON-P1-2 | Playwright e2e onboarding spec passes verifying wizard flow and dashboard redirect | M | antigravity | pass — delivered: 8b28a25de55b92f96b5e62e244bf8187ebe6c18b (see Errata — SLON-P1-3) | | | | |
| SLON-P1-GOV | Phase 1 Governor reconciliation: merge Phase 1 deliverables, run user onboarding verification suite | SLON-P1-3 | 100% Phase 1 tests pass; zero regressions; Governor certification recorded | M | antigravity | | | | | |
| SLON-P2-PRE | Preflight verification of agent claim API, SPIFFE provider, and Nono optionality probe | SLON-P1-GOV | Preflight proof recorded in `docs/signalloom/slon-p2-preflight-proof.md` | S | antigravity | | | | | |
| SLON-P2-1 | Deploy dual demo agents: agent-nono-evidenced and agent-standard-baseline with discovery labels | SLON-P2-PRE | BATS test verifying both demo agent pods running in fe-signalloom-agents and registered | M | antigravity | | | | | |
| SLON-P2-2 | Implement dynamic Nono optionality detection and signed audit session telemetry ingest | SLON-P2-1 | BATS assertions verifying graceful fallback when Nono absent and signed sessions when present | M | antigravity | | | | | |
| SLON-P2-3 | Implement operator dual-agent claim flow in dashboard and wire comparative activity telemetry | SLON-P2-1, SLON-P2-2 | Playwright test asserting both agents claimed and distinct telemetry streams rendered | M | antigravity | | | | | |
| SLON-P2-4 | Create isolated demo smoke test suite (`make demo-signalloom-smoke`) for rapid dual-agent validation | SLON-P2-PRE | `make demo-signalloom-smoke` passes in < 90 seconds | S | antigravity | | | | | |
| SLON-P2-GOV | Phase 2 Governor reconciliation: merge Phase 2 deliverables, verify dual-agent claim persistence | SLON-P2-3, SLON-P2-4 | 100% Phase 2 tests pass; both claims persist across restart; Governor cert recorded | M | antigravity | | | | | |
| SLON-P3-PRE | Preflight verification of docs-signalloom Astro build and documentation routes | SLON-P2-GOV | Preflight proof recorded in `docs/signalloom/slon-p3-preflight-proof.md` | S | antigravity | | | | | |
| SLON-P3-1 | Author complete user and dual-agent onboarding guides and operator runbooks in docs portal | SLON-P3-PRE | Clean Astro build; `docs-signalloom` tests pass; zero broken links | M | antigravity | | | | | |
| SLON-P3-2 | Execute adversarial tests asserting tenant isolation during onboarding and claim tampering rejection | SLON-P3-PRE | BATS and Pytest negative security tests pass asserting HTTP 403 on tenant mismatch | M | antigravity | | | | | |
| SLON-P3-GOV | Final Programme Governor certification: certify all deliverables and verify mission acceptance criteria | SLON-P3-1, SLON-P3-2 | 100% test pass across all suites; final mission certification report recorded | M | antigravity | | | | | |

### Spec: Errata

*(Append-only record of completed cards, deviations, and governor certifications)*

#### Governor Dispatch — SLON-GOV-INIT
- **Timestamp**: 2026-09-10T08:08:30Z
- **Actor**: Governor (Mission Initialization)
- **Status**: active
- **Digest**: `b7c63415e969e05fef5c120eae990a07ade802ace9b618ba5ff992788af9ae71`
- **Lease**: `ajm-auto-kanban-slon-a6a426045e5f`
- **Shared Governor Log**: `docs/signalloom/slon-governor-log.md`
- **Inter-Agent Directive**: All task agents must execute under `--agent antigravity` in isolated worktrees created from `--base-ref refs/heads/integration/slon-v0.1.0`. Dual demo agent governance (SP-5) is active: `agent-nono-evidenced` (optional Nono Landlock sandboxing with signed audit session logs; dynamic probe with graceful fallback) and `agent-standard-baseline` (baseline containerized agent). Phase 1 is in progress with `SLON-P1-PRE`. All task completions, deviations, and blockers must be communicated through the shared governor log and recorded in this errata ledger.

#### Errata — SLON-P1-PRE Preflight Verification (2026-09-10 09:10:02+01:00)

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

**Created:** 2026-09-10 09:10:02+01:00  
**Last Updated:** 2026-09-10 09:10:02+01:00  
**Status:** `pass` — GO verdict for Phase 1 implementation  
**Phase 1 can proceed:** yes  
**Commit SHA:** `0e228c66`  
**Integration Ref:** `refs/heads/integration/slon-v0.1.0`  
**Base Commit SHA:** `47359d528b3a03dc377f0a911a37c050d0327f31`  
**Workspace:** `osramp-demo` (`/home/andy/src/.worktrees/0e83e/osramp-demo`)  
**Preflight Proof:** `docs/signalloom/slon-p1-preflight-proof.md`  

**Findings & Validations:**
- Base git commit `47359d528b3a03dc377f0a911a37c050d0327f31` is confirmed aligned with `integration/slon-v0.1.0` via `git merge-base --is-ancestor`.
- Kind single-node cluster `osramp` is active and healthy; all core foundation namespaces (`fe-signalloom`, `ingress`, `flux-system`, `inf-signalloom`, `inf-bao`, `registry`, `kube-system`) report 0 unready or crashlooping pods.
- Envoy Gateway ingress controllers (`envoy-gateway`, `envoy-ingress-cluster-6b24dc08`) are fully rolled out and routing HTTP (301 redirect) and HTTPS Gateway API HTTPRoutes (`/docs/` -> 200 OK, dashboard proxy, dex).
- Frontend `dashboard-signalloom` Vite production build and `tsc` typecheck verified clean (`✓ built in 8.46s`).
- Backend `fe-signalloom` API contracts and migration tests pass 56/56 tests (`scripts/signalloom-api-test.sh contract`).
- Unlinked external worktree symlinks to preserve nono sandbox isolation in isolated build environment.
- Documented preflight proof in `docs/signalloom/slon-p1-preflight-proof.md` and indexed in `docs/README.md`.

#### Errata — SLON-P1-1 Wire onboarding API client to live database endpoints and eliminate mock mode fallback
**Created:** 2026-09-10 09:19:10+01:00  
**Last Updated:** 2026-09-10 09:19:10+01:00  
**Status:** Completed  
**Commit:** ad2fec79d26dc3445efd50bc37351663c7e91867  
**Governor merge:** [pending Governor reconciliation]  
**Decisions:** Hardened `onboardingClient.ts` with structured `OnboardingApiError` and full endpoint coverage (`getStatus`, `skip`, `complete`, `getState`, `putState`). Updated `App.tsx` and `OnboardingWizard.tsx` to ensure authoritative server status resolution and eliminate mock fallbacks. Extended `test_onboarding.py` with comprehensive persistence, anti-IDOR, and lifecycle test assertions.  
**Deviations:** None. All changes conform strictly to SP-1 and zero-mock persistence invariants.  
**Notes:** Vitest (157/157 test files, 3,093 tests) and Pytest (79 tests) suites pass 100%. Evidence recorded in `docs/signalloom/slon-p1-1-evidence.md`.  
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — SLON-P1-2 Reorder dashboard left-hand sidebar navigation into View, Control, Design categories
**Created:** 2026-09-10 09:21:40+01:00  
**Last Updated:** 2026-09-10 09:21:40+01:00  
**Status:** Completed  
**Commit:** 26eef1b933655d0f6eb3427283b645e3db0dfc26  
**Governor merge:** [pending Governor reconciliation]  
**Decisions:** Restructured `Sidebar.tsx` into strict SP-2 3-tier hierarchy (View: Overview, Agents, Topology, Activity, FAIR Risk; Control: Policies, Containment, Approvals, Audit Trail; Design: Workspaces, Connectors, Fleet Config, Settings). Added persistent anchors for Onboarding (`/onboarding`) and Help & Support. Implemented distinct SVG iconography per destination without collision. Added Playwright acceptance test suite `test/acceptance/navigation.spec.ts` and registered in `SPEC-REGISTRY.tsv`.  
**Deviations:** None. All changes conform strictly to SP-2 and WCAG 2.5.3 accessibility invariants.  
**Notes:** Vitest (156/156 test files, 3,088 tests passed; `Sidebar.test.tsx` 84/84 passed), production build (`✓ built in 5.75s`), and BATS spec registry test (7/7 passed) all 100% clean. Evidence recorded in `docs/signalloom/slon-p1-2-evidence.md`.  
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — SLON-P1-3 Implement first user onboarding wizard flow with persistent organization setup and consent
**Created:** 2026-09-10 09:39:00+01:00  
**Last Updated:** 2026-09-10 09:39:00+01:00  
**Status:** Completed  
**Commit:** 8b28a25de55b92f96b5e62e244bf8187ebe6c18b  
**Governor merge:** [pending Governor reconciliation]  
**Decisions:** Built 3-step first user onboarding wizard (`TenantIdentityStep`, `IdpLinkageStep`, `ContainmentPolicyConsentStep`) and celebratory completion screen (`CompletionCelebration`) in `dashboard-signalloom`. Connected directly to live backend endpoints (`GET/PUT /api/onboarding/state`, `POST /api/onboarding/complete`, `POST /api/onboarding/skip`, `GET /api/onboarding/status`) with strict zero-mock state persistence (SP-1). Implemented client-side validation error alert banner (`ValidationErrorBanner`) and interactive IdP connection test probe. Integrated with `ProtectedRoute` to direct unonboarded operators to `/onboarding` and redirect completed/skipped operators to `/overview`. Added Playwright acceptance test suite `test/acceptance/onboarding.spec.ts` registered with `suite-only` runner in `SPEC-REGISTRY.tsv`.  
**Deviations:** None. All changes conform strictly to SP-1, SP-2, and WCAG accessibility standards.  
**Notes:** Vitest suite (158/158 test files, 3,107 passed tests; `OnboardingWizard.test.tsx` 14/14 passed), TypeScript typecheck (0 errors), Vite production build (`✓ built in 4.43s`), and BATS spec registry test (7/7 passed) all 100% clean. Evidence recorded in `docs/signalloom/slon-p1-3-evidence.md`.  
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->




