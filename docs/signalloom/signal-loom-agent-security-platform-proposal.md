---
created: 2026-07-28
reviewers:
  - "#vicente-herrera"
  - "#francesco-beltramini"
capabilities:
  - "#cap-security"
  - "#cap-kubernetes"
  - "#cap-threat-modelling"
  - "#cap-architecture"
  - "#cap-secure-ai-sdlc"
  - "#cap-supply-chain-security"
  - "#cap-policy-as-code"
  - "#cap-observability"
  - "#cap-gitops"
  - "#cap-red-team"
practice:
  - AI & Data Security
  - Cyber Resilience & Threat Assurance
  - Governance, Risk & Compliance Enablement
url:
obsidianProject: "1. Projects/2026-07-agent-security-platform/"
parentProposal:
enhancements:
  -
tags:
  - innovation-proposals
  - proposal-2026-q3-controlplane-agent-security-platform
aliases:
  - "#proposal-2026-q3-controlplane-agent-security-platform"
---
# Proposal — ControlPlane Agent Security Platform (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-07-28) |
| Reviewer & Date: |  |
| Approver & Date: |  |

> **Working name.** "ControlPlane Agent Security Platform" (ASP) is a placeholder. The system is the
> unification of four capabilities that already exist in the `osramp-demo` estate — **Signal Loom**
> (agent governance), **Olly/Sentinel** (agentic runtime security + identity), **Eye-in-the-Sky**
> (estate observability), and **OSRAMP** (software/model supply chain) — into a single control plane
> for the AI-agent lifecycle. Assumptions are flagged inline as **[ASSUMPTION]**.

## Press Release

**ControlPlane launches the first agent security control plane that can find, govern, prove, and
kill any AI agent running in your estate — yours or anyone else's.**

Enterprises are shipping AI agents faster than any security function can inventory them. Agents hold
non-human identities, call tools through MCP, talk to each other over A2A, read from memory stores,
and act on production systems — mostly outside CMDB, IAM, and SIEM. A single prompt-injected or
colluding agent now has the blast radius of a compromised service account with a language model
attached. Regulators (EU AI Act, DORA, NIS2) are turning "we govern our AI" from a slide into an
auditable control with fines attached.

The ControlPlane Agent Security Platform gives a CISO one pane of glass that **discovers** every
agent across Kubernetes (k8s/Flux/Argo) and the cloud agent runtimes (Azure AI Foundry, AWS Bedrock
Agents, GCP Vertex/ADK); **identifies** each one by its A2A card, non-human identity, and SPIFFE
workload identity; **governs** its lifecycle and compliance posture against EU AI Act / NIST AI RMF;
**guards** it at runtime with LLM-layer defences and least-privilege, narrow-only authorization; and,
when something goes wrong, **kills or quarantines** it in seconds — revoking its identity, cutting it
off at the service mesh, and blocking readmission at admission control — while preserving a
cryptographically-attested forensic trail of exactly who authorized what.

It is not a wrapper. It is built on the supply-chain integrity, GitOps, and signed-attestation
machinery ControlPlane already ships in OSRAMP, extended into the agent domain. This is the product
expression of ControlPlane's thesis: **Regulatory Immunity + Feature Velocity** — the security
platform that lets a bank deploy agents *faster* because governance, evidence, and the kill switch
are built in, not bolted on.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [x] product
- [ ] marketing
- [ ] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Regulated enterprises already adopting agentic AI — the ARC-class
client this estate abstracts (large financial-services GCO), JPMC/FINOS-adjacent programmes, and Tier-1
banks facing DORA/EU-AI-Act deadlines. **[ASSUMPTION]** the first paying design partner is the existing
ARC client, with the platform generalised from that engagement.

