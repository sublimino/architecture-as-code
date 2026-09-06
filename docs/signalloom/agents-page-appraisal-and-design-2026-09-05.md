# Agents page: evidence appraisal and redesign

**For:** Andrew Martin · **Date:** 5 September 2026 · **Status:** design for review, not implemented.

## Recommendation

Make `/agents` the operational index into Signal Loom: **what is this actor, where is it running, who is responsible, what evidence do we have, and does it need intervention?** Make `/agents/:id` its evidence dossier. Do not turn the list into another cryptography dashboard or put an unexplained posture percentage at its centre.

The missing columns are mostly a data integration problem, not a layout problem. The current list concatenates Kubernetes discovery with PostgreSQL registration without reconciling them. It then gives discovered records empty governance values. A redesign must repair that contract before decorating those values.

### Evidence boundary

- Source inspected at checkout HEAD `2efc851d`; uncommitted unrelated work was present and left untouched.
- The supplied `https://ftna-signalloom.taild4da3.ts.net/agents` returned HTTP 200 HTML with successful certificate verification. That proves HTML reachability only.
- An unauthenticated `GET /api/agents` on that origin returned HTTP **401**, JSON `authentication_required` / `Bearer authentication is required`.
- Browser inspection could not launch: missing Playwright executable and `EACCES` launching installed Chrome. No screenshot or authenticated row payload was obtained.
- Therefore this is a verified **source/producer appraisal**, not a claim about the current database contents, deployed revision, row counts or per-agent credential state. Andrew's reported missing values remain the live symptom. An authenticated payload comparison is the outstanding live-validation step.
- No scan, lifecycle mutation, deployment or authenticated audit-detail GET was performed. The audit GET has a discovered write side effect, described below.

## 1. Why the page looks empty

Paths in references are relative to the repository. `BE` means `d2-signalloom/apps/fe-signalloom/src/api_compat.py`; `FE` means `d2-signalloom/apps/dashboard-signalloom/src`; `PROXY` means `d2-signalloom/apps/fake-integration-proxy/server.py`.

| Current promise | Actual source behaviour | Design consequence |
|---|---|---|
| Auto-scan every 15 minutes | Static copy at `FE/pages/AgentsPage.tsx:1097–1100`. List refresh calls GET on a 2.5-second interval (`:1016–1052`, `FE/api/pollInterval.ts:13–23`). That is polling, not evaluation. No 15-minute evaluator was identified in the audited path. | Remove the claim. Separate **inventory refreshed**, **evidence observed**, and **assessment evaluated**. Show scheduling only from a real scheduler's status. |
| Scan Compliance | The database implementation updates existing `assessed_at` values, not control results (`BE:3418–3443`). | Do not expose this as a security evaluation. Disable/hide operational scan until a real evaluator exists; retain demo behaviour only with explicit labelling. Renaming it “refresh timestamp” is technically honest but not a useful operator action. |
| Compliance pending | Discovered rows are assigned zero total/pass/fail/pending controls (`BE:2066–2072`). UI maps absence of passing/failing evidence to `pending` (`AgentsPage.tsx:265–270`). | Show **Not assessed**. Reserve **Queued** or **Running** for actual jobs. Never imply work is scheduled when it is not. |
| Posture score | Discovered records receive `0`. Registry scores are `passing / total` in range 0–1 (`BE:1396–1426`), whereas the bar expects 0–100 (`AgentsPage.tsx:274–283`). | Missing evidence must be null/Not assessed. Normalize a versioned scale once. Prefer “5/6 controls passed, 1 failed” over an opaque score. |
| Owner | Discovery hardcodes `None`; registered owner comes from a separate record (`BE:2056–2061`, `:2086–2095`). | Display **Unassigned** only when assignment is genuinely absent; **Registry not linked** when the discovery record has not been reconciled. |
| Type | Adapter does forward `discovered.type`; proxy derives it from pod labels or Kagent `spec.type` (`BE:2059`; `PROXY:485–496,592–595`). | Current source does not explain universal missing type. Compare authenticated deployed payload/build. Separate execution mode, framework and business role; “Declarative” is not an ownership or risk category. |
| Last Activity | UI reads `last_transition_at`, hardcoded null for discovered rows (`BE:2063`; `AgentsPage.tsx:743–750`). | Rename existing field **Last transition**. Introduce **Last observed** separately, then **Last action** only from attributable events. Pod creation is not activity. |
| Total agents | `merged = k8s_agents + db_agents` (`BE:2094–2095`). | Do not assume this is a unique-actor count. Separate source-record counts until identity resolution is reliable. |

