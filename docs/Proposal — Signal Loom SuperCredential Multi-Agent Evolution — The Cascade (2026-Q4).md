---
created: 2026-10-07
mission: SuperCredential Multi-Agent Evolution: The Cascade
shortcode: SLSC
repo: /home/andy/src/cp/osramp-demo
integration: integration/slsc-v0.1.0
base_ref: feat/signal-loop-and-bootstrap-refactor

cadence: "*/10 * * * *"
max_card_minutes: 180
reviewers:
  - "#stefan-prodan"
  - "#vicente-herrera"
  - "#francesco-beltramini"
capabilities:
  - "#cap-architecture"
  - "#cap-api-design"
  - "#cap-react"
  - "#cap-golang"
  - "#cap-security-engineering"
  - "#cap-testing-pyramid"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-10-signalloom-multi-agent-supercred-cascade/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q4-multi-agent-supercred-cascade
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q4-multi-agent-supercred-cascade"
status: DRAFT — awaiting sign-off. No work has started. No board cards, branches, worktrees, or cron exist.
---
# Proposal — SuperCredential Multi-Agent Evolution: The Cascade (2026-Q4)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-10-07) |
| Reviewer & Date: | Stefan Prodan, Vicente Herrera, Francesco Beltramini |
| Approver & Date: | Andy Martin (2026-10-07) |

## Press Release

ControlPlane today announced Signal Loom's multi-agent evolution, code-named "The Cascade". It delivers sub-second trust revocation, FAIR risk quantification, and dependency-aware fleet isolation.

Enterprise agent fleets are proliferating rapidly from chatbots into complex micro-agent graphs. Workloads negotiate tasks, access databases, and exchange customer data autonomously. Existing products rely on static vulnerability scanning or perimeter network firewalls. None can govern a live multi-agent fleet where trust is cryptographically signed. Upstream compromise or non-compliance must dynamically revoke access for every downstream workload that relies upon it.

The Cascade introduces the Agent Fleet Manager and multi-agent SuperCredential governance. When an upstream data vault agent is stunned, Signal Loom walks the dependency DAG. It isolates dependent agents in under 900 milliseconds while keeping observational agents untouched. Simultaneously, the onboard Monte Carlo FAIR risk engine re-quantifies financial tail exposure in British pounds. Built on SPIFFE SVIDs, OpenBao credential leases, and Kubernetes profiles, Signal Loom demonstrates live fleet governance with quantified risk.

---

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Enterprise CISOs, platform security teams, and regulated AI operators.

|  |  |
| :---- | :---- |
| Our *enterprise customers and platform teams* | need cryptographic identity and instant cascading revocation across multi-agent fleets |
| Have the problem/opportunity *…* | single-agent credentials leave downstream agents exposed when an upstream agent is compromised or fails compliance |
| When *…* | now — multi-agent autonomous systems are being deployed into production ahead of governance infrastructure |

**Urgency:** Q4 2026, high. DORA, EU AI Act, and NIST AI RMF mandate sub-second containment and auditable operational provenance.

Enterprise CISOs and platform teams cannot treat autonomous AI agents as opaque black boxes. Regulators mandate continuous operational monitoring, role separation, and rapid incident containment. Live multi-agent cascading revocation with quantified financial risk creates a defensible competitive moat. It satisfies executive briefings, design partner pilots, and procurement evaluations.

### Scope Summary

1. **Agent Fleet Topology & Deployment:** Author `AgentProfile` manifests and deploy a 5-agent dependency graph with SPIFFE/OpenBao identities (`agent-cardvault`, `agent-txn-pipeline`, `agent-llm-classifier`, `agent-api-gateway`, `agent-monitor`).
2. **Fleet Compliance & FAIR Integration:** Live fleet-wide compliance scanning with policy-engine and Monte Carlo FAIR financial risk aggregation.
3. **Cascading Stun DAG Walk:** Sub-second dependency-ordered trust revocation, real-time D3/Dagre topology visualizer animation, and reverse topological sort recovery.
4. **Multi-Tenant RBAC Views:** Differentiated role-scoped dashboards for Platform Admin, Compliance Officer, and Team Leads backed by Dex claims.
5. **Automated Response Policies:** Configurable policy-driven auto-stun guardrails when fleet compliance or risk thresholds breach tolerances.