|  |  |
| :---- | :---- |
| Our *CISOs and platform-security teams at regulated enterprises* | are accountable for AI agents they cannot see, inventory, or stop. |
| Have the problem/opportunity *…* | agents run outside CMDB/IAM/SIEM with non-human identities and tool/A2A access; there is no unified way to discover them, prove governance to a regulator, or kill a misbehaving one — so security becomes the blocker to agent adoption. |
| When *…* | an agent is prompt-injected, colludes to escalate privilege, exfiltrates via a tool call, or an auditor asks "show me every agent, its risk class, and who authorized its last action" and no one can answer. |

**Urgency and subcomponents.** Q3–Q4 2026 to a demonstrable MVP that maps directly onto live
regulatory deadlines (EU AI Act GPAI obligations, DORA). Subcomponents already in flight in this repo:
the Signal Loom Cryptography (PQC/SPIFFE), Collusion & Access (KubeSec-AFM, KTP with King's College
London), and Federated Services (Cofide/SPIFFE) pages; the Olly A2A/identity-chain runtime; and the
OSRAMP supply-chain spine.

## Scope Summary

**Technology Readiness Level: 2+ (Alpha) trending to 3 (Beta) for the MVP capability slice.** Rationale:
the four pillars exist as working local demos (TRL 2 validated locally); this proposal hardens a
**minimal-but-sufficient** vertical slice — *discover → identify → govern → guard → kill, with
attested evidence* — into a Beta a design partner can run against a real estate. The 20 capability
areas below define the full product surface; the MVP proves the spine, and the rest are sequenced
as nice-to-haves and enhancement proposals.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Agent discovery + inventory (MVP spine) | Discover agents across k8s API, Flux, and Argo, plus one cloud runtime (Azure AI Foundry **[ASSUMPTION]**), and populate the Signal Loom Agent Registry with identity + A2A card. | Specific: enumerate agents from ≥3 k8s-native sources + 1 cloud API into one inventory.<br/>Measurable: ≥95% of seeded agents discovered with identity + card; false-negative list produced.<br/>Attainable: extends the existing Agent Registry + NHI discovery.<br/>Realistic: read-only APIs, no agent runtime changes.<br/>Time-Bound: MVP milestone M2. | Contract tests + a seeded-estate discovery run with a known agent set. |
| Agentic killswitch + quarantine | One action that suspends an agent's lifecycle, revokes its token/credential, isolates it at the service mesh, and blocks readmission at admission control. | Specific: kill/quarantine an agent from the UI and API.<br/>Measurable: post-action, the agent cannot make MCP/A2A/tool calls (proven denied) within a bounded SLA (**[ASSUMPTION]** ≤30 s).<br/>Attainable: composes lifecycle-suspend + SPIFFE/OpenBao revocation + mesh NetworkPolicy/AuthorizationPolicy + kyverno.<br/>Realistic: mesh + admission already in-estate.<br/>Time-Bound: MVP milestone M4. | Red-team validation: attempt agent action pre/post kill; assert denial + attested evidence. |
| Attested forensic trail | Every governance/kill/authorization event is bound to an `authz_ctx_id` and a signed attestation, answerable as a single audit query. | Specific: "who authorized this action?" returns identity + policy + evidence in one lookup.<br/>Measurable: 100% of privileged actions carry an attested, tamper-evident record.<br/>Attainable: extends Jarvis (OTel→Splunk) + Witness/Archivista.<br/>Realistic: attestation spine exists in OSRAMP.<br/>Time-Bound: MVP milestone M5. | Tamper test (mutate a record → detected) + single-query audit demo. |
| Governance + compliance mapping | Agent lifecycle + risk classification mapped to EU AI Act, NIST AI RMF, OWASP LLM Top 10, MITRE ATLAS, with exportable evidence. | Specific: each agent carries a risk class + control mapping + exportable evidence pack.<br/>Measurable: evidence export passes a mock regulator checklist.<br/>Attainable: extends Signal Loom compliance/frameworks.<br/>Realistic: frameworks modelled.<br/>Time-Bound: MVP milestone M3. | GRC review against a framework checklist; export contract test. |

