# Kusari pilot: dashboard pages

This page has one section per dashboard page a Kusari user will use. Each
section gives the path, what the page shows, which API it calls, what actions
it offers, and who may take them. It describes the tree at commit `dfc1a849`.
It derives from the route table in
[`App.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/App.tsx), the
pages under
[`src/pages/`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/), and
the acceptance specs under [`test/acceptance/`](../../test/acceptance/).

The dashboard is served at `https://dashboard.osramp.acme.local:30754`. Every
page except `/login` and `/callback` needs a session. The dashboard sends the
ID token as `Authorization: Bearer` on every API call. Paths under `/api/` go
to the portal API `fe-signalloom`. Paths under `/afm/` go to the AFM platform
without a token. Paths under `/fleet-api/` go to `fleet-manager` after a
superadmin check. The proxy rules are in
[`nginx.conf`](../../d2-signalloom/apps/dashboard-signalloom/nginx.conf).

## Who may do what

| Identity | Tenant | Superadmin | Can |
| :--- | :--- | :--- | :--- |
| `kusari-operator@signalloom.local` | `kusari` | No | Read every tenant-scoped page. Claim agents. Issue and revoke agent credentials. Run compliance scans. Export audit and compliance data. |
| `demo-user@signalloom.local` | `tenant-demo` | Yes | All of the above for `tenant-demo`, plus `/fleet`, `/signal-fusion`, `/supercred`, demo pages, fleet actions, and the AFM import as a signed-in user. |

Superadmin is a name match on the demo user. The dashboard also has a
**superadmin** toggle in the sidebar footer that shows or hides the superadmin
links
([`Sidebar.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/components/Sidebar.tsx),
`superadmin-toggle`). The toggle is a visibility control. Routes wrapped in
`SuperadminRoute` redirect a non-eligible user to `/agents` whatever the
toggle says.

Redirects you will meet: `/` goes to `/agents`. `/overview` and `/workspaces`
go to `/discovery`. `/containment` goes to `/compliance`. `/approvals` goes to
`/collusion-access`. `/connectors` goes to `/federated-services`. `/activity`
goes to `/weave`. An unknown path goes to `/agents`.

## /onboarding

| | |
| :--- | :--- |
| Shows | A three-step wizard: Organization and Identity, Identity Provider, Containment and Consent |
| Component | [`OnboardingWizard.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx) |
| Reads | `GET /api/onboarding/status`, `GET /api/onboarding/state` |
| Actions | **Next** and **Back** save with `PUT /api/onboarding/state`. **Complete** calls `POST /api/onboarding/complete`. **Skip** calls `POST /api/onboarding/skip`. |
| Who | Any signed-in user, for their own tenant |
| Spec | [`onboarding.spec.ts`](../../test/acceptance/onboarding.spec.ts): the full walkthrough, skip, and back-and-forward persistence |

The wizard does not create a tenant, does not bind you to one, and has no
cluster or connector step. **Test Connection** on step 2 sends no request.
See [onboarding](onboarding.md#3-what-you-see-first).

## /redeem-invite

| | |
| :--- | :--- |
| Shows | A "Create your workspace" form, gated on `?code=SL-XXXX-XXXX` |
| Component | [`RedeemInvite.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RedeemInvite.tsx) |
| Actions | Submit posts to `/api/registry/signup` |
| Who | Nobody. The portal has no route at that path. |

Do not use this page. See [onboarding](onboarding.md#1-get-an-identity).

## /agents

| | |
| :--- | :--- |
| Shows | The agents the central cluster discovers, with lifecycle and kernel-state badges, a signal summary, and a Coding Agents tab |
| Component | [`AgentsPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/AgentsPage.tsx) |
| Reads | `GET /api/agents`, `GET /api/agents/{id}` |
| Actions | **Auto-Claim** or **Claim Agent** calls `POST /api/v1/agents/{id}/claim`. **Register Agent** calls `POST /api/agents`. **Scan Compliance** calls `POST /api/compliance/policy/scan`. |
| Who | Any signed-in user. A claim succeeds only when the workload's `signalloom.ai/tenant` equals the user's tenant and the workload declares a model. |
| Spec | [`kagent-agents.spec.ts`](../../test/acceptance/kagent-agents.spec.ts), [`smoke.spec.ts`](../../test/acceptance/smoke.spec.ts) "Agents page renders past loading" |

The list comes from the discovery service on the central cluster, label
`signalloom.ai/agent=true`, namespaces `fe-signalloom-agents` and
`fe-signalloom`. It is not filtered by tenant. Workloads on the Kusari cluster
are not in it. See [onboarding](onboarding.md#4-how-your-agents-appear).

## /agents/:id

| | |
| :--- | :--- |
| Shows | One agent's dossier: Overview, Identity, Access, Assessments, and Activity tabs, a violations timeline, and credential actions |
| Component | [`AgentDetailPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/AgentDetailPage.tsx) |
| Reads | `GET /api/agents/{id}`, `GET /api/audit?agent={id}&limit=50`, `GET /api/agents/{id}/violations`, `GET /api/compliance/posture`, `GET /api/agents/{id}/telemetry`, `GET /api/agents/{id}/external-evidence` |
| Actions | **Issue Credential** calls `POST /api/agents/{id}/credentials`. **Revoke** calls `POST /api/agents/{id}/credentials/revoke`. **Acknowledge** a violation calls `POST /api/agents/violations/{id}/acknowledge`. **Reassess** calls `POST /api/agents/{id}/compliance/{controlId}/reassess`. |
| Who | Any signed-in user of the agent's tenant |
| Spec | [`credential-lifecycle.spec.ts`](../../test/acceptance/credential-lifecycle.spec.ts), [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 3b" |

The stun state in the dossier comes from the audit trail, event type
`agent.stunned`
([`api_compat.py`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py),
`_latest_stun_index`). There is no stun button on this page. The telemetry
tab reads the kubelet cAdvisor poller
([`cadvisor_poller.py`](../../d2-signalloom/apps/fe-signalloom/src/cadvisor_poller.py)),
which samples containers named `kusari-agent` and the namespace
`fe-signalloom-agents` on the central cluster.

## /weave

| | |
| :--- | :--- |
| Shows | Live observations from the signal layers, converging on provisional actors, with an evidence drawer and a coverage panel |
| Component | [`WeavePage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/WeavePage.tsx) |
| Reads | `GET /api/signals/observations`, `GET /api/signals/actors`, `GET /api/signals/coverage`, stream `GET /api/signals/observations/stream` |
| Actions | **Seed fixtures** calls `POST /api/signals/collectors/seed`. **Promote** renders for an actionable actor but has no click handler. |
| Who | Any signed-in user. Reads act for the user's tenant. |
| Spec | [`cloudaudit-dashboard.spec.ts`](../../test/acceptance/cloudaudit-dashboard.spec.ts), [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 5" |

This is the page where a warden observation from the Kusari cluster appears,
once the forwarding path works. The portal reads `signal-ingest` with the key
`fe-signalloom-gateway` and the header `X-SignalLoom-Acting-Tenant: kusari`
([`ingest_client.py`](../../d2-signalloom/apps/fe-signalloom/src/ingest_client.py),
[`signal_fusion.py`](../../d2-signalloom/apps/fe-signalloom/src/signal_fusion.py)).
An observation with `tenant_id: __unattributed__` is not shown to a tenant
user. See [secondary-cluster](secondary-cluster.md#4-map-your-workloads-to-the-tenant).

## /audit

| | |
| :--- | :--- |
| Shows | A filterable, live-polling table of audit events with a raw JSON drawer |
| Component | [`AuditTrail.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/views/AuditTrail.tsx) |
| Reads | `GET /api/audit?...`, stream `GET /api/audit/stream` |
| Actions | **Export CSV** |
| Who | Any signed-in user, scoped to their tenant |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 10" |

Events come from the `audit_events` table of the portal, scoped by
`tenant_id`. Claims, credential actions, compliance scans, and stuns proxied
through the portal appear here. A stun recorded by the warden straight to
`fleet-manager` does not.

## /compliance

| | |
| :--- | :--- |
| Shows | Posture donut, framework cards, and a per-agent compliance table with a drawer |
| Component | [`Compliance.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/views/Compliance.tsx) |
| Reads | `GET /api/compliance/posture`, `/frameworks`, `/summary`, `GET /api/agents`, `GET /api/tenant/settings` |
| Actions | **Export** calls `GET /api/compliance/export?format=json` |
| Who | Any signed-in user |
| Spec | [`policy-editor.spec.ts`](../../test/acceptance/policy-editor.spec.ts), [`smoke.spec.ts`](../../test/acceptance/smoke.spec.ts) |

`/containment` redirects here. `/compliance/posture` shows the per-control
view. `/compliance/:frameworkId` shows one framework's matrix with a
**Reassess** action per control. `/compliance/risk` is the same page as
`/risk`.

## /risk

| | |
| :--- | :--- |
| Shows | OpenFAIR exposure: annualised loss, tail value at risk, a loss-exceedance curve, and an agent table |
| Component | [`RiskExposurePage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RiskExposurePage.tsx) |
| Reads | `GET /api/v1/fair/versions`, `GET /api/agents`, `GET /api/compliance/posture`, and `POST /api/compliance/policy/scan` on each filter change |
| Actions | Population filter only |
| Who | Any signed-in user |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 6" |

## /discovery

| | |
| :--- | :--- |
| Shows | Discovered workloads from several sources, with facet filters and control recommendations |
| Component | [`DiscoveryPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/DiscoveryPage.tsx) |
| Reads | `GET /api/discovery/workloads`, fallback `GET /api/nhi/discovered`, `GET /api/nhi/scans`, `GET /api/agents` |
| Actions | **Claim** calls `POST /api/nhi/discovered/{id}/enroll`. **Dismiss** calls `POST /api/nhi/discovered/{id}/dismiss`. **Claim Namespace** calls `POST /api/agents/autoclaim-discovered`. |
| Who | Any signed-in user. The namespace autoclaim applies the same tenant and model rule as a single claim. |
| Spec | [`discovery-claim.spec.ts`](../../test/acceptance/discovery-claim.spec.ts) |

## /federated-services

| | |
| :--- | :--- |
| Shows | Trust zones, federations, services, attestation policies, SPIFFE identities, and events, with a live or demo source indicator |
| Component | [`FederatedServicesPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/FederatedServicesPage.tsx) |
| Reads | `GET /api/v1/federation/summary` |
| Actions | None |
| Who | Any signed-in user |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 11" |

`/connectors` redirects here. The portal proxies `/api/v1/federation/*` to
`signal-ingest` in the central cluster
([`federation.py`](../../d2-signalloom/apps/fe-signalloom/src/routers/federation.py)).
Nothing on this page reads the Kusari cluster. The zone and federation names
in demo mode are fixtures.

## /help/connectors/:provider

| | |
| :--- | :--- |
| Shows | A bundled setup guide for one identity provider |
| Component | [`ConnectorHelpPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/ConnectorHelpPage.tsx) |
| Reads | Nothing. The content is compiled in. |
| Providers | `entra`, `okta`, `openai` have guides. `google`, `aws`, `gcp` show "Coming soon". |
| Who | Any signed-in user |

## /collusion-access

| | |
| :--- | :--- |
| Shows | AFM findings: collusion pairs, privilege escalation, shared roles, and conformance, per cluster or aggregate |
| Component | [`CollusionAccessPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/CollusionAccessPage.tsx) |
| Reads | `/afm/clusters/{id}/jobs`, `/afm/clusters/{id}/analysis/*`, `/afm/jobs/{id}/result`, all without a token |
| Actions | **Run collusion scan** calls `POST /afm/clusters/{id}/analysis/escalation` without a token. **Run RBAC scan** calls `POST /api/rbac/clusters/{id}/scan` with the token. |
| Who | Any signed-in user. The AFM proxy is unauthenticated. |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 9" |

`/approvals` redirects here. The clusters listed are the clusters AFM has
imported. See [`/rbac-analysis`](#rbac-analysis).

## /rbac-analysis

| | |
| :--- | :--- |
| Shows | AFM health and cluster count, an embedded AFM dashboard, and the RBAC importer panel |
| Component | [`RbacAnalysisPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RbacAnalysisPage.tsx) |
| Reads | `GET /afm/health`, `GET /afm/clusters` |
| Actions | **Generate YAML**, **Copy**, and **Send to AFM** in [`RbacImporterPanel.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/components/RbacImporterPanel.tsx). **Send to AFM** calls `POST /api/v1/afm/clusters/import` with the token. |
| Who | The link is hidden for a non-superadmin, but the route is open by URL. **Send to AFM** needs a superadmin or a static key with scope `afm:import`. A `kusari-operator` send gets `403 superadmin_required`. |
| Spec | [`rbac-analysis.spec.ts`](../../test/acceptance/rbac-analysis.spec.ts), [`afm-integration.spec.ts`](../../test/acceptance/afm-integration.spec.ts) |

The import route is in
[`afm_import.py`](../../d2-signalloom/apps/fe-signalloom/src/afm_import.py).
It accepts a payload up to 8 MiB with a non-empty `id`, audits the request,
and forwards it to the AFM platform. The results read back through
[`rbac_correlation.py`](../../d2-signalloom/apps/fe-signalloom/src/rbac_correlation.py)
on `/rbac-explorer`. The static key is bound to cluster `kind-osramp`. See
[faq-and-limits](faq-and-limits.md#rbac-analysis-shows-no-kusari-cluster).

## /rbac-explorer

| | |
| :--- | :--- |
| Shows | Correlated RBAC per cluster: subjects, roles, bindings, and findings, with cluster and namespace selectors |
| Component | [`RbacExplorerPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RbacExplorerPage.tsx) |
| Reads | `GET /api/rbac/clusters`, `GET /api/rbac/clusters/{id}/correlated`, `GET /api/agents` |
| Actions | **Refresh** |
| Who | Any signed-in user by URL. The sidebar link is superadmin-only. |
| Spec | [`rbac-explorer.spec.ts`](../../test/acceptance/rbac-explorer.spec.ts) |

## /credential-inventory

| | |
| :--- | :--- |
| Shows | Workload identities and credentials of registered agents, plus identities seen by the SuperCred proxy, with crypto health |
| Component | [`CredentialInventoryPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/CredentialInventoryPage.tsx) |
| Reads | `GET /api/agents`, `GET /api/health/crypto`, `GET /supercred-api/agents` |
| Actions | None |
| Who | Any signed-in user by URL. The sidebar link is superadmin-only. |
| Spec | [`live-data.spec.ts`](../../test/acceptance/live-data.spec.ts) route loop |

## /topology

| | |
| :--- | :--- |
| Shows | The trust graph of agents and identities, with a node drawer that carries attestation and denied-authorisation evidence |
| Component | [`AgentTrustTopologyPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/AgentTrustTopologyPage.tsx) |
| Reads | `GET /api/trust-topology` |
| Actions | None |
| Who | Any signed-in user |
| Spec | [`topology-graph.spec.ts`](../../test/acceptance/topology-graph.spec.ts) |

## /settings

| | |
| :--- | :--- |
| Shows | Tenant settings: API key, compliance frameworks, connectors, load-time and currency preferences, platform users |
| Component | [`Settings.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/views/Settings.tsx) |
| Reads | `GET /api/tenant/settings`, `/api/compliance/frameworks`, `/api/nhi/scans`, `/api/tenant/users`, `/api/connectors/providers`, `/api/connectors` |
| Actions | **Reveal my API key** calls `POST /api/tenants/{tenant}/api-keys/initial`. **Rotate API Key** calls `POST /api/tenants/{tenant}/api-keys/rotate`. Framework toggles call `PUT /api/tenant/settings/frameworks`. **Save preferences** calls `PUT /api/tenant/settings/preferences`. **Disconnect** a connector calls `DELETE /api/connectors/{id}`. |
| Who | Any signed-in user, for their own tenant |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 13" |

The superadmin toggle is not here. It is in the sidebar footer.

## /fleet and /fleet/audience

| | |
| :--- | :--- |
| Shows | The fleet demo: topology graph, risk gauge, per-agent state table, and a five-second heartbeat |
| Component | [`FleetDemoPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/FleetDemoPage.tsx) |
| Reads | `GET /fleet-api/v1/fleet/topology`, straight to `fleet-manager` |
| Actions | **Deploy Fleet**, **Scan Fleet**, **Stun** with a mandatory reason, **Recover Fleet**, **Reset Fleet**. They call `POST /fleet-api/v1/fleet/{deploy,scan,stun/{id},recover,reset}` ([`fleetApi.ts`](../../d2-signalloom/apps/dashboard-signalloom/src/api/fleetApi.ts)). |
| Who | Superadmin only. The route redirects everyone else to `/agents`. `/fleet/audience` is the read-only view. |
| Spec | [`risk-audit.spec.ts`](../../test/acceptance/risk-audit.spec.ts) "Surface 12" |

A `kusari-operator` session cannot open this page. The `/fleet-api/` proxy
checks `GET /api/v1/auth/check`, which answers `204` for a superadmin and
`403` otherwise, then swaps in the `dashboard` caller key. That key has the
scopes `stun`, `deploy`, `scan`, and `reset`. It has no `recover` and no
`resume`, so **Recover Fleet** answers `403` even for the superadmin. The
agents on this page are the five demo agents in
[`fleet-config.yaml`](../../d2-signalloom/apps/fleet-manager/base/fleet-config.yaml).
The Kusari stub is not among them.