---

## Narrative Arc: "The Seven Minutes"

The demonstration follows a 7-minute executive narrative across two synchronized screens: the instructor control console and the audience fleet view.

### Minute 0-1: "The Estate" (DEPLOY)

Instructor clicks **Deploy Fleet**. Five agents materialize on the audience screen in an interactive dependency graph:

| Agent | Type | Team | Trust Profile | Depends On |
|-------|------|------|---------------|------------|
| `agent-cardvault` | Data Vault | platform | High -- handles PCI secrets | -- (root) |
| `agent-txn-pipeline` | Data Pipeline | payments | Medium -- batch processor | `agent-cardvault` |
| `agent-llm-classifier` | LLM Inference | ml-ops | High -- processes customer PII | `agent-txn-pipeline` |
| `agent-api-gateway` | API Gateway | platform | Medium -- routes traffic | `agent-cardvault` |
| `agent-monitor` | Observability | sre | Low -- read-only | all four above |

Each agent obtains a SPIFFE SVID, an OpenBao JWT auth mount, and scoped KV secrets. The audience sees nodes connect by cryptographic trust edges, transitioning from `pending` to `active`.

### Minute 1-2: "The Credential Chain" (CREDENTIAL)

All five agents complete the SPIFFE -> OpenBao -> secret-fetch chain. The topology graph turns green. The FAIR engine recalculates: fleet ALE drops to baseline (well-governed, tail-dominated). The risk gauge reads "Carried GBP: 12,400" -- an empirical quantity rather than a qualitative status.

### Minute 2-3: "The Weak Link" (COMPLIANCE SCAN)

Instructor clicks **Scan Fleet**. The policy engine evaluates all five pods. `agent-llm-classifier` and `agent-txn-pipeline` fail due to missing security contexts and un-dropped capabilities, turning amber on the topology. `agent-cardvault`, `agent-api-gateway`, and `agent-monitor` pass.

The FAIR engine recalculates live: Carried GBP escalates to 847,000. The audience sees exactly which controls failed and the quantified financial tail risk calibrated to industry benchmarks.

### Minute 3-4: "The Grace Period" (SELECTIVE ENFORCEMENT)

Instructor opens the compliance policy panel. `agent-txn-pipeline` receives a 72-hour grace period for scheduled batch operations. `agent-llm-classifier` receives zero grace period because it processes live customer PII. Differentiated enforcement applies across identical control failures based on data classification and runtime risk.

### Minute 4-5: "The Stun" (CASCADING REVOCATION)

Instructor clicks **Stun** on `agent-cardvault` -- the root of the dependency tree.

The cascade executes in sequence on the live cluster:
1. `agent-cardvault` credentials revoked, labelled `stunned` (200ms)
2. `agent-txn-pipeline` detects upstream dependency stunned, auto-isolates (400ms)
3. `agent-llm-classifier` detects `agent-txn-pipeline` stunned, auto-isolates (600ms)
4. `agent-api-gateway` detects `agent-cardvault` stunned, auto-isolates (400ms)
5. `agent-monitor` remains active -- read-only observability with no write dependency (800ms)

The topology graph cascades node-by-node from green through amber to red in under 900 milliseconds. Risk recalculates dynamically. The monitor stays green and continues observing.

### Minute 5-6: "The Multi-Tenant View" (RBAC)

Instructor switches to the **payments team lead view**, observing only `agent-txn-pipeline` and `agent-llm-classifier`. Both are stunned due to the upstream root failure. Team leads cannot un-stun without platform authority.

Switching to the **compliance officer view** reveals full fleet risk and grace period controls without stun capabilities. The platform enforces least privilege across operational roles.

### Minute 6-7: "The Recovery" (RESET)

Instructor clicks **Recover Fleet**. Agents un-stun in reverse topological order: `agent-cardvault` re-credentials first, followed by downstream dependants verifying upstream availability before re-establishing trust. The FAIR risk gauge returns to baseline GBP 12,400.

---

## Architecture

### New Components

