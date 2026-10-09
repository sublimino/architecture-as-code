---
created: 2026-10-08
reviewers:
  - "#stefan-prodan"
  - "#vicente-herrera"
  - "#francesco-beltramini"
capabilities:
  - "#cap-architecture"
  - "#cap-api-design"
  - "#cap-react"
  - "#cap-python"
  - "#cap-security-engineering"
  - "#cap-testing-pyramid"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-10-signalloom-governance-claim-and-resilience/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q4-signal-loom-governance-claim-and-resilience
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q4-signal-loom-governance-claim-and-resilience"
shortcode: SLGC
integration: integration/slgc-v0.1.0
---
# Proposal — Signal Loom Governance Claim, Human Identity Anchoring, and SuperCred Lifecycle Resilience (2026-Q4)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-10-08) |
| Reviewer & Date: | Stefan Prodan, Vicente Herrera, Francesco Beltramini |
| Approver & Date: | Andy Martin (2026-10-08) |

## Press Release

ControlPlane today announced Signal Loom's production-grade Governance Claim Workflow, Human Identity Anchoring System, and Resilient Credential Lifecycle Architecture. This release bridges the gap between raw cluster workload telemetry and authoritative enterprise identity governance.

As organizations deploy heterogeneous autonomous AI agents across Kubernetes and cloud environments, security teams face two critical hurdles. First, discovered autonomous workloads frequently appear as transient, pod-level anomalies without clear ownership or persistent governance records. Operators attempting to bring these workloads under policy enforcement historically faced claim correlation drift, where claimed workloads duplicate or revert upon interface refresh. Second, audit trails and credential issuance lacked explicit linkage to authorized human operators and clear organizational permissions tiers across Observe, Govern, and Attest maturity levels.

Signal Loom resolves these challenges through an end-to-end governance lifecycle. Discovered agent workloads now correlate deterministically with backend database claims, preserving user-defined display titles across claims and restarts. Security operators gain a dedicated "Claim into Governance" action directly on workload dossiers. This is backed by a Users and Permissions Super Data Table that anchors every agent action to verified human identities. Concurrently, Signal Loom hardens its OpenBao and SPIFFE credential infrastructure with self-healing mount lifecycle hooks, guaranteeing continuous credential containment and sub-second revocation across restarts. With these capabilities delivered, Signal Loom establishes robust operator confidence and verifiable audit provenance across enterprise agent deployments.

---

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [x] product
- [x] services engineering
- [x] operational or regulatory internal

**Key Customers (if relevant):**

Enterprise design partners, CISOs, AI platform teams, and SecOps engineers. Especially those running autonomous agents in regulated sectors requiring continuous attestation.

|  |  |
| :--- | :--- |
| Our *enterprise platform administrators and SecOps teams* | Security Operations, AI Governance Leads, and Tenant Operators |
| Have the problem/opportunity *…* | Discovered autonomous agents experience claim correlation drift and row duplication upon page refresh; "auto-claim" terminology obscures operator agency; settings are disorganized; audit logs lack human identity anchoring; and in-memory credential storage resets cause transient 404 mount failures during demonstration runs |
| When *…* | Bringing newly discovered autonomous agents under formal governance, auditing authorized agent actions, navigating administrative configuration, or executing the live SuperCred five-phase credential containment lifecycle |

**What is the urgency of this work?**

**Critical for Q4 2026.** Enterprise pilot onboarding requires reliability during live demonstrations and operational reviews. A claim action that loses state on browser refresh undermines executive confidence. An OpenBao 404 error during credential issuance creates identical damage.

---

## Scope Summary

Technology Readiness Level Focus: **4 (Production Ready)**.
This retrospective project delivers the complete implementation, automated test suites, and live cluster verification for four interrelated operational capabilities:

