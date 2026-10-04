# Kusari pilot: onboarding from zero

This page takes a Kusari engineer from no access to a signed-in session that
shows the pilot tenant and its agents. It describes the tree at commit
`dfc1a849`. It derives from ADR-03 and ADR-12 in
[the Spireless proposal](../Proposal%20—%20Signal%20Loom%20Spireless%20Token-Based%20Agent%20Identity%20Migration%20%282026-Q4%29.md)
and from the portal code in
[`d2-signalloom/apps/fe-signalloom/src`](../../d2-signalloom/apps/fe-signalloom/src).

Result: you are signed in as the pilot identity, the portal reports
`tenant: kusari`, and the [Agents page](pages.md#agents) lists the Kusari
agent stub.

Prerequisites:

- A browser that can reach `https://dashboard.osramp.acme.local:30754`. The
  central cluster serves a self-signed certificate from
  [`cluster-issuer.yaml`](../../d2-infra/components/cert-manager/configs/base/cluster-issuer.yaml).
  Accept the certificate warning once.
- A Dex identity and an invite token from ControlPlane. See
  [step 1](#1-get-an-identity).

## How identity and tenancy work

The dashboard signs you in with Dex, the OpenID Connect provider inside the
central cluster. The dashboard sends the ID token to the portal API as an
`Authorization: Bearer` header on every request
([`client.ts:317-322`](../../d2-signalloom/apps/dashboard-signalloom/src/api/client.ts)).

The portal does not read a tenant claim from the token. It maps the token
subject to a tenant server-side, in two places, in this order
([`api_compat.py:1766-1781`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py)):

1. The `subject_tenants` table (migration
   [`053_invites_and_subject_tenants.sql`](../../d2-signalloom/apps/fe-signalloom/src/db/migrations/053_invites_and_subject_tenants.sql)),
   written when a subject redeems an invite. The lookup is cached per subject
   for 30 seconds
   ([`api_compat.py:1690-1704`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py)).
   Redeem drops the cache entry, so a new binding is live on the next request.
2. The `API_SUBJECT_TENANTS` environment variable of the `fe-signalloom`
   Deployment
   ([`deployment.yaml:108-115`](../../d2-signalloom/apps/fe-signalloom/base/deployment.yaml)).
   This is the fallback, and the only path when the portal has no database.

A subject in neither gets `403 tenant_forbidden`
([`api_compat.py:1781`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py)).

The table maps one subject to tenant `kusari`: `kusari-operator`. The Dex
identity is `kusari-operator@signalloom.local`, defined in
[`dex.yaml:95-105`](../../d2-signalloom/infra/inf-signalloom/base/dex.yaml).
The comment there records that this is a local-demo credential and that it is
not a superadmin.

Two other identities exist. `demo-user@signalloom.local` is the superadmin and
maps to `tenant-demo`. `viewer@signalloom.local` is a plain user of
`tenant-demo`. Neither sees tenant `kusari` data through tenant-scoped routes.

NOTE: The superadmin check is an allow-list, not a role table and not a group
claim. The Deployment sets `API_SUPERADMIN_EMAILS` and
`API_SUPERADMIN_SUBJECTS` explicitly. `superadmin.py` carries the same demo
values as defaults. The dashboard follows the server. `GET /api/v1/me` returns
`subject`, `tenant`, `email` and `superadmin`, the same verdict
`require_superadmin` applies. The browser-side name match in
[`superadmin.ts`](../../d2-signalloom/apps/dashboard-signalloom/src/auth/superadmin.ts)
is now the pre-flight answer for the first render only, and a failed request
never promotes.

## 1. Get an identity

Two things have to be true: Dex knows the identity, and the portal maps its
subject to tenant `kusari`. The first is still an edit by ControlPlane. The
second is self-service through an invite.

1. Ask ControlPlane for a Dex identity. For the pilot that is
   `kusari-operator@signalloom.local`, already mapped to `kusari` by the
   environment table. For a second person, ControlPlane adds a
   `staticPasswords` entry to
   [`dex.yaml`](../../d2-signalloom/infra/inf-signalloom/base/dex.yaml) and
   restarts the `dex` Deployment. Dex reads its config once at start and never
   reloads it. The comment at `dex.yaml:116-136` records this. The portal does
   not create identities.
2. Ask ControlPlane for an invite. A superadmin calls
   `POST /api/v1/invites` with `{"email": "<the Dex email>", "tenant": "kusari"}`
   ([`invites.py:183-215`](../../d2-signalloom/apps/fe-signalloom/src/invites.py)).
   The response carries a one-time `token`. The table keeps only its sha256
   ([`invites.py:203`](../../d2-signalloom/apps/fe-signalloom/src/invites.py)),
   so the token cannot be recovered later. It expires after seven days
   ([`invites.py:57`](../../d2-signalloom/apps/fe-signalloom/src/invites.py)).
3. Sign in with the Dex identity ([step 2](#2-log-in)), then open
   `/redeem-invite?token=<token>` and select **Redeem invite**. The page posts
   the token with your ID token to `POST /api/v1/invites/redeem`
   ([`RedeemInvite.tsx:111`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RedeemInvite.tsx)),
   and shows the tenant you are now bound to.

The redeem route accepts a verified Dex identity that has no tenant yet. That
is its purpose
([`invites.py:251-266`](../../d2-signalloom/apps/fe-signalloom/src/invites.py)).
It refuses three things. A token whose `email` claim differs from the
invite's email gets `403 invite_email_mismatch`. A subject already bound to a
different tenant gets `409 tenant_mismatch`. An expired or spent invite gets
`410`. A superadmin lists invites with `GET /api/v1/invites`. The listing
never includes a token. Both actions appear on the
[Audit Trail](pages.md#audit) as `invite.created` and `invite.redeemed`.

A `403 tenant_forbidden` after a successful redeem means the ID token's `sub`
differs from the one that redeemed. The binding is by subject, not by email.

The environment-table route still works. ControlPlane can use it instead of
an invite by adding the subject to `API_SUBJECT_TENANTS` in
[`deployment.yaml`](../../d2-signalloom/apps/fe-signalloom/base/deployment.yaml)
and rolling the `fe-signalloom` Deployment. The table wins over the environment
map when both name the same subject.

## 2. Log in

1. Open `https://dashboard.osramp.acme.local:30754/login`.
2. Select **Sign in with Dex**. The page is
   [`LoginPage.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/LoginPage.tsx).
3. Enter the email `kusari-operator@signalloom.local` and the password.
4. Dex returns you to `/callback`, then the dashboard opens `/agents`. The
   root path `/` redirects to `/agents`
   ([`App.tsx:411`](../../d2-signalloom/apps/dashboard-signalloom/src/App.tsx)).

Check: open the browser developer tools, select the Network tab, and reload.
The request `GET /api/capabilities` returns `200` with a body that contains
`"tenant": "kusari"` and `"is_superadmin": false`. The route is
[`api_compat.py:3276-3307`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py).

The same check from a terminal, with the token copied from the request:

```bash
TOKEN='<id token from the Authorization header>'
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://dashboard.osramp.acme.local:30754/api/capabilities | jq '{tenant, is_superadmin, roles}'
```

Expected output:

```json
{ "tenant": "kusari", "is_superadmin": false, "roles": ["operator"] }
```

## 3. What you see first

On the first login the dashboard redirects you to `/onboarding`, the
wizard. The gate is in
[`ProtectedRoute.tsx:72-77`](../../d2-signalloom/apps/dashboard-signalloom/src/auth/ProtectedRoute.tsx).
It fires when the tenant has no connected connector and the wizard status is
neither `completed` nor `skipped`
([`App.tsx:269-283`](../../d2-signalloom/apps/dashboard-signalloom/src/App.tsx)).

A tenant with no saved progress sees a welcome screen first
([`OnboardingWizard.tsx:368`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx)).
The persisted steps are, in order
([`OnboardingWizard.tsx:40-46`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx)):

| Step | Asks for | What it does |
| :--- | :--- | :--- |
| Organization and Identity | Organisation name, workspace id, admin email, environment, description | Saves the form with `PUT /api/onboarding/state`. It does not create a tenant and does not bind you to one. |
| Identity Provider | Issuer URL, client id, client secret, scopes | Saves the form. **Test Connection** calls `GET /api/v1/me` with your session token and shows the subject and tenant the portal verified, or the HTTP status it answered ([`OnboardingWizard.tsx:213-217`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx), [`IdpLinkageStep.tsx:128-150`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/IdpLinkageStep.tsx)). It proves the session, not the issuer URL in the form; the message says so. |
| Scan preferences | Scan cadence, alert email, alert threshold | Loads from `GET /api/tenant/settings` and saves with `PATCH /api/tenant/settings/preferences` ([`OnboardingWizard.tsx:251`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx)), the same row the Settings page edits. A failed save keeps you on the step with the server's message. |
| API key | Nothing; an opt-in reveal | **Reveal my API key**, then a confirmation, calls `POST /api/tenants/{tenant}/api-keys/initial` ([`OnboardingWizard.tsx:278`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx)). The key is shown once. **I'll do this later** moves on without calling it. |
| Containment and Consent | Policy tier, zero-trust identity, autonomous containment, audit retention | Saves the form. **Complete** calls `POST /api/onboarding/complete`. |

You can select **Skip**. It calls `POST /api/onboarding/skip`, records the
status per tenant in the `tenant_onboarding` table, and sends you to
`/overview`, which redirects to `/discovery`. The skip also sets a 30-minute
browser flag so the gate does not fire again at once.

NOTE: The wizard has no step that adds a cluster and no step that connects a
provider. The provider steps in
[`src/components/onboarding/`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/)
belong to the Connectors page, which owns that flow. The tenant is fixed by
the binding in [step 1](#1-get-an-identity), not by this wizard.

## 4. How your agents appear

The portal reads two sources. It gets the central agent list from the
discovery service `fake-integration-proxy` in the central cluster
([`api_compat.py:49-52`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py)).
That service lists pods that carry the label `signalloom.ai/agent=true` in the
namespaces `fe-signalloom-agents` and `fe-signalloom` of the central cluster
([`server.py:55-56`](../../d2-signalloom/apps/fake-integration-proxy/server.py)).

So the agents on `/agents` are the agents that run next to Signal Loom on the
central cluster. The pilot stub `agent-kusari` is one of them. Its Deployment
carries `signalloom.ai/tenant: kusari` and `signalloom.ai/model: deterministic`
([`deployment.yaml:18-20`](../../d2-signalloom/infra/agent-swarm/kusari-agent/deployment.yaml)).

Workloads on the Kusari cluster appear on `/agents` too, through
`fleet-manager`'s workload registry. The warden reports the pods on its node,
and the portal merges that registry
([`fleet_workloads.py`](../../d2-signalloom/apps/fe-signalloom/src/fleet_workloads.py)).
A remote row carries `origin: "remote"` with `cluster_id`, `pod` and `frozen`.
Its id is `remote:<cluster>/<namespace>/<pod>`.

The registry is an inventory, not a governance record. A remote pod cannot be
claimed. It has no cAdvisor telemetry and no local pod object, so its dossier
degrades rather than inventing one.

Reading the registry needs `FLEET_MANAGER_READ_KEY`, a `fleet-manager` caller
key with scope `read`. Without it `/api/agents` reports
`source_health_detail.remote_registry` as `unavailable` and lists no remote
workload. See
[faq-and-limits](faq-and-limits.md#my-cluster-workloads-are-not-on-the-agents-page).

A discovered agent becomes a governed agent when a user claims it. The claim is
`POST /api/v1/agents/{id}/claim`. The portal accepts the claim only when the
workload's `signalloom.ai/tenant` label equals your tenant and the workload
declares a model
([`claim_tenancy.py:108-152`](../../d2-signalloom/apps/fe-signalloom/src/claim_tenancy.py)).
A workload without a model gets `422 workload_model_undeclared`. The portal
never invents a model name.

1. Open `/agents`.
2. Find **Kusari Agent (stub)**.
3. Select **Auto-Claim**. The dashboard sends the claim as you, and the
   registry row is written with `tenant_id = kusari`.

Check: the row shows a governed lifecycle state, and `/audit` shows a claim
event for the agent.

The agent list is filtered by tenant. You see a discovered, registry or remote
workload only when its declared `signalloom.ai/tenant` is exactly yours. A
superadmin sees every tenant's.

A workload that declares no tenant is shown to nobody. That hides the
platform's own `controlplane`-labelled agents and any unlabelled workload.
Neither was claimable
([`api_compat.py`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py),
`_visible_to_tenant`).

## 5. Where to go next

| Need | Page |
| :--- | :--- |
| See one agent in depth | [`/agents/:id`](pages.md#agentsid) |
| Watch live observations from the warden | [`/weave`](pages.md#weave) |
| Read the audit trail of your tenant | [`/audit`](pages.md#audit) |
| Check compliance posture | [`/compliance`](pages.md#compliance) |
| Stand up the warden on the Kusari cluster | [secondary-cluster.md](secondary-cluster.md) |
| Understand what happens on a detection | [enforcement.md](enforcement.md) |

Pages you cannot use as `kusari-operator`: `/fleet`, `/fleet/audience`,
`/signal-fusion`, `/supercred`, and `/demos/*`. They are wrapped in
`SuperadminRoute` and redirect to `/agents`
([`App.tsx:17-22`](../../d2-signalloom/apps/dashboard-signalloom/src/App.tsx)).
