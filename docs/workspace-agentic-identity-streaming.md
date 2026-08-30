# Google Workspace Agentic Identity Streaming — Research Synthesis

> Deep research: how OSRAMP ingests Workspace activity as a stream, monitors
> agentic identities for misbehaviour, and executes the revocation chain
> (supercredential revoke → identity block → runtime controls).
>
> Date: 2026-08-25 | Status: Research complete, pending stress-test

## Executive Summary

Google Workspace was designed for human users with browsers. Service accounts
(and thus AI agents) authenticate via a parallel path that **bypasses most
user-facing controls** — Context-Aware Access, device compliance, session
management. The strongest Workspace-native control that applies to service
accounts is DLP, and DLP cannot block reads. No competitor bridges
cryptographic agent identity → scoped Workspace credentials → behavioural
monitoring → automated revocation. OSRAMP's SPIRE/OpenBao/SuperCred model is
architecturally unique here.

The key architectural move: **make OpenBao the credential gateway for Workspace
access**, so every agent's Workspace token is short-lived, scope-bounded,
SPIFFE-attested, and revocable — extending the SuperCred model from Kubernetes
to SaaS.

---

## Part 1: Google Workspace API Surface

### 1.1 Activity Ingestion — Three Paths

| Path | Mechanism | Latency | Coverage | Service Account Visibility |
|------|-----------|---------|----------|---------------------------|
| **Near-real-time** | Workspace Events API → Pub/Sub | 1–5 seconds | Chat, Meet, Drive (GA/Preview). NOT Gmail, Calendar | Events describe the resource change, not the actor. Must correlate with Reports API for attribution |
| **Audit polling** | Admin SDK Reports API | Minutes (Admin/Drive/Gmail) to hours (Calendar/OAuth) | ALL Workspace services. 180-day retention | `actor.callerType=KEY` for service accounts. **Critical caveat:** DWD impersonation logs as the impersonated user |
| **Analytics** | BigQuery export via Cloud Logging | Batch | All audit log types. Indefinite retention | Same attribution model as Reports API |

**Gmail and Calendar** have their own push mechanisms (`watch()`) that deliver
to Pub/Sub but are not part of the Workspace Events API. A complete ingestion
layer needs all three: Events API for Chat/Meet/Drive, `watch()` for
Gmail/Calendar, Reports API polling as the comprehensive fallback.

### 1.2 The DWD Impersonation Blind Spot

When a service account uses domain-wide delegation to impersonate a user,
**Workspace logs attribute the action to the impersonated user, not the service
account**. The only mechanisms to unmask the true actor:

1. `applicationInfo.oauthClientId` — present on some audit events (2026+)
2. `applicationInfo.impersonation` — boolean flag, new in 2026, not universally populated
3. OAuth Token log correlation — join activity logs with token grant logs on timestamp + user
4. **OSRAMP's own audit trail** — if all Workspace credentials are issued through OpenBao, OSRAMP knows which SPIFFE-attested agent requested which token, regardless of what Workspace logs show

Option 4 is the architectural winner. It means OSRAMP doesn't need to unmask
DWD at the Workspace layer because it has its own attribution chain from
credential issuance.

### 1.3 Detection Signals

| Source | What it sees | Programmatic | Latency |
|--------|-------------|-------------|---------|
| **SCC Event Threat Detection** | Anomalous SA impersonation, credential leaks, unusual API volume, dormant SA reactivation | YES (Findings API, Pub/Sub export) | Seconds to minutes |
| **Workspace Alert Center** | DLP violations, suspicious logins, admin changes, OAuth grants | YES (v1beta1 API, retrieval only) | Minutes |
| **Reports API activity patterns** | Volume spikes, scope drift, off-hours access, sensitive file access | YES (polling) | Minutes to hours |
| **DLP rule violations** | Content matching sensitive patterns in Drive/Gmail/Chat | YES (Policy API, June 2026) | Near-real-time |