There is another compliance trap: the UI treats any passing controls with no failures as compliant even if other controls remain pending (`AgentsPage.tsx:265–269`). A future summary must represent incomplete coverage, not only the absence of failures.

## 2. What the system can supply

“Available” below means a verified source contract or producer, **not proof that it is populated on the supplied deployment**.

| Information | Source and fields | Availability / work needed |
|---|---|---|
| Basic record | `GET /api/agents`: id, name, type, owner, tenant, lifecycle, transition timestamp/actor, EU AI Act class, compliance summary, model, created time (`BE:123–144`). | Already returned; many fields intentionally null/default on discovery rows. |
| Discovered workload | Namespace, framework, model, runtime, state, created time, node, phase, service account (`PROXY:457–507,561–612`); pods selected by `signalloom.ai/agent=true`, plus Kagent CR discovery (`:1468–1509`). | Real producer path exists. The list adapter drops namespace/framework/runtime/node/phase/service account. Preserve these first. |
| Rich registration | Registry schema: description, version/image, ownership/team, capabilities, configuration and governance metadata. Migration `004_agent_governance_schema.sql:45–90`. | Schema does not equal population. Minimal registration API and explicit demo SQL provide different subsets. Do not advertise runtime-fed values merely because columns exist. |
| Ownership relationship | Registry `owner_id` → `platform_users.id`; user-role scopes and grant metadata. Migration `008_platform_users.sql:57–106`. | Relationship exists; mock SQL populates examples. Role schema is explicitly future RBAC, not established enforcement. Assignment needs authoritative producer and permissions. |
| Identity and trust | `GET /api/trust-topology`: namespace, service account, SPIFFE ID, pod UID, readiness; evidence state/source, observed time, freshness, assurance, reason and collector status (`FE/types/api.ts:70–143`). | Useful evidence model already exists. Registry-to-workload mapping is missing. Modelled or fixture-tested topology is not runtime-observed proof. |
| Credentials | Credential inventory projections contain SPIFFE identity, lifecycle and provenance (`FE/data/credentialInventory.ts:33–51,333–365`). | Show source-qualified credential summaries after exact identity mapping. Inspect concrete field producers before adding expiry/serial/rotation claims. Do not infer issuer verification from a SPIFFE-looking string. |
| Cryptographic proofs | `GET /api/health/crypto` proxies a typed proof list (`BE:2098–2118`). `/cryptography` itself is mostly mock-backed (`FE/pages/CryptographyPage.tsx:4–10`). | Reuse attributable proof objects, not mock tables as live evidence. Health endpoint returns an empty proof list on upstream failure: add unavailable/error state before treating empty as “no proofs”. Cluster-level proof must not be relabelled agent-specific. |
| SuperCred | `/supercred-api/agents/{pod-id}/compliance?namespace=…` (`FE/pages/SuperCredPage.tsx:91–94`; `PROXY:510–546`); inventory has a SuperCred overlay keyed by discovered ID (`FE/data/supercredProjection.ts:153–170`). | Richer narrow flow than generic governance scanning. Preserve namespace and observation provenance. A compliance observation does not by itself prove process freeze or network denial. |
| Governance assessments | Registry UUID → `agent_compliance_results`; `GET /api/compliance/posture`, per-agent violations. `BE:1396–1426`; migration `004…:132–149,223–238`. | Persisted data, much of it explicitly mock-seeded. No substantive evaluator identified in manual scan. Present applicability, assessed counts, methodology and provenance. |
| Activity | Audit events and lifecycle transitions keyed to registry UUID; `GET /api/audit?agent=…&limit=50` and agent violations are consumed by detail (`FE/pages/AgentDetailPage.tsx:999–1017`). | Mutation paths do emit events, but synthetic fallbacks contaminate trust. Fix before using as operational timeline or last action. `last_heartbeat` exists in schema; no writer was identified. |
| Permissions and boundaries | `/rbac-analysis`, `/rbac-explorer`, `/collusion-access`, `/network-tests`; topology edges include decisions, policy reference and denial kind. | Service account/namespace/SPIFFE join needed. Separate configured permissions, calculated reachability and observed test results. NetworkPolicy establishes L3/L4 reachability, not caller identity. |
| Fleet dependencies | `/fleet-api/v1/fleet/topology`: DAG agents/dependencies (`FE/api/fleetApi.ts:54–98`; fleet-manager `topology.go:20–48`). | Workload-name IDs are not registry UUIDs; aggregate risk is authored demo configuration. Show dependency links with provenance; no fleet-derived numerical risk until a real model exists. |
| Signals and actor resolution | Signal ingest models carry principals, actors, sessions and delegation information. Kubernetes impersonation can yield an explicit delegation edge (`signal-ingest/api/audit/receiver.go:245–272,317–350`). Actor model has optional registry ID (`model/actor.go:17–31`). | Existing primitives, incomplete cross-system integration. Deterministic actor links can feed activity after source/provenance validation. Do not merge human and agent actors. |
| Discovery normalization | `FE/data/agentDiscovery.ts:82–111,167–229` has richer tenant/project/role/harness/SPIFFE/provenance/containment normalization. | Audit found no callers of `discoverAgents()`. Reuse useful contract ideas, not assume this code currently feeds the page. |