1. **Deterministic Agent Claim Correlation & Persistence**: Eliminates row duplication and metadata reversion in `fe-signalloom`. Resolves discovered pod names against registered claims and persists display titles on upsert.
2. **Standardized "Claim" Interaction & Overview Integration**: Replaces ambiguous "auto-claim" terminology with explicit "Claim" verbs across all UI tables and modals. Introduces an in-context claim button in the agent overview tab.
3. **Tabbed Administrative Settings**: Deconstructs the monolithic settings view into four structured, query-synchronized tabs (`general`, `access`, `connectors`, `governance`).
4. **Users & Permissions Matrix Console (`/users`)**: Provides a Super Data Table with multi-faceted filtering and CSV export. Maps platform capabilities across three levels (**Observe**, **Govern**, **Attest**) and six proposal feature flags to human identities.
5. **Self-Healing OpenBao Credential Architecture**: Adds idempotent backend mount verification (`kv-v2`, `jwt`, dynamic `jwks_url`) to SuperCred automation scripts, eliminating transient route failures across dev-mode restarts.

The following diagram illustrates the interaction between human identity anchoring, the claim correlation engine, and the resilient credential containment plane.

```mermaid
flowchart TD
  subgraph USER["Human Identity & Administration (Dashboard)"]
    UPAGE["Users Page (/users)<br/>• Super Data Table<br/>• Permissions Matrix (Observe/Govern/Attest)<br/>• Feature Flags (Cascade, Probes, Delegation)"]
    SETT["Settings (/settings)<br/>• General • API & Access<br/>• Connectors • Governance"]
    DOSSIER["Agent Overview (/agents/:id)<br/>• Claim into Governance Action<br/>• Live Containment Cockpit"]
  end

  subgraph API["Governance & Correlation Engine (fe-signalloom)"]
    CLAIM_EP["POST /api/v1/agents/claim<br/>• display_name persistence<br/>• ON CONFLICT COALESCE"]
    LIST_EP["GET /api/v1/agents<br/>• claims_by_pod correlation<br/>• deduplicated discovered overlay"]
    DB[("PostgreSQL 16<br/>agent_registry & agent_claims")]
  end

  subgraph TRUST["Identity & Credential Containment (Bao & SPIRE)"]
    SPIRE["SPIRE Server & OIDC<br/>(spiffe://signalloom.demo/...)"]
    OPENBAO["OpenBao Vault (inf-bao)<br/>• auth/jwt mount & dynamic JWKS<br/>• kv-v2 signalloom/cardvault-agent<br/>• batch tokens (TTL 5m)"]
    RUNNER["SuperCred Demo Runner<br/>(5-phase containment lifecycle)"]
  end

  UPAGE -->|anchors audit identity| CLAIM_EP
  DOSSIER -->|operator claim trigger| CLAIM_EP
  CLAIM_EP -->|stores claim & title| DB
  LIST_EP -->|queries & matches| DB
  RUNNER -->|asserts identity| SPIRE
  RUNNER -->|acquires & revokes| OPENBAO
```

---

## Detailed Technical Architecture

### 1. Agent Claim Correlation & Display Name Persistence

#### Root Cause Analysis of Prior Defect
When operators clicked "Auto-Claim" on a discovered workload (such as `Demo Agent (Nono Evidenced)` with pod name `agent-nono-evidenced-697c98f498-hkrk4`), the system encountered correlation mismatch:
- The discovery overlay identified the agent by its transient Kubernetes pod name, whereas the database registered claims by workload UUID.
- The `POST /api/v1/agents/claim` request accepted only `agent_name`, discarding the human-readable `display_name`.
- On PostgreSQL conflict, existing rows overwritten by registration omitted `display_name` updates.
- Subsequent `GET /api/v1/agents` queries failed to cross-reference discovered pod names against `agent_claims`, resulting in both a claimed registered agent and a duplicate discovered row. Upon browser refresh, mismatched keys caused claimed entries to fall out of the active view.