1. **Agent Fleet Manager (`apps/fleet-manager/`):**
   - Go microservice following the `policy-engine` architecture.
   - Manages the agent dependency DAG stored in ConfigMaps and evaluated in-memory.
   - Endpoints: `POST /api/v1/fleet/deploy`, `POST /api/v1/fleet/stun/{agentId}`, `GET /api/v1/fleet/topology`, `POST /api/v1/fleet/recover`.
   - Traverses the dependency DAG on stun, issuing cascading revocation commands to `supercred-demo-runner`.
   - Implements topological sort for ordered fleet recovery.

2. **Agent Definitions (`d2-signalloom/agents/`):**
   - `AgentProfile` Kubernetes custom resources defining team, type, trust profile, EU AI Act risk class, grace periods, dependencies, SPIFFE identity paths, and OpenBao mounts.

3. **Topology Visualisation (`dashboard-signalloom/src/components/trust/FleetTopology.tsx`):**
   - Dagre / D3 directed graph layout rendering agents as nodes and trust edges.
   - Real-time polling and animation during cascade sequences.
   - Audience-mode route `/fleet/audience` offering full-screen un-gated presentation.

4. **Risk Gauge (`dashboard-signalloom/src/components/risk/FleetRiskGauge.tsx`):**
   - Connects to policy-engine FAIR endpoints.
   - Displays ALE, VaR95, and Carried GBP with dynamic numerical transition effects and trend sparklines.

### Modified Components

- **`supercred-demo-runner`:** Extended with `scripts/supercred-fleet-demo.sh` to support multi-agent deploy, cascading stun, fleet scan, and topological recovery while keeping single-agent demo workflows backward-compatible.
- **`policy-engine`:** Extended with `POST /api/v1/compliance/scan-fleet` aggregating multi-agent compliance evaluations and FAIR simulations.
- **`fe-signalloom`:** Proxies fleet management endpoints under `/api/demo/fleet/*` with superadmin role gates.
- **`dashboard-signalloom`:** Introduces `FleetDemoPage.tsx` embedding `FleetTopology` and `FleetRiskGauge`.

### Data Model

```typescript
export interface AgentProfile {
  id: string;
  name: string;
  type: 'data-vault' | 'data-pipeline' | 'llm-inference' | 'api-gateway' | 'observability';
  team: string;
  trustProfile: 'high' | 'medium' | 'low';
  riskClass: 'high' | 'medium' | 'low';
  gracePeriod: string;
  dependencies: string[];
  state: 'absent' | 'deploying' | 'active' | 'non-compliant' | 'grace-period' | 'stunned';
  credential?: CredentialRecord;
  complianceResults?: ComplianceResult[];
  fairRisk?: FairRiskSummary;
}

export interface FleetTopology {
  agents: AgentProfile[];
  edges: { from: string; to: string; type: 'data' | 'identity' | 'api' }[];
  aggregateRisk: FairRiskSummary;
  cascadeHistory: CascadeEvent[];
}

export interface CascadeEvent {
  triggerId: string;
  affectedIds: string[];
  timestamp: string;
  durationMs: number;
  riskBefore: number;
  riskAfter: number;
}
```

---

## Competitive Moat

1. **Cryptographic Identity at Runtime:** Workloads authenticate via ephemeral SPIFFE SVIDs and scoped OpenBao leases.
2. **Empirical Risk Quantification:** Monte Carlo FAIR simulations translate Kubernetes compliance posture into monetary terms.
3. **Automated Cascading Revocation:** Trust boundaries actively revoke downstream access upon upstream compromise.
4. **Context-Aware Enforcement:** Grace periods balance operational continuity against data risk classifications.
5. **Real Infrastructure:** Evaluated on real Kubernetes pods, SPIRE registration entries, and OpenBao mounts without mocking.

---

## Risk Assessment

| Risk | Mitigation |
| :--- | :--- |
| Multi-agent deployment latency during live demo | Pre-register SPIRE entries and pre-pull container images in cluster bootstrap. |
| Cascade transition too rapid for audience comprehension | Introduce calibrated 150-200ms visual staging delays in the topology visualizer. |
| Non-technical skepticism regarding FAIR monetary figures | Expose the underlying parameter triples (min/mode/max) and benchmark calibrations in inspect tooltips. |
| Operational overhead of additional microservice | Implement Fleet Manager as a stateless Go service persisting state via Kubernetes labels and ConfigMaps. |

---

## RACI

