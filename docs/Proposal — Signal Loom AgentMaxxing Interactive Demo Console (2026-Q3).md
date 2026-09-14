---
created: 2026-09-13
reviewers:
  - John Kjell
  - Andrew Martin
capabilities:
  - "#cap-kubernetes"
  - "#cap-networking"
  - "#cap-golang"
  - "#cap-threat-modelling"
  - "#cap-purple-team"
  - "#cap-secrets"
practice:
  - Cyber Resilience & Threat Assurance
  - AI & Data Security
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-07-signalloom-d2-platform-baseline/"
parentProposal: "[[Proposal — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - enhancement-proposals
  - proposal-2026-q3-signal-loom-agentmaxxing-interactive-demo-console
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q3-signal-loom-agentmaxxing-interactive-demo-console"
updated: 2026-09-13T22:00
---
# Proposal — Signal Loom AgentMaxxing Interactive Demo Console (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-13) |
| Reviewer & Date: | John Kjell (2026-09-13) |
| Approver & Date: |  |

> [!important] Why this, why now
> The AgentMaxxing Signal Loom User and External Agent Onboarding (AMXO) initiative has successfully completed its core engineering across all six phases (Phases 0–6 certified, 7 multi-layer test suites passing 100%). While the underlying host sensor, Landlock confinement, one-time enrollment exchange, ingestion spine, and dossier timeline exist, the platform lacks a dedicated, interactive, standalone **Demo Console & Stepping Suite** (`/demos/agentmaxxing`). Prospective customers, CISOs, and partner evaluators currently only see external agent activity nested inside static dossiers. To convert design-partner interest into Tier-1 enterprise adoption, Signal Loom requires an executive-ready, interactive demonstration surface where operators can step through the agent lifecycle, trigger adversarial tamper injections, view live confinement telemetry, and verify instantaneous attributable revocation in seconds.

## Press Release

**Signal Loom launches the AgentMaxxing Interactive Demo Console — enabling security leaders to simulate, observe, and test external AI agent governance with a single click.**

As autonomous coding and reasoning agents enter production development workflows, enterprise security teams must answer a critical question: *Can we safely onboard external host agents without exposing private code or losing runtime control?* The new Signal Loom AgentMaxxing Demo Console provides an interactive, live-stepping laboratory where security architects can evaluate the entire agent governance lifecycle in real time. From initial operator token issuance and Ed25519 host enrollment to Landlock LSM process confinement, live SHA-256 artifact hashing, adversarial tamper injection, and instant attributable revocation, the Demo Console makes complex agentic security tangible. Built with strict zero-customer-payload guarantees, the console proves that enterprise observability does not require sacrificing IP or privacy.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [x] marketing
- [x] product
- [ ] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Regulated financial institutions, healthcare providers, enterprise CISOs evaluating autonomous agent governance, and design partners onboarding external Linux developer agents.

|  |  |
| :---- | :---- |
| Our *…* | enterprise security leaders, CISOs, and prospective customers evaluating Signal Loom |
| Have the problem/opportunity *…* | seeing and proving how external agent governance, Landlock confinement, and instant revocation operate without manually setting up complex multi-node infrastructure |
| When *…* | evaluating agentic security solutions, conducting executive proofs-of-concept, or validating compliance against AI safety and governance frameworks |

**Urgency.** 2026-Q3. Essential for upcoming design-partner executive briefings and keynote product demonstrations, capitalizing on the freshly certified AMXO foundation.

## Scope Summary

**Technology Readiness Level: 2+ (Alpha) → 3 (Beta).** Rationale: The core enrollment, telemetry, and ingestion backends are fully built and tested (TRL 2 validated in AMXO); this proposal builds the user-facing interactive stepping console, scenario presets, adversarial simulators, and automated acceptance tests (TRL 3 Beta).

