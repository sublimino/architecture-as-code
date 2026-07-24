# Init delivery

This package has three parts: the Eye in the Sky Grafana dashboards, the A2A agent cards
for the Olly and Orbit agents, and the 'payload contracts' those agents produce. Everything
here is read-only reference material and self-contained.

## Grafana dashboards

Three Grafana dashboards which go from Eye in the Sky (estate view) -> Eye in the Sky (SRE view) -> tenant app view with the custom theme I showed today (dark security-control-center theme
with an inline 'Matrix' background). Each file is self-contained (theme styling is inline in
text panels, no external CSS, fonts, or scripts) and was exported "for sharing externally",
so the Prometheus and Elasticsearch datasources are template variables you can bind on your own (however you have these services setup and running local to your env).

A quick note on the theme: the dark control-center CSS and the Matrix background both live in a single text panel on the estate dashboard and inject globally, so they carry across to the SRE and tenant views as you navigate in from estate (the home dashboard). We left the SRE and tenant dashboards without their own theming on purpose, to keep Grafana's native visualisations clean on those detailed views, but we can apply the theme to them, or restyle it however you want.

### Contents

| File | Dashboard | UID | Scope |
|------|-----------|-----|-------|
| `eye-in-the-sky-estate.json` | Eye in the Sky (Estate) | `estate-pane` | Landing page: estate health, firing alerts, change counts, and the applications table. |
| `eye-in-the-sky-sre.json` | Eye in the Sky (SRE) | `eye-in-the-sky` | SRE drill-down: RCA lifecycle, HITL approvals, per-tenant health, Aqua/Trivy. |
| `tenant-app-view.json` | Tenant App View | `tenant-app-view` | Per-tenant cut, opened from the tables above. |

### How we use them

- **Estate is the 'single pane of glass' overview level dashboard.** The top row is the estate verdict
  computed from Prometheus alert rules (healthy / warning / critical app counts, alerts
  firing) plus two change counters from the Elasticsearch audit index. The table below
  joins each app's serving state, 5xx rate, latency, upstream health, INC/CHG counts, and
  an escalation link.
- **SRE is the operator view.** Per-stage RCA latency from `olly_stage_duration_seconds`,
  enrichment throughput and outcomes from `olly_incidents_*`, the human-in-the-loop
  approval queue from `olly_hitl_pending`, model token spend, and the Aqua/Trivy
  vulnerability feed. The tables here also link into ServiceNow per INC and into the tenant
  dashboard per app.
- **Tenant is the per-app cut** of the same request, health, and RCA metrics, reached by
  clicking an app in either table above.
- **Data comes from two read-only sources.** Prometheus supplies `tenant_app_*` (tenant
  metrics), `olly_*` (agent metrics), and the Trivy Operator metrics; Elasticsearch
  supplies the `olly-incidents` index for tickets and the `*-logs-*` indices for evidence.

### How to use them

1. Set two Grafana options so the inline theme renders:

   ```ini
   [panels]
   disable_sanitize_html = true

   [users]
   default_theme = dark
   ```

   (or as env vars): `GF_PANELS_DISABLE_SANITIZE_HTML=true` and
   `GF_USERS_DEFAULT_THEME=dark`. The same block is in `grafana.ini.snippet` in this
   folder. Without the first, Grafana strips the inline
   `<style>`/`<script>` and the theme does not render (data still shows). Panels that
   display raw log text keep Grafana's HTML escaping on, which is a light sanitisation
   control.

2. Import each file (Dashboards, Import, upload the JSON). Grafana prompts for the
   datasource bindings; point `DS_PROMETHEUS` at your Prometheus and `DS_ELASTICSEARCH`
   at your Elasticsearch.
   - Elasticsearch: the `olly-incidents` index backs the incident tables, `*-logs-*` back
     the log panels.
   - Prometheus: `tenant_app_*`, `olly_*`, and the Trivy Operator metrics.

3. Import the estate dashboard first and set it as the home dashboard. The estate and SRE
   tables link into the tenant dashboard by its UID, so import all three. The ServiceNow
   links point at a placeholder instance (`dev12345.service-now.com`); change them to
   your own instance URL.

## A2A and the agent cards

I've also attached the A2A agent cards I showed this morning. `agent-card.olly-sentinel.v1.json` (the read-only
triage and enrichment agent) and `agent-card.orbit.v1.json` (the 'action' agent). There is also a JSON schema (`rca-enrichment.v1.schema.json`) for the RCA enrichment payload which is what Olly returns -> event_response -> ServiceNow tickets.

### What an agent card is

