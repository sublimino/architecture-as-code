---
created: 2026-09-12
reviewers:
  - "#james-callaghan"
  - "#vicente-herrera"
capabilities:
  - "#cap-grc"
  - "#cap-secrets"
  - "#cap-architecture"
  - "#cap-supply-chain-security"
  - "#cap-threat-modelling"
  - "#cap-policy-as-code"
practice:
  - Governance, Risk & Compliance Enablement
  - AI & Data Security
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: 1. Projects/2026-07-signalloom-d2-platform-baseline/
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - enhancement-proposals
  - proposal-2026-q3-signal-loom-production-and-data-protection-hardening
  - partner-signal-loom
  - osramp
  - gdpr
aliases:
  - "#proposal-2026-q3-signal-loom-production-and-data-protection-hardening"
updated: 2026-09-14T07:48
---
# Proposal — Signal Loom Production and Data-Protection Hardening (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-12) |
| Reviewer & Date: |  |
| Approver & Date: |  |

> [!important] Why this, why now
> The Signal Fusion spine is **built and adversarially certified in the demo estate**. The gap between that and *"deployable inside a regulated bank"* is not more features — it is the **gating layer**: data protection (GDPR), multi-tenancy isolation, a production deployment/residency model, and production key custody. Signal Fusion processes identity data by construction (usernames, emails, IPs, service accounts, and a graph of who acts for whom), so the data-protection layer is not optional polish — it is the thing a bank's second line and DPO will ask about first, and it is currently **designed but not built**. This proposal builds it, so the certified spine can actually be sold and deployed.

## Press Release

**Signal Loom becomes deployable inside a regulated bank — with the data-protection, tenant-isolation, and production-key controls a DPO and a second-line reviewer sign off, not just an engineer.**

The certified "who authorized this action?" spine runs today in a demo estate. To run it against a real customer's identity data, three things must be true that are not yet: personal data must be **minimised, pseudonymised, retained-and-erasable** under GDPR (including the hard reconciliation of the right to erasure with a tamper-evident evidence store); tenants must be **provably isolated** so one customer's identity graph is never readable by another; and the platform must **deploy in the customer's region with production-grade key custody**. This proposal delivers that gating layer — turning "your identity data never leaves your boundary" from a slide into an enforced, auditable property, and shipping a DPIA pack that lets a customer complete their own compliance obligation faster.

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

**Key Customers (if relevant):** The ARC-class design partner and any Tier-1 bank; their DPO and second-line risk function are the real approvers of a deployment.

|  |  |
| :---- | :---- |
| Our *…* | regulated customers whose DPO/second-line must approve any system that processes employee and service identity data |
| Have the problem/opportunity *…* | the certified spine is demo-grade on data protection: no pseudonymisation policy, no retention, no erasure mechanism against the immutable store, no tenant isolation, and demo-grade key custody |
| When *…* | moving from a certified demo to a paid deployment against a customer's real estate — the DPO/CISO's second line asks "how do you handle erasure, retention, tenant isolation, and where do the keys live?" |

**Urgency.** 2026-Q3–Q4, in lockstep with converting the design partner. This is the gate on any real-estate deployment; building it late blocks revenue.

## Scope Summary

**Technology Readiness Level: 1 (R&D) → 2 (Alpha).** Rationale: the data-protection layer is currently a design position (see the Architecture & GDPR Reference §10); this proposal builds it to a testable alpha — pseudonymisation, retention, erasure, tenant isolation, and a production deployment — that a DPO can review and a design partner can run.

