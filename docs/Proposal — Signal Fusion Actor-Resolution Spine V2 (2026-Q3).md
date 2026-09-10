---
created: 2026-09-10
reviewers:
  - "#vicente-herrera"
  - "#francesco-beltramini"
capabilities:
  - "#cap-golang"
  - "#cap-kubernetes-api-programming"
  - "#cap-build-provenance"
  - "#cap-supply-chain-security"
  - "#cap-threat-modelling"
  - "#cap-architecture"
  - "#cap-red-team"
  - "#cap-frontend"
  - "#cap-testing-pyramid"
practice:
  - AI & Data Security
  - Cyber Resilience & Threat Assurance
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: 1. Projects/2026-07-signalloom-d2-platform-baseline/
parentProposal:
enhancements:
  - "[[Proposal — SuperCredential Multi-Agent Evolution — The Cascade]]"
  - "[[Proposal — Signal Fusion Agents Page Operational Redesign and Evidence Dossier (2026-Q3)]]"
  - "[[Proposal — Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment (2026-Q3)]]"
  - "[[Proposal — Signal Loom First User and Agent Onboarding (2026-Q3)]]"
  - "[[Proposal — Signal Fusion Collector Wiring Harness (2026-Q3)]]"
  - "[[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]]"
  - "[[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]]"
  - "[[Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-signal-fusion-actor-resolution-spine-v2
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q3-signal-fusion-actor-resolution-spine-v2"
updated: 2026-09-10T20:15
status: draft
---
# Proposal — Signal Fusion Actor-Resolution Spine V2 (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-10) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

**ControlPlane turns multi-agent autonomous swarms from untraceable black boxes into cryptographically provable delegation chains — backed by live Landlock audit telemetry, instant dossier verification, and sub-second kernel containment.**

When an autonomous AI agent in a regulated enterprise triggers a privileged operation, modern security teams face a fundamental barrier: in a multi-tier agent architecture, an executing data vault agent is commanded by a batch pipeline agent, which was instructed by an LLM reasoning agent, which was delegated by a human operator. Traditional CNAPP and SIEM solutions observe five disjoint telemetry planes that cannot connect the dots. The execution chain breaks, attribution is lost, and compliance under EU AI Act Article 26 and DORA Article 5 becomes impossible.

The Signal Fusion Actor-Resolution Spine V2 solves this problem in production. Building directly upon the core resolution engine and tamper-evident Parquet attestor delivered in V1, V2 scales the spine to govern live autonomous fleets. It resolves recursive, multi-hop delegation chains ("The Cascade") across heterogeneous identifiers, ingests detached SPIFFE-signed audit session logs from Landlock-confined demo agents, embeds the 7-hop cryptographic proof directly into the operator's operational Agent Dossier, and binds directly to the Stun Sentinel to instantly sever temporal delegation edges upon containment. Regulators and CISOs no longer have to rely on promises or logs that can be tampered with — they receive an independently verifiable, mathematically sound answer to "who authorized this action?" in real time.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [ ] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Signal Loom platform partner; Tier-1 financial institutions and regulated critical national infrastructure (CNI) deploying multi-agent autonomous workflows; AI safety and compliance auditors.

|  |  |
| :---- | :---- |
| Our *…* | regulated enterprise security and risk operations teams managing multi-tier autonomous AI swarms |
| Have the problem/opportunity *…* | they cannot prove, from tamper-evident independent evidence, which human principal authorized an action across a multi-hop agent delegation cascade, leaving them exposed to prompt injection, borrowed identity abuse, and regulatory non-compliance |
| When *…* | an agent executes an unauthorized tool or touches sensitive data, requiring immediate attribution, forensic drill-down in the operational dossier, or instant cgroup/TC containment |

**What’s the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