In A2A an agent card is a JSON "business card" a client fetches to discover an agent and
understand its capabilities. The protocol recommends serving it at
`https://<base_url>/.well-known/agent-card.json`, retrieved with a plain HTTP GET. The
card declares `name`, `description`, `url`, `version`, a `capabilities` object
(`streaming` for SSE, `pushNotifications`, `stateTransitionHistory`),
`defaultInputModes` / `defaultOutputModes`, `securitySchemes`, and a `skills` array where
each skill carries an `id`, `name`, `description`, `tags`, and `examples`.

### How the exchange works

A client reads the card, then calls the agent over JSON-RPC (`message/send`). The agent
runs the request as a task that moves through a lifecycle (`submitted`, `working`,
`completed`), or pauses at `input-required` when it needs something back before it can
finish. Our agents use this same shape:

- **Olly** serves its card at `/.well-known/agent-card.json` and exposes one skill,
  `triage_enrich_incident`. A `message/send` runs the read-only RCA and returns an
  `rca-enrichment.v1` payload. It never writes to ServiceNow.
- **Orbit** serves its own card and exposes `propose_action`. That skill is
  approval-gated, so a `message/send` comes back as an `input-required` task: Orbit has
  proposed one action and is waiting on a human decision. The decision is an
  ed25519-signed token Orbit verifies with a public key it holds and cannot mint.
- When Olly parks an action, it hands the decision to Orbit over A2A via
  `message/send`; that hand-off is recorded on the decision bus as `orbit_a2a / engaged`.

### How it maps to ARC

A2A defines three discovery modes: open discovery through the well-known URI, private
API-based discovery, and curated registries, where "enterprise-level applications will
provide curated Agent registries through directory interfaces ... maintained by
administrators." ARC is that curated registry (as you've shown us on Friday). In your estate, ARC ingests these
committed cards as governed agent identities, resolves them from its directory rather than
a raw URL, and enforces the auth the cards declare in `securitySchemes` (the EEMS bearer
role, and Orbit's signed-approval scheme). Concretely, that bearer is where COIN comes in:
in your estate the EEMS scheme resolves to a COIN machine-to-machine (M2M) credential, so
each client-to-agent and agent-to-agent `message/send` carries a COIN-issued M2M token
that ARC or the gateway validates before the call reaches the skill. That token is the
machine identity (who is calling); Orbit's ed25519 approval token is a separate thing that
authorises one specific action (the human decision). The card fields are a sort of
'categorization surface' that ARC governs (skills, tags, capabilities, version, read-only
scope, etc).

### How we run it in the demo

The A2A mechanics here are real, not mocked: both cards are served at
`/.well-known/agent-card.json`, they validate as A2A cards, a `message/send` runs the
actual skill (Olly's read-only RCA, Orbit's `propose_action`), and Orbit genuinely comes
back with an `input-required` task that the signed approval resolves. What differs from how
you would deploy it via ARC is the hardening and durability around the protocol, not the
protocol itself:

- **The URLs are cluster-internal.** The cards point at
  `olly-sentinel.olly-replica.svc.cluster.local` (`:8080` for Olly, `:8081` for Orbit),
  not a public gateway domain, so we reach Orbit's endpoint with a `kubectl port-forward`.
  Under ARC the `url` resolves from the registry to a real gateway address instead.
- **The declared auth is not challenged here.** The `securitySchemes` on the cards (the
  EEMS bearer, and Orbit's approval JWT) are the contract ARC and COIN consume; the replica
  does not actually reject an unauthenticated caller on the A2A endpoints. In your estate,
  COIN M2M mints and validates that bearer before the call reaches the skill (see "How it
  maps to ARC"). The one gate that IS enforced locally is the signed approval token: the
  broker holds the private key, the sentinel holds only the public key, so the agent cannot
  approve its own work.
- **State is in-memory and single-instance.** The sentinel runs as one pod, and both the
  A2A tasks and the parked proposals live in that process's memory, not a database. A pod
  restart drops every in-flight task and every not-yet-approved proposal, and a second
  replica would not see the first's state, so it does not scale horizontally as-is.
  Production should back both with a durable, shared store.
- **The endpoints are plain HTTP.** No TLS on `:8080` / `:8081`. Fine for loopback and
  in-cluster traffic on a kind cluster, not for anything crossing an untrusted network;
  production puts the endpoints behind TLS (a gateway, or mesh mTLS).
- **`input-required` is model-driven.** Orbit produces the pause through ADK's
  confirmation-gated tool: the model reads the message, calls `propose_action`, and that
  pending confirmation is what ADK surfaces as `input-required`. With no model configured
  the Orbit A2A agent does not even start, so the pause needs a reachable model (here
  `google/gemini-2.5-flash` via the R2D2 gateway) and adds one model round-trip per call.