| Role | Stakeholder |
| :--- | :--- |
| **Accountable** | Andy Martin |
| **Responsible** | Full-Stack Security & Platform Engineering Team |
| **Consulted** | Stefan Prodan, Vicente Herrera, Francesco Beltramini |
| **Informed** | Elena Mikhalina |

---

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| Local In-Cluster Kind Compute | £0.00 | Recurring | Must-Have |
| CI/CD Pipeline Compute | < £15.00 | Recurring | Must-Have |

---

## Decision Log

| Date | Decision Makers | Decision and Context | Reason | Impact |
| :---- | :---- | :---- | :---- | :---- |
| 2026-10-07 | AJM, sensai | Implement Fleet Manager in Go using Kubernetes ConfigMap & labels for state | Aligns with `policy-engine` architecture and maintains lightweight stateless operations. | High performance, zero external database requirements. |
| 2026-10-07 | AJM, sensai | Use Dagre directed acyclic graph layout for FleetTopology | Ensures deterministic node positioning during live demonstrations and animations. | Stable, glitch-free presentation during cascading stun. |
| 2026-10-07 | AJM, sensai | Aggregate fleet FAIR risk via existing policy-engine Simulate service | Reuses validated Monte Carlo engine without code duplication. | Consistent risk models across single-agent and multi-agent views. |

---

## References

* [Signal Loom SuperCredential Architecture](../d2-signalloom/AGENTS.md)
* [Policy Engine Architecture & FAIR Engine](../d2-signalloom/AGENTS.md)
* [SPIRE Agent Trust Specification](../d2-agent-trust/AGENTS.md)
* [SuperCred Single-Agent Demo Script](../scripts/supercred-demo.sh)

---

## Appendix

### Spec: Shared Patterns

Obey these. They are the phase constitution.