2026-Q3. V1 delivered and certified the foundational substrate on 2026-09-05 (deterministic-first resolver, Postgres identity graph, FrostDB flush-boundary attestor, who-authorized API). In parallel, four adjacent platform slices have completed: `SLON` (dual demo agents with Nono Landlock sandboxing), `SFAGENTS` (production 5-tab Agent Dossier), `CRKC` (Stun Sentinel cgroup freezer and TC eBPF packet severance), and `AUDIT` (formal security audit). Furthermore, the keystone proposal "SuperCredential Multi-Agent Evolution — The Cascade" demands multi-agent transitive delegation. V2 unites these independent platform slices into a cohesive, production-grade operational governance engine.

## Scope Summary

**Technology Readiness Level: 3 (Beta).** Rationale: The core primitives (CEL correlation, FrostDB pushdown store, `go-witness` segment attestation, and single-hop resolution) are already implemented and certified in `d2-signalloom/apps/signal-ingest`. V2 takes these proven primitives and binds them to live in-cluster workloads (`agent-nono-evidenced`), UI workflows (Agent Dossier Tabs 2 and 5), automated containment hooks (`stun-sentinel`), and transitive multi-hop graph traversal.

The MVP focuses on closing five specific operational gaps:
1. Recursive / transitive delegation graph traversal across multi-agent chains with loop detection.
2. Ingestion and verification of detached SPIFFE-signed audit session logs from the live `agent-nono-evidenced` container.
3. Automated injection of human onboarding claims into the PostgreSQL identity and delegation graph.
4. Native embedding of the 7-hop attested authorization chain into Tab 2 (Identity & SPIFFE) and Tab 5 (Activity Timeline) of `AgentDetailPage.tsx`.
5. Closed-loop integration with `stun-sentinel` to clamp temporal delegation validity upon containment.

### In Scope Activities

*Within project delivery and managed by the project team*

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Transitive Multi-Agent Delegation Engine | Recursive graph traversal extending `correlation/resolve.go` and `identity/repository.go` across arbitrary agent-to-agent delegation hops ($A \to B \to C \to \text{Principal}$) with cycle detection and depth clamping. | Specific: Traverses $\ge 4$ transitive delegation hops to resolve originating principal<br/>Measurable: 100% of valid delegation chains resolve; cycle detection halts in $< 5$ms<br/>Attainable: Graph traversal algorithms in Go backed by indexed Postgres edges<br/>Realistic: Reuses existing `identityStore` and `model.ProvisionalActor`<br/>Time-Bound: 2026-Q3 | Go unit and table tests asserting multi-hop traversal and circular delegation rejection |
| Live Signed Telemetry Ingestion (`agent-nono-evidenced`) | Ingest and verify detached SPIFFE-signed audit session logs emitted by the Landlock-confined demo agent deployed in `SLON`. | Specific: Verifies detached signature against workload SPIFFE SVID and ingests into FrostDB<br/>Measurable: 100% of signed session records verified; tampered signatures rejected<br/>Attainable: `go-witness` and crypto primitives already wired<br/>Realistic: Builds directly on `collectors/ebpf` and `api/audit`<br/>Time-Bound: 2026-Q3 | BATS test verifying live pod audit stream ingestion and signature validation |
| Human Claim Delegation Injection | Wire operator onboarding claims (`/api/agents/{id}/claim`) to persist authenticated human $\to$ agent `acts-on-behalf-of` edges in PostgreSQL. | Specific: Claiming an agent automatically records a temporal delegation edge<br/>Measurable: 100% of claimed demo agents reflect operator principal in graph<br/>Attainable: Postgres `delegations` table already supports time-valid edges<br/>Realistic: Minimal additive hook in `agentClaim.ts` and signal-ingest API<br/>Time-Bound: 2026-Q3 | Integration test asserting claim persistence and immediate query reflection |
| Operational Dossier Authorization Embedding | Embed `WhoAuthorizedPanel` into Tab 2 (Identity & SPIFFE) and Tab 5 (Activity Timeline) of `AgentDetailPage.tsx`. | Specific: Tab 2 renders full upstream/downstream trust tree; Tab 5 events drill down into cryptographic proof<br/>Measurable: Clicking timeline audit event opens 7-hop proof drawer in $< 100$ms<br/>Attainable: Components exist in `WeavePage.tsx`; relocate and compose into tabs<br/>Realistic: Extends existing React dashboard architecture<br/>Time-Bound: 2026-Q3 | Vitest component tests and Playwright e2e spec verifying interactive drill-downs |
| Stun Sentinel Containment Loop & Revocation | Invalidate active delegation edges (`valid_to = now()`) upon receiving `swarm.sentinel.stun_triggered`, and trigger containment on unverified chains. | Specific: Stunning an agent severs its delegation authority immediately<br/>Measurable: Subsequent authorization queries report `INCOMPLETE / REVOKED` within 50ms<br/>Attainable: Stun Sentinel events already published to bus/log<br/>Realistic: Simple SQL update on active delegation edges<br/>Time-Bound: 2026-Q3 | BATS test verifying stun command severs authorization chain in real time |