### Evidence defects that block trustworthy enrichment

1. **Filtered audit GET fabricates history.** With an agent filter and zero results, the DB path inserts synthetic discovery, attestation-like transition and compliance events (`BE:3881–3906`). Fixture fallback also synthesizes events. Do not call this endpoint on missing records merely to populate a design preview; do not derive “last active” or attestation badges from it.
2. **Unknown detail ID becomes a synthetic agent**, rather than an explicit not-found or discovery-only record (`BE:2460–2482`). `/agents/:id` is a real route, but its response is not automatically verified identity evidence.
3. **Kernel labels are inferred from lifecycle**, rather than observed cgroup/TC telemetry (`AgentsPage.tsx:680–724`). “Frozen” and “Network isolated” must report acknowledgements/measurements, not lifecycle-derived decoration.
4. **Silent data-source failure looks like absence.** Discovery errors are swallowed (`BE:2077–2078`), and crypto errors return an empty list. Every projection needs source health, partial-result and stale-last-good semantics.

These are source findings, not claims that all four paths executed on this deployment today.

## 3. Recommended page design

### List: an operational inventory, not a compliance spreadsheet

Use existing Signal Loom dark surfaces, typography, compact table, StatCard and badge patterns. Use semantic status colours sparingly; provenance and source are neutral. Text and icon must carry meaning without colour alone.

**Header:** `Agents` · `Runtime identities and their security evidence`

**Refresh line:** `Inventory refreshed <time> · <N> sources responding · Assessments: <actual status>`

Keep retrieval time separate from evidence observation time. Do not reset freshness whenever a cached record is fetched. No fixed “15 minutes” promise unless backed by scheduler status.

**Four summaries:** Needs attention; Identity coverage (resolved/unresolved/conflicting); Observed workloads; Evidence coverage (fresh/stale/unavailable). Until correlation exists, replace the identity summary with separate registered/discovered record counts. Counts require explicit scopes and denominators; fixture records excluded from operational counts by default.

**Default seven columns:**