### Out of Scope

* Building the agents themselves (this governs/secures agents; it is not an agent framework).
* Replacing the enterprise IdP, SIEM, or service mesh — the platform integrates with COIN/PlainID/EEMS,
  Splunk, and Istio/Linkerd/Cilium rather than reimplementing them.
* Full production PQC migration of enterprise crypto (we provide readiness/agility posture + crypto-BOM;
  the migration is a downstream programme).
* Non-agent workload security (covered by existing ControlPlane offerings).
* Model *training* security and data-pipeline security beyond model-BOM/provenance at deploy time.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Agent inventory coverage of a seeded estate | ~0 (no unified inventory) | ≥95% discovered w/ identity + card | Seeded-estate discovery run |
| Mean time to kill/quarantine a flagged agent | manual / undefined | ≤30 s to proven denial **[ASSUMPTION]** | Red-team pre/post assertion |
| Privileged actions with attested "who authorized" answer | partial (Olly authz_ctx only) | 100% across governed agents | Audit-query + tamper test |
| Regulatory evidence export accepted by mock auditor | none | pass EU AI Act + DORA checklist | GRC checklist review |
| Design-partner-blocking findings closed pre-Beta | n/a | 0 open critical | Adversarial critique appendix (this proposal) |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Threat model per capability area | STRIDE + OWASP LLM Top 10 + MITRE ATLAS mapping, reviewed | AI & Data Security practice |
| Runtime guardrail efficacy | promptfoo red-team suite + injection eval in CI (extends `security-sandbox`) | Cyber Resilience & Threat Assurance |
| Killswitch/quarantine efficacy | purple-team: prove denial of MCP/A2A/tool/mesh paths post-kill | Red-team + Platform |
| Supply-chain integrity of agent/model artifacts | SLSA provenance + cosign verify + SBOM/model-BOM gate | GitOps & Continuous Delivery |
| Authorization correctness | policy-as-code tests (Rego), narrow-only AuthZ-CTX invariants | AI & Data Security |
| Independent adversarial critique | multi-agent critique of this proposal + open-question appendices | External/AI critique panel (see Appendix) |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Kubernetes + Flux (GitOps) + kyverno | Estate substrate, signed-artifact reconciliation, admission control | Core ControlPlane / Flux sponsorship |
| Google A2A + Agent Cards | Agent identity, capability, and auth declaration; tamper detection (committed-vs-served) | Exists in Olly/Sentinel |
| MCP (Model Context Protocol) gateway | Mandatory tool intermediary; scope-checked, capped, read-only-by-default | Exists in Olly (`elk-search-mcp`) |
| COIN / PlainID (Rego PDP) / EEMS (PIP) | Identity chain: OBO tokens, policy at issuance, narrow-only AuthZ-CTX | Exists as `olly-authz` |
| SPIFFE/SPIRE + Cofide (xDS) + OpenBao | Workload identity, federated trust zones, secrets/PKI, revocation | In-flight (Cryptography/Federated pages) |
| Service mesh (Istio/Linkerd/Cilium) **[ASSUMPTION]** | Quarantine/isolation enforcement point (mTLS AuthorizationPolicy) | New integration surface |
| Witness + Archivista + cosign + SLSA | Attestation, system-of-record, signing, provenance for agent/model artifacts | Core OSRAMP |
| LLM Guard (Lakera-adjacent) | Prompt-injection/PII/jailbreak defence, data/instruction separation | Exists in Olly `llm-guard`; Checkpoint/Lakera partnership |
| OTel → Splunk (Jarvis) + Grafana | Audit, telemetry, Eye-in-the-Sky estate observability | Exists |
| React/Vite dashboard (Signal Loom) + FastAPI + Dex OIDC | Operator UI + API + auth | Exists (this repo) |
| PQC (Kyber/Dilithium-class) crypto-agility posture | Post-quantum readiness + crypto-BOM | In-flight (Cryptography page) |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Monorepo estate | `osramp-demo` (github.com/controlplaneio-in-toto/osramp-demo) | Signal Loom, Olly, OSRAMP, infra |
| Feature branch | `feat/signal-loop-and-bootstrap-refactor` | The migrated UI + Dex login + bootstrap work this builds on |
| In-cluster registry | Zot (signed OCI, SLSA/cosign) | Local trust root; CI path is keyless-OIDC |
| Agent runtime abstraction | `olly-replica` ("ARC" model) | Google ADK agents, A2A cards, identity chain |
| Design/proposal docs | `docs/signalloom/` | This proposal + `dashboard-ui-migration.md`, `dex-oidc-design.md`, threat model |

