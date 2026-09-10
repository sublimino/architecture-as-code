---
created: 2026-09-05
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
practice:
  - AI & Data Security
  - Cyber Resilience & Threat Assurance
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: 1. Projects/2026-07-signalloom-d2-platform-baseline/
parentProposal:
enhancements:
  - "[[Proposal — Signal Fusion Collector Wiring Harness (2026-Q3)]]"
  - "[[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]]"
  - "[[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]]"
  - "[[Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-signal-fusion-actor-resolution-spine
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q3-signal-fusion-actor-resolution-spine"
updated: 2026-09-05T13:25
---
# Proposal — Signal Fusion Actor-Resolution Spine (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-05) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

**ControlPlane can now answer, with cryptographic proof, a question no CNAPP joins into a single attested answer: "who authorized this agent action?"**

When an AI agent in a regulated estate reads a secret, calls a tool, or opens a network connection, the security team's first question is not *what happened* — the logs already say that — but *on whose authority did it happen, and can we prove it*. Today that answer is stitched together by hand across five telemetry planes that each name the same actor differently: SPIRE emits a SPIFFE ID, the Kubernetes API server emits `system:serviceaccount:...`, GCP emits an email, an OAuth provider emits a subject, KAgent emits a namespace and agent name. The identities never join, so the chain from *action* back to *human principal* is broken exactly where it matters most.

The Signal Fusion Actor-Resolution Spine closes that gap. It resolves heterogeneous identifiers into one canonical actor, models delegation ("acts on behalf of") as a first-class, never-merged relationship, and emits a single query: *action → agent identity → on-behalf-of → human/service principal → the authorization decision that permitted it → a confidence-scored, evidence-backed answer*. Every raw signal underneath that answer is written into a tamper-evident, Witness-attested store the customer cannot silently mutate. The result is not another dashboard of correlations — it is an auditable, independently verifiable answer to the question that EU AI Act and DORA make the regulated entity responsible for, and the defensible spine that the rest of the Signal Loom platform hangs off.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [ ] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [ ] operational or regulatory internal

**Key Customers (if relevant):** Signal Loom (platform partner); Tier-1 bank / regulated-sector design partner (ARC-model client, to be named at the commercial gate); ControlPlane keynote and demo audiences.

|  |  |
| :---- | :---- |
| Our *…* | regulated-sector security teams running (or about to run) autonomous AI agents in their estate |
| Have the problem/opportunity *…* | they cannot prove, from independent evidence, which human or service principal authorized a given agent action — the identities across their telemetry planes do not join, and the evidence store is mutable |
| When *…* | an incident, audit, or regulator (EU AI Act Art. 26 / DORA Art. 5) demands a defensible answer to "who authorized this?" — and whenever an agent acts under a borrowed identity |

**What's the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