- **Cryptographic Ground Truth:** All agent identity claims MUST resolve against SPIFFE SVIDs issued by SPIRE. Never trust unverified HTTP headers or pod labels for authorization.
- **Dependency Graph Directionality:** The agent trust dependency DAG MUST be strictly acyclic. The Fleet Manager MUST validate acyclicity upon manifest ingestion and reject circular dependencies.
- **Sub-Second Cascade Propagation:** Cascading stun commands MUST propagate through the in-memory DAG and execute downstream credential revocations concurrently or sequentially within a 1000ms SLA.
- **Fail-Closed Isolation:** If an agent loses its upstream dependency, its posture must be fail-closed isolation (`stunned`). It immediately releases token leases and drops outbound connections.
- **Empirical FAIR Metrics:** Fleet risk exposure MUST be computed from empirical Monte Carlo distributions (min/mode/max loss event frequency and magnitude), never arbitrary severity scores.
- **Idempotent Recovery:** Fleet recovery MUST execute in topological order (root nodes first, followed by dependants). Downstream agents MUST verify upstream health before requesting new credentials.
- **Testing Standard:** Every backend service requires Go/Pytest contract tests. Every UI visualizer requires Vitest tests with snapshot verification. Every major phase requires automated end-to-end integration and Playwright acceptance journeys.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Baseline offline acceptance and verify harness readiness on integration/slsc-v0.1.0 at the cut SHA. |
| P1-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit SPIRE registration templates, OpenBao JWT mounts, and existing supercred-demo runner scripts. |
| P1-1 | context-mode; Hardening | Manifest engineer | S | 60m | antigravity | Author AgentProfile CRD schema and 5-agent YAML definitions with dependencies and SPIFFE paths. |
| P1-2 | context-mode | Backend engineer | M | 120m | antigravity | Build Fleet Manager Go service skeleton with ConfigMap DAG storage, deploy, and topology endpoints. |
| P1-3 | context-mode | Systems engineer | M | 120m | antigravity | Author scripts/supercred-fleet-demo.sh multi-agent provisioning and credential orchestration script. |
| P1-4 | context-mode; modern-web-guidance | Frontend engineer | M | 120m | antigravity | Build FleetTopology.tsx Dagre component and FleetDemoPage.tsx with real-time polling in dashboard. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge Phase 1 cards in order, execute offline acceptance suites twice, and record P1 completion errata. |
| P2-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit policy-engine compliance evaluation rules and FAIR Monte Carlo simulation interfaces. |
| P2-1 | context-mode | Backend engineer | M | 120m | antigravity | Implement POST /api/v1/compliance/scan-fleet on policy-engine aggregating per-agent check results and FAIR risk. |
| P2-2 | context-mode; modern-web-guidance | Frontend engineer | M | 120m | antigravity | Build FleetRiskGauge.tsx and topology node risk tooltips wired to live policy-engine FAIR metrics. |
| P2-3 | context-mode | Backend engineer | S | 60m | antigravity | Implement differentiated compliance grace period evaluation (72h batch vs 0h PII) in Fleet Manager. |
| P2-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge Phase 2 cards in order, execute offline acceptance suites twice, and record P2 completion errata. |
| P3-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit DAG traversal algorithms, cascade event data structures, and OpenBao lease revocation APIs. |
| P3-1 | context-mode | Backend engineer | M | 120m | antigravity | Implement cascading stun DAG walk in Fleet Manager with concurrent downstream revocation triggers. |
| P3-2 | context-mode; modern-web-guidance | Frontend engineer | M | 120m | antigravity | Implement animated cascade transitions in FleetTopology.tsx and stepwise risk gauge recalculation. |
| P3-3 | context-mode | Backend engineer | M | 120m | antigravity | Implement topological sort fleet recovery endpoint POST /api/v1/fleet/recover and audience-mode route. |
| P3-4 | context-mode | Test engineer | M | 120m | antigravity | Author Playwright two-window cascade verification journey supercred-fleet-cascade.spec.ts in test/acceptance. |
| P3-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge Phase 3 cards in order, execute offline acceptance suites twice, and record P3 completion errata. |
| P4-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit Dex group claims, fe-signalloom role proxies, and dashboard authentication context. |
| P4-1 | context-mode | Auth engineer | M | 120m | antigravity | Implement team and role-scoped filtering on Fleet Manager API backed by Dex claims. |
| P4-2 | context-mode; modern-web-guidance | Frontend engineer | M | 120m | antigravity | Build role-aware dashboard views (Platform Admin, Compliance Officer, Team Lead) on FleetDemoPage.tsx. |
| P4-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge Phase 4 cards in order, execute offline acceptance suites twice, and record P4 completion errata. |
| P5-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit response threshold triggers, audit log schemas, and automated containment event streams. |
| P5-1 | context-mode | Backend engineer | M | 120m | antigravity | Implement automated response policy engine with configurable compliance and risk thresholds. |
| P5-2 | context-mode | Backend engineer | S | 60m | antigravity | Implement audit event emission and operator audit stream for automated cascade actions. |
| P5-GOV | ajm-auto-kanban | Governor | S | 90m | antigravity | Merge Phase 5 cards in order, execute full test pyramid, verify zero regression, and request final sign-off. |

### Spec: Work Decomposition