**SCC is the best detection layer** — it applies ML-based anomaly detection to
Workspace logs and produces findings. But it's detection-only; enforcement
requires a separate action. That action is where OSRAMP lives.

---

## Part 2: Revocation Chain

### 2.1 Enforcement Mechanisms (fastest to slowest)

| # | Action | Latency | Programmatic | Scope | Reversible |
|---|--------|---------|-------------|-------|------------|
| 1 | `serviceAccounts.disable` | **Immediate** | YES (`gcloud iam service-accounts disable`) | Kills ALL auth including DWD | YES (`enable`) |
| 2 | `serviceAccountKeys.disable` | Immediate | YES (IAM API) | Single key | YES |
| 3 | Remove IAM role bindings | Immediate (new requests); 3-min cache for existing tokens | YES (`setIamPolicy`) | Specific permissions | YES |
| 4 | Revoke OAuth tokens | 3-minute propagation (cached) | YES (`POST oauth2.googleapis.com/revoke`) | Token chain | NO (new token needed) |
| 5 | Delete DWD entry | Immediate | **NO — Admin Console only** | All DWD scopes | YES (re-create) |
| 6 | Edit DWD scopes | **Up to 24 hours** | **NO — Admin Console only** | Specific scopes | YES |
| 7 | Dynamic DLP rules | Minutes | YES (Policy API, June 2026) | Content patterns | YES (delete rule) |

**The critical asymmetry:** The kill switch (`serviceAccounts.disable`) is fast
and programmatic. Surgical scope adjustment (DWD scope editing) is slow and
manual. This means OSRAMP's automated response must favour the blunt instrument
(disable) over the scalpel (scope edit) for time-critical incidents.

### 2.2 OSRAMP Stun Cascade — Workspace Extension

Extending the existing SuperCred "stun" pattern to Workspace:

```
Misbehaviour detected (Workspace activity stream)
    │
    ├─→ Policy engine evaluates against agent risk profile + data classification
    │
    ├─→ Decision: grace period OR immediate stun
    │
    └─→ STUN executes (sub-second):
         1. serviceAccounts.disable via IAM API (immediate, kills all DWD)
         2. Revoke OpenBao lease for this agent's Workspace credentials
         3. Create dynamic DLP rules via Policy API (block residual sharing)
         4. Update SuperCred state: STUNNED — WORKSPACE ACCESS REVOKED
         5. FAIR engine recalculates fleet risk exposure
         6. Dashboard updates live (existing poll mechanism)
```

**Recovery path:**
1. Re-enable SA (`serviceAccounts.enable`)
2. Re-issue OpenBao credential with same or restricted scopes
3. Remove emergency DLP rules
4. SuperCred state: STUNNED → ACTIVE

### 2.3 What OSRAMP Cannot Do (Workspace Gaps)

| Gap | Why | Workaround |
|-----|-----|-----------|
| Block reads via DLP | DLP controls sharing/exfiltration, not reading | Disable the SA entirely |
| Apply Context-Aware Access to SAs | Google explicitly excludes SAs from CAA | Use OpenBao as the access gate instead |
| VPC-SC for Workspace APIs | VPC-SC only covers Cloud services | Proxy Workspace access through Cloud resources behind VPC-SC |
| Programmatic DWD management | No API exists | Disable the SA instead (faster and more comprehensive) |
| Govern non-Google-Cloud agents inline | Agent Gateway only covers GCP agents | SPIRE + OpenBao works regardless of agent runtime location |

---

## Part 3: Architecture Mapping to OSRAMP

### 3.1 Current Architecture

```
Kubernetes Pod → SPIRE (attestation) → OpenBao (credential) → Secret (access)
                     ↓                       ↓
               Policy Engine          SuperCred State
               (compliance)           (lifecycle mgmt)
                     ↓                       ↓
               FAIR Engine            SignalLoom Dashboard
               (risk £)              (visualisation)
```

### 3.2 Proposed Workspace Extension