| Column | Primary / secondary contents | Why it earns space |
|---|---|---|
| Agent | Name; registered/discovered/resolved/fixture badge; execution mode | Recognise the subject and avoid false deduplication. |
| Runtime | Namespace and framework; model as secondary text | Most immediately useful metadata already produced upstream. Node, image and pod UID stay in detail. |
| Responsibility | Team/owner or precise missing state | Answers who can act. Do not infer ownership from pod creator or namespace name. |
| Operational state | Observed runtime state; separate containment indication if measured | A running process, a valid credential and an unfrozen cgroup are independent facts. |
| Attention | Highest verified issue; assessed-control counts where meaningful | Prioritise actual risk and evidence gaps. Do not put unassessed below “healthy” via a zero score. |
| Identity & evidence | Identity linkage plus compact trust/credential evidence summary | An entry point into the rest of Signal Loom; not an unexplained assurance percentage. |
| Last observed | Source timestamp and freshness | Useful for discovered records now; last action and last transition remain distinct secondary/detail values. |

Optional columns: owner/team separately, model, execution mode, last action, last transition, assessed control ratio, credential expiry (when supplied), source class. Avoid displaying EU AI Act risk as universal per-agent posture; put it in applicable governance detail.

**Filters:** search name/alias/SPIFFE; tenant/cluster/namespace; framework/model; record class; owner; attention; source/freshness. Search and sorting must cover the full backend result set, not merely the current client page. Preserve filters in URL; respect tenant authorization at the server.

**Default order:** verified urgent failures, evidence/identity gaps, then other records; offer recent observations and alphabetical sorting. No action must silently change order under keyboard focus. Retain stale last-good rows with source error context.

### Wireframe — schematic only, not live records or counts

```text
Agents                                    [Refresh inventory] [Columns]
Runtime identities and their security evidence
Inventory refreshed <time> · Source health <status> · Evaluation <status>

[Needs attention] [Identity coverage] [Observed workloads] [Evidence coverage]

[Search names, aliases, SPIFFE...] [Namespace] [Owner] [Evidence] [More]

Agent          Runtime       Responsibility   State      Attention        Identity/evidence   Last observed
<name>         <namespace>   Registry not     Running    Not assessed     Observed workload   <source time>
Discovered     <framework>  linked                        Identity unlinked

<name>         <namespace>   <team>           Running    <verified issue> SPIFFE linked       <source time>
Resolved       <model>                                     <proof status>

Selecting a row opens a quick evidence drawer; Open record goes to /agents/:id.
```

### Quick drawer and full record

Drawer: identity header; runtime snapshot; most important verified issue; responsibility; identity/credentials; source health; Open full record. Keep mutation controls out of the row itself. Copy identifiers must not copy secret credential material.

Full record has five tabs, avoiding one tab per backend product:

1. **Overview:** what/where/who; current issue; observed runtime; last observation/action/transition; coverage gaps; scoped source links.
2. **Identity & trust:** canonical actor and aliases; registry/workload links; SPIFFE and service account; credential lifecycle; proof subject/issuer/algorithm/verification result when actually provided; authorizing principal and delegation as separate entities. Links to credential inventory, cryptography and trust topology.
3. **Access & containment:** effective access evidence; configured versus observed network boundary; dependencies; execution freeze, network isolation and credential revocation as three separate tracks. Each shows requested state, observed state, time, acknowledgement, scope, source and failure reason. Fleet/RBAC/network-test drill-downs.
4. **Assessments:** applicable frameworks, control results, failing/pending counts, evaluator/version, assessment time, evidence references, exceptions. Optional score only with a documented scale, denominator and coverage. “Not assessed” is a first-class state.
5. **Activity & evidence:** attributable timeline, source/time/event filters, actor-resolution rationale, event references and attestation verification. Link to Signal Fusion/Weave and evidence-store investigation. This is where FrostDB adds depth without bloating the inventory.

## 4. Deep links and superadmin surfaces

Existing routes verified in `FE/App.tsx:378–404`. **Existing route is not equivalent to supported agent filter.** Most secondary pages currently filter local state without parsing an agent selection from the URL.