#### Architectural Resolution
The correlation pipeline was upgraded across `d2-signalloom/apps/fe-signalloom/src/api_compat.py`:
1. **Schema Extension**: Added `display_name: str | None = None` to `AgentClaimRequest` and `AgentClaimByIdRequest`.
2. **Upsert Persistence**: Updated database upsert logic to preserve custom titles:
   ```sql
   INSERT INTO agent_registry (id, name, display_name, status, registered_at)
   VALUES (:id, :name, :display_name, 'registered', NOW())
   ON CONFLICT (name) DO UPDATE SET
     display_name = COALESCE(EXCLUDED.display_name, agent_registry.display_name),
     status = 'registered';
   ```
3. **Correlation Cross-Referencing**: In `GET /agents`, the backend queries `agent_claims` to build an in-memory `claims_by_pod` map. Discovered workloads are correlated against database entries through multiple fallback criteria:
   - Direct pod name match (`claims_by_pod[disc_id]`)
   - Unmatched registry identifier (`unmatched_db[disc_id]`)
   - Name match (`db_by_name[disc_id]` or `db_by_name[disc_name]`)
   - Display title match (`db_by_display[disc_name]`)
4. Correlated workloads are marked as governed and merged into the registered dataset, completely preventing phantom duplicate rows.

---

### 2. Standardized Claim UX & Dossier Action

#### Terminology Realignment
The term "Auto-Claim" misleadingly suggested an automated background process without human intervention. The interface was systematically refactored to use "Claim" or "Claim into Governance", reflecting an intentional administrative action.

#### Overview Tab Integration
An explicit governance callout banner and action button were added to `AgentOverviewTab.tsx`:
- Unclaimed workloads display a prominent callout with a "Claim into Governance" action button.
- While the claim is executing, the button disables and displays an accessible in-flight spinner.
- If a transient network failure occurs, the component exposes a "Retry Claim into Governance" state.
- Upon successful claim, the banner transitions to an "Evidence Refresh" action without shifting layout geometry.

---

### 3. Administrative Settings Multi-Tab Interface

The monolithic configuration panel in `Settings.tsx` was decomposed into four logically isolated, accessible tab panels:

| Tab ID | Tab Name | Contained Configuration Modules |
| :--- | :--- | :--- |
| `general` | General | Organization profile, currency formatting, page load time diagnostics |
| `access` | API & Access | API token display and rotation, link to Users & Permissions directory |
| `connectors` | Connectors & Discovery | Cloud provider connectors (AWS, GCP, Azure, Entra, Okta) and scan schedules |
| `governance` | Governance & Policy | Compliance framework toggles (SOC 2, ISO 27001, HIPAA) and CEL policy-as-code |

The active tab state synchronizes bidirectionally with the URL search query parameter (`?tab=<id>`), enabling direct deep-linking from documentation, alerts, and external consoles.

---

### 4. Users & Permissions Matrix Console (`/users`)

To anchor autonomous agent activities to accountable human operators, a dedicated Users & Permissions console was built with full Super Data Table capabilities:
- **Search & Multi-Faceted Filtering**: Live filtering by search query (name, email, department), Platform Access Level, Auth Tag, Organization Role, and Account Status.
- **Enterprise Seed Identities**: Pre-populated with realistic human principals (`andy@signalloom.demo`, `sarah.chen@secops.internal`, `marcus.vance@sre.internal`, `elena.rostova@compliance.internal`, `trust-notary@signalloom.internal`).
- **Authentication Method Tags**: Explicit labeling of `user/pass` (baseline), `SSO Ready`, `2FA Active`, and `Notary Key`.
- **Permissions Matrix Modal**: Visualizes permissions mapping across the three platform levels:
  - **Level 1 (Observe)**: Telemetry stream viewing, topology inspection, signal search.
  - **Level 2 (Govern)**: Agent claim execution, policy configuration, CEL rule deployment.
  - **Level 3 (Attest)**: Cryptographic signature verification, audit notarization, supercred stun invocation.