```
                    ┌──────────────────────────────────────────┐
                    │         Workspace Connector              │
                    │  ┌─────────┐ ┌──────────┐ ┌──────────┐  │
                    │  │Events   │ │Reports   │ │SCC       │  │
                    │  │API      │ │API       │ │Findings  │  │
                    │  │(Pub/Sub)│ │(polling) │ │(Pub/Sub) │  │
                    │  └────┬────┘ └────┬─────┘ └────┬─────┘  │
                    │       └───────────┼────────────┘         │
                    │                   ↓                      │
                    │        Normalised Event Stream           │
                    └──────────────────┬───────────────────────┘
                                       ↓
                    ┌──────────────────────────────────────────┐
                    │      Behavioural Anomaly Detector        │
                    │  Volume │ Scope  │ Sensitive │ Collusion │
                    │  spikes │ drift  │ data      │ patterns  │
                    └──────────────────┬───────────────────────┘
                                       ↓
┌──────────────┐   ┌──────────────────────────────────────────┐
│ Agent ID     │   │           Policy Engine                  │
│ Registry     │──→│  Compliance eval + FAIR risk scoring     │
│ SPIFFE ↔     │   │  (extends existing Go policy-engine)     │
│ GCP SA ↔     │   └──────────────────┬───────────────────────┘
│ Workspace    │                      ↓
│ scopes       │   ┌──────────────────────────────────────────┐
└──────────────┘   │      Workspace Enforcement Controller    │
                   │  1. serviceAccounts.disable (immediate)  │
       ↑           │  2. OpenBao lease revocation             │
       │           │  3. Dynamic DLP via Policy API           │
       │           │  4. SuperCred state transition           │
       │           └──────────────────┬───────────────────────┘
       │                              ↓
┌──────────────┐   ┌──────────────────────────────────────────┐
│ OpenBao      │   │         SignalLoom Dashboard             │
│ GCP Secrets  │   │  Workspace activity stream view          │
│ Engine       │   │  Agent-to-Workspace access map           │
│ (credential  │   │  Workspace risk exposure (FAIR £)        │
│  gateway)    │   └──────────────────────────────────────────┘
└──────────────┘
```

### 3.3 OpenBao as the Workspace Credential Gateway

This is the central architectural move. OpenBao's GCP Secrets Engine can
generate OAuth2 access tokens on demand:

1. Configure with a SA that has `iam.serviceAccountTokenCreator` role
2. Define roles specifying which SA to impersonate and which scopes
3. Agent authenticates via JWT (SPIFFE SVID) → OpenBao validates attestation
4. OpenBao generates a short-lived OAuth token (minutes, not hours)
5. Agent uses token to access Workspace APIs
6. Token expires; agent must re-request through OpenBao

**What this achieves:**
- Every Workspace access is SPIFFE-attested and logged in OpenBao's audit trail
- Tokens are minutes-lived, not hours-lived (reduces blast radius)
- OpenBao lease revocation instantly invalidates the credential chain
- Policy engine can evaluate each credential request against risk state
- The DWD impersonation blind spot is irrelevant — OSRAMP's own audit trail
  has the attribution chain from SPIFFE ID → credential request → Workspace token

**Workload Identity Federation bridge** (for non-GCP agents):
1. Agent presents its SPIFFE JWT-SVID
2. GCP Workload Identity Federation validates it (SPIRE is a supported OIDC provider)
3. Maps to a GCP service account
4. OpenBao issues a scoped Workspace token via that SA

This means OSRAMP governs agents regardless of where they run.

### 3.4 New Components Required