| Destination | Existing capability | Proposed scoped link contract — not implemented |
|---|---|---|
| `/agents/:id` | Existing row-specific route; detail joins several sources, with unsafe fallback noted above | Stable canonical record route, source-only records explicit, unknown ID returns honest 404. |
| `/credential-inventory` | Identity/lifecycle/provenance filtering | `?actor=<canonical-id>` resolving to exact SPIFFE identities. |
| `/cryptography` | Mostly mock-backed multi-table view; some separate crypto-health proof infrastructure | `?actor=<id>&proof=<proof-id>` only for proofs attributable to this subject. |
| `/agent-trust-topology` | Local plane/tenant/location/evidence/decision filters | `?actor=<id>` highlights exact node and neighbourhood with attribution. |
| `/audit` | API has agent/time/type filters; UI does not initialise agent URL filter | `?agent=<registry-uuid>&from=<time>&to=<time>` after removing synthetic fallbacks. |
| `/supercred` | Lab workflow and per-pod namespace-qualified observations | `?actor=<id>` resolves namespace/pod identity; navigation does not execute demo steps. |
| `/fleet` | Topology and roster; authored demo risk | `?actor=<id>` focuses mapped workload and dependencies. |
| `/rbac-analysis`, `/rbac-explorer`, `/collusion-access` | Existing global investigative surfaces | `?actor=<id>` resolves server-authorized service account/principal and scope. |
| `/network-tests` | Existing test-result board; results are cluster-scoped (`BE:2121–2149`) | `?actor=<id>` selects relevant subject/peer evidence; does not launch tests. |
| `/signal-fusion`, `/weave`, `/signal-store` | Existing investigation destinations | `?actor=<id>&from=<time>&to=<time>` selects attributable evidence and returns to the same record. |

Before filter support lands, offer clearly labelled **Open all credentials**, **Open trust topology**, etc. Do not silently ignore a query parameter and make a global page look agent-scoped. A scoped link should preserve time range, visibly show the subject, support back navigation and return an explicit unresolved/unauthorized state.

Superadmin sidebar flags are **visibility preferences, not authorization** (`FE/auth/superadmin.ts:1–11`, `Sidebar.tsx:85–98`, `App.tsx:406+`). Existing privileged mutations use JWT-derived allowlists (`fe-signalloom/src/superadmin.py:56–77`). The design requires a backend capabilities response before promising a role-based action menu; that response is a proposed contract, not an existing feature.

Ordinary operators should see permitted security evidence without entering a demo console. Privileged controls belong in the detail action menu with capability checks, reason, scope and confirmation. Keep “Run SuperCred scenario” distinct from genuine incident response. Future decommission remains unavailable until enforced dual approval exists.

## 5. Correlation and data contract

Do not join on display names, partial audit-name matches, or synthesized SPIFFE strings. Current non-UUID audit filtering uses `ILIKE` (`BE:3857–3867`), which is not a canonical identity relation.

**Proposed projection, built on the actor-resolution spine rather than a competing resolver:**

- Canonical actor ID, tenant boundary, registry UUID where linked, record class.
- Workload identity: cluster identifier, namespace, Kubernetes kind/UID, pod UID, service account, observed SPIFFE identity and validity interval. Namespace/name alone cannot distinguish clusters or replacement pods.
- Aliases and explicit resolution edges: method, evidence reference, confidence, valid-from/to, conflicting candidate IDs. Deterministic resolution first; probabilistic suggestions never silently merge identities.
- Per-field value + source + observed time + evidence reference + availability reason. Page fetch time does not establish observation freshness.
- Separately model runtime, governance, credential and containment states. Keep requested control action separate from observed outcome.
- Coverage/collector health: live, fixture, off, unavailable, stale; partial results and last good observation.
- Per-assessment producer/version, applicability, denominator, pass/fail/pending/not-applicable counts and original evaluation timestamp.
- Backend-authorized navigation/action capabilities, tenant-scoped pagination, filters and sort.

Current durable registry joins: UUID to compliance, violations, audit and lifecycle; `owner_id` to platform user. Trust/credentials use SPIFFE or workload identifiers; Fleet uses names; Signal Fusion has optional registry association. Retain many-workloads-to-one-actor and temporal replacement relationships rather than forcing a 1:1 mapping.