**MVP:** identity data is pseudonymised at rest with a separately-controlled re-identification map; a data subject can be erased without breaking the attestation proof (crypto-shred + attested tombstone); two tenants are provably isolated; the platform deploys region-pinned with a KMS-backed signing key; and a DPIA pack ships with it.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Pseudonymisation at rest + field allow-list | Store pseudonymous canonical actor IDs (HMAC) in the evidence/graph; hold the re-identification map separately and access-controlled; ingest only security-required fields (drop payloads/bodies). Builds on the existing scrubber/redactor/HMAC-anonymiser. | Specific: direct identifiers are pseudonymised at rest; re-id map is separate + audited<br/>Measurable: 0 direct identifiers in the evidence store on a fixture estate; re-identification is an audited event<br/>Attainable: transform primitives exist<br/>Realistic: policy + wiring<br/>Time-Bound: 2026-Q4 | Store inspection test; audit-of-re-identification test |
| Retention + crypto-shred erasure + attested tombstones | A configurable retention/rotation policy on both stores; erasure of a data subject via destroying the re-identification key ("crypto-shred"), recorded as an itself-attested tombstone so the proof stays internally consistent; support an Art 17(3) retention-exception assertion. | Specific: a subject can be erased; the evidence store stays verifiable; erasure is attested<br/>Measurable: post-erasure the subject is unlinkable; `witness verify` still passes; tombstone present<br/>Attainable: attestation + revocation primitives exist (delegation revocation shipped this week)<br/>Realistic: bounded<br/>Time-Bound: 2026-Q4 | Erasure test: subject unlinkable + proof still verifies + tombstone attested |
| Graph confidentiality + multi-tenant isolation | Encrypt the identity/delegation graph at rest with least-privilege, audited access; isolate per tenant so one tenant's graph/evidence/attestation keys are never readable by another. | Specific: per-tenant isolation of graph + evidence + keys<br/>Measurable: cross-tenant read attempt denied in tests; graph encrypted at rest<br/>Attainable: builds on the tenant-scoped claim work landed this week<br/>Realistic: bounded<br/>Time-Bound: 2026-Q4 | Cross-tenant isolation test; encryption-at-rest check |
| Production deployment + key custody + DPIA pack | Region-pinned deployment (self-hosted / processor model), KMS-backed signing key (replacing the local workload key), Archivista/Rekor residency, and a productised **DPIA pack** (data map, lawful basis / LIA template, minimisation controls, retention, erasure mechanism). | Specific: region-pinned deploy + KMS signing + DPIA pack<br/>Measurable: deploy on a GKE region with KMS signing; DPIA pack complete and reviewed<br/>Attainable: signing + deploy machinery exist<br/>Realistic: bounded<br/>Time-Bound: 2026-Q4 | GKE region deploy smoke; DPIA pack review with GRC/legal |

### Out of Scope

* Full external certification/audit (this makes us *auditable*, it does not confer compliance — the "no regulatory immunity" rule).
* The enforcement/kill path (Proposal 1).
* Data-subject-rights self-service portal (the mechanisms are built; a customer-facing portal is a follow-on).

### KPIs