| Component | Type | What It Does | Maps To |
|-----------|------|-------------|---------|
| **Workspace Connector** | Go service | Ingests Workspace activity via Events API, Reports API, SCC. Normalises events. Publishes to internal bus | New; pattern matches existing policy-engine service |
| **Agent Identity Registry** | Extension of SuperCred types | Maps SPIFFE ID ↔ GCP SA ↔ Workspace scopes. Tracks DWD grants per agent | Extends `credentialInventory.ts` and `supercredTypes.ts` |
| **Behavioural Detector** | Go service or extension of policy-engine | Detects volume spikes, scope drift, sensitive data access, collusion | Extends AFM's analysis model to Workspace permissions |
| **Workspace Enforcement Controller** | Go service | Executes revocation chain: SA disable, token revoke, DLP creation | New; maps to `supercred-demo.sh` stun pattern |
| **OpenBao GCP Secrets Engine config** | Infrastructure (Terraform/Kustomize) | Configures OpenBao to broker Workspace credentials | Extends existing `inf-bao` Kustomize base |
| **SuperCred `workspace-delegation` kind** | Type extension | New credential kind alongside `openbao-lease` | Extends `CredentialKind` in `credentialInventory.ts` |
| **Dashboard Workspace views** | React pages | Activity stream, access map, Workspace risk exposure | New pages in SignalLoom dashboard |

### 3.5 Behavioural Signals for Workspace Agents

| Signal | Detection Method | Risk Level | Response |
|--------|-----------------|------------|----------|
| **Volume anomaly** | Reports API — agent accessing 10× baseline file count | Medium → High | Grace period, then restrict scopes |
| **Scope drift** | OpenBao audit — agent requesting credentials for undeclared scopes | High | Deny credential, alert |
| **Sensitive data access** | DLP violation event from Policy API | Critical | Immediate stun |
| **External sharing** | Drive audit — agent sharing files outside org | Critical | Immediate stun + DLP rule |
| **Lateral movement** | Reports API — agent impersonating users outside its configured set | Critical | Immediate SA disable |
| **Credential abuse** | OpenBao audit — agent requesting tokens at unusual rate | High | Rate-limit at OpenBao, alert |
| **Collusion** | AFM analysis — agents with complementary scopes coordinating | High | Stun both agents in cascade |

### 3.6 AFM Extension for Workspace

AFM currently analyses Kubernetes RBAC (subjects, roles, bindings) for attack
paths and collusion. Extending to Workspace means adding OAuth scopes and DWD
grants to the graph:

- **Node types:** Agent (SPIFFE ID), Workspace User (impersonated), Drive File,
  Gmail Mailbox, Calendar, OAuth Scope
- **Edge types:** `has_delegation` (SA → User), `has_scope` (SA → Scope),
  `accessed` (Agent → File), `shared_with` (File → External)
- **Collusion detection:** "Agent A has Drive.readonly scope and Agent B has
  Gmail.send scope — together they can exfiltrate Drive content via email"
- **Attack path analysis:** "Agent with `admin.directory.user.readonly` scope
  can enumerate all users, enabling targeted impersonation"

---

## Part 4: Competitive Positioning

### 4.1 The Six Gaps OSRAMP Fills

| # | Gap | Current State | OSRAMP's Answer |
|---|-----|--------------|-----------------|
| 1 | **Cryptographic agent identity across heterogeneous SaaS** | Google Agent Identity: Gemini agents only. Everyone else: OAuth tokens / SA keys | SPIRE issues SPIFFE IDs to ANY agent → WIF → scoped Workspace SA |
| 2 | **Policy-as-code for agent access** | All competitors: console-click governance | OPA/Rego policies in git, evaluated at credential-issuance time |
| 3 | **Short-lived, scoped credentials** | Static DWD grants, long-lived tokens | OpenBao issues minute-lived tokens bound to SPIFFE attestation |
| 4 | **Cross-SaaS delegation chains** | No product tracks these | SPIFFE ID → OpenBao credential → Workspace token. Full chain auditable |
| 5 | **Risk scoring tied to credential posture** | Reco: app-level risk. WitnessAI: network-level | FAIR Monte Carlo on credential state: scope count, TTL, rotation age, attestation freshness |
| 6 | **Regulatory compliance evidence** | Dashboards and reports | Cryptographic proof: SPIFFE attestation + OpenBao audit log + policy-as-code |

### 4.2 Competitive Moat