Avoid issuing a dozen per-agent requests every 2.5 seconds. Use a bounded aggregate list projection and lazy-load detail evidence; version snapshots, report partial source failures, and measure real latency/load before choosing production polling cadence. No new datastore is justified just for this page.

## 6. Future proposals: FrostDB, Stun and Signal Fusion

“Frosty B” is very likely **FrostDB**: it is explicitly referenced in the two 5 September Signal Fusion proposals and a query-pushdown delivery card. This is a high-confidence contextual resolution, not an explicit nickname declaration. “The Stun” maps strongly to the containment/SuperCred programme; several proposals contribute rather than one uniquely named item.

Proposal titles and folders below are relative to the Obsidian vault. They were read through the supported search/read wrappers. Project-routing index reads were denied; one additional Fleet proposal read timed out and is not a basis for conclusions.

| Proposal / source | Relevant direction | How the page accommodates it |
|---|---|---|
| Innovation: **Proposal — Signal Fusion Delivery Plan (2026-Q3)**, created 5 Sep, updated 17:45; **Proposal — Signal Fusion Actor-Resolution Spine (2026-Q3)**, created 5 Sep, updated 13:25 | Deterministic-first canonical identity; confidence/aliases; eventual “Who authorized this action?” and write-time attestation | Identity linkage in list; resolution explanation, delegation and action-to-authorizer evidence in detail. |
| Enhancement: **Proposal — Signal Loom Signal Fusion V2 — Columnar Signal Ingestion & Live Multilayer Correlation (2026-Q3)**, created 1 Sep, updated 5 Sep 11:24 | FrostDB/Arrow/Parquet evidence exploration; folded into delivery spine | User-facing label **Activity & evidence**, not “FrostDB”. Time/source/layer filters; link to Weave/store. |
| Enhancement: **Proposal — Signal Fusion K8s Audit Collector (2026-Q3)**; **Proposal — Signal Fusion KAgent Tool-Log Resolver (2026-Q3)**; **Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)**, created 5 Sep | Wider observation coverage and actor attribution | Per-source coverage and fidelity. Workspace/M365 currently contract/fixtures, not a live “connected” badge. |
| Enhancement: **Proposal — Signal Loom Stun under Flux Operator (2026-Q3)**, created 3 Aug; **Proposal — Signal Loom eBPF Containment Primitives (2026-Q3)**, created 13 Aug; both updated 5 Sep | Reconcile desired containment through GitOps, process freeze, network control, credential revocation and recovery | Three observed control tracks, requested/observed state, control-plane authority, latency and recovery evidence. No single magic “Stunned” badge. |
| Enhancement: **Proposal — Signal Loom Resilient eBPF Sentinel, Declarative Kagent Swarm & Fleet Discovery (2026-Q3)**, created 1 Sep, updated 5 Sep | Resilient kernel enforcement, declarative fleet and discovery | Workload identity continuity, dependencies, node-level evidence health, unsupported-platform states. |
| Innovation: **Proposal — Signal Loom Agent Security Platform (2026-Q3)**, created 28 Jul, updated 5 Sep | Broader response modes, forensic sandbox and irreversible decommission | Reserve gated detail actions; legal review for deception, dual control for decommission. Do not show these as operational today. |

### Do not confuse proposal completion with availability

The research checked source history as well as proposal status. Shared `Resolve()` contract commits (`4ba3be37`, `a107e4eb`) were merged, but the complete deterministic resolver was not established as finished. Identity/delegation graph commit `4946d1df` and FrostDB pushdown commit `f429b9e1` existed but were not ancestors of inspected HEAD, despite a COMPLETE label in proposal material. Their presence somewhere in Git does not prove inclusion or deployment.

Repository corroboration: `docs/signalloom/sfdp-p3-preflight-proof.md:61,106–110` describes the existing FrostDB foundation and spine work; `docs/signalloom/sfdp-p2-4-blocker.md:15,48–59` explicitly records the GKE Tetragon/Hubble authentication blocker and stopped implementation; `docs/signalloom/stun-under-flux.md:7+` distinguishes invocation from outcome. Sentinel implementation and hardening commits exist, but this appraisal did not run containment probes.