| Metric | Current | Target | Measurement |
| :---- | :---- | :---- | :---- |
| Direct identifiers in the evidence store at rest | present | 0 (pseudonymised) | Store inspection |
| Erasure without breaking the proof | not possible | demonstrated (crypto-shred + tombstone; `witness verify` passes) | Erasure test |
| Cross-tenant read isolation | none | proven denied | Isolation test |
| Production key custody | local key | KMS-backed | Deploy check |
| DPIA pack | none | complete + GRC-reviewed | Review |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Pseudonymisation + erasure | Store inspection + erasure/verify round-trip | AI & Data Security practice |
| Tenant isolation | Cross-tenant read-denial tests | Delivery team |
| DPIA / lawful basis | Review with GRC + external legal (Kirsty / DPO) | GRC practice |
| Production deploy | GKE region-pinned smoke + KMS signing | Delivery team |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| HMAC pseudonymisation + separate re-id store | GDPR pseudonymisation (Art 4(5)) | Extends existing scrubber/HMAC-anonymiser |
| Envelope encryption (per-subject/segment keys) + KMS | Crypto-shred erasure + graph confidentiality + prod key custody | New; standard pattern |
| Postgres row-level isolation / per-tenant schema | Multi-tenancy | Builds on tenant-scoped claim work |
| Witness + attested tombstones | Erasure that preserves the proof | Exists (spine) |
| DPIA pack (doc + templates) | Productised compliance artifact | New deliverable |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Data-protection layer | `d2-signalloom/apps/signal-ingest/{transform,identity,store}` | pseudonymise + retention + erasure |
| Deployment | GKE region-pinned; `1. Projects/2026-08-signalloom-gcp-terraform/` | KMS signing, residency |
| DPIA pack | `docs/signalloom/` + Obsidian | productised artifact |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Identity/delegation graph exfiltration (a map of every principal's authority) | Critical | Encrypt at rest, least-privilege, audited access |
| Cross-tenant data leakage | Critical | Per-tenant isolation of graph + evidence + keys; isolation tests |
| Erasure vs immutability conflict | High | Pseudonymise + crypto-shred + attested tombstone; Art 17(3) exception path |
| Re-identification map compromise | High | Separate store, strict access control, every re-id audited |
| Key custody in production | High | KMS-backed keys; break-glass with dual control |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Turns "data never leaves your boundary" into an enforced property | Least-built area; needs legal sign-off to be load-bearing |
| Ships a DPIA pack — a productised compliance asset | Erasure/immutability reconciliation is subtle |

| Opportunities | Threats |
| :---- | :---- |
| Unblocks paid deployment in regulated estates | A DPO objection can block a deal if unaddressed |
| DPIA pack is a differentiated sales artifact | Over-claiming compliance (kill the "GDPR-compliant" language) |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Pseudonymisation at rest + separated re-identification map + field allow-list |  |  |  |  | #cap-secrets #cap-architecture |
| M2: Retention/rotation + crypto-shred erasure + attested tombstones (Art 17 + 17(3) exception) |  |  |  |  | #cap-grc #cap-supply-chain-security |
| M3: Graph confidentiality (encrypt-at-rest) + multi-tenant isolation |  |  |  |  | #cap-architecture #cap-threat-modelling |
| M4: Region-pinned production deploy + KMS signing + DPIA pack |  |  |  |  | #cap-grc #cap-policy-as-code |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* Direct identifiers pseudonymised at rest; re-identification is separated and audited.
* A data subject can be erased (crypto-shred + attested tombstone) with the attestation proof still verifying.
* Two tenants provably isolated; the graph is encrypted at rest.
* Region-pinned deploy with a KMS-backed signing key; a complete, GRC-reviewed DPIA pack ships.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Governance, Risk & Compliance practice lead ([James Callaghan](mailto:james.callaghan@control-plane.io)) |
| Responsible | Signal Loom / signal-ingest delivery team |
| Consulted | AI & Data Security practice; external legal / DPO (erasure & lawful basis) |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

Funded as Signal Loom platform investment; it is the gate on any paid real-estate deployment. External legal/DPO review is a line item.

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| KMS (cloud) for production signing keys | TBD | Recurring | Must-Have (at production) |
| External legal / DPO review of the erasure + lawful-basis design | TBD | One Off | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-12 | AJM | Build the data-protection + production layer as the second next-build | It is the gate between a certified demo and a paid deployment | Sequenced as Proposal 2 for the Wednesday planning meeting |
| 2026-09-12 | AJM | Reconcile erasure vs tamper-evidence via pseudonymisation + crypto-shred + attested tombstones | Can't naively both "prove nothing deleted" and "delete on request" | Needs DPO/legal sign-off before it is load-bearing |
| 2026-09-12 | AJM | Ship a productised DPIA pack | Compliance is the buying trigger; make it an asset | DPIA becomes a sales artifact, not a blocker |

## Appendix

### A. Useful Links

* Parent: [[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]
* Sibling: [[Proposal — Signal Loom Enforcement and Response (2026-Q3)]]
* Data-protection design: [[Signal Loom — Architecture, Ingestion Pipelines & GDPR Compliance Reference]] (§9–§11)
* Report: [[Signal Loom CEO Delivery Report]]
* Regulatory: GDPR Arts 4(5), 5, 6(1)(f), 17 + 17(3), 25, 28, 32, 35.

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `SLDP`
- Integration branch: `refs/heads/integration/sldp-v0.1.0`
- Target components: `d2-signalloom/apps/signal-ingest/{identity,store,transform,audit,api}`, `d2-signalloom/apps/fe-signalloom/src/audit_anchor`
- Acceptance commands: `make test-signal-ingest`, `make demo-signalloom-api-test TIER=contract`, `bats test/acceptance-spec-coverage.bats`

#### Card numbering

`P0` is the mission baseline and is a single card. Each phase then opens with a
`PN-PRE` preflight, carries `PN-K` implementation cards, and closes with a `PN-GOV`
governor. This is what `link-check` enforces: R1 requires every implementation card
to reach its phase preflight, R2 requires the governor to wait on every
implementation card in its phase, and R3 requires each preflight to wait on the
previous phase governor, or on `P0` for phase 1.

#### Architectural constitution

- **This mission builds, it does not harden.** There is no erasure, deletion or
  retention code anywhere in the repository. `EventPartitionDropped` is declared at
  `audit/audit.go:22,34` with zero call sites, and the only existing reaper flips a
  status field at `identity/repository.go:372-387`. Size every estimate accordingly.
- **Controls fail closed.** `NewEncryptorFromKeyString("")` currently returns a
  passthrough encryptor and `NopWriter` discards every audit event. No control added
  by this mission may degrade silently.
- **Pseudonymise in Parquet, encrypt in Postgres.** Encrypting a columnar field
  destroys Arrow predicate pushdown and with it the 2.75 ms p95 budget at 12,000
  observations.
- **Never rewrite attested evidence.** Add a schema version; do not mutate existing
  segment bytes. Deleting a segment also breaks checkpoint continuity, so retention
  and Article 17 must be reconciled explicitly rather than assumed compatible.
- **Every acceptance criterion must be able to fail.** There is no `Verify*`
  entrypoint in `store/segment_attestor.go`, so until P1-3 lands, no test can
  evaluate evidence-segment integrity.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Verify claimed primitives and map implementation boundaries. |
| P1-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Confirm live-hole seams and route inventory before closing them. |
| P1-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Authenticate and authorise the signal-ingest HTTP API. |
| P1-2 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | daily | Make encryption and audit writers fail closed. |
| P1-3 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Build segment and checkpoint chain verifier; size milestones. |
| P1-GOV | ripwire-quality-bar; RedTeam | Governor | M | 90m | daily | Certify live holes closed and verifier working. |
| P2-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Confirm identity-layer seams and the next free migration sequence. |
| P2-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Keyed HMAC pseudonyms and envelope-encrypted alias values. |
| P2-2 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Tenant column and enforced row-level security on identity graph. |
| P2-3 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | daily | Pin never-merge invariant across pseudonymisation change. |
| P2-GOV | ripwire-quality-bar; RedTeam | Governor | M | 90m | daily | Freeze identity privacy contract; no cleartext identifier remains. |
| P3-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Confirm columnar schema seams and the attestation chain shape. |
| P3-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Remove cleartext identity from immutable columnar segments. |
| P3-2 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Gate erasure with legal hold and dual-operator authorisation. |
| P3-GOV | ripwire-quality-bar; RedTeam | Governor | M | 90m | daily | Certify redaction, attestation validity and latency budget. |
| P4-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Confirm key-management seams and erasure preconditions. |
| P4-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Per-subject key hierarchy with idempotent erasure saga. |
| P4-2 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | daily | Non-linkable attested tombstones. |
| P4-GOV | ripwire-quality-bar; RedTeam | Governor | M | 90m | daily | Certify per-subject erasure and non-linkable tombstones. |
| P5-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Prototype the KMS signer and confirm data-subject-rights surfaces. |
| P5-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Abstract segment signer for non-exportable KMS keys. |
| P5-2 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | daily | DPIA and legitimate-interest assessment pack. |
| P5-3 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Build Article 15, 20 and 21 data-subject-rights mechanisms. |
| P5-GOV | ripwire-quality-bar; RedTeam | Governor | M | 90m | daily | Certify KMS signing, DPIA completeness and data-subject rights. |
| P6-PRE | ripwire-before-you-build; FirstPrinciples | Preflight | S | 45m | fast | Inventory retention sinks and confirm the deployment model. |
| P6-1 | ripwire-write-tests; ripwire-security-scan | Implementation | L | 150m | deep | Retention controller with deletion receipts across every sink. |
| P6-2 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | daily | Customer-self-hosted install proof as primary validation. |
| P6-GOV | ripwire-quality-bar; RedTeam | Governor | L | 150m | deep | Certify data-protection contract and publish downstream contract. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | preflight | Verify claimed primitives and map implementation boundaries | None | `ripwire d2-signalloom/apps/signal-ingest` | S | fast | pass — delivered: 9d00d295 (see Errata — SLDP-P0) | $0.00 | N/A | 32m | antigravity |
| P1-PRE | preflight | Confirm live-hole seams and route inventory before closing them | P0 | `rg -n 'HandleFunc|NewServeMux' d2-signalloom/apps/signal-ingest/main.go` | S | fast | pass — delivered: 70136be0 (see Errata — SLDP-P1-PRE) | $0.00 | N/A | 25m | antigravity |
| P1-1 | implementation | Authenticate and authorise the signal-ingest HTTP API | P1-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./api/...` | L | deep | pass — delivered: 0e6076ae (see Errata — SLDP-P1-1) | $0.00 | N/A | 45m | antigravity |
| P1-2 | implementation | Make encryption and audit writers fail closed | P1-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | M | daily | pass — delivered: f375d731 (see Errata — SLDP-P1-2) | $0.00 | N/A | 25m | antigravity |
| P1-3 | implementation | Build segment and checkpoint chain verifier; size milestones | P1-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./store/...` | L | deep | pass — delivered: c3c36f96 (see Errata — SLDP-P1-3) | $0.00 | N/A | 50m | antigravity |
| P1-GOV | governor | Certify live holes closed and verifier working | P1-1, P1-2, P1-3 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | M | daily | pass — certified: 53e412b6 (see Errata — SLDP-P1-GOV) | $0.00 | N/A | 15m | antigravity |
| P2-PRE | preflight | Confirm identity-layer seams and the next free migration sequence | P1-GOV | `ls -1 d2-signalloom/apps/signal-ingest/identity/migrations/` | S | fast | pass — delivered: d4762cd3 (see Errata — SLDP-P2-PRE) | $0.00 | N/A | 1m | antigravity |
| P2-1 | implementation | Keyed HMAC pseudonyms and envelope-encrypted alias values | P2-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | L | deep | pass — delivered: fd9a4aa8 (see Errata — SLDP-P2-1) | $0.00 | N/A | 39m | kpai |
| P2-2 | implementation | Tenant column and enforced row-level security on identity graph | P2-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | L | deep | pass — delivered: c16599af (see Errata — SLDP-P2-2) | $0.00 | N/A | 38m | kpai |

| P2-3 | implementation | Pin never-merge invariant across pseudonymisation change | P2-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-GOV | governor | Freeze identity privacy contract; no cleartext identifier remains | P2-1, P2-2, P2-3 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-PRE | preflight | Confirm columnar schema seams and the attestation chain shape | P2-GOV | `rg -n 'actor_hint|labels' d2-signalloom/apps/signal-ingest/store/frostdb.go` | S | fast | Pending | $0.00 | N/A | N/A | N/A |
| P3-1 | implementation | Remove cleartext identity from immutable columnar segments | P3-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./store/...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P3-2 | implementation | Gate erasure with legal hold and dual-operator authorisation | P3-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P3-GOV | governor | Certify redaction, attestation validity and latency budget | P3-1, P3-2 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-PRE | preflight | Confirm key-management seams and erasure preconditions | P3-GOV | `cd d2-signalloom/apps/signal-ingest && go test ./identity/...` | S | fast | Pending | $0.00 | N/A | N/A | N/A |
| P4-1 | implementation | Per-subject key hierarchy with idempotent erasure saga | P4-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P4-2 | implementation | Non-linkable attested tombstones | P4-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./...` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-GOV | governor | Certify per-subject erasure and non-linkable tombstones | P4-1, P4-2 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-PRE | preflight | Prototype the KMS signer and confirm data-subject-rights surfaces | P4-GOV | `rg -n 'ed25519|PrivateKey' d2-signalloom/apps/signal-ingest/store/segment_attestor.go` | S | fast | Pending | $0.00 | N/A | N/A | N/A |
| P5-1 | implementation | Abstract segment signer for non-exportable KMS keys | P5-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./store/...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P5-2 | implementation | DPIA and legitimate-interest assessment pack | P5-PRE | `test -f docs/signalloom/dpia-reference-pack.md` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-3 | implementation | Build Article 15, 20 and 21 data-subject-rights mechanisms | P5-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P5-GOV | governor | Certify KMS signing, DPIA completeness and data-subject rights | P5-1, P5-2, P5-3 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-PRE | preflight | Inventory retention sinks and confirm the deployment model | P5-GOV | `rg -c 'EventPartitionDropped' d2-signalloom/apps/signal-ingest/audit/audit.go` | S | fast | Pending | $0.00 | N/A | N/A | N/A |
| P6-1 | implementation | Retention controller with deletion receipts across every sink | P6-PRE | `cd d2-signalloom/apps/signal-ingest && go test ./...` | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P6-2 | implementation | Customer-self-hosted install proof as primary validation | P6-PRE | `test -f docs/signalloom/sldp-p6-2-selfhost-install-proof.md` | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-GOV | governor | Certify data-protection contract and publish downstream contract | P6-1, P6-2 | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLDP` | L | deep | Pending | $0.00 | N/A | N/A | N/A |

### Spec: Errata

#### Errata — SLDP-P0 (qualified preflight failure)
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

- Council disposition: existing `SegmentAttestor` capability plus delegation revocation satisfy the P0 baseline; attestation-specific revocation is future composition work, not a P0 blocker.
- Verification correction: Python `audit_anchor` already verifies persisted segment bytes, signed predicates, checkpoint chains and protected high-water state; only the public Go `SegmentAttestor.Verify*` boundary is absent.
- Status: `pass`
- Proceed: `yes`
- Blocking drift: `no`
- Commit SHA: `9d00d29503088e2f91c0fe80b4caa89503a3cc41`
- Commit scope: exactly `docs/signalloom/sldp-p0-boundary-map.md` and `docs/signalloom/sldp-p0-proof.md`.
- Required checks: `make test`, `make test-signal-ingest`, `make demo-signalloom-api-test TIER=contract`, and `bats test/acceptance-spec-coverage.bats` each exited `0`.
- Additional validation: signal-ingest `go vet ./...` exited `0` with isolated caches and `CGO_ENABLED=0`; independent citation review and final staged-document review reported no unresolved blocker.
- Deliverables: the boundary map records primitive verdicts, interfaces, personal-data copies, migration sequence and revised estimates; the proof map records reproducible command evidence plus false-green limits.
- Scope control: no application source, migration, runtime state, sibling worktree or production environment was modified; no remote push was performed.

#### Errata — SLDP-P1-PRE: Preflight Verification
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 12:30:10+01:00  
**Last Updated:** 2026-09-14 12:30:10+01:00  
**Status:** `pass`  
**Commit:** `70136be0c7d011e00caa54295ecf53c234dd04af`  
**Evidence:** `docs/signalloom/sldp-p1-pre-proof.md`  

Preflight checks verified 100% PASS. All 32 HTTP route endpoints for signal-ingest inventoried, identity system binding to SPIFFE Workload Identity (JWT-SVID) decided and justified, both fail-open sites (NoopEncryptor and NopWriter) confirmed at exact file and line, zero Go segment verifier entrypoints confirmed, and empty-key reliance in current live deployment documented for P1-2 coordination.

#### Errata — SLDP-P1-2 Make encryption and audit writers fail closed
**Created:** 2026-09-14 12:41:31+01:00  
**Last Updated:** 2026-09-14 12:41:31+01:00  
**Status:** Completed  
**Commit:** f375d731  
**Governor merge:** [pending Governor reconciliation]  
**Decisions:** Gated NoopEncryptor behind explicit INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR environment flag; configured background warning loop logging every 30s during passthrough lifecycle; enforced fail-closed policy (503 Service Unavailable) on high-stakes actor promotion when audit writes fail; exposed encryption and audit security postures at /health and /api/v1/health; updated deployment.yaml and secrets.yaml to provision IDENTITY_ENCRYPTION_KEY.  
**Deviations:** None. All deliverables completed and tested with 100% pass across signal-ingest unit, integration, and contract test suites.  
**Notes:** Live Kubernetes deployments now have IDENTITY_ENCRYPTION_KEY populated via discovery-portal-database secret.  
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — SLDP-P1-1 Authenticate and authorise the signal-ingest HTTP API
**Created:** 2026-09-14 14:14:04+01:00  
**Last Updated:** 2026-09-14 14:14:04+01:00  
**Status:** Completed  
**Commit:** 0e6076ae  
**Governor merge:** [pending Governor reconciliation]  
**Decisions:** Gated all 32 HTTP route endpoints exclusively through NewProtectedRouter; authenticated using SPIFFE JWT-SVID bound to trust domain; protected /metrics under PermissionMetrics (metrics:read) to prevent label cardinality and identifier leakage; derived TenantContext strictly from authenticated principal claims for downstream row-level security (P2-2); enforced pagination bounds and shared per-principal enumeration rate limits across listing endpoints; terminated SSE connections at credential expiration with context cancellation and write deadlines; logged fail-closed HMAC-pseudonymized audit events on all auth/authz rejections with zero credential leakage. Recorded note that encryption-at-rest does not mitigate unauthenticated HTTP read exfiltration.  
**Deviations:** None. All deliverables and hostile-request tests implemented and passing.  
**Notes:** Downstream tasks (P2-2 RLS) should consume TenantContext from request context.  
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — SLDP-P1-3 Build segment and checkpoint chain verifier; size milestones
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 14:13:39+01:00  
**Last Updated:** 2026-09-14 14:13:39+01:00  
**Status:** `pass`  
**Commit:** `c3c36f96`  
**Evidence:** `docs/signalloom/sldp-p1-3-proof.md`, `docs/signalloom/segment-verifier.md`, `docs/signalloom/sldp-p1-3-milestone-sizing.md`  

- **Independent Segment and Checkpoint Verifier**: Built `d2-signalloom/apps/signal-ingest/store/verify/verify.go` providing fail-closed DSSE / Ed25519 signature verification, checkpoint continuity checks (`Sequence`, `PrevCheckpointDigest`, `CumulativeRowCount`), Merkle tree verification against segment SHA-256 digests, and strict schema validation (`ErrUnknownSchemaVersion`).
- **Standalone Verification CLI**: Delivered `cmd/segment-verify` with `--data-dir`, `--public-key`, `--highwater`, `--allow-partial`, `--check-rekor`, `--archivist-url` flags and structured JSON output.
- **Tamper & Negative Test Suite**: Added 17 verification tests in `store/segment_verifier_test.go` and `cmd/segment-verify/main_test.go` exercising corruption of segment Parquet bytes, signature forgery, intermediate symlinks, oversized envelopes, discontinuous journal sequence numbers, broken checkpoint chains, cumulative row count mismatches, schema tampering, highwater tip mutation, and historical key rotation.
- **Milestone Sizing Published**: Sized M1–M4 in `docs/signalloom/sldp-p1-3-milestone-sizing.md` (Total 75.25–102.25 working days, 126.5–172.5 person-days across 2 core engineers, D+76–103 relative to D0).

#### Errata — SLDP-P1-GOV: Phase 1 Governor Certification
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 14:28:12+01:00  
**Last Updated:** 2026-09-14 14:28:12+01:00  
**Status:** `pass`  
**Commit:** `53e412b6`  
**Evidence:** `docs/signalloom/sldp-p1-gov-proof.md`  

**Phase 1 Governor Certification Summary:**
- **Live Holes Certified Closed**: Verified all 32 HTTP route endpoints and 4 SSE streams in `signal-ingest` enforce SPIFFE JWT-SVID authentication and authorization under `NewProtectedRouter`, rejecting unauthenticated calls with 401/403.
- **Fail-Closed Controls Verified**: Confirmed missing/empty encryption keys fail startup (`ErrNoopEncryptionNotAllowed`), `NopWriter` returns `ErrAuditDisabled`, and `handlePromoteActor` fails closed (503) on audit persistence failure.
- **Independent Verifier Operational**: Verified `store/verify` and `cmd/segment-verify` correctly reject corrupted Parquet bytes, signature forgery, intermediate symlinks, and broken checkpoint chains (17 test suites pass 100%).
- **Milestone Sizing Attached**: Integrated M1–M4 sizing (75.25–102.25 working days, 126.5–172.5 person-days, 2 core consultants, D+76–103).
- **Tenant-Binding Contract Published**: Published strict downstream contract for `SLDP-P2-2` (Row-Level Security).
- **Certified Proof**: Documented in `docs/signalloom/sldp-p1-gov-proof.md`.


#### Errata — SLDP-P2-PRE: Confirm identity-layer seams and the next free migration sequence
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 14:33:39+01:00  
**Last Updated:** 2026-09-14 14:33:39+01:00  
**Status:** `pass`  
**Commit:** `d4762cd3`  
**Evidence:** `docs/signalloom/sldp-p2-pre-proof.md`  

**Summary of changes and evidence:**
- Audited `d2-signalloom/apps/signal-ingest/identity/migrations/` and reserved sequence numbers: `005` for P2-1 (pseudonymisation & envelope encryption), `006` for P2-2 (tenant isolation & RLS), `007` for P2-3 (never-merge pin / trigger).
- Re-read `check_never_merge_alias` and `check_never_merge_delegation` in `001_identity_graph.sql:63-87,95-114`. Documented that comparing `alias_value` directly against `delegate_actor_id`/`principal_actor_id` will fail OPEN once `alias_value` is pseudonymised, mandating that P2-3 pin the invariant before P2-1 schema alterations.
- Restated P1-GOV tenant-binding contract for P2-2: `TenantContext` ingestion from SPIFFE JWT identity, strict prohibition against untrusted `X-Tenant-ID` headers/params, and PostgreSQL RLS transaction scoping via `SET LOCAL app.current_tenant = $tenant_id`.
- Catalogued 10 indexes currently indexing cleartext identifiers (`actor_id`, `alias_value`, `delegate_actor_id`, `principal_actor_id`), highlighting `idx_aliases_value_temporal` and `idx_aliases_idempotent_seed` as primary P2-1 targets.
- Documented unconfirmed assumptions regarding RLS query latency overhead, dynamic HMAC salt rotation, and columnar downstream integration.
- Full execution evidence published to `docs/signalloom/sldp-p2-pre-proof.md`.


#### Errata — SLDP-P2-1: Keyed HMAC pseudonyms and envelope-encrypted alias values
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 15:19:10+01:00  
**Last Updated:** 2026-09-14 15:19:10+01:00  
**Status:** `pass`  
**Commit:** `fd9a4aa8`  
**Evidence:** `docs/signalloom/sldp-p2-1-proof.md`  

**Summary of changes and evidence:**
- Implemented HKDF-SHA256 derived per-tenant, per-epoch pseudonym key ring in `identity/pseudonym.go`, replacing unkeyed bare `sha256.Sum256`.
- Implemented AES-GCM envelope encryption with per-record data encryption keys (DEK) and additional authenticated data (AAD) row binding over `(actor_id, alias_type, pseudonym)`.
- Authored and verified PostgreSQL migration `005_pseudonymisation_and_encryption.sql` and rollback `005_pseudonymisation_and_encryption_rollback.sql`.
- Authored adversarial dictionary attack test in `pseudonym_test.go` with positive control (unkeyed inverted 6/6; keyed inverted 0/6 across 1,446 candidate identifiers).
- Removed committed default salt from `transform/secrets_scrubber.go` in favor of fail-closed construction, widening `AnonymizeHMAC` from 64 to 128 bits.
- Full test suite verified: `make test-signal-ingest` **EXIT=0 (539 PASS / 0 FAIL / 7 SKIP)**.

#### Errata — SLDP-P2-2: Tenant column and enforced row-level security on identity graph
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-14 15:19:34+01:00  
**Last Updated:** 2026-09-14 15:19:34+01:00  
**Status:** `pass`  
**Commit:** `c16599af`  
**Evidence:** `docs/signalloom/sldp-p2-2-proof.md`  

**Summary of changes and evidence:**
- Authored migration `006_tenant_isolation_rls.sql` adding `tenant_id NOT NULL` with `DEFAULT app_current_tenant()` to `actors`, `aliases`, and `delegations`.
- Enforced `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` across all three tables.
- Added tenant-leading composite temporal indexes to prevent full scans under RLS predicates.
- Enforced cross-tenant maintenance path gated by dedicated role and transaction-local reason GUC.
- Quarantined pre-tenancy rows to `__unattributed__` tenant with comprehensive backfill report.
- Implemented `identity/tenant_live_test.go` with 28 hostile-context live PostgreSQL tests (including superuser rejection, connection reset safety, and falsification test) passing 100%.


#### Errata — SLDP-P2-3 (bootstrap)
##### Task identity
- Card: `SLDP-P2-3`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P2-GOV (bootstrap)
##### Task identity
- Card: `SLDP-P2-GOV`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P3-PRE (bootstrap)
##### Task identity
- Card: `SLDP-P3-PRE`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P3-1 (bootstrap)
##### Task identity
- Card: `SLDP-P3-1`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P3-2 (bootstrap)
##### Task identity
- Card: `SLDP-P3-2`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P3-GOV (bootstrap)
##### Task identity
- Card: `SLDP-P3-GOV`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P4-PRE (bootstrap)
##### Task identity
- Card: `SLDP-P4-PRE`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P4-1 (bootstrap)
##### Task identity
- Card: `SLDP-P4-1`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P4-2 (bootstrap)
##### Task identity
- Card: `SLDP-P4-2`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P4-GOV (bootstrap)
##### Task identity
- Card: `SLDP-P4-GOV`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P5-PRE (bootstrap)
##### Task identity
- Card: `SLDP-P5-PRE`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P5-1 (bootstrap)
##### Task identity
- Card: `SLDP-P5-1`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P5-2 (bootstrap)
##### Task identity
- Card: `SLDP-P5-2`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P5-3 (bootstrap)
##### Task identity
- Card: `SLDP-P5-3`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P5-GOV (bootstrap)
##### Task identity
- Card: `SLDP-P5-GOV`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P6-PRE (bootstrap)
##### Task identity
- Card: `SLDP-P6-PRE`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P6-1 (bootstrap)
##### Task identity
- Card: `SLDP-P6-1`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P6-2 (bootstrap)
##### Task identity
- Card: `SLDP-P6-2`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

#### Errata — SLDP-P6-GOV (bootstrap)
##### Task identity
- Card: `SLDP-P6-GOV`
- Shortcode: `SLDP`
- Commit: Pending
- Result: Pending