What this proves that Reco, Obsidian, WitnessAI, and Google's own Agent
Identity cannot show:

1. **Cross-platform identity attestation** — the same SPIFFE ID governs an
   agent's Kubernetes access AND its Workspace access. One stun revokes both.
2. **Credential-layer enforcement** — competitors discover and monitor; OSRAMP
   controls issuance. An agent that never gets a credential cannot misbehave.
3. **Quantified risk in pounds** — not traffic lights. FAIR Monte Carlo on
   live agent state including Workspace credential posture.
4. **Policy-as-code** — agent access rules are git-versioned, PR-reviewed,
   CI-tested. No other product versions agent access policy.
5. **Attribution through credential issuance** — solves the DWD impersonation
   blind spot without relying on Google's incomplete `applicationInfo` fields.

### 4.3 Market Context

- AI systems security: projected $0 → $8B by 2030 (Dell'Oro Group)
- 82% of organisations have unknown agents in their environment (CSA 2026)
- 144:1 NHI-to-human ratio in enterprise SaaS (Obsidian Security)
- 68% cannot distinguish agent from human activity (CSA 2026)
- EU AI Act high-risk obligations took effect 2026-08-02
- Notable M&A: Cisco/Astrix ~$400M, SailPoint/Entro ~$200M, Check Point/Lakera ~$300M

---

## Part 5: Demo Narrative Extension

### The Workspace Beat (extends "The Seven Minutes")

> "You have 12 AI agents with Google Workspace access. One starts accessing
> files it was never supposed to see. In 900 milliseconds, its service account
> is disabled, its OpenBao credentials are revoked, and dynamic DLP rules
> prevent any residual data exfiltration. The board-level risk exposure
> recalculates live. Your compliance officer sees the cascade on her phone.
> Nobody touched a keyboard."

**Phase sequence:**
1. **Deploy** — 3 agents registered with SPIFFE IDs, each mapped to a scoped
   Workspace SA via OpenBao's GCP Secrets Engine
2. **Credential Chain** — agents fetch short-lived Workspace tokens through
   OpenBao. Credential Inventory shows Workspace credentials alongside
   Kubernetes credentials
3. **Activity Stream** — Workspace Connector shows agent activity in real time.
   Normal baseline establishes
4. **The Anomaly** — one agent accesses 50 sensitive files in 10 seconds
   (volume spike + sensitive data pattern)
5. **The Stun** — SA disabled, OpenBao lease revoked, DLP rule created.
   Agent's Workspace access dies in sub-second. Risk gauge recalculates
6. **Cross-Platform Cascade** — same agent's Kubernetes credentials also
   revoked (one SPIFFE ID, both platforms stunned)

---

## Part 6: Implementation Considerations

### 6.1 Phase 1 — Credential Gateway (foundation, 3–4 weeks)

- Configure OpenBao GCP Secrets Engine for Workspace SA token issuance
- Extend SuperCred types with `workspace-delegation` credential kind
- Agent Identity Registry: SPIFFE ID ↔ GCP SA ↔ Workspace scopes mapping
- Extend Credential Inventory page with Workspace credentials
- Unit tests for credential lifecycle

### 6.2 Phase 2 — Activity Ingestion (streaming, 2–3 weeks)

- Workspace Connector service (Go) consuming Events API + Reports API
- Pub/Sub subscription for near-real-time events
- Event normalisation and internal bus
- Dashboard: Workspace activity stream view
- Integration tests against Workspace sandbox

### 6.3 Phase 3 — Behavioural Detection (intelligence, 3–4 weeks)

- Behavioural Anomaly Detector extending policy engine
- Signal definitions: volume, scope drift, sensitive data, collusion
- SCC findings ingestion via Pub/Sub
- FAIR risk recalculation including Workspace credential posture
- AFM extension: Workspace permissions in the access graph

### 6.4 Phase 4 — Enforcement (the stun, 2–3 weeks)

- Workspace Enforcement Controller (SA disable, token revoke, dynamic DLP)
- SuperCred stun cascade extended to Workspace
- Cross-platform cascade: one SPIFFE ID, both platforms stunned
- Recovery workflow
- End-to-end demo script

### 6.5 Phase 5 — Agent Gateway Integration (future, depends on GA)

- Google Agent Gateway integration when it exits Private Preview
- Semantic Governance Policies for inline agent traffic control
- Model Armor integration for prompt/response inspection
- This phase is Google-Cloud-only and complements (not replaces) Phases 1–4

### 6.6 Prerequisites

- Google Workspace Business Plus or Enterprise (for audit log APIs)
- Admin SDK API enabled in GCP project
- Service account with domain-wide delegation for:
  - `admin.reports.audit.readonly` (activity monitoring)
  - `admin.directory.user.readonly` (user enumeration for DWD mapping)
- OpenBao GCP Secrets Engine configured with `iam.serviceAccountTokenCreator`
- SCC Premium tier (for Event Threat Detection signals)

---

## Part 7: Risk Assessment

### 7.1 Technical Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| DWD scope edit propagation delay (up to 24h) | Surgical scope reduction is slow | Use SA disable (immediate) for all automated responses |
| OAuth token 3-minute cache | Revoked token may still work briefly | SA disable kills token validation at source, not just revocation |
| Google may deprecate/change APIs | Ingestion layer breaks | Abstract behind connector interface; Events API is GA for Chat/Meet |
| Agent Gateway may not reach GA | Phase 5 blocked | Phases 1–4 don't depend on Agent Gateway |
| Workspace Events API doesn't cover all services | Incomplete real-time coverage | Reports API polling fills gaps (Gmail, Calendar) |

### 7.2 Business Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Google's Agent Identity becomes cross-platform | Reduces OSRAMP's unique value | OSRAMP's policy-as-code + FAIR risk quantification remain unique |
| Reco or Obsidian adds credential governance | Competitor parity | They'd need to build SPIRE + OpenBao equivalent; years of catch-up |
| Customers want Microsoft 365 not Workspace | Wrong SaaS target | Architecture is SaaS-agnostic; swap Workspace Connector for M365 Connector |
| EU AI Act enforcement is weak | Reduces compliance urgency | NIST AI RMF and banking regs (SR 11-7) drive demand independently |

---

## Appendix: Key API References

| API | Purpose | Auth Model |
|-----|---------|-----------|
| Workspace Events API | Push-based resource change events | OAuth 2.0 (user or DWD SA) |
| Admin SDK Reports API | Audit log retrieval | DWD SA impersonating super admin |
| Workspace Policy API | DLP rule CRUD (mutate GA June 2026) | DWD SA impersonating super admin |
| Alert Center API | Security alert retrieval (v1beta1) | DWD SA |
| IAM API | SA disable/enable, key management | GCP IAM credentials |
| Cloud SCC API | Threat findings retrieval and export | GCP IAM credentials |
| Access Context Manager API | VPC-SC and access level management | GCP IAM credentials |
| Agent Gateway API (Private Preview) | Agent traffic governance policies | GCP IAM credentials |

## Appendix: Standards Landscape

| Standard | Status (Aug 2026) | Relevance |
|----------|-------------------|-----------|
| **MCP** (Model Context Protocol) | De facto standard, 110M+ monthly downloads | Agent-to-tool communication. OSRAMP could inspect MCP traffic |
| **A2A** (Agent-to-Agent) | v1.0, Linux Foundation, 150+ orgs | Agent-to-agent discovery. OSRAMP could validate agent cards |
| **IETF WIMSE** | Active drafts (Agent Auth Profile, Transaction Tokens) | Future standard for agent identity. OSRAMP's SPIFFE model aligns |
| **SPIFFE/SPIRE** | Mature, CNCF graduated | OSRAMP's identity layer. Google uses it for Agent Identity |
| **OpenID AIIM** | Community Group, interop demos | MCP + open identity standards. Watch for convergence |