Treat readiness as independent gates: **proposed → contract/fixture → implemented → integrated → deployed → observed**. Store this in capability/evidence metadata, not as an assumption derived from a proposal checklist. Do not add empty “coming soon” columns to the inventory; reserve future detail components until capability detection enables them.

## 7. Truthful state language

| Condition | Display |
|---|---|
| No assessment results | Not assessed |
| Actual job accepted / executing | Queued / Evaluating, with job reference |
| Registry owner not assigned | Unassigned |
| Discovery has no registry relationship | Registry not linked |
| Upstream has the field, adapter omits it | Unavailable in this view |
| Producer never supplied a value | Not supplied |
| Observation cannot be made | Not observed / Unsupported, with reason |
| Evidence expired | Stale, retaining last observation time |
| Collector failed | Source unavailable, not zero records |
| No matching source events | No observed events, never synthesized history |
| Multiple identity candidates | Identity conflict / Unresolved |
| Demonstration data | Fixture / Modelled, never Operational |
| Control requested without acknowledgement | Requested, outcome unconfirmed |
| Evidence proves denial only at network layer | Network denial observed, not “identity verified” |

## 8. Delivery sequence and acceptance

**Phase 0 — Evidence honesty.** Correct scan wording/behaviour, null/zero semantics, score scale and last-transition label; remove synthetic production fallbacks; expose source health and fixture provenance. Do not rewrite historical events indiscriminately: isolate demonstrably synthetic records with provenance review and explicit approval before cleanup.

**Phase 1 — Useful inventory now.** Preserve already-produced workload fields, expose record class, use honest source counts, implement the seven-column layout and evidence drawer. Unknown detail IDs must not fabricate agents. Owners remain unlinked where no relationship exists.

**Phase 2 — System-wide dossier.** Reuse the actor spine for canonical correlation. Add source-qualified trust/credential/compliance/dependency projections and genuine URL-filtered deep links. Add backend action capabilities; do not rely on sidebar visibility.

**Phase 3 — Signal Fusion and containment.** Integrate attributable FrostDB timelines and delegation as their delivery gates pass. Surface sentinel acknowledgements, freeze/isolation/revocation outcomes, recovery and future approval workflows without changing the core inventory structure.

### Acceptance tests required before implementation is called complete

- A discovery-only record exposes namespace/service account/framework when supplied, without invented owner, risk, score or activity.
- A registry record and workload with similar names do not merge without an explicit authorized identity relation.
- Identical names in different tenants/clusters do not cross-link; replacement pod UIDs retain correct temporal attribution.
- Unknown agent detail returns explicit not-found or an explicitly resolved source-only record; never a synthetic registry entry.
- An empty filtered audit GET writes zero events and returns empty evidence.
- No controls renders Not assessed; one passing plus pending controls renders incomplete; a known failure renders failed.
- The agreed 0–1 production score contract converts `0.82` to `82%` exactly once; fixtures are migrated explicitly rather than heuristically guessing units.
- Stale or failed collectors cannot generate fresh/healthy badges; retrieving a record does not advance observation or evaluation time.
- Lifecycle alone never proves cgroup freeze, network isolation or credential revocation.
- Each deep link selects the correct actor and time range on reload, or clearly reports unsupported selection; no silently ignored parameters.
- Unauthorized mutation requests return server-side denial even when the client exposes a route or modifies local superadmin visibility.
- Human authorizer and agent actor remain separate in delegation chains.
- Fixture/cluster-wide proofs cannot appear as live per-agent verification.
- Keyboard row selection, drawer focus/escape, non-colour status labels and compact/mobile layouts work without hiding essential evidence state.
- Evaluate representative payloads from the authenticated supplied deployment before choosing production default columns or quoting coverage counts.

**Decision requested:** approve the evidence-led inventory/dossier direction and Phase 0/1 scope. No implementation or deployment has been performed by this appraisal.