**MVP:** A dedicated route (`/demos/agentmaxxing`) in `dashboard-signalloom` providing a 5-stage interactive lifecycle stepper, live telemetry stream visualizer, adversarial tamper injector, attributable revocation validator, and automated Playwright test suite.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| 5-Stage Interactive Lifecycle Stepper UI | Build standalone `/demos/agentmaxxing` console with stage progression: Stage 1 (Operator Token Issue), Stage 2 (Host Ed25519 Enrollment), Stage 3 (Landlock Confinement Telemetry), Stage 4 (Adversarial Tamper Simulation), Stage 5 (Attributable Revocation & 403 Denial). | Specific: dedicated interactive page with 5 distinct steps and state badges<br/>Measurable: 100% of stages advanceable via manual or auto-stepping<br/>Attainable: builds on React/Tailwind/lucide-react stack<br/>Realistic: bounded UI engineering<br/>Time-Bound: 2026-Q3 | Vitest component tests + Playwright browser tests |
| Live Confinement & Zero-Payload Telemetry Visualizers | Real-time process gauges (CPU %, RSS MB, Open FDs), live file hashing table (comparing computed SHA-256 against expected with match badges), and Zero-Payload Inspector proving 100% metadata-only telemetry. | Specific: gauges render live streaming values; zero prompt/code text exposed<br/>Measurable: Zero customer payload inspector confirms 0 payload leaks<br/>Attainable: uses AMXO host-sensor telemetry schema<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Unit tests on telemetry parsers + UI snapshot tests |
| Adversarial Tamper Injection Panel | Interactive simulation controls allowing the operator to inject hash mismatches, symlink traversal attempts, or oversized writes, triggering instant boundary breach containment alerts. | Specific: clicking "Inject Tamper" modifies artifact hash and triggers red containment badge<br/>Measurable: breach detected in <100ms on UI timeline<br/>Attainable: uses mock/live defect injection endpoints<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Integration test with defect simulation fixtures |
| Attributable Revocation & 403 Denial Verification | Operator revokes host credential with attributable reason; console verifies instant 403 denial on subsequent upload; live cryptographic timeline audit renders revocation event. | Specific: revocation fires API call; subsequent upload fails with 403 Forbidden<br/>Measurable: 403 denial verified with green checkmark within 2s<br/>Attainable: integrates with AMXO host-revocation endpoint<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Playwright acceptance spec asserting 403 status code |
| Demo Automation, Presets & Documentation | Auto-Play mode with speed toggle (1x, 2x, instant), scenario selector (Happy Path, Tamper Breach, Revocation Race), idempotent state reset, and user guide in `apps/docs-signalloom`. | Specific: auto-play steps through all 5 stages; reset restores baseline state<br/>Measurable: reset takes <500ms; docs site renders complete guide<br/>Attainable: state-machine based stepping<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Acceptance suite + Astro docs diagnostic |

### Out of Scope

* Modifying the production kernel LSM or nono profile generation (delivered in AMXO Phase 4).
* Multi-cluster cross-cloud federation (covered in separate fleet proposals).
* In-cluster agent mesh containment (covered in Proposal SLER).

### KPIs