2026-Q3. This is the keystone of a four-proposal set. The three feeder proposals — [[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]], [[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]], and [[Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)]] — each emit standard `model.Observation` shapes into this spine and are meaningless without it; the spine is deliverable and demonstrable on its own. It builds directly on the `osramp-demo` Signal Loom D2 platform baseline (signal-ingest service, FrostDB store, and the already-wired Witness/Archivista/`audit_anchor` attestation stack), and realises the "defensible wedge" identified in the Signal Loom Agent Security Platform adversarial critique (Appendix B, findings #1/#3/#4/#6/#9).

## Scope Summary

**Technology Readiness Level: 2 (Alpha).** Rationale: the substrate (signal-ingest, CEL correlation, FrostDB Parquet store, Witness/Archivista signing keys, `audit_anchor` Merkle checkpointing) exists at PoC quality in `osramp-demo`. The resolver, the identity/delegation graph, and write-time segment attestation are net-new capability built on that substrate — an alpha that produces a real, verifiable answer against a labelled fixture estate, not yet a production multi-tenant service.

The MVP is deliberately narrow: **replace the brittle `correlationKey()` heuristic with a deterministic-first, fidelity-gated resolver, back it with a mutable identity graph, make the evidence store tamper-evident, and expose the single authorization query — proven correct against ground truth and against an adversarial red team.** The three feeder collectors (`collectors/k8saudit`, `collectors/saas`, `collectors/kagent`) operate as fully decoupled Go packages emitting standard `model.Observation` shapes into `d2-signalloom/apps/signal-ingest`, enabling independent worktrees to build them in parallel. Everything beyond that (probabilistic entity resolution at scale, multi-tenant isolation, live customer feeds) is explicitly a nice-to-have or a downstream proposal.

### In Scope Activities

*Within project delivery and managed by the project team*

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Canonical actor-resolution engine | Deterministic-first, fidelity-gated resolver replacing `correlationKey()`. Maps SPIFFE ID ↔ `system:serviceaccount:<ns>:<name>` ↔ GCP `principalEmail` ↔ OAuth subject ↔ pod UID ↔ KAgent `ns/agent-name` onto one canonical `actor_id`. Typed edges: `same-entity(deterministic)` may merge; `same-entity(probabilistic)` and temporal/IP coincidence only raise confidence of an existing edge; merge requires ≥1 deterministic edge (mirrors the existing `CorroborationCap`). | Specific: one canonical `actor_id` per real principal across ≥5 identifier types<br/>Measurable: false-merge rate = 0 and resolution recall ≥ 90% on the labelled fixture estate<br/>Attainable: deterministic conventions (SPIFFE↔SA) are documented and stable<br/>Realistic: extends existing correlation engine, not a rewrite<br/>Time-Bound: 2026-Q3 | Go unit + table tests against labelled fixtures; equivalence test vs current engine |
| Identity/alias/delegation graph (Postgres) | Mutable graph store — `actors`, `aliases` (typed, edge-fidelity, time-valid), `delegations` (`acts-on-behalf-of`, authz reference, time-valid) — reusing the existing `DATABASE_URL`. FrostDB remains the append-only evidence store. `acts-on-behalf-of` never triggers a merge. | Specific: delegation is a distinct, queryable, never-merged edge type<br/>Measurable: 100% of `impersonatedUser`/OBO events produce a delegation edge, 0 collapse a principal<br/>Attainable: Postgres already deployed for the audit path<br/>Realistic: schema is small and bounded<br/>Time-Bound: 2026-Q3 | Schema migration tests; delegation-edge integrity tests; adversarial split-human fixture |
| Write-time evidence attestation | Each FrostDB Parquet segment signed at flush with the local ed25519 workload key (`make workload-key`) via the in-process `go-witness` SDK; rolling Merkle checkpoint over segment digests (reuse `audit_anchor`) published to Archivista; optional Rekor anchor of the checkpoint root. | Specific: every persisted segment has a retrievable, verifiable attestation<br/>Measurable: 100% of segments attested; independent verify passes; per-segment signing adds < 5 ms p99<br/>Attainable: signing keys and Merkle checkpointing already wired in-repo<br/>Realistic: local-key signing avoids Fulcio network cost<br/>Time-Bound: 2026-Q3 | `witness verify` / `cosign verify-blob` round-trip; tamper-injection test proves detection |
| "Who authorized this action?" query + API | Single query and endpoint returning the full attested chain: action → agent identity → `acts-on-behalf-of` → principal → authorization decision → confidence + evidence refs → attestation gitoid. Dashboard panel renders it. | Specific: one call returns the complete chain for a given action<br/>Measurable: ≥ 90% of agent actions in the demo estate return a complete attested chain<br/>Attainable: graph join over attested evidence refs<br/>Realistic: builds on existing promote/actor API<br/>Time-Bound: 2026-Q3 | Playwright acceptance against demo estate; chain-completeness assertion |
| Adversarial resolution red-team + published ceiling | Independent injection of hidden aliases, a deliberately-split human principal, and a shadow agent with no SVID; measure catch vs miss; publish a resolution *ceiling* rather than a headline percentage. | Specific: named adversarial cases run in CI<br/>Measurable: false-merge = 0 under attack; adversarial catch rate published as X/N caught (a falsifiable count)<br/>Attainable: fixtures are constructible now<br/>Realistic: bounded case set<br/>Time-Bound: 2026-Q3 | Red-team BATS/Go suite; ceiling documented in the repo and proposal appendix |

### Out of Scope

* Probabilistic / ML entity-resolution clustering beyond confidence-raising of existing deterministic edges (future proposal).
* Live customer Workspace/M365 feeds and multi-tenant isolation — gated behind the commercial gate and the feeder proposals.
* FrostDB columnar query-pushdown performance work — tracked separately (the volume path is exercised here but predicate-pushdown optimisation is its own effort).
* Enforcement / killswitch actions on a resolved actor — this spine answers "who authorized", it does not act.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| False-merge rate (distinct labelled principals collapsed into one actor) | Unknown (heuristic `correlationKey`, no guard) | 0 — hard release gate | Labelled fixture estate; adversarial split-human case |
| Actor-resolution recall on labelled aliases | ~exact-match only | ≥ 90% | Labelled fixture estate |
| Agent actions returning a complete *attested* authorization chain | 0% (chain broken across planes) | ≥ 90% in demo estate | Playwright acceptance |
| Segments with a verifiable write-time attestation | 0% | 100% | `witness verify` round-trip in CI |
| Adversarial catch rate on the named hidden-alias / split-human / shadow-agent cases | None | Published as X/N caught (falsifiable count, not an adjective) | Red-team suite |
| FrostDB query p95 at stated observation volume | Unmeasured (full-scan) | Documented p95 @ N observations | Volume benchmark harness |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Resolution correctness | Go unit/table tests + equivalence vs current engine, on labelled fixtures | Delivery team |
| False-merge & delegation integrity | Adversarial fixtures (split human, shadow agent, hidden alias); false-merge = 0 gate in CI | #cap-red-team specialist |
| Attestation integrity | Independent `witness verify` / `cosign verify-blob` + tamper-injection proof | AI & Data Security practice |
| End-to-end authorization query | Playwright acceptance against the demo estate | Delivery team |
| Independent review | Cross-vendor audit (Cato/GPT-family) of the resolver merge logic and attestation chain | AI & Data Security practice |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Go (signal-ingest) | Resolver engine, graph access, attestation hooks | Core service language in `osramp-demo` |
| PostgreSQL | Mutable identity/alias/delegation graph | Already deployed for the audit path (`audit/postgres.go`, `DATABASE_URL`) |
| FrostDB (Parquet, objstore) | Append-only, attested evidence store | Exists (`store/frostdb.go`, `-tags frostdb`) |
| CEL (cel-go) | Cross-layer correlation rules keyed on canonical `actor_id` | Existing correlation engine |
| SPIFFE/SPIRE | Deterministic workload-identity join key (`spiffe://td/ns/<ns>/sa/<name>`) | In-estate (spirea collector) |
| Witness + go-witness SDK | In-process write-time attestation of segments | Wired (`scripts/attested-test.sh`, `make workload-key`) |
| Archivista | Attestation store, retrieval by subject digest / gitoid | Wired (GraphQL `dsses`) |
| Merkle checkpoint (`audit_anchor`) + Rekor (optional) | Chain segment attestations; roll-back-proof anchor | Prototyped (`fe-signalloom/src/audit_anchor/anchor.py`) |
| React/Vite dashboard | "Who authorized this action?" panel | Exists (dashboard-signalloom) |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Monorepo | `osramp-demo` (github.com/controlplaneio-in-toto/osramp-demo) | signal-ingest, FrostDB store, attestation scripts |
| Service | `d2-signalloom/apps/signal-ingest` | Resolver + graph + attestation land here |
| Evidence store | `d2-signalloom/apps/signal-ingest/store/frostdb.go` | Segment-attestation hook at flush boundary |
| Attestation | `scripts/attested-test.sh`, `Makefile` (`signing-keys`, `workload-key`, `attested-test`), `audit_anchor/anchor.py` | Reuse, do not reinvent |
| Project artifacts | `1. Projects/2026-07-signalloom-d2-platform-baseline/` | Notes, ISAs, progress |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| False merge — two distinct principals collapsed into one `actor_id` | Critical (wrong party accused/blocked/killed on cryptographic-looking evidence) | Deterministic-first merge; merge requires ≥1 deterministic edge; `acts-on-behalf-of` never merges; false-merge = 0 hard gate; adversarial split-human test |
| Forged delegation — a prompt-injected agent claims a wider on-behalf-of context | High | Delegation edges sourced from authenticated audit fields (`impersonatedUser`, OBO tokens), not agent self-assertion; asymmetric per-workload signing bound to SVID (roadmap dependency) |
| Evidence tampering — customer mutates raw observations under a signed answer | Critical (undermines the whole tamper-evidence claim) | Write-time segment attestation + rolling Merkle checkpoint + optional Rekor anchor; independent verify path |
| Attestation key compromise | High | Local workload key scoped to the signer; KMS-backed key as production upgrade path; break-glass rotation |
| Resolution graph poisoning (inject a bogus alias to reroute authority) | High | Alias edges require deterministic provenance; edge writes are audited and attested; quorum on high-impact merges (roadmap) |
| Stale identity binding (SA/SVID reused over time → wrong actor at time T) | Medium | Time-valid edges (`valid_from`/`valid_to`); queries resolve as-of the action timestamp |
| Graph confidentiality — the Postgres identity/delegation graph is a complete map of every principal and its authority (high-value recon target for exfiltration) | High | Least-privilege + encrypted-at-rest graph store; read access audited and itself emitted as an observation; the evidence store is tamper-evident but the graph must also be confidentiality-protected, not just integrity-protected |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Substrate + attestation stack already wired — extend, not invent | Correctness depends on deterministic identity conventions holding across real feeds |
| Answers a question CNAPP/hyperscalers structurally do not own | Real value only lands once ≥2 heterogeneous feeders are live |

| Opportunities | Threats |
| :---- | :---- |
| The defensible wedge for the whole Signal Loom platform; maps to EU AI Act / DORA | Standards churn (A2A/MCP/OCSF identity fields) forces adapter rework |
| Design-partner pull-through from OSRAMP / FINOS relationships | A single false-merge in a demo destroys the trust the product is selling |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Canonical actor-resolution engine (deterministic-first, fidelity-gated, typed edges) replacing `correlationKey()` |  |  |  |  | #cap-golang #cap-architecture |
| M2: Postgres identity/alias/delegation graph with time-valid edges; `acts-on-behalf-of` never-merge |  |  |  |  | #cap-golang #cap-kubernetes-api-programming |
| M3: Write-time segment attestation + rolling Merkle checkpoint (go-witness, Archivista, optional Rekor) |  |  |  |  | #cap-build-provenance #cap-supply-chain-security |
| M4: "Who authorized this action?" query, API, and dashboard panel |  |  |  |  | #cap-golang #cap-architecture |
| M5: Adversarial resolution red-team + published resolution ceiling; false-merge = 0 gate in CI |  |  |  |  | #cap-red-team #cap-threat-modelling |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* `correlationKey()` heuristic replaced by the canonical resolver; equivalence and correctness tests green.
* Identity/alias/delegation graph live in Postgres; delegation modelled as a never-merged edge.
* Every persisted FrostDB segment carries a verifiable write-time attestation; tamper-injection is detected.
* The "who authorized this action?" query returns a complete attested chain for ≥ 90% of demo-estate agent actions.
* False-merge = 0 under adversarial injection; an honest resolution ceiling is published.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | AI & Data Security practice lead ([Vicente Herrera](mailto:vicente.herrera@control-plane.io)) |
| Responsible | Signal Loom / signal-ingest delivery team |
| Consulted | Cyber Resilience & Threat Assurance practice (#cap-red-team); Supply-chain / build-provenance specialist |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

Funded now as Signal Loom platform / partner investment: the spine advances the product thesis, the keynote demo, and the defensible wedge, with concrete internal deliverables. **Commercial gate:** a design-partner LOI or paid pilot — with a stated price and a 90-day first-value milestone — is required before scaling the resolver to any live customer's Workspace/M365 feeds (see feeder proposals). This proposal does not claim a signed buyer today; it makes the buyer a gate, not an assumption.

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| Rekor / transparency-log anchoring (if public anchor adopted) | TBD | Recurring | Nice-to-Have |
| KMS-backed signing key (production upgrade from local workload key) | TBD | Recurring | Nice-to-Have |
| Postgres capacity for the graph store | Negligible (existing instance) | Recurring | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-05 | AJM | Structure as spine + 3 feeder proposals; Witness attestation lives in the spine | The resolved actor + evidence chain is the thing that must be tamper-evident; matches the critique's defensible wedge | Feeders become Enhancement-tier children of this Innovation |
| 2026-09-05 | AJM | Deterministic-first, fidelity-gated resolution; `acts-on-behalf-of` never merges | False merge is the catastrophic failure; make it structurally hard | Merge requires ≥1 deterministic edge; probabilistic signals only raise confidence |
| 2026-09-05 | AJM | Headline deliverable = attested "who authorized this action?" query | The one question CNAPP/hyperscalers do not own | Product is the query, not the inventory |
| 2026-09-05 | AJM | Postgres graph + FrostDB stays append-only attested evidence store | Split by mutability; each store does what it is good at | Two stores; graph is joinable/mutable, evidence is immutable/attested |
| 2026-09-05 | AJM | Segment-attest at flush with local workload key + rolling Merkle anchor | Per-segment Fulcio keyless is network-bound/rate-limited; local key is µs | Reuses `audit_anchor` + `make workload-key` |
| 2026-09-05 | AJM | KPIs graded on labelled fixtures + adversarial red-team ceiling | Prior proposals dinged for unfalsifiable self-graded KPIs | Every number externally checkable |
| 2026-09-05 | AJM | Funded as platform investment now; design-partner LOI gates live-customer scale | Answers critique #7 without inventing a buyer | Commercial gate before Workspace/M365 live wiring |

## Appendix

### A. Useful Links

* [[Proposal — Signal Loom Agent Security Platform (2026-Q3)]] + [[Proposal — Signal Loom Agent Security Platform — Critique Appendix (2026-Q3)]] (Critique Appendix B)
* [[Proposal — Policy as Versioned Code, Priced Agent Risk (2026-Q3)]]
* `osramp-demo` — `d2-signalloom/apps/signal-ingest` (correlation engine, FrostDB store, `collectors/{k8saudit,saas,kagent}`)
* `scripts/attested-test.sh`, `audit_anchor/anchor.py` — existing Witness/Archivista/Merkle plumbing
* SignalLoom D2 platform baseline project: `1. Projects/2026-07-signalloom-d2-platform-baseline/`

### B. Feeder proposals (Enhancement-tier children)

* [[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]] — build now; deterministic SPIFFE join; OBO from `impersonatedUser`; package `d2-signalloom/apps/signal-ingest/collectors/k8saudit` emitting `model.Observation`.
* [[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]] — thin (contract + fixtures); live wiring gated on feed arrival + commercial gate; package `d2-signalloom/apps/signal-ingest/collectors/saas` emitting `model.Observation`.
* [[Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)]] — calibration-gated; build on stable `ns/agent-name` + SA keys now; package `d2-signalloom/apps/signal-ingest/collectors/kagent` emitting `model.Observation`.

### C. Adversarial resolution red-team — case seeds

* Hidden alias: an identifier type present in one feeder, absent from the deterministic map — measure whether it is left fragmented (correct) or wrongly merged (fail).
* Split human: one real person behind two identities sharing a NAT source IP — must NOT collapse on IP coincidence alone.
* Shadow agent: an agent action with no SVID and no registration — must surface as unresolved, not silently attributed.