### Out of Scope

* Unsupervised ML / probabilistic entity resolution clustering without deterministic seed anchors.
* Multi-cloud cross-tenant trust federation (outside Kind cluster boundary).
* Modification of Linux kernel Landlock or cgroup subsystems beyond existing `stun-sentinel` controllers.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Multi-hop transitive delegation resolution recall | 0% (single-hop only) | $\ge 95\%$ on cascade estates | Go integration tests in `correlation/` |
| Live `agent-nono-evidenced` signed audit ingestion | 0% (fixture-only) | 100% of live session streams verified | Live cluster BATS test |
| Onboarding claim-to-delegation persistence | Manual / unlinked | 100% automated upon claim | API contract test |
| Dossier timeline action drill-down latency | N/A (unwired) | $< 100$ms to render 7-hop proof | Vitest and Playwright performance timing |
| Post-stun delegation revocation latency | Unmeasured | $< 50$ms to clamp `valid_to` in Postgres | BATS stun integration test |
| False-merge rate across multi-hop chains | 0 (V1 single-hop) | 0 (hard gate across transitive hops) | Adversarial cascade regression suite |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Transitive delegation correctness | Table-driven Go tests with deep DAG trees and cyclic graph injections | Delivery team |
| Live Landlock signature verification | Independent `witness verify` and SPIFFE X.509 SVID validation of live container streams | AI & Data Security practice |
| Dossier UI/UX and proof drill-down | Playwright browser acceptance tests across all 5 Dossier tabs | Frontend engineering lead |
| Stun containment and revocation timing | High-resolution timestamp verification of cgroup freeze and Postgres edge clamping | Cyber Resilience practice (#cap-red-team) |
| Adversarial cascade red-team | Independent injection of multi-agent impersonation and forged intermediate hops | Independent cross-vendor audit |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Go (signal-ingest) | Core resolver, transitive graph traversal, and collector pipelines | Core backend platform language |
| PostgreSQL | Temporal identity, alias, and delegation graph store | Reuses existing `DATABASE_URL` audit pool |
| FrostDB / Parquet | Append-only, tamper-evident columnar observation store | In-tree columnar storage engine |
| CEL (cel-go) | Multi-layer correlation evaluation | Standard declarative policy language |
| SPIFFE / SPIRE | Cryptographic workload identity and SVID verification | Deployed in `inf-bao` / `d2-agent-trust` |
| Linux Landlock & Nono | In-workload security sandboxing and signed session auditing | Deployed in `agent-nono-evidenced` |
| Stun Sentinel (cgroups/eBPF) | Sub-50ms execution halting and packet severance | Deployed in `d2-signalloom/infra/stun-sentinel` |
| React / Vite / TypeScript | Operational Agent Dossier and cryptographic proof drawers | Core frontend dashboard stack |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Monorepo | `osramp-demo` (github.com/controlplaneio-in-toto/osramp-demo) | Shared platform root |
| Signal Ingest Service | `d2-signalloom/apps/signal-ingest` | Backend resolver, identity graph, collectors |
| Dashboard SPA | `d2-signalloom/apps/dashboard-signalloom` | Agent Dossier, WhoAuthorizedPanel, timeline |
| Demo Agent Workloads | `d2-signalloom/agents/` | `agent-nono-evidenced`, `agent-standard-baseline` |
| Stun Sentinel | `d2-signalloom/infra/stun-sentinel` | cgroup.freeze containment controller |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Transitive False Merge — intermediate agent identity collapses distinct principals | Critical | `SP-1` and `SP-2`: Transitive delegation edges never collapse actors; merge requires deterministic same-entity proof at each hop |
| Circular Delegation Loop — malicious agent creates $A \to B \to A$ cycle to exhaust resolver | High | Traversal depth limit (max 8 hops) + cycle detection set in Go resolver |
| Forged Intermediate Delegation — agent claims on-behalf-of without cryptographic proof | Critical | Delegation edges require verified SPIFFE SVID or authenticated JWT context |
| Stun Desynchronization — stunned agent continues acting under cached delegation | High | Stun Sentinel immediately emits revocation event, clamping `valid_to = now()` in Postgres |
| Attestation Tampering — modified audit records presented as valid | Critical | Write-time `go-witness` segment signing + Merkle checkpoint verification (`audit_anchor`) |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Builds on proven, certified V1 substrate (`SFDP`) | Requires active SPIRE and PostgreSQL instances for full live mode |
| Seamlessly unites 4 previously completed platform slices | Multi-agent DAG traversal introduces minor CPU overhead (mitigated by caching) |

| Opportunities | Threats |
| :---- | :---- |
| Delivers the signature "Cascade" demo no competitor can match | Evolving agent communication standards (A2A, MCP) may require schema tuning |
| Fulfills EU AI Act Art. 26 and DORA Art. 5 requirements out-of-the-box | Rogue agent modifying local telemetry before container freeze |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Transitive Multi-Agent Delegation Graph Traversal & Engine ("The Cascade") |  |  |  |  | #cap-golang #cap-architecture |
| M2: Live Demo Agent Signed Telemetry Ingestion & Operator Claim Binding |  |  |  |  | #cap-golang #cap-kubernetes-api-programming #cap-spiffe-openbao |
| M3: Operational Dossier Authorization Embedding (Tab 2 Identity & Tab 5 Activity) |  |  |  |  | #cap-frontend #cap-architecture #cap-testing-pyramid |
| M4: Closed-Loop Containment & Temporal Revocation with Stun Sentinel |  |  |  |  | #cap-golang #cap-red-team #cap-threat-modelling |
| M5: Multi-Agent Adversarial Red-Team, Published Ceiling & Live Fleet Acceptance |  |  |  |  | #cap-red-team #cap-testing-pyramid #cap-architecture |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* Transitive delegation resolves across $\ge 4$ agent hops with zero false merges and cycle protection.
* Live `agent-nono-evidenced` pod telemetry is ingested and verified with detached SPIFFE signatures.
* Onboarding claims automatically persist human-to-agent delegation edges in PostgreSQL.
* The 7-hop cryptographic authorization proof is natively embedded in Dossier Tab 2 and drillable from Tab 5.
* Triggering Stun Sentinel immediately clamps `valid_to` on active delegation edges in $< 50$ms.
* Adversarial cascade test suite passes with `false-merge == 0` and a published $X/N$ ceiling.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | AI & Data Security practice lead ([Vicente Herrera](mailto:vicente.herrera@control-plane.io)) |
| Responsible | Signal Loom / signal-ingest delivery team |
| Consulted | Cyber Resilience & Threat Assurance practice (#cap-red-team); Frontend Engineering lead |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

Funded as core Signal Loom platform investment. Advances the "SuperCredential Multi-Agent Evolution — The Cascade" keynote demonstration and cements the defensible wedge across enterprise design partners.

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| None (utilizes existing Kind, PostgreSQL, and FrostDB infrastructure) | $0.00 | One-off | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-05 | AJM | Certify V1 baseline actor-resolution spine under SFDP (`003120a8`) | Baseline resolution, Postgres graph, and FrostDB attestor completed and verified | Establishes production substrate for V2 |
| 2026-09-10 | AJM | Deprecate V1 and launch V2 proposal to govern live platform integration | V1 lacked multi-agent cascade, live demo agent telemetry, and Dossier embedding | Unites SLON, SFAGENTS, and CRKC into one cohesive governance spine |
| 2026-09-10 | AJM | Enforce recursive multi-hop delegation with cycle detection in Go resolver | Multi-tier agent swarms require transitive delegation back to human principal | Enables complete end-to-end attribution across The Cascade |
| 2026-09-10 | AJM | Embed WhoAuthorizedPanel directly into Agent Dossier Tabs 2 and 5 | Operators live in the Dossier, not isolated experimental pages | Primary UX drill-down for cryptographic proof of authority |
| 2026-09-10 | AJM | Bind Stun Sentinel containment events directly to temporal edge invalidation | Stunned agents must not retain active borrowed authority | Sub-50ms revocation guaranteed in PostgreSQL graph |

## Appendix

### A. Useful Links

* [[Proposal — Signal Fusion Actor-Resolution Spine (2026-Q3)]] (V1 — Deprecated baseline)
* [[Proposal — Signal Fusion Delivery Plan (2026-Q3)]] (`SFDP` — Certified implementation)
* [[Proposal — SuperCredential Multi-Agent Evolution — The Cascade]]
* [[Proposal — Signal Fusion Agents Page Operational Redesign and Evidence Dossier (2026-Q3)]] (`SFAGENTS`)
* [[Proposal — Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment (2026-Q3)]] (`CRKC`)
* [[Proposal — Signal Loom First User and Agent Onboarding (2026-Q3)]] (`SLON`)

### B. Feeder & Sibling Proposals

* [[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]] — Live webhook receiver for APIServer audit events.
* [[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]] — SaaS observation adapter and OAuth join keys.
* [[Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)]] — Tool execution observation resolver.

### C. Multi-Agent Cascade Adversarial Test Scenarios

* **Cascading Impersonation**: Agent $C$ asserts borrowed identity of Agent $B$, which asserts human $A$, but $B \to C$ delegation is un-attested — resolver must sever chain at $B$ and report `INCOMPLETE CHAIN`.
* **Cyclic Delegation Attack**: Malicious agent registers circular delegation $A \to B \to C \to A$ — resolver must detect cycle, halt in $< 5$ms, and flag containment alert.
* **Stun Bypass Probe**: Stunned agent attempts privileged action using cached pre-stun delegation token — resolver checks temporal validity against `valid_to` and rejects with HTTP 403.
* **NAT Split-Human with Multi-Agent Swarm**: Two operators behind shared egress IP dispatch independent agent cascades — resolver maintains strictly isolated actor graphs.

### Spec: Shared Patterns

#### SP-1: Transitive Delegation & Strict Never-Merge Invariant
The delegation relationship (`acts-on-behalf-of`) is a distinct, directed edge connecting an executing delegatee agent to a delegating principal (human or upstream agent). A delegation edge must NEVER collapse, merge, or alias the delegator and delegatee into a single canonical actor. Across arbitrary transitive hops ($A \to B \to C$), each hop retains separate entity identity while forming a continuous, unbroken chain of authority.

#### SP-2: Deterministic-First Merge & Corroboration Cap
Merging two identity representations into a single `actor_id` strictly requires at least one deterministic identity edge (e.g. SPIFFE ID ↔ `system:serviceaccount:<ns>:<name>`). Probabilistic or heuristic signals (shared IP, temporal coincidence, user-agent) may only elevate the confidence score of an already-established deterministic edge; they must never trigger an entity merge on their own.

#### SP-3: Write-Time Parquet Segment Attestation Boundary
Every FrostDB Parquet segment must be cryptographically attested at flush boundary using the local ed25519 workload key (`make workload-key`) via `go-witness`. Persisting or querying un-attested segments in production mode is prohibited, and any byte-level divergence must trigger an immediate verifiable verification failure (`exit 2`).

#### SP-4: Zero False-Merge Release Gate & Published Falsifiable Ceiling
The system enforces a non-negotiable `false-merge == 0` release gate across all regression and adversarial test suites. Under adversarial cascade evaluation, resolution accuracy must be reported as an exact, falsifiable ratio ($X/N$ caught), never as an ungrounded percentage or heuristic claim.

#### SP-5: Closed-Loop Stun Revocation & Dossier Visibility
When an agent is stunned by `stun-sentinel`, the system must immediately clamp `valid_to = now()` on all active delegation edges originating from or terminating at that agent. All authorization chains, active delegations, and containment statuses must be visible in real time within the operational Agent Dossier (Tabs 2 and 5).

### Spec: Capability Plan

| Logical ID | Role | Skills Required | Size Band | Ceiling (Min) | Agent Model | Task Summary |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SFAS-P1-PRE` | preflight | #cap-golang · #cap-kubernetes-api-programming · #cap-architecture | S | 30 | antigravity | Preflight verification of live signal-ingest routes, Postgres graph schema, and Kind cluster demo agent pods. |
| `SFAS-P1-1` | implementation | #cap-golang · #cap-architecture · #cap-testing-pyramid | M | 60 | antigravity | Implement transitive multi-agent delegation graph traversal in Go resolver with cycle detection and depth clamping. |
| `SFAS-P1-2` | implementation | #cap-golang · #cap-build-provenance · #cap-spiffe-openbao | M | 60 | antigravity | Implement live ingestion and cryptographic verification of detached SPIFFE-signed audit session logs from agent-nono-evidenced. |
| `SFAS-P1-3` | implementation | #cap-golang · #cap-frontend · #cap-kubernetes-api-programming | M | 60 | antigravity | Auto-inject authenticated human onboarding claims into PostgreSQL delegation graph upon operator claim mutation. |
| `SFAS-P1-GOV` | governor | #cap-architecture · #cap-golang · #cap-testing-pyramid | M | 60 | antigravity | Phase 1 Governor reconciliation: merge Phase 1 deliverables, verify transitive delegation and live claim persistence. |
| `SFAS-P2-PRE` | preflight | #cap-frontend · #cap-testing-pyramid · #cap-architecture | S | 30 | antigravity | Preflight verification of AgentDetailPage component tree, Weave panel, and test fixtures. |
| `SFAS-P2-1` | implementation | #cap-frontend · #cap-architecture · #cap-testing-pyramid | M | 60 | antigravity | Embed 7-hop attested authorization chain into Agent Dossier Tab 2 (Identity & SPIFFE) with live delegator tree. |
| `SFAS-P2-2` | implementation | #cap-frontend · #cap-architecture · #cap-testing-pyramid | M | 60 | antigravity | Wire timeline audit events in Agent Dossier Tab 5 (Activity) to launch interactive cryptographic authorization proof drawer. |
| `SFAS-P2-GOV` | governor | #cap-architecture · #cap-frontend · #cap-testing-pyramid | M | 60 | antigravity | Phase 2 Governor reconciliation: merge Phase 2 deliverables, verify Dossier identity and activity proof drill-downs. |
| `SFAS-P3-PRE` | preflight | #cap-golang · #cap-red-team · #cap-kubernetes-api-programming | S | 30 | antigravity | Preflight verification of Stun Sentinel cgroup controller, eBPF classifier hooks, and event bus. |
| `SFAS-P3-1` | implementation | #cap-golang · #cap-kubernetes-api-programming · #cap-threat-modelling | M | 60 | antigravity | Invalidate active temporal delegation edges (valid_to = now()) upon receiving swarm.sentinel.stun_triggered events. |
| `SFAS-P3-2` | implementation | #cap-golang · #cap-red-team · #cap-threat-modelling | M | 60 | antigravity | Implement automated containment trigger and alert dispatch when an agent executes actions under an unverified delegation chain. |
| `SFAS-P3-GOV` | governor | #cap-architecture · #cap-golang · #cap-red-team | M | 60 | antigravity | Phase 3 Governor reconciliation: merge Phase 3 deliverables, verify real-time stun revocation and containment severing. |
| `SFAS-P4-PRE` | preflight | #cap-red-team · #cap-threat-modelling · #cap-testing-pyramid | S | 30 | antigravity | Preflight verification of adversarial cascade test runner, fixture generators, and red-team harness. |
| `SFAS-P4-1` | implementation | #cap-red-team · #cap-threat-modelling · #cap-golang | M | 60 | antigravity | Implement multi-agent cascade adversarial attack suite (cascading impersonation, circular delegation, NAT split-human). |
| `SFAS-P4-2` | implementation | #cap-testing-pyramid · #cap-golang · #cap-frontend | M | 60 | antigravity | Run full-estate live acceptance asserting 100% complete chains for claimed demo agents, Dossier drill-downs, and stun severing. |
| `SFAS-P4-GOV` | governor | #cap-architecture · #cap-project-management · #cap-testing-pyramid | M | 60 | antigravity | Final Programme Governor certification: reconcile all 4 phases, run complete multi-suite verification, and sign off mission. |

### Spec: Work Decomposition

| ID | Title | Depends on | Tests / evidence | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :--- |
| SFAS-P1-PRE | Preflight verification of live signal-ingest routes, Postgres graph schema, and Kind cluster demo agent pods | | Preflight proof recorded in `docs/signalloom/sfas-p1-preflight-proof.md`; routes and pods confirmed | S | antigravity | | | | | |
| SFAS-P1-1 | Implement transitive multi-agent delegation graph traversal in Go resolver with cycle detection and depth clamping | SFAS-P1-PRE | Go unit/table tests in `correlation/` and `identity/` pass; >=4 hop chains resolve; cycles halt in <5ms | M | antigravity | | | | | |
| SFAS-P1-2 | Implement live ingestion and cryptographic verification of detached SPIFFE-signed audit session logs from agent-nono-evidenced | SFAS-P1-PRE | BATS test verifying live audit stream ingestion and detached signature validation | M | antigravity | | | | | |
| SFAS-P1-3 | Auto-inject authenticated human onboarding claims into PostgreSQL delegation graph upon operator claim mutation | SFAS-P1-1, SFAS-P1-2 | Integration test asserting claim persistence and immediate reflection in /api/v1/authorization | M | antigravity | | | | | |
| SFAS-P1-GOV | Phase 1 Governor reconciliation: merge Phase 1 deliverables, verify transitive delegation and live claim persistence | SFAS-P1-3 | 100% Phase 1 tests pass; zero regressions; Governor certification recorded | M | antigravity | | | | | |
| SFAS-P2-PRE | Preflight verification of AgentDetailPage component tree, Weave panel, and test fixtures | SFAS-P1-GOV | Preflight proof recorded in `docs/signalloom/sfas-p2-preflight-proof.md` | S | antigravity | | | | | |
| SFAS-P2-1 | Embed 7-hop attested authorization chain into Agent Dossier Tab 2 (Identity & SPIFFE) with live delegator tree | SFAS-P2-PRE | Vitest component tests pass asserting WhoAuthorizedPanel renders inside AgentIdentityTab | M | antigravity | | | | | |
| SFAS-P2-2 | Wire timeline audit events in Agent Dossier Tab 5 (Activity) to launch interactive cryptographic authorization proof drawer | SFAS-P2-1 | Vitest and Playwright tests asserting clicking timeline event opens 7-hop proof drawer | M | antigravity | | | | | |
| SFAS-P2-GOV | Phase 2 Governor reconciliation: merge Phase 2 deliverables, verify Dossier identity and activity proof drill-downs | SFAS-P2-2 | 100% Phase 2 tests pass; Playwright acceptance green; Governor certification recorded | M | antigravity | | | | | |
| SFAS-P3-PRE | Preflight verification of Stun Sentinel cgroup controller, eBPF classifier hooks, and event bus | SFAS-P2-GOV | Preflight proof recorded in `docs/signalloom/sfas-p3-preflight-proof.md` | S | antigravity | | | | | |
| SFAS-P3-1 | Invalidate active temporal delegation edges (valid_to = now()) upon receiving swarm.sentinel.stun_triggered events | SFAS-P3-PRE | Go integration test asserting edge clamping and subsequent authorization query returns REVOKED in <50ms | M | antigravity | | | | | |
| SFAS-P3-2 | Implement automated containment trigger and alert dispatch when an agent executes actions under an unverified delegation chain | SFAS-P3-1 | Integration test asserting unverified action emits containment alert to Stun Sentinel | M | antigravity | | | | | |
| SFAS-P3-GOV | Phase 3 Governor reconciliation: merge Phase 3 deliverables, verify real-time stun revocation and containment severing | SFAS-P3-2 | 100% Phase 3 tests pass; stun revocation latency verified; Governor certification recorded | M | antigravity | | | | | |
| SFAS-P4-PRE | Preflight verification of adversarial cascade test runner, fixture generators, and red-team harness | SFAS-P3-GOV | Preflight proof recorded in `docs/signalloom/sfas-p4-preflight-proof.md` | S | antigravity | | | | | |
| SFAS-P4-1 | Implement multi-agent cascade adversarial attack suite (cascading impersonation, circular delegation, NAT split-human) | SFAS-P4-PRE | Adversarial suite passes; false-merge == 0; redteam_cascade_ceiling.json published | M | antigravity | | | | | |
| SFAS-P4-2 | Run full-estate live acceptance asserting 100% complete chains for claimed demo agents, Dossier drill-downs, and stun severing | SFAS-P4-1 | End-to-end acceptance suite passes verifying full live demo estate | M | antigravity | | | | | |
| SFAS-P4-GOV | Final Programme Governor certification: reconcile all 4 phases, run complete multi-suite verification, and sign off mission | SFAS-P4-2 | 100% test pass across all acceptance commands; final mission certification report recorded | M | antigravity | | | | | |

### Spec: Errata

*(Append-only record of completed cards, deviations, and governor certifications)*

#### Governor Dispatch — SFAS-GOV-INIT
- **Timestamp**: 2026-09-10T20:20:00Z
- **Actor**: Governor (Mission Initialization)
- **Status**: active
- **Digest**: `6a54fa37b08d259aa93c3f45b980d12a43d562eee2f01cc278e0b4b403eebc9d`
- **Lease**: ajm-auto-kanban-sfas-v2
- **Shared Governor Log**: `docs/signalloom/sfas-governor-log.md`
- **Inter-Agent Directive**: All task agents must execute under `--agent antigravity` in isolated worktrees created from `--base-ref refs/heads/integration/sfas-v0.1.0`. Strict adherence to SP-1 (transitive delegation never-merge), SP-2 (deterministic-first merge), SP-3 (write-time segment attestation), SP-4 (false-merge == 0 release gate), and SP-5 (closed-loop stun revocation) is required. All task completions, deviations, and blockers must be communicated through the shared governor log and recorded in this errata ledger.

#### Errata — SFAS-P1-PRE: Preflight Verification
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Last Updated:** 2026-09-10T19:35:00Z  
**Commit:** `6ac1c6fc`  
**Evidence:** docs/signalloom/sfas-p1-preflight-proof.md  

Preflight checks verified 100% PASS. Kind cluster connectivity, namespace pods, live signal-ingest routes on port 28082, and identity test suites are ready for Phase 1 implementation.

#### Errata — SFAS-P1-1: Transitive Multi-Agent Delegation Graph Traversal
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Last Updated:** 2026-09-10T20:05:00Z  
**Commit:** `71f6596d`  
**Evidence:** docs/signalloom/sfas-p1-1-evidence.md  

Implemented recursive transitive delegation graph traversal in PostgreSQL via bounded recursive CTE and in MemoryRepository via cycle-safe visited-set traversal. Added composite indices in migration 002. Exposing multi-hop delegation paths in /api/v1/authorization. All unit, table, benchmark (6.5µs), and SP-1 never-merge tests pass 100%.