| Metric | Current | Target | Measurement |
| :---- | :---- | :---- | :---- |
| Standalone demo pages for external agent governance | 0 (only nested in dossiers) | 1 dedicated console (`/demos/agentmaxxing`) | Route verification |
| Time to demonstrate complete 5-stage agent lifecycle | >15 mins manual setup | <90 seconds via Auto-Play | Stepper benchmark |
| Interactive adversarial tamper injection scenarios | 0 | 3 (hash mismatch, symlink escape, oversize) | Feature test |
| Zero-customer-payload visual proof availability | None | 100% visible on inspector toggle | Accessibility audit |
| End-to-end browser test coverage | None for demo console | 100% green Playwright suite | `make demo-agentmaxxing-ui-test` |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| UI Stepper state-machine integrity | Vitest unit tests in `dashboard-signalloom` | Delivery team |
| Zero customer payload leak audit | Automated DOM inspection asserting absence of prompt/code strings | AI & Data Security practice |
| Browser acceptance journey | Playwright test suite (`agentmaxxing-demo-console.spec.ts`) | Delivery team |
| Accessibility & responsive layout | `make acceptance-test` checking a11y contrast and keyboard navigation | Cyber Resilience practice |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| React / TypeScript | Stepper UI, telemetry charts, interactive simulator | Standard Signal Loom dashboard frontend |
| Tailwind CSS / Lucide React | Clean, high-contrast dark-mode component styling | Monorepo design system (`d2-signalloom/DESIGN.md`) |
| FastAPI / Go | Backend enrollment, telemetry streaming, revocation APIs | Existing Signal Loom backend stack |
| Playwright | Browser acceptance testing across desktop and tablet | Monorepo testing standard (`test/acceptance/`) |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Dashboard SPA | `d2-signalloom/apps/dashboard-signalloom/` | Hosts `/demos/agentmaxxing` route and stepper |
| Documentation site | `d2-signalloom/apps/docs-signalloom/` | User documentation and demo guide |
| Backend API | `d2-signalloom/apps/fe-signalloom/` | Serves enrollment, telemetry, and revocation endpoints |
| Test suite | `test/acceptance/agentmaxxing-demo-console.spec.ts` | End-to-end browser acceptance spec |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Demo console leaks sensitive prompt or host code contents | High | Strict zero-customer-payload invariant: UI models only accept bounded metadata fields; automated regex leak scanner |
| State-machine desynchronization during rapid user clicking | Medium | Immutable stage transitions with disabled navigation buttons during async operations |
| Mock/Live bridge drift between demo simulation and actual API | Medium | Shared TypeScript contracts between demo simulator and live backend endpoints |
| Unauthenticated access to revocation endpoints | High | Demo endpoints enforce tenant-bound session tokens or read-only simulation sandbox mode |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Leverages complete, certified AMXO infrastructure; immediate visual ROI | Requires keeping demo presets in sync with backend API evolution |
| Differentiates Signal Loom in live enterprise sales conversations | Requires Playwright fixtures for deterministic headless CI runs |

| Opportunities | Threats |
| :---- | :---- |
| Accelerated enterprise design-partner acquisition | Complex state machines can produce flaky browser tests if not properly isolated |
| Direct visual evidence of zero-payload security for compliance audits | Competitor claims of "simulated-only" governance |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Stepper state-machine architecture, wire contracts & scenario presets |  |  |  |  | #cap-architecture #cap-golang |
| M2: Interactive Stepper UI & Stage 1–2 panels (Token Issue & Enrollment) |  |  |  |  | #cap-kubernetes #cap-secrets |
| M3: Stage 3 Confinement Telemetry panel & Zero-Payload Inspector |  |  |  |  | #cap-observability #cap-threat-modelling |
| M4: Stage 4–5 Adversarial Simulation & Attributable Revocation panel |  |  |  |  | #cap-purple-team #cap-security |
| M5: Demo Automation, Auto-Play mode, and Documentation Guide |  |  |  |  | #cap-documentation #cap-testing-pyramid |
| M6: Playwright Acceptance Suite & Monorepo Certification |  |  |  |  | #cap-testing-pyramid #cap-sdlc-tooling |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* `/demos/agentmaxxing` route is fully accessible and navigable in `dashboard-signalloom`.
* All 5 lifecycle stages step smoothly with live visual telemetry, hash verification, and zero-payload audit proof.
* Adversarial tamper injection and attributable revocation panels demonstrate instantaneous 403 denial.
* 100% of Playwright acceptance tests pass cleanly in `make demo-agentmaxxing-ui-test`.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Product & Customer Engineering practice lead ([Andrew Martin](mailto:andy@control-plane.io)) |
| Responsible | Signal Loom frontend & demo delivery team |
| Consulted | Cyber Resilience & Threat Assurance (John Kjell); AI & Data Security |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