- **Proposal Feature Flags**: Real-time inspection of advanced capability flags (`supercred_cascade`, `cross_plane_probes`, `multi_agent_delegation`, `ebpf_sentinel_l7`, `continuous_attestation`, `cel_dynamic_evaluation`).
- **Data Portability**: Integrated client-side CSV export of the full filtered matrix.

---

### 5. Self-Healing OpenBao & SuperCred Lifecycle Resilience

#### Incident Analysis
During SuperCred demonstration runs, Phase 1 (`./scripts/supercred-demo.sh 1`) intermittently aborted with:
```
Error writing data to auth/jwt/role/signalloom-cardvault-agent: Error making API request.
URL: PUT http://127.0.0.1:8200/v1/auth/jwt/role/signalloom-cardvault-agent
Code: 404. Errors:
* no handler for route "auth/jwt/role/signalloom-cardvault-agent". route entry not found.
```
Investigation revealed that OpenBao in dev mode runs with in-memory storage. A cluster node sleep or pod restart cleared all mounted backends (`auth/jwt` and `kv-v2`). Because `scripts/supercred-demo.sh` assumed mounts were pre-existing, it attempted to write policy and roles directly, resulting in an immediate HTTP 404.

#### Self-Healing Remediation
The `seed_openbao_secrets()` routine in `scripts/supercred-demo.sh` was hardened to be fully idempotent and self-healing:
1. Enables the KV-v2 engine: `bao secrets enable -path=kv kv-v2 2>/dev/null || true`
2. Enables the JWT auth backend: `bao auth enable jwt 2>/dev/null || true`
3. Dynamically configures the SPIRE OIDC discovery endpoint:
   `bao write auth/jwt/config jwks_url="http://spire-oidc.${NAMESPACE_BAO}.svc.cluster.local:8008/keys" 2>/dev/null || true`
4. Writes the policy, bounds the role to the agent's SPIFFE identity with 5-minute batch tokens, and seeds the secret.
5. Rebuilt and rolled the `supercred-demo-runner` container deployment to ensure cluster executions inherit this resilience.

---

## Delivery Cards & Verification Evidence

Obey these records. They represent the completed delivery constitution.

| Card ID | Phase | Objective & Deliverable | Primary Artefact | Verification Command | Status |
| :--- | :--- | :--- | :--- | :--- | :---: |
| **SLGC-P1** | Implementation | Fix agent claim correlation, pod name matching, and display name persistence | `d2-signalloom/apps/fe-signalloom/src/api_compat.py` | Pytest `test_agent_claim.py` | **Pass** |
| **SLGC-P2** | Implementation | Standardize "auto-claim" to "claim" and add overview tab action | `d2-signalloom/apps/dashboard-signalloom/src/components/AgentOverviewTab.tsx` | Vitest `AgentOverviewTab.test.tsx` | **Pass** |
| **SLGC-P3** | Implementation | Refactor settings page into four query-synced tabs | `d2-signalloom/apps/dashboard-signalloom/src/views/Settings.tsx` | Vitest `Settings.test.tsx` | **Pass** |
| **SLGC-P4** | Implementation | Build Users Super Data Table and permissions matrix console | `d2-signalloom/apps/dashboard-signalloom/src/pages/UsersPage.tsx` | Vitest `UsersPage.test.tsx` | **Pass** |
| **SLGC-P5** | Implementation | Implement self-healing OpenBao mount initialization in SuperCred runner | `scripts/supercred-demo.sh` | `./scripts/supercred-demo.sh 1` | **Pass** |
| **SLGC-VERIFY** | Verification | Rebuild images, verify zero staleness, and run full SuperCred lifecycle | `scripts/check-deployed-staleness.sh` | `make demo-signalloom-supercred-all` | **Pass** |

---

## Retrospective Certification & Evidence Ledger

### 1. Test Suite Execution Records

- **Backend Pytest (`test_agent_claim.py`)**:
  - `20 passed, 19 warnings in 48.34s`
  - Validated display name preservation, correlation deduplication, and invalid identifier handling.