#### Security and Risk

**Threat model for this deliverable (platform-level; per-area models in the Appendix):**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Prompt injection via untrusted context (logs/tickets/tool output) steers an agent | Critical (LLM01 / ATLAS AML.T0051) | Data/instruction separation, structured extraction, injection eval suite in CI, LLM Guard |
| Colluding subjects/agents jointly escalate privilege | High | KubeSec-AFM collusion model-checking; narrow-only AuthZ-CTX; deny impersonation paths |
| Agent identity/card tampering or spoofing | High | A2A card committed-vs-served CI assertion; SPIFFE workload identity; signed cards |
| Killswitch fails or is bypassed (agent keeps acting) | Critical | Defence-in-depth kill: lifecycle + token revocation + mesh isolation + admission block, purple-team proven |
| Over-privileged MCP/tool access, credential replay | High | MCP gateway scope-check + caps; OBO tokens; least-privilege EEMS scopes; rotation |
| Forensic record tampering / "who authorized?" unanswerable | High | `authz_ctx_id` anchoring + Witness attestation + tamper-evident audit |
| Cross-tenant agent/data disclosure | Critical | Tenant binding + RLS-equivalent; default-deny; per-tenant SPIFFE trust domains |
| The platform itself becomes the highest-value target | Critical | Same supply-chain + signing + least-privilege controls applied to the platform; break-glass with dual control |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Four working pillars already in-estate; not greenfield | Breadth (20 areas) risks diluting the MVP; needs ruthless sequencing |
| Built on ControlPlane's signed-attestation + GitOps credibility | Depends on integrations (mesh, cloud agent APIs) not yet built |
| Maps directly to live regulation (EU AI Act/DORA) — a buying trigger | Standards (A2A, MCP, agent security) are young and moving |