Funded under Signal Loom Product Demonstration & GTM Enablement investment.

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| CI browser testing minutes | Minimal (<$20/mo) | Recurring | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-13 | AJM | Create dedicated standalone demo console (`/demos/agentmaxxing`) rather than burying in dossiers | High-impact sales and executive demonstrations require a frictionless, step-by-step experience | Accelerated prospect evaluation and clear visual differentiator |
| 2026-09-13 | AJM | Include dedicated Zero-Customer-Payload Inspector in the live UI | Enterprise CISOs need provable assurance that external agent telemetry does not leak code or prompts | Immediate compliance and privacy credibility |
| 2026-09-13 | AJM | Support both manual stepping and Auto-Play mode with speed controls | Live conference presentations need hands-free execution; deep technical reviews need step-by-step inspection | Dual-mode presentation flexibility |

## Appendix

### A. Useful Links

* Parent: [[Proposal — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3)]]
* Sibling: [[Proposal — Signal Loom Enforcement and Response (2026-Q3)]]
* Code: `d2-signalloom/apps/dashboard-signalloom/src/components/`, `d2-signalloom/apps/fe-signalloom/`
* Design: `d2-signalloom/DESIGN.md`

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `AMXD`
- Integration branch: `refs/heads/integration/amxd-v0.1.0`
- Target components: `d2-signalloom/apps/dashboard-signalloom`, `d2-signalloom/apps/docs-signalloom`, `test/acceptance/`
- Acceptance commands: `make demo-agentmaxxing-ui-test`, `bats test/acceptance-spec-coverage.bats`

#### Architectural constitution
- **State-Machine Controlled Stepper**: The demo console operates as a deterministic 5-stage finite state machine (`operator_init` → `host_enrolled` → `confinement_streaming` → `adversarial_tamper` → `revocation_denied`). Transitions are strictly validated, preventing out-of-order state corruptions.
- **Strict Zero-Customer-Payload Invariant**: The UI and client-side models are structurally prohibited from receiving, storing, or rendering prompt bodies, model generation tokens, or customer source code files. Telemetry tables display strictly allowlisted metadata (SHA-256 digests, process comm names, RSS byte counters, CPU execution ticks).
- **Dual-Mode Execution (Manual vs Auto-Play)**: Operators can manually click through individual stages or activate Auto-Play mode with configurable pacing (1x: 4s per stage, 2x: 2s per stage, instant: 100ms per stage).
- **Adversarial Defect Simulation**: Clicking "Inject Tamper" modifies the calculated SHA-256 artifact hash on the client/mock channel, proving that the verification engine flags the discrepancy and denies downstream ingestion.
- **Attributable Revocation & 403 Proof**: Revoking the agent issues an authenticated `POST /api/v1/agentmaxxing/hosts/{host_id}/revoke` with an operator attribution reason; the subsequent upload assertion visibly fails with `403 Forbidden` and updates the timeline with an immutable red badge.
- **Idempotent Reset**: A "Reset Estate" action wipes simulated demo state and returns the UI to Stage 1 without requiring pod restart or database dropping.

#### Canonical locations
- `d2-signalloom/apps/dashboard-signalloom/src/pages/AgentMaxxingDemoPage.tsx` — Main demo console page
- `d2-signalloom/apps/dashboard-signalloom/src/components/demos/` — Stepper, telemetry gauges, tamper panel components
- `d2-signalloom/apps/docs-signalloom/src/content/docs/demos/agentmaxxing.mdx` — User documentation
- `test/acceptance/agentmaxxing-demo-console.spec.ts` — Playwright acceptance spec

#### Testing standards
- Component & State Machine Tests: `bun run test --run src/components/demos/` in `dashboard-signalloom`
- Typecheck: `bun run typecheck` in `dashboard-signalloom`
- Browser Acceptance Suite: `make demo-agentmaxxing-ui-test`
- Spec Coverage Registry Gate: `bats test/acceptance-spec-coverage.bats`