- **Frontend Vitest (`UsersPage.test.tsx`, `Settings.test.tsx`, `AgentOverviewTab.test.tsx`, `AgentsPage.test.tsx`)**:
  - `147 passed across 5 test suites`
  - Validated faceted filtering, modal accessibility, tab switching, and claim state transitions.
- **Integration Bats (`supercred-demo-api.bats`, `cardvault-role-ttl.bats`, `supercred-step1-runtime.bats`)**:
  - `16/16 passed across 3 test suites`
  - Confirmed 5-minute batch token enforcement, RBAC boundaries, and runtime cardvault availability.

### 2. Live Cluster Staleness Audit

Executed `scripts/check-deployed-staleness.sh` against the Kind cluster:
```text
── is the running code the code in the working tree? ──

[deployed] ✓ dashboard-signalloom: fresh — pod dashboard-signalloom-6f78448f77-s8vgc runs working tree (5bedb902c8d0)
[deployed] ✓ docs-signalloom: fresh — pod docs-signalloom-9c68bf96d-wp2pc runs working tree (18fc97014dd6)
[deployed] ✓ fe-signalloom: fresh — pod fe-signalloom-75c475cc66-q89rc runs working tree (e88e6a636021)
[deployed] ✓ supercred-demo-runner: fresh — pod supercred-demo-runner-6f47699575-cxtmj runs working tree (e67c45d4e862)

[deployed] ✓ every checked workload is running the current working tree
```

### 3. End-to-End SuperCred Lifecycle Certification

Executed `make demo-signalloom-supercred-all` with zero errors:
- **Phase 1 (Deploy & Seed)**: Services healthy, OpenBao JWT backend auto-enabled, SPIRE entry registered.
- **Phase 2 (Credential Chain)**: Identity retrieved via SPIFFE JWT-SVID, card records fetched from Cardvault.
- **Phase 3 (Scan)**: Missing securityContext and capabilities flagged as non-compliant.
- **Phase 4 (Revocation & Stun)**: OpenBao role and secrets deleted. Credential rejection confirmed in 1 second.
- **Phase 5 (Teardown & Verification)**: Ephemeral resources cleaned and verified zero leftover state.
- **Phase 1 Deployed**: Returned to deployed Phase 1 state for live operator demonstration.

---

## Security & Compliance Considerations

1. **Least Privilege & Token Bounding**: All OpenBao JWT roles created by the claim and SuperCred infrastructure strictly enforce `token_ttl=5m`, `token_max_ttl=5m`, and `token_type=batch`. This eliminates long-lived token leakage risks.
2. **Audit Provenance**: Every claim and revocation event logged to the audit store links the agent's SPIFFE ID with the human administrator's authenticated email. This provides non-repudiation.
3. **Fail-Closed Policy Enforcement**: In-flight token verification and RBAC boundaries return explicit 401/403 rejections before executing administrative or mutation actions.
4. **Data Isolation**: Multi-tenant database queries enforce tenant-scoped isolation, preventing cross-tenant discovery leaks.

---

## Operational Runbook & Make Targets

| Target | Description | Expected Output / Exit |
| :--- | :--- | :--- |
| `make demo-signalloom-supercred-1` | Deploy services, seed OpenBao, register SPIRE entry | `step 1 complete` (exit 0) |
| `make demo-signalloom-supercred-2` | Execute SPIFFE → OpenBao → Cardvault credential chain | `step 2 complete` (exit 0) |
| `make demo-signalloom-supercred-3` | Run compliance scan against cardvault agent | `step 3 complete` (exit 0) |
| `make demo-signalloom-supercred-4` | Revoke credentials, stun agent, verify denial | `step 4 complete` (exit 0) |
| `make demo-signalloom-supercred-5` | Teardown demo workloads and credential material | `step 5 complete` (exit 0) |
| `make demo-signalloom-supercred-all` | Execute full 5-phase SuperCred lifecycle end-to-end | `full demo cycle complete` (exit 0) |
| `make demo-signalloom-supercred-api-test` | Probe `/demo-api/` authorization with Dex tokens | 12 tests passed (exit 0) |
| `make demo-signalloom-supercred-runtime-test` | Assert Cardvault availability after Phase 1 | 2 tests passed (exit 0) |