| Opportunities | Threats |
| :---- | :---- |
| First-mover on an "agent security control plane" category | Hyperscalers/CNAPP vendors bundle agent security into existing suites |
| Land via ARC client, expand to Tier-1 banks; OSRAMP/FINOS pull-through | Standards churn (A2A/MCP) forces rework |
| Partnerships (Lakera, Google, Cofide, King's College) de-risk depth | "Killswitch that fails" is a reputational single point of failure |

## Feature Architecture — 20 Capability Areas

Each area states **what it is**, **the pillar it extends**, **key controls**, and **standards mapping**.
Areas 1–5 form the MVP spine (discover → identify → govern → guard → kill); 6–20 are the full surface.

1. **Agent Governance & Lifecycle** — *Signal Loom.* Register → issue identity credential → lifecycle
   (active/enrolled/suspended/decommissioned) → violations → posture → reassessment, with EU AI Act
   risk classification per agent. *Controls:* state-machine invariants, tenant binding, audit on every
   transition. *Standards:* EU AI Act risk tiers, NIST AI RMF Govern/Manage.

2. **Agent Discovery & Inventory** — *Signal Loom + new.* Continuously enumerate agents from k8s API,
   Flux (Kustomizations/ResourceSets), Argo, and cloud runtimes (Azure AI Foundry, AWS Bedrock Agents,
   GCP Vertex/ADK), plus A2A `/.well-known/agent-card.json` crawling and NHI scans. *Controls:*
   read-only discovery, reconciliation to a single inventory, drift/appearance alerts. *Standards:*
   CMDB/CSCC alignment, NIST AI RMF Map.

3. **Agent Identity & Card Management** — *Olly + Signal Loom.* Every agent carries a verifiable A2A
   card, a SPIFFE workload identity, and (for NHI) a governed non-human identity; committed-vs-served
   card diff detects tampering. *Controls:* signed cards, CI-asserted card parity, SPIFFE SVIDs,
   OBO-only machine identity. *Standards:* A2A spec, SPIFFE, OAuth2 OBO.

4. **Agentic Killswitch & Quarantine** — *new, composed.* One action isolates an agent: lifecycle
   suspend + credential/token revocation (OpenBao/SPIFFE) + service-mesh isolation (mTLS
   AuthorizationPolicy / NetworkPolicy) + admission block (kyverno) so it cannot be readmitted. Graded:
   *observe → quarantine (mesh-isolated, read-only) → kill (identity revoked)*. *Controls:* defence-in-
   depth, bounded-SLA proven denial, break-glass with dual control + attestation. *Standards:* MITRE
   ATLAS response, NIST IR.

5. **Runtime Guardrails / LLM Guard** — *Olly.* Prompt-injection, PII/secret redaction, jailbreak, and
   data/instruction separation at context assembly; injection eval suite runs in CI. *Controls:*
   untrusted-input treatment of all context sources, output sanitisation, guardrail-in-agent boundary.
   *Standards:* OWASP LLM Top 10 (LLM01/06), MITRE ATLAS AML.T0051.

6. **Authorization & Policy Enforcement** — *Olly.* COIN→PlainID(Rego PDP)→EEMS(PIP) issues OBO tokens
   with `permitted_actions`; the MCP gateway scope-checks every tool call; the `X-AuthZ-CTX` header
   narrows-only (never widens) across A2A hops; one `authz_ctx_id` anchors the chain. *Controls:*
   policy-as-code, least privilege, narrow-only invariant, single-query audit. *Standards:* XACML/ABAC,
   OAuth2, zero-trust.

7. **Collusion Detection & Access Analytics** — *Signal Loom (KubeSec-AFM, KTP w/ King's College).*
   Model-check whether pairs/groups of subjects (users + service accounts + agents) can *exchange*
   permissions to jointly reach a higher-privileged role; impersonation and cross-namespace escalation
   paths. *Controls:* RBAC graph analysis, self-escalation pruning, collusion-pair reporting.
   *Standards:* NIST RBAC, k8s RBAC hardening.

8. **Post-Quantum Cryptography & Crypto Agility** — *Signal Loom (Cryptography page).* Inventory the
   estate's cryptographic trust foundation (SPIFFE/SPIRE, OpenBao) and report PQC cipher readiness +
   migration posture; emit a **crypto-BOM**. *Controls:* algorithm inventory, agility scoring,
   deprecation flags. *Standards:* NIST PQC (Kyber/Dilithium), CNSA 2.0, crypto-BOM (CycloneDX).

9. **Agent Forensics & Incident Response** — *Olly + OSRAMP.* Reconstruct an agent incident from the
   `authz_ctx_id`-anchored trail, RCA enrichment, and Witness/Archivista attestations; replay the event
   sequence. *Controls:* tamper-evident evidence, chain-of-custody, single-query "who authorized",
   attested exports. *Standards:* NIST SP 800-86, MITRE ATLAS.

10. **Memory & Context Management** — *Olly + new.* Govern agent memory/context: retention limits,
    context-poisoning defence at assembly, provenance of retrieved context, and a **context-BOM** of
    what entered the window. *Controls:* source provenance, poisoning eval, retention/erasure policy,
    PII minimisation. *Standards:* OWASP LLM04/LLM08, GDPR minimisation.

11. **Supply Chain Security for Agents & Models** — *OSRAMP.* SBOM + **model-BOM** for every agent
    image, model, prompt-pack, and MCP server; SLSA L3 provenance; cosign signatures; VEX triage;
    policy-gated promotion. *Controls:* signed artifacts, admission verify, provenance gates.
    *Standards:* SLSA, in-toto/Witness, CycloneDX ML-BOM, SSDF.

12. **Observability & Estate Pane-of-Glass** — *Eye-in-the-Sky.* Live estate view of agents, A2A flows,
    MCP calls, incidents, and RCA; per-agent telemetry, vulnerability posture, and identity hand-offs.
    *Controls:* read-only MCP telemetry, output-encoded panels, injection-safe assembly separation.
    *Standards:* OpenTelemetry, NIST AI RMF Measure.

13. **Human-in-the-Loop Approvals & Action Gating** — *Olly (Orbit).* Any write/remediation is proposed
    (one action), paused as an A2A `input-required` task, and executed only on a signed `approval_jwt`;
    permission narrows on delegation. *Controls:* dual control, signed approval, no-write-by-default
    for reasoning agents. *Standards:* SoD, zero-trust action gating.

14. **Compliance & Regulatory Mapping** — *Signal Loom.* Map agent controls to EU AI Act, NIST AI RMF,
    DORA, NIS2, OWASP LLM Top 10, MITRE ATLAS; generate auditor-ready evidence packs. *Controls:*
    control-to-evidence binding, exportable packs, framework selection per tenant. *Standards:* the
    above frameworks; this is the "Regulatory Immunity" surface.

15. **Adversarial Testing & Continuous Evaluation** — *Olly (security-sandbox).* Continuous red-team of
    agents (promptfoo baselines), eval-harness with `eval-record` contracts, injection eval gating in
    CI; human-vs-agent efficacy claims are evidence-backed. *Controls:* CI-gated evals, red-team
    regression, baseline drift alerts. *Standards:* OWASP LLM testing, MITRE ATLAS test cases.

16. **Multi-Cloud / Multi-Orchestrator Coverage** — *new.* Adapters for k8s/Flux/Argo and the cloud
    agent runtimes (Azure AI Foundry, AWS Bedrock Agents, GCP Vertex/ADK); normalise their agents into
    the common identity + card + policy model. *Controls:* least-privilege read roles per cloud, adapter
    conformance tests. *Standards:* CSA, provider agent APIs.

17. **Tenant Isolation & Multi-Tenancy** — *Signal Loom (threat model).* Per-tenant binding on every
    record, RLS-equivalent DB isolation, per-tenant SPIFFE trust domains, default-deny networking.
    *Controls:* authenticated tenant on create/read, isolation tests, cross-tenant denial proofs.
    *Standards:* NIST SP 800-53 AC, multi-tenancy hardening.

18. **Behavioral Analytics & Anomaly Detection** — *new (extends Eye-in-the-Sky).* Baseline each agent's
    normal tool/A2A/memory behaviour; flag drift, payload/card change, off-baseline tool use, and
    exfil-shaped patterns; feed the killswitch. *Controls:* per-agent baselines, anomaly scoring,
    auto-quarantine thresholds (human-confirmed). *Standards:* UEBA, MITRE ATLAS TTP detection.

19. **Federated Trust & Cross-Zone Identity** — *Signal Loom (Federated Services).* SPIFFE federation
    across trust zones/clusters/clouds via Cofide (xDS/Go SDK); agents in different trust domains
    discover and reach each other under governed, revocable trust. *Controls:* trust-domain bundles,
    federation policy, revocation propagation. *Standards:* SPIFFE Federation, SPIRE.

20. **Reporting, Alerting & SOC/SIEM Integration** — *Olly + Eye-in-the-Sky.* Feed governance, kill,
    anomaly, and attestation events to SOC/IEM/ServiceNow/Splunk; executive + regulator reporting; VEX
    and attestation feeds outward. *Controls:* signed event feeds, dedup/loop-guard, ticket-write only
    via the gated path. *Standards:* OCSF/CEF, SOAR integration.

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Platform architecture + per-area threat models + MVP-spine scoping (areas 1–5) |  |  |  |  | #cap-architecture #cap-threat-modelling #cap-secure-ai-sdlc |
| M2: Agent discovery + inventory across k8s/Flux/Argo + 1 cloud runtime (area 2) |  |  |  |  | #cap-kubernetes #cap-kubernetes-api-programming #cap-golang #cap-azure |
| M3: Governance + identity + compliance mapping hardening (areas 1,3,14) |  |  |  |  | #cap-security #cap-grc #cap-policy-as-code #cap-python |
| M4: Agentic killswitch + quarantine, purple-team proven (area 4) |  |  |  |  | #cap-security #cap-red-team #cap-networking #cap-secrets |
| M5: Attested forensic trail + supply-chain evidence for agents (areas 9,11) |  |  |  |  | #cap-supply-chain-security #cap-build-provenance #cap-observability |
| M6: Runtime guardrails + continuous eval integration (areas 5,15) |  |  |  |  | #cap-red-team #cap-secure-ai-sdlc #cap-python |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| M7: Beta hardening + design-partner runbook + adversarial-critique closure |  |  |  |  | #cap-architecture #cap-engagement-management #cap-documentation |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* The MVP spine (areas 1–5) runs against a seeded estate with the KPIs met and zero open critical
  findings from the adversarial critique.
* Every privileged action is attested and answerable as a single "who authorized this?" query.
* A kill/quarantine is purple-team-proven to deny all agent action paths within the SLA.
* Each of the 20 areas has a threat model and a stated MVP-vs-enhancement disposition.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Head of Technical Solutions (Francesco Beltramini) / AI & Data Security practice lead |
| Responsible | AI & Data Security + Cyber Resilience & Threat Assurance + GitOps practice teams |
| Consulted | King's College London (KubeSec-AFM/collusion), Lakera (LLM Guard), Cofide (SPIFFE federation), Google (A2A/ADK) |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| Cloud agent-runtime test accounts (Azure/AWS/GCP) | TBD | Recurring | Must-Have (area 16) |
| Partner engagement (Lakera/Cofide/KCL) | TBD | Recurring | Nice-to-Have (depth) |
| Design-partner environment / pilot infra | TBD | One Off | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason  | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-07-28 | AJM | MVP spine = discover→identify→govern→guard→kill (areas 1–5) rather than breadth-first across 20 | Prove the killswitch + attestation value before widening | Focuses M1–M6; areas 6–20 sequenced as enhancements |
| 2026-07-28 | AJM | Build on existing four pillars; do not greenfield | Speed + credibility + reuse of signed-attestation spine | Lower risk, faster Beta |

## Appendix

### A. Useful Links

* `docs/signalloom/dashboard-ui-migration.md` — Signal Loom UI + Dex login architecture and bootstrap/test.
* `docs/signalloom/dex-oidc-design.md` — local identity/OIDC contract.
* `docs/signalloom/demo-to-hosted-threat-model.md` — Signal Loom threat model + promotion gates.
* `olly-replica/agentic-sre-design-doc.md` — Olly/ARC model, A2A, MCP, identity chain, Eye-in-the-Sky.
* `olly-replica/contracts/agent-card.*.v1.json` — A2A agent card contracts.
* `README.md` — OSRAMP supply-chain spine (SBOM/VEX/Witness/Archivista/SLSA).

### B. Adversarial Critique & Open-Question Appendices (to be populated)

*This section is filled by the adversarial-agent critique pass: per-capability-area open questions,
challenges to assumptions, competitive threats, and de-risking actions. See appended B.1–B.20.*