#### Anti-patterns
- Never display raw customer source code or prompt text in demo widgets.
- Never use non-deterministic timeouts (`page.waitForTimeout`) in Playwright demo tests.
- Never let demo state leak into production agent dossiers without explicit tenant/mock isolation flags.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; ripwire-before-you-build | Baseline engineer | S | 45m | fast | Validate AMXD harness identity, existing AMXO contracts, and dashboard baseline. |
| P1-PRE | FirstPrinciples; ripwire-before-you-build | Contract architect | S | 45m | daily | Inventory AMXO API endpoints, route structure, and component library. |
| P1-1 | ripwire-write-tests; FirstPrinciples | Stepper architect | M | 90m | daily | Design 5-stage lifecycle state machine and step-control contract. |
| P1-2 | ripwire-write-tests; Security | Scenario architect | M | 90m | daily | Define demo scenario presets (Happy Path, Tamper Breach, Revocation Race). |
| P1-3 | ripwire-before-you-build; Security | Integration architect | L | 150m | deep | Freeze demo mock/live bridge contracts and reset/seed endpoints. |
| P1-4 | ripwire-write-tests; ripwire-security-scan | Implementation | S | 45m | antigravity | nginx.conf contains zero `location /v1/` blocks, and Dockerfile:27-29 copies that config over the built dist, so production serves behind it. The console's integration is broken in the real image, not only in local development. |
| P1-5 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | kpai | test/acceptance/helpers.ts:108 defaults demoMode to true, so a specification passes with no backend. A 403 is structurally unreachable in demo mode because an unfixtured route throws demoModeError at 501 or 404, never 403, so the headline authorisation assertion can only pass by fabricating the response it claims to verify. Must land before P4-2 depends on that assertion. |
| P1-GOV | CodeReview; ripwire-change-check | Architecture Governor | M, P1-4, P1-5 | 90m | deep | Approve stepper contracts and verify zero unresolved kickoff gates. |
| P2-PRE | ripwire-before-you-build; Browser | UI pre-flight engineer | S | 45m | daily | Confirm UI components, styling standards, and routing seams. |
| P2-1 | Browser; ripwire-write-tests | Frontend engineer | L | 150m | daily | Build Stepper Header and Stage Progression Controller (Stages 1 to 5). |
| P2-2 | Browser; ripwire-write-tests | Enrollment UI engineer | L | 150m | daily | Implement Stage 1 (Token Issue) & Stage 2 (Ed25519 Enrollment) panels. |
| P2-GOV | CodeReview; Browser; ripwire-change-check | Frontend Governor | M | 90m | deep | Merge Stage 1-2 UI and verify attributable enrollment display. |
| P3-PRE | ripwire-before-you-build; ripwire-reuse-first | Telemetry pre-flight engineer | S | 45m | daily | Confirm SSE/websocket telemetry streaming and host metrics contract. |
| P3-1 | Browser; ripwire-write-tests | Telemetry UI engineer | L | 150m | daily | Implement Stage 3 Confinement Telemetry panel (CPU/RSS gauges, file hashing). |
| P3-2 | Browser; Security | Privacy UI engineer | L | 150m | daily | Implement Zero-Payload Inspector widget proving prompt/code confidentiality. |
| P3-GOV | CodeReview; ripwire-change-check | Telemetry Governor | M | 90m | deep | Merge telemetry visualization and verify zero customer payload display. |
| P4-PRE | ripwire-before-you-build; ripwire-write-tests | Adversarial pre-flight engineer | S | 45m | daily | Confirm defect injection hooks and revocation API seams. |
| P4-1 | Browser; ripwire-write-tests | Adversarial simulation engineer | L | 150m | daily | Implement Stage 4 Adversarial Simulation (hash tamper, symlink escape, oversize). |
| P4-2 | Browser; Security | Revocation UI engineer | L | 150m | daily | Implement Stage 5 Attributable Revocation & live 403 denial verification panel. |
| P4-GOV | CodeReview; Browser; ripwire-change-check | Adversarial Governor | L | 150m | deep | Merge adversarial and revocation panels and verify deterministic denial feedback. |
| P5-PRE | ripwire-before-you-build; ripwire-reuse-first | Automation pre-flight engineer | S | 45m | daily | Confirm automated stepping timers and docs integration seams. |
| P5-1 | Browser; ripwire-write-tests | Automation engineer | M | 90m | daily | Implement Auto-Play mode, speed toggles (1x, 2x, instant), and state reset engine. |
| P5-2 | Drawio; Browser | Documentation engineer | M | 90m | daily | Publish interactive demo walkthrough guide in apps/docs-signalloom. |
| P5-GOV | CodeReview; Browser; ripwire-change-check | Experience Governor | M | 90m | deep | Merge demo automation and docs and verify presentation readiness. |
| P6-PRE | ripwire-before-you-build; Browser | Acceptance pre-flight engineer | S | 45m | daily | Confirm Playwright test harness, mock server fixtures, and SPEC-REGISTRY. |
| P6-1 | Browser; ripwire-write-tests | Acceptance engineer | L | 150m | deep | Build Playwright acceptance suite covering all 5 stages and tamper injection. |
| P6-2 | ripwire-write-tests; SystemsThinking | Test wiring engineer | M | 90m | daily | Wire make demo-agentmaxxing-ui-test into estate runners and update SPEC-REGISTRY. |
| P6-GOV | CodeReview; Browser; ripwire-change-check | Acceptance Governor | L | 150m | deep | Reconcile acceptance wiring, run full test suite, and certify AMXD delivery. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | preflight | Validate AMXD harness identity and clean dashboard build baseline | None | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode AMXD`; repository and board evidence only | S | fast | Pending | $0.00 | N/A | N/A | N/A |
| P1-PRE | preflight | Inventory AMXO API endpoints, route structure, and component library | P0 | Endpoint schema review; `d2-signalloom/apps/dashboard-signalloom` inventory | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-1 | implementation | Design 5-stage lifecycle state machine and step-control contract | P1-PRE | Vitest state-machine transitions; `src/components/demos/types.ts` contract | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-2 | implementation | Define demo scenario presets for happy path, tamper breach, and revocation | P1-PRE | Presets schema tests; deterministic scenario fixture data | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-3 | implementation | Freeze demo mock/live bridge contracts and reset/seed endpoints | P1-1, P1-2 | Contract snapshot; client bridge interface tests; idempotent reset contract | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P1-4 | implementation | Add the missing /v1/ proxy route to nginx and verify behind the real image | P1-PRE | `rg -n 'location' d2-signalloom/apps/dashboard-signalloom/nginx.conf` | S | antigravity | Pending | $0.00 | N/A | N/A | N/A |
| P1-5 | implementation | Make the acceptance suite capable of failing | P1-PRE | `bats test/acceptance-spec-coverage.bats` | M | kpai | Pending | $0.00 | N/A | N/A | N/A |
| P1-GOV | governor | Approve stepper contracts and verify zero unresolved kickoff gates | P1-1, P1-2, P1-3, P1-4, P1-5 | Architecture review; zero kickoff gate exceptions | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P2-PRE | preflight | Confirm UI components, styling standards, and routing seams | P1-GOV | Component library check; `/demos/agentmaxxing` route registration check | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-1 | implementation | Build Stepper Header and Stage Progression Controller | P2-PRE | Vitest stepper unit tests; stage navigation click assertions | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-2 | implementation | Implement Stage 1 Token Issue and Stage 2 Ed25519 Enrollment panels | P2-PRE | Vitest enrollment panel tests; attributable token generation visual check | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-GOV | governor | Merge Stage 1-2 UI and verify attributable enrollment display | P2-1, P2-2 | Typecheck + vitest suites pass; zero regression in existing sidebar | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P3-PRE | preflight | Confirm SSE/websocket telemetry streaming and host metrics contract | P2-GOV | Telemetry fixture probe; host sensor payload schema verification | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-1 | implementation | Implement Stage 3 Confinement Telemetry panel | P3-PRE | Gauge rendering tests; live CPU/RSS/FD updates; hash comparison table | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-2 | implementation | Implement Zero-Payload Inspector widget proving prompt/code confidentiality | P3-PRE | Zero-payload assertion tests; metadata-only display proof | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-GOV | governor | Merge telemetry visualization and verify zero customer payload display | P3-1, P3-2 | Vitest suites pass; zero prompt/code leak verified | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P4-PRE | preflight | Confirm defect injection hooks and revocation API seams | P3-GOV | Defect injection contract check; revocation status endpoint verify | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-1 | implementation | Implement Stage 4 Adversarial Simulation panel | P4-PRE | Hash tamper test; symlink escape test; breach alert trigger assertion | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-2 | implementation | Implement Stage 5 Attributable Revocation and live 403 denial verification panel | P4-PRE | Revocation dispatch test; 403 denial badge assertion; audit timeline check | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-GOV | governor | Merge adversarial and revocation panels and verify deterministic denial feedback | P4-1, P4-2 | Combined tamper + revocation test; zero visual flakiness | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P5-PRE | preflight | Confirm automated stepping timers and docs integration seams | P4-GOV | Timer mock verification; docs navigation link inventory | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-1 | implementation | Implement Auto-Play mode, speed toggles, and state reset engine | P5-PRE | Auto-stepping timer tests (1x, 2x, instant); reset idempotency test | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-2 | implementation | Publish interactive demo walkthrough guide in apps/docs-signalloom | P5-PRE | Astro docs build passes; demo guide content verified | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-GOV | governor | Merge demo automation and docs and verify presentation readiness | P5-1, P5-2 | Full auto-play pass verification; docs link check | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P6-PRE | preflight | Confirm Playwright test harness, mock server fixtures, and SPEC-REGISTRY | P5-GOV | Test harness check; mock server seed verification | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-1 | implementation | Build Playwright acceptance suite covering all 5 stages and tamper injection | P6-PRE | `test/acceptance/agentmaxxing-demo-console.spec.ts` passes 100% | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P6-2 | implementation | Wire make demo-agentmaxxing-ui-test into estate runners | P6-PRE | `make demo-agentmaxxing-ui-test` passes; SPEC-REGISTRY.tsv updated | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-GOV | governor | Reconcile acceptance wiring, run full test suite, and certify AMXD delivery | P6-1, P6-2 | `bats test/acceptance-spec-coverage.bats` passes; all console tests green | L | deep | Pending | $0.00 | N/A | N/A | N/A |

### Spec: Errata

#### Errata — AMXD-P0 (bootstrap)
##### Task identity
- Card: `AMXD-P0`
- Shortcode: `AMXD`
- Commit: Pending
- Result: Pending

##### Deliverable verification
- Verification: Baseline monorepo check and doctor output verified.

#### Errata — AMXD-P1-PRE (preflight)
##### Task identity
- Card: `AMXD-P1-PRE`
- Shortcode: `AMXD`
- Commit: Pending
- Result: Pending

##### Deliverable verification
- Verification: Seam inventory and kick-off gates verified.

#### Errata — AMXD-P1-4 (bootstrap)
##### Task identity
- Card: `AMXD-P1-4`
- Shortcode: `AMXD`
- Commit: Pending
- Result: Pending

#### Errata — AMXD-P1-5 (bootstrap)
##### Task identity
- Card: `AMXD-P1-5`
- Shortcode: `AMXD`
- Commit: Pending
- Result: Pending