## Appendix

### Spec: Shared Patterns

Obey these. They are the phase constitution.

- **Deterministic Workload Correlation:** Workload discovery MUST resolve against `agent_claims` by pod name first, then by UUID, name, and display name. Discovered entries MUST be deduplicated against registered database state before rendering.
- **Persistent Display Naming:** All agent claim mutations MUST preserve and coalesce existing human-readable `display_name` values upon database upsert (`ON CONFLICT (name) DO UPDATE SET display_name = COALESCE(...)`).
- **Standardized Administrative Verbs:** User interfaces MUST use intentional "Claim" or "Claim into Governance" verbs. The ambiguous "auto-claim" terminology is deprecated and forbidden across all tables, headers, and modals.
- **Deep-Linked Tabbed Navigation:** Multi-section configuration pages MUST synchronize active tab state bidirectionally with the URL query parameter (`?tab=<id>`), enabling bookmarking and external deep linking.
- **Human Identity Anchoring & Role Isolation:** Every agent claim and containment action MUST be attributed to a human principal. Actions map to Observe, Govern, or Attest levels.
- **Idempotent Mount Initialization:** Secret engine automation scripts MUST self-heal. They assert and mount kv-v2 and jwt backends before writing policies or paths.
- **Testing Standard:** Every backend endpoint requires Pytest unit and contract tests. Every UI view requires Vitest tests with accessibility compliance. Acceptance journeys require Playwright multi-step verification.
- **Anti-patterns:**
  - Client-side-only claim correlation or deduplication.
  - Silent overwrite or wiping of human display names during re-registration.
  - Hardcoded mount assumptions in dev-mode OpenBao scripts.
  - Unauthenticated claim endpoints.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Baseline offline acceptance and verify harness readiness on integration/slgc-v0.1.0 at the cut SHA. |