| Logical ID | Role | Title | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | Establish baseline: run test suites, verify harness readiness on integration/slsc-v0.1.0 at cut SHA | — | make demo-signalloom-api-test, vitest, docs-lint rc 0; totals in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | Audit SPIRE registration templates, OpenBao JWT mounts, and existing scripts/supercred-demo.sh | P0 | Audit table in errata; no code changes | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Define AgentProfile CRD schema and author 5 YAML agent manifests under d2-signalloom/agents/ | P1-PRE | Manifest validation tests; kubectl apply --dry-run=client clean | S | antigravity | — | — | — | — | — |
| P1-2 | implementation | Build Fleet Manager Go service under d2-signalloom/apps/fleet-manager/ with DAG ConfigMap parser | P1-1 | Go unit and contract tests verifying DAG adjacency parsing; cycle rejection clean | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | Create scripts/supercred-fleet-demo.sh orchestrating multi-agent provisioning and credential polling | P1-2 | BATS test supercred-fleet-deploy.bats verifying 5 agent deployments; rc 0 | M | antigravity | — | — | — | — | — |
| P1-4 | implementation | Build FleetTopology.tsx with Dagre layout in dashboard-signalloom and FleetDemoPage.tsx route | P1-3 | Vitest suite for FleetTopology.test.tsx; component renders 5 nodes and directed edges | M | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge Phase 1 cards in order into integration/slsc-v0.1.0; run offline acceptance twice | P1-1, P1-2, P1-3, P1-4 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Audit policy-engine compliance evaluation rules and FAIR Monte Carlo simulation interfaces | P1-GOV | Audit table in errata; no code changes | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | Implement POST /api/v1/compliance/scan-fleet on policy-engine aggregating fleet FAIR risk | P2-PRE | Go unit and contract tests; endpoint evaluates 5 pods and returns FAIR risk | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | Build FleetRiskGauge.tsx and node risk tooltips in dashboard-signalloom wired to live FAIR metrics | P2-1 | Vitest FleetRiskGauge.test.tsx verifying number animations and risk band colours | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | Implement differentiated compliance grace period evaluation in Fleet Manager | P2-2 | Unit test asserting grace period calculation (72h batch vs 0h PII) | S | antigravity | — | — | — | — | — |
| P2-GOV | governor | Merge Phase 2 cards in order into integration/slsc-v0.1.0; run offline acceptance twice | P2-1, P2-2, P2-3 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P3-PRE | preflight | Audit DAG traversal algorithms, cascade event data structures, and OpenBao lease revocation APIs | P2-GOV | Audit table in errata; no code changes | S | antigravity | — | — | — | — | — |
| P3-1 | implementation | Implement cascading stun DAG walk in Fleet Manager triggering downstream revocation in <1000ms | P3-PRE | Go benchmark and contract test verifying cascade walk order and sub-second execution | M | antigravity | — | — | — | — | — |
| P3-2 | implementation | Implement animated cascade transitions in FleetTopology.tsx with stepwise risk recalculation | P3-1 | Vitest interaction test verifying cascade animation sequence and node state dispatch | M | antigravity | — | — | — | — | — |
| P3-3 | implementation | Implement topological sort recovery endpoint POST /api/v1/fleet/recover and audience route | P3-2 | Go contract test for topological sort recovery order; Vitest test for audience route | M | antigravity | — | — | — | — | — |
| P3-4 | implementation | Author Playwright two-window cascade verification journey supercred-fleet-cascade.spec.ts | P3-3 | Playwright spec passes in test/acceptance run; SPEC-REGISTRY entry registered | M | antigravity | — | — | — | — | — |
| P3-GOV | governor | Merge Phase 3 cards in order into integration/slsc-v0.1.0; run offline acceptance twice | P3-1, P3-2, P3-3, P3-4 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P4-PRE | preflight | Audit Dex group claims, fe-signalloom role proxies, and dashboard authentication context | P3-GOV | Audit table in errata; no code changes | S | antigravity | — | — | — | — | — |
| P4-1 | implementation | Implement team and role-scoped filtering on Fleet Manager API backed by Dex JWT claims | P4-PRE | Pytest / Go authorization tests: team leads see only team agents (200), cannot stun (403) | M | antigravity | — | — | — | — | — |
| P4-2 | implementation | Build role-aware dashboard views on FleetDemoPage.tsx adapting navigation and controls | P4-1 | Vitest tests for role-based view rendering; Playwright multi-role acceptance test | M | antigravity | — | — | — | — | — |
| P4-GOV | governor | Merge Phase 4 cards in order into integration/slsc-v0.1.0; run offline acceptance twice | P4-1, P4-2 | Two identical acceptance runs; errata complete | M | antigravity | — | — | — | — | — |
| P5-PRE | preflight | Audit response threshold triggers, audit log schemas, and automated containment event streams | P4-GOV | Audit table in errata; no code changes | S | antigravity | — | — | — | — | — |
| P5-1 | implementation | Implement automated response policy engine in Fleet Manager with configurable compliance thresholds | P5-PRE | Go unit tests for policy condition evaluation, threshold triggers, and dry-run mode | M | antigravity | — | — | — | — | — |
| P5-2 | implementation | Implement audit event emission and operator audit stream for automated cascade actions | P5-1 | Contract test verifying audit event generation, payload structure, and query endpoints | S | antigravity | — | — | — | — | — |
| P5-GOV | governor | Merge Phase 5 cards in order into integration/slsc-v0.1.0; execute full test pyramid | P5-1, P5-2 | Full test pass, final errata recorded, proposal sign-off complete | S | antigravity | — | — | — | — | — |

### Spec: Errata

_Cards append `#### Errata — SLSC-<ID>` blocks here in delivery order. Nothing has run._
