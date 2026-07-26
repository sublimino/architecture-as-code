# Olly Sentinel replica

A ControlPlane-internal replica of the Olly Sentinel pipeline, built on the
OSRAMP substrate to de-risk the first week of the client engagement. The
design source of truth is [agentic-sre-design-doc.md](agentic-sre-design-doc.md);
this README covers what actually runs in this directory. Everything ships
through OSRAMP: manifests are pushed as cosign-signed OCI artifacts, Flux
verifies and reconciles them, and nothing reaches the cluster by hand.

## What ARC is (the platform this abstracts)

This replica is a local abstraction of ARC, the client's enterprise runtime and
control plane for agentic AI. The full model is in the design doc
[Part II](agentic-sre-design-doc.md#part-ii-arc-platform-model-and-the-agentic-sre-dashboard);
the short version:

- **ARC is the runway, not the plane.** ARC (a Helix CLI wrapper over Google
  ADK) governs how agents run: namespace isolation, default-deny egress via
  Tiramisu, identity propagation, audit, secrets, telemetry, lifecycle. The
  agent team owns what the agent does: prompts, reasoning, tool use, outputs,
  guardrail integration, failure paths. The boundary question is always "is this
  about how the agent runs (ARC), or what the agent does (the team)?" This is why
  our LLM Guard and redaction sit in the agent, above that line.
- **Four layers:** (1) app team, (2) ARC control plane + runtime + registry,
  (3) enterprise services (COIN, Lakera, SOC, IEM), (4) OpenShift. See
  [img/arc-architecture.png](img/arc-architecture.png).
- **MCP is the mandatory intermediary.** Agents reach business systems only
  through MCP, never a direct client path. Our `elk-search-mcp` is the demo
  `acme-co-mcp`; the design doc maps DEV/UAT/PROD endpoints and the cache/metrics/
  auth middleware.
- **Identity chain (integrated).** The ARC identity chain runs in-cluster as the
  `olly-authz` service (`apps/authz/`): COIN carries the human ACME id through
  H2M then M2M (OBO), PlainID evaluates a Rego-style policy at issuance calling
  EEMS as a PIP, and one `authz_ctx_id` anchors the whole chain for a
  single-query audit answer. It is not a standalone demo: Olly mints a COIN M2M
  token on-behalf-of the SRE on-call and carries the bearer on **every MCP call**
  (elk-search-mcp verifies the token and scope) and the same token as the
  `X-AuthZ-CTX` on the **Olly -> Orbit A2A hop**, where Orbit re-validates and
  narrows it by its own local grant (`restart_service` 3 -> 1, never widened)
  before proposing. The Agentic SRE dashboard shows the live hand-off (COIN
  identity, message/send + AuthZ-CTX, input-required) on its A2A panel. Verify
  with `make authz-test` and the sentinel suite (`tests/test_authz_ctx.py`).
- **Registry + agent cards.** ARC's registry holds per-agent governance metadata
  with the A2A card published beside it. The Estate 95 "Agent Registry" window
  already mirrors this (committed-vs-live card diff included); the remaining
  parity gaps and the Real-Time Agent Execution and Transparency UI are scoped in
  the design doc.

## Layout

| Path | What it is | Design doc |
| --- | --- | --- |
| `agentic-sre-design-doc.md` | The current design: architecture, invariants, threat model, replica status, evals, open items. | n/a |
| `contracts/` | The versioned JSON Schemas everything imports; drift fails CI. Committed before any component that uses them. | §1.3, §5 |
| `components/` | The Flux manifests, in the `controllers/` and `configs/` split the d2-infra components use, with base/local/staging/production overlays. | §5 |
| `components/configs/base/seed/` | The synthetic log generator and the injection corpus, shipped inside the manifest artifact so the seed Job and its corpus version together. | §5, §6 |
| `components/configs/base/dashboards/` | The Eye in the Sky dashboards: the estate view plus a per-tenant app view. | §2 |
| `apps/` | The components we build: sentinel (Python/ADK), elk-search-mcp, the stubs, the tenant-app, eval-harness. Each flows through the OSRAMP image pipeline (build, SBOM, scan, VEX, sign/attest, admission). | §5 |

## What reconciles today

The fleet's `olly` ResourceSet creates the `olly-replica` tenant namespace and
reconciles two Kustomizations from the `olly/olly-replica` artifact.

**olly-controllers** installs the ECK operator (scoped to this namespace) and a
single-broker Redpanda, both HelmReleases from allowlisted chart repos. The
namespace carries the `toolkit.fluxcd.io/role: tenant` label, so the CEL
admission policy rejects any source the fleet allowlist does not name.

**olly-configs** brings up the rest:

- A single-node Elasticsearch with `app-logs-*`, `infra-logs-*`, and
  `audit-logs-*` as data streams.
- A Job that creates the pipeline topics: the NOI Event Queue
  `netcool.io.events`, the IO-Declined stand-in, and the
  `ideas-172472-sn30.167564-impact.event_response` topic the Mapping Service
  reads.
- The seed Job, which loads synthetic logs together with the injection
  payloads and planted fake secrets the safety suite tests against. The demo
  incidents cover the three fault domains: `inventory-service` connection-pool
  exhaustion against the positions ledger (dependency), `payments-api`
  settlement-worker OOM during the EOD batch (infrastructure), and
  `customer-portal` post-release NullPointerException (application).
- The three managed tenant apps (see [Managed tenant apps](#managed-tenant-apps)).
- The Eye in the Sky Grafana, with one datasource per allowed index pattern and
  a Prometheus datasource. It carries two dashboards: the estate view and the
  per-tenant app view. It provisions no external plugins, so it starts with no
  runtime download.

The Aqua stand-in is a platform-owned d2-infra component (`trivy-system`).
Trivy Operator scans the frontend, backend, and olly-replica namespaces, and
its report metrics reach the dashboards through the monitoring stack. That is
the scoped, read-only, provenance-labelled feed the client uses, and it gives
OSRAMP a runtime evidence source next to the build-time attestations. The
chart is on 0.34.0 (operator 0.32.0): the older 0.24.1 chart shipped operator
0.22.0, which predates Kubernetes 1.31's `SuccessCriteriaMet` Job condition and
silently writes no VulnerabilityReports on newer clusters.

## Trying it

```bash
./scripts/setup.sh        # or `make up` if the tools are installed
make demo-olly-up
kubectl -n olly-replica get pods,elasticsearch,helmrelease
kubectl -n olly-replica port-forward svc/eye-in-the-sky-grafana 3000:80
# http://localhost:3000  (admin / olly-replica-demo)
#   home "Eye in the Sky (Estate)":  the landing page, one row per app
#   dashboard "Eye in the Sky (SRE)":  SRE drill-down (control tower)
#   dashboard "Tenant App View (Olly replica)": pick a tenant from the app dropdown
```

Grafana opens on the estate single pane of glass: a top bar counting healthy,
warning, and critical apps with firing alerts and change records, over a per-app
table (condition, status, last scrape, response time, tickets, alerts, upstream
health). App names link to the tenant dashboard, ticket counts and the
escalation buttons link into ServiceNow, and the header links to the Eye in the
Sky control tower.

## Design invariants

The short version the implementation honors: Phase 1 is read-only; Olly never
writes to ServiceNow (enrichment goes to the `event_response` topic and the IO
Mapping Service writes the ticket); the correlation-ID is the join key and no
INC number reaches the agent; EEMS gates all seven read-only MCP tools under
`gco-sentinel-read` with a SIEM audit line; every gate emits a decision record
to the causality bus; the action gate (Orbit) proposes but only a signed human
approval executes; Eye in the Sky is the agent's control tower as much as the
estate view. The full statements and their threat-model rows live in
[agentic-sre-design-doc.md](agentic-sre-design-doc.md).

## The enrichment loop

One Go module ([apps/](apps/)) builds several images from a single context so
the contracts bake into each at `/contracts`. The in-build unit tests
round-trip the Go payload shapes through the schemas, so an image with drifted
contracts cannot build. These deploy via olly-configs:

- **`olly-elk-mcp:dev`** (`apps/cmd/elk-search-mcp`): the read-only MCP gateway.
  It speaks the MCP protocol (JSON-RPC 2.0 `initialize` / `tools/list` /
  `tools/call`) at `/mcp` and exposes seven tools, each under its own EEMS
  scope: `elk_search_logs` (`elk.logs.read`), `grafana_query_metrics`
  (`grafana.dashboards.read`), `observr_traces` (`observr.traces.read`),
  `cmdb_lookup_ci` (`cmdb.topology.read`), `drift_changes`
  (`drift.changes.read`), `io_events_query` (`io.events.read`), and
  `servicenow_inc_chg` (`servicenow.incidents.read`). ELK reads the seeded log
  and trace indices; the others read Prometheus, the tenant apps' live topology,
  and the Mapping Service store. An init container mints a 7-day Elasticsearch
  API key scoped to the log and trace patterns, so the process holds no
  superuser credential. Every tool checks its scope, applies query caps, and
  writes an audit line; a pattern outside the ELK allowlist returns 403.
- **`olly-stubs:dev`** (`apps/cmd/mapping-stub` and `apps/cmd/replay-producer`):
  the IO Mapping Service stand-in. It runs the subscription gate, declines
  automation onto the IO-Declined topic, and owns the only ServiceNow write
  path. It validates every `event_response` payload against the contract
  (spoofed or malformed payloads are dropped, never written) and updates the
  ticket. Without a PDI it keeps an in-memory store on `:8080`; with one it
  upserts the real incident (see [ServiceNow](#servicenow-the-pdi-write-path)).
  The replay producer emits contract-validated synthetic events.
- **`olly-sentinel:dev`** (`apps/sentinel`): the agent, on Google ADK (the
  runtime ARC manages internally) with A2A as its agent-to-agent surface. An
  ADK `BaseAgent` pipeline consumes both topics with schema validation and
  event dedup, resolves the CI and topology from CMDB by correlation-ID,
  connects to the MCP gateway as a client and calls all seven tools in parallel
  under EEMS scope checks, and correlates the evidence into a dated timeline
  (every hit treated as data and scrubbed). It classifies the fault domain from
  the dominant error signal, promotes to the `change` domain when a DRIFT record
  correlates with the error burst, and derives confidence from how many sources
  corroborate. The RCA narrative is deterministic by default; wire an LLM
  narrator with `make olly-llm-secret` (OpenRouter, Anthropic, OpenAI, or a
  local Ollama, configured in `.env`) to have a model write it. The model
  narrates the RCA; the fault domain, confidence, and suggested actions are
  computed deterministically. The pipeline then applies the loop guard and
  redaction pass, validates its own payload against the contract, publishes to
  `event_response`, and emits control-tower metrics labelled by `app_id`. Every
  gate it evaluates emits a `pipeline-decision.v1` record to
  `olly.pipeline.decisions` (see [Decision bus](#decision-bus)). The committed
  AgentCard
  ([contracts/agent-card.olly-sentinel.v1.json](contracts/agent-card.olly-sentinel.v1.json))
  is served at `/.well-known/agent-card.json`, and A2A `message/send` invokes
  the read-only TROUBLESHOOT skill directly. A module-level `root_agent` makes
  the same pipeline discoverable to `adk web` and `adk eval` (see
  [Evals](#evals)).

### Decision bus

Every gate the flow evaluates (subscription, automation-eligibility,
schema-validation, source-filter, dedup, loop-guard, HITL, publish,
ticket-write) emits one `pipeline-decision.v1` record to the
`olly.pipeline.decisions` topic, keyed by correlation-ID. The records for one
correlation-ID are that incident's causality chain, replayable and joinable
across the Mapping Service and the agent. This is observability: a record marks
a decision, it does not change routing.

### Orbit and the action gate

Orbit is the action sub-agent behind the strategic decision (Olly as a
component with TROUBLESHOOT and REMEDIATE actions). Given a completed RCA it
proposes one action from the `action-proposal.v1` closed enum
(`troubleshoot`, `remediate_restart_service`, `no_action`), selected from the
fault domain. A restart-addressable incident parks the enrichment as a proposal
instead of publishing it. Approval is an ed25519-signed token bound to the one
proposal: the console broker holds the private key and mints it when an operator
approves; the sentinel holds only the public key and verifies, so it cannot
approve its own proposals. On approval a deterministic executor records the
action under a separate identity; in Phase 1 it logs the action and performs no
mutation. Enable it with `ORBIT_ENABLED` and publish the public key with
`make orbit-approval-configmap`; Orbit's card is
[contracts/agent-card.orbit.v1.json](contracts/agent-card.orbit.v1.json).

## Managed tenant apps

`inventory-service`, `payments-api`, and `customer-portal` are the apps Olly
observes. They run as real Deployments in `olly-replica`, one per `app_id`,
from the `olly-tenant-app:dev` image (`apps/cmd/tenant-app`). Each serves a
request-rate, error-rate, and latency histogram at `/metrics`, driven by an
internal traffic generator so the series stay live without external load. A
single ServiceMonitor scrapes all three; `app_id` is a metric label, so the
per-tenant dashboard filters on it. Because the pods are real, cAdvisor also
reports genuine CPU and memory.

The apps call each other over a real dependency graph
(`customer-portal → payments-api → inventory-service`, and
`customer-portal → inventory-service`), declared per-pod with `UPSTREAMS`. Each
app calls its upstreams on the request path and probes their health, so a fault
injected into a leaf service cascades up the graph and shows in the callers'
error rates. This produces the signals the enriched flow reads as measured data
rather than static config: `tenant_app_upstream_up` for the estate table's
upstream-health light, the live edge set the `cmdb_lookup_ci` tool resolves as
topology, and W3C-traced spans written to the `traces-*` index that
`observr_traces` reads.

The metrics image is a local distroless build that Trivy cannot pull, so each
pod also carries an idle `runtime` sidecar on a distinct CVE-bearing public
image (python, redis, nginx). Trivy scans those and writes a real per-tenant
VulnerabilityReport, mirroring the vulnerable base a live service would ship.
The dashboards read the counts by `exported_namespace` (the scanned workload's
namespace) and `resource_name`, not `namespace`: because Trivy is its own
tenant, the metric's `namespace` label is always `trivy-system`, and Prometheus
moves the real namespace to `exported_namespace`. The estate and per-tenant
dashboards both break the vulnerabilities down by image and severity; for
CVE-level detail (IDs, fixed versions) index the VulnerabilityReport CRs into
Elasticsearch and read them through the ES datasource.

Per-app knobs (RPS, error rate, latency) are set in
[components/configs/base/tenant-apps.yaml](components/configs/base/tenant-apps.yaml)
so the three tenants read distinctly. To drive a visible incident, spike one:

```bash
kubectl -n olly-replica exec deploy/customer-portal -- \
  wget -qO- "http://localhost:8080/fault?seconds=180"   # 3 min of elevated errors + latency
```

## ServiceNow: the PDI write path

Olly enriches incidents; it does not open them. The IO Mapping Service does,
against a free ServiceNow Personal Developer Instance (PDI). Put the PDI
credentials in a repo-root `.env` (it is gitignored):

```bash
SERVICENOW_URL=https://dev123456.service-now.com/
SERVICENOW_USER=admin
SERVICENOW_PASSWORD=your-pdi-password
```

`make olly-pdi-secret` turns those into the `servicenow-pdi` secret and
restarts the stub. On startup the stub seeds roughly 15 incidents per tenant
app, specific to that app and spanning every fault domain (dependency,
infrastructure, application, change, data) in a mix of states (new,
in-progress, and already-enriched with a stored RCA to compare a live
deterministic or LLM re-run against), so the dashboards are populated before
any live event, and every enrichment
upserts by `correlation_id` so a ticket is tracked across passes rather than
duplicated. It also mirrors each ticket (with its ServiceNow `sys_id`) into the
`olly-incidents` Elasticsearch index, which is what the dashboards' incident
tables read. Without a `.env` the in-memory store stands in and the rest of the
loop is unchanged.

### Where to see the incidents

Two views:

- **Grafana.** Both dashboards list the individual incidents in an "Incidents"
  table (read from the `olly-incidents` index). `state=enriched` means Olly has
  posted an RCA, and each INC links straight to its own ServiceNow record by
  `sys_id`; the estate view lists every tenant's incidents, a tenant view lists
  just that app's. Set the dashboard `snow_url` constant to match your
  `SERVICENOW_URL` (the top-right link and the tile drill-downs use it). Without
  ServiceNow, the stub still serves the raw list:
  `kubectl -n olly-replica port-forward svc/io-mapping-stub 8080:8080` then
  `curl -s localhost:8080/incidents`.
- **ServiceNow itself.** Sign in at your PDI URL (the `SERVICENOW_URL` from
  `.env`) with the admin credentials. In the left filter navigator, type
  `incident.list` and press enter, or open **All > Service Desk > Incidents**.
  The seeded records have a short description like
  `[inventory-service] stock-db connection pool exhausted`; open one and check
  the **Notes** tab for the RCA work note, and the **Correlation ID** field
  (`seed-<app>-<NN>`, e.g. `seed-inventory-service-00`) for the join key. To
  follow a specific one, filter on Correlation ID.

New to PDIs: they sleep after about an hour idle and can be reclaimed after ten
days unused. Wake or renew yours at [developer.servicenow.com](https://developer.servicenow.com)
under Manage instance. If a write fails, the stub logs it and keeps serving
from the in-memory store, so the demo never blocks on ServiceNow being awake.

## Prove it

```bash
make -C olly-replica replay              # one synthetic event through the whole loop
make olly-test                           # the behavioral bats suite (also in the e2e job)
```

[test/olly.bats](test/olly.bats) reseeds Elasticsearch at startup (the seed Job
stamps `@timestamp` at ingest, so a cluster seeded hours ago would age its
incidents out of the agent's query window) and then asserts: the tenant
reconciled from a verified artifact; ES green with the seeded fixtures; topics
present; the source allowlist denies a rogue chart repo; the MCP refuses
out-of-scope index patterns; the full loop from replay event to declined to RCA
to response topic to an enriched ticket with agent attribution, the correct
fault domain for each of the three managed apps, and the planted secrets
provably absent from the published enrichment; the served agent card equals the
committed contract; and the direct A2A triage skill returns a report while
provably creating no ticket.

It also drives each core routing branch deterministically, not just the happy
path: an unsubscribed app raises a raw incident and never reaches Olly; an
automation-eligible event (`replay-producer -eligible`, a per-event marker the
mapping service acts on) is auto-remediated and never declined to Olly; a
schema-invalid event is dropped at consume and never processed; and a second
replay of the same correlation-ID is stopped by the loop guard so exactly one
enrichment publishes. The in-build pytest suite adds the deterministic-vs-LLM
check ([test_det_vs_llm.py](apps/sentinel/tests/test_det_vs_llm.py)): wiring an
LlmAgent narrator changes only the RCA summary text and the reported model id,
never the fault domain, confidence, evidence, or redaction.

## Evals

The agent is a Google ADK agent, so the same triage runs and RCAs
are inspectable in `adk web` and gated in CI. Two layers, both offline against
the seeded golden incidents:

- **The gate** ([apps/sentinel/tests/test_rca_signals.py](apps/sentinel/tests/test_rca_signals.py)):
  the full pipeline against a hermetic evidence fixture
  ([elk_stub.py](apps/sentinel/tests/elk_stub.py)) for all three apps, asserting
  fault domain, confidence, the read-only evidence trajectory (the three ELK
  patterns under `elk.logs.read`), per-app secret redaction, and no CHG inferred
  from log text. Runs in the image build. A `BaseAgent` emits no ADK
  `tool_use`, so the evidence check is the trajectory guarantee.
- **The ADK Eval tab**: `rca_readiness.evalset.json` / `.test.json` +
  `test_config.json` next to `agent.py` populate `adk web`'s Eval tab and run
  under `adk eval` / `AgentEvaluator`; a loose ROUGE response match, with the
  gate above as the hard check.

```bash
make olly-eval        # signal-check gate + rca_readiness, offline
make olly-adk-web     # adk web on :8000: agent card, Trace, and Eval tabs
```

The repo-root `make console` serves a local Windows-95 dashboard over this
replica (agent card, ServiceNow tickets, the live Kafka pipeline, cluster
state, a scoped read-only terminal, and the Eval Lab).

## Still to come

`apps/eval-harness`: the governance layer above the ADK eval set. It replays a
labelled incident set, captures capability timings (the sub-15-minute
time-to-RCA target), runs shadow-mode agent-versus-human comparison, and emits
records that validate against `contracts/eval-record.v1.schema.json`. It needs
the client-owned historical incident set for the human baseline (design doc
§7 #6). A green eval run is the demo's exit criterion.