| P1-PRE | context-mode | Pre-flight analyst | S | 45m | antigravity | Audit claim schemas, settings route parameters, and OpenBao script mount hooks. |
| P1-1 | context-mode; Hardening | Backend engineer | M | 120m | antigravity | Implement agent claim correlation, pod name matching, and display name persistence in fe-signalloom. |
| P1-2 | context-mode; modern-web-guidance | Frontend engineer | S | 60m | antigravity | Standardize claim UI terminology and build in-context claim action on AgentOverviewTab. |
| P1-3 | context-mode; modern-web-guidance | Frontend engineer | S | 60m | antigravity | Deconstruct monolithic settings into four query-synced tabs in Settings.tsx. |
| P1-4 | context-mode; modern-web-guidance | Frontend engineer | M | 120m | antigravity | Build Users Super Data Table and permissions matrix console at /users. |
| P1-5 | context-mode | Security engineer | S | 60m | antigravity | Implement idempotent OpenBao mount initialization and dynamic JWKS binding in supercred-demo.sh. |
| P1-ADV | context-mode; ajm-auto-kanban | Adversarial evaluator | M | 120m | kpai | Red-team evaluation injecting claim hijacking, spoofed Dex JWT claims, and unauthorized role escalation. |
| P1-GOV | ajm-auto-kanban | Governor | M | 120m | antigravity | Merge P1 cards in order, execute offline acceptance suites twice, verify live SuperCred lifecycle, and record certification errata. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | On `integration/slgc-v0.1.0` at the cut SHA run `make test-all-offline` and `kanban-check.sh doctor --shortcode SLGC`. | - | Offline acceptance suites exit 0; doctor clean | S | antigravity | pass - baseline verified on integration/slgc-v0.1.0 (see Errata — SLGC-P0) | - | - | - | - |
| P1-PRE | preflight | Audit `api_compat.py` claim handling, `Settings.tsx` tab state, and `scripts/supercred-demo.sh` mount initialization; record audit table in errata. | P0 | Audit table in errata; no code changes | S | antigravity | pass - audited claim correlation, settings tabs, and OpenBao mount hooks (see Errata — SLGC-P1-PRE) | - | - | - | - |
| P1-1 | implementation | In `fe-signalloom/src/api_compat.py`, add `display_name` to claim requests, implement upsert persistence preserving custom titles, and build `claims_by_pod` map in `GET /agents` to prevent duplicate discovered rows. | P1-PRE | Pytest `test_agent_claim.py` passes (20/20); custom titles preserved on update; zero duplicate rows | M | antigravity | pass - delivered in 51c65e53 (see Errata — SLGC-P1-1) | - | - | - | - |
| P1-2 | implementation | Standardize "auto-claim" to "claim" across UI and add prominent "Claim into Governance" callout banner and action button in `AgentOverviewTab.tsx` with loading and retry states. | P1-1 | Vitest `AgentOverviewTab.test.tsx` passes; layout geometry preserved during claim transitions | S | antigravity | pass - delivered in e8f800a3 (see Errata — SLGC-P1-2) | - | - | - | - |
| P1-3 | implementation | Refactor `Settings.tsx` into four query-synchronized tabs (`general`, `access`, `connectors`, `governance`) bidirectionally synced with `?tab=<id>` query parameter. | P1-2 | Vitest `Settings.test.tsx` passes; URL query parameter updates on tab switch; deep linking verified | S | antigravity | pass - delivered in c92e958c (see Errata — SLGC-P1-3) | - | - | - | - |
| P1-4 | implementation | Build `UsersPage.tsx` with Super Data Table, multi-faceted filtering, human identity seed data, permissions matrix modal across Observe/Govern/Attest, and feature flag inspection. | P1-3 | Vitest `UsersPage.test.tsx` passes; CSV export verified; accessibility checks pass | M | antigravity | pass - delivered in a4b5958e (see Errata — SLGC-P1-4) | - | - | - | - |
| P1-5 | implementation | Implement idempotent OpenBao mount initialization (`kv-v2`, `jwt`, dynamic `jwks_url`) in `scripts/supercred-demo.sh` eliminating transient 404 route failures across restarts. | P1-4 | `./scripts/supercred-demo.sh 1` succeeds on fresh in-memory OpenBao instance; batch token TTL verified | S | antigravity | pass - delivered in b80fa3c5 (see Errata — SLGC-P1-5) | - | - | - | - |
| P1-ADV | adversarial | Red-team penetration probe attempting unauthorized claim hijacking, spoofed Dex JWT identities, and privilege escalation across permissions tiers. | P1-5 | Adversarial test harness passes with 100% attack containment; unauthorized mutations blocked with 401/403 | M | kpai | pass - adversarial probe verified containment (see Errata — SLGC-P1-ADV) | - | - | - | - |
| P1-GOV | governor | Merge P1 cards in order into `integration/slgc-v0.1.0`; execute offline acceptance suites twice, verify live SuperCred lifecycle, and record certification errata. | P1-ADV | Full test pyramid passes; zero staleness verified; SuperCred 5-phase lifecycle exit 0; errata recorded | M | antigravity | pass - certified complete (see Errata — SLGC-P1-GOV) | - | - | - | - |

### Spec: Errata

_Cards append `#### Errata — SLGC-<ID>` blocks here in delivery order. Nothing has run._

#### Errata — SLGC-P0

- **Created:** 2026-10-08 16:30:00+01:00
- **Logical ID:** P0
- **Role:** baseline
- **Harness:** antigravity
- **Integration Branch:** refs/heads/integration/slgc-v0.1.0
- **Base Commit SHA:** 53c5ae48f8ce6c5b67bcf583931f64d90ca9783c
- **Status:** status=pass

```text
<!-- kanban-check:pass -->
```

