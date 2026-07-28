# Mocks & Proxy Fidelity Appraisal — SignalLoom D2 Demo Cluster

> Read-only appraisal. Scope: fake-integration-proxy, olly-replica stubs, dashboard connectors frontend mock.
> Root: `.../signalloom-d2-v2.5.0/governor/`
> Date: 2026-07-27

## (a) Inventory

| Name | What it fakes | Endpoints exposed | Fidelity | Deployed in-cluster? | Contract test? |
|------|---------------|-------------------|----------|----------------------|----------------|
| **fake-integration-proxy** (`d2-signalloom/apps/fake-integration-proxy/server.py`, 197 LOC) | Outbound SaaS integrations for the SignalLoom demo: LLM assistants, CRM, notifications, outbound-reporting. Makes **no** outbound calls; pure in-process fake. | `GET /health`; business: `/llm/*`, `/crm/*`, `/notification/*`, `/outbound-reporting/*` (all verbs); control (demo-only): `GET/DELETE /_test/requests`, `GET /_test/fixtures`, `PUT /_test/fixtures/{cat}/{name}` | **Stateful (mutable, ephemeral)**. Deterministic default fixtures per category (`DEFAULT_FIXTURES`, server.py:31-36); route-suffix fixture selection (`select_fixture`, :77-82); fixtures overridable at runtime via control API; request-capture log with secret/PII redaction (`redact`, :39-48; `SENSITIVE_BODY_KEYS`, :25-28). State lost on pod restart. | **Yes.** Deployment+Service in `infra/inf-signalloom/base/fake-integration-proxy.yaml`, referenced by `base/kustomization.yaml`. Ingress NetworkPolicy in `configs/base/fake-integration-proxy-networkpolicy.yaml` (referenced by `configs/base/kustomization.yaml`) — only `fe-signalloom` pods may reach `:8080`. | **Yes.** `test/test_proxy.py` (100 LOC, unittest) + `test/container-test.sh` (redaction assertion in-container). Covers determinism, secret redaction, header exclusion, fixture mutation/reset, control-API gating. |
| **io-mapping-stub** (`olly-replica/apps/cmd/mapping-stub/main.go`, 1216 LOC; image `olly-stubs:dev`) | IBM Netcool/BigPanda "IO Mapping Service": subscription gate, event routing/decline, and the **sole** ServiceNow write path in the Olly pipeline. | `GET /incidents` (opt `?app_id=`), `GET /incidents/{corr}`, `GET /events`, `GET /metrics` (Prometheus `olly_incidents{app_id}`, `olly_incidents_state{app_id,state}`), `GET /healthz` (main.go:618-682). Plus Kafka consumer/producer (not HTTP). | **High — near-production, stateful + real side effects.** Real Kafka consumers/producer via `segmentio/kafka-go`; **JSON-Schema contract validation** of every event and enrichment payload (`santhosh-tekuri/jsonschema/v5` + `internal/contracts`: EligibleEvent, RcaEnrichment, PipelineDecision) with DROP-and-count on invalid (:496-501, :598-599); real **ServiceNow Table API** client (`snClient`, upsert keyed by correlation_id, create→PATCH, captures sys_id, :706-857); real **Elasticsearch** writer into `olly-incidents*` with index-template bootstrap (`esClient.ensureSchema`, :858-940); in-memory ticket store as fallback/assertion surface. ServiceNow/ES degrade gracefully when unwired (best-effort, non-blocking). | **Yes.** `components/configs/base/io-mapping-stub.yaml` in `configs/base/kustomization.yaml` (line 10). ServiceMonitor scrapes `/metrics`. | **Contract-enforcing by design** (schemas gate the write path); assertion surface is the in-memory store + wider olly test suite. No standalone `*_test.go` co-located in this dir observed. |
| **replay-producer** (`olly-replica/apps/cmd/` — same `olly-stubs:dev` image; per `apps/stubs/README.md`) | Netcool/BigPanda event source. Emits one synthetic event onto `netcool.io.events`. | n/a (Kafka producer, `make replay`) | **Scripted, schema-guarded.** Validates against `contracts/eligible-event.v1.schema.json`; refuses drifted payloads. | Built into `olly-stubs:dev` (deployed image); run on-demand. | Schema-validated emission (self-contract). |
| **elk_stub** (`olly-replica/apps/sentinel/tests/elk_stub.py`, 272 LOC) | The ELK/MCP evidence server (`elk-search-mcp`) for hermetic Olly Sentinel ADK evals/`adk web`. | HTTP: `POST /tools/{tool}` and `POST /mcp` (JSON-RPC: `initialize`, `tools/list`, `tools/call`) for tools `elk_search_logs`, `grafana_query_metrics`, `observr_traces`, `drift_changes`, `cmdb_lookup_ci`, `io_events_query`, `servicenow_inc_chg`. | **Hardcoded golden corpus.** `GOLDEN = _build()` — canned hits for 3 seeded incidents (inventory→dependency, payments→infra, customer-portal→application) mirroring `seed/seed-logs.sh` + `injection-corpus.ndjson`; `EXPECTED` per-incident redaction ground truth. Non-ELK tools return empty envelopes. Includes planted prompt-injection / secret / PII lines to exercise the guard. | **No — test/eval fixture only.** Serves `127.0.0.1:8099` standalone or `serve_in_thread` for tests. Not in any kustomization. | **It is the contract test fixture** — imported by `olly_sentinel/eval_test.py`; `GOLDEN`/`EXPECTED` are the eval oracle. |
| **connectorsClient.ts mock layer** (`platform/dashboard/src/api/connectorsClient.ts`, 228 LOC; mirror at `d2-signalloom/apps/dashboard-signalloom/src/api/connectorsClient.ts`) | The connector-framework backend (ADR-ENHC-012, "PR #19" on `services/agent_registry/routers/connectors.py`) — a browser-side stand-in. | Mock intercepts the client calls; real client (`liveConnectorsApi`) would call `GET /api/connectors/providers`, `GET /api/connectors`, `POST /api/connectors`, `DELETE /api/connectors/{id}`, `POST /api/connectors/{id}/test` (`/api` prefix added in `req`, :39). | **Hardcoded providers + in-memory session state.** `MOCK_PROVIDERS` = 4 canned providers (Entra ID, Google Workspace, AWS IAM, GCP IAM) with wizard field specs (:93-162); `mockConnectors` module-level array, resets on reload (:164-167); create/delete/test mutate it; `delay()` simulates latency. | **N/A — frontend build-time toggle.** `VITE_CONNECTORS_API_MODE` defaults `!== 'live'` → mock (`MOCK_MODE`, :226-228). No server component. | Component tests exist (`WizardFieldRenderer.test.tsx` etc.); no backend contract test — the backend it mocks does not exist yet. |

## (b) Verdict — correct standard for a live walking demo?

- **fake-integration-proxy — AT STANDARD (demo-grade, correctly scoped).** Deterministic, stateful, runtime-mutable fixtures; security-hardened (readOnlyRootFS, drop ALL caps, non-root, no egress, ingress locked to `fe-signalloom`); secret/PII redaction with tests. For a *walking demo of the SignalLoom integration surfaces* it is exactly the right fidelity — deterministic and safe. Its explicit purpose ("not an integration gateway", server.py:2-6) matches its scope. Not toy-grade. **Caveat:** it does **not** serve the connectors framework (see (c)).

- **io-mapping-stub — ABOVE STANDARD (production-adjacent).** This is not a toy: real Kafka, real JSON-Schema contract enforcement with drop-and-count, real ServiceNow Table API upserts, real Elasticsearch mirroring, Prometheus metrics feeding the dashboards. It carries the routing/contract behaviour of the real component and can be pointed at a live ServiceNow PDI with zero code change. Comfortably backs a live walking demo; the "stub" label understates it.

- **replay-producer — AT STANDARD** for its narrow job (schema-guarded synthetic event injection).

- **elk_stub — AT STANDARD *as a test/eval fixture*, TOY-GRADE if mistaken for cluster infra.** It is a hermetic hardcoded golden corpus, correct and deliberate for reproducible ADK evals, but it is not deployed and must not back a live cluster demo — the live path uses the real `elk-search-mcp` against seeded Elasticsearch. Fine as long as the demo uses the deployed MCP, not this file.

- **connectors frontend mock — TOY-GRADE relative to a live walking demo, by admission.** In-memory, resets on reload, 4 hardcoded providers, no persistence, no real credential validation. Header comments state it is a placeholder "until PR #19 merges." Acceptable to *demo the onboarding wizard UI*, but any claim of a live end-to-end connector flow is unbacked. See (c).

## (c) The connectors live-mode gap (dashboard vs cluster)

**In live mode (`VITE_CONNECTORS_API_MODE=live`), the dashboard would call:**

| Method | URL (client adds `/api` prefix, connectorsClient.ts:39) | Live handler |
|--------|----------------------------------------------------------|--------------|
| GET | `/api/connectors/providers` (:62) | `listProviders` |
| GET | `/api/connectors` (:67) | `listConnectors` |
| POST | `/api/connectors` (:72) then refetch `/api/connectors` (:75) | `createConnector` |
| DELETE | `/api/connectors/{id}` (:84) | `deleteConnector` |
| POST | `/api/connectors/{id}/test` (:88) | `testConnector` |

**What the cluster actually serves:** nothing at those paths. Confirmed:

1. **No backend exists.** No `services/agent_registry/` directory, no `connectors.py`, no router serving `/connectors*` or `/ln/*` anywhere in `d2-signalloom/`, `olly-replica/`, or `platform/`. "PR #19" (ADR-ENHC-012, `platform/docs/adr/ADR-ENHC-012-connector-framework.md`) is **unmerged** — the client comment (connectorsClient.ts:13-16) says so explicitly. The ADR places these routes on the `agent-registry` service, which carries no connectors router in-tree.
2. **fake-integration-proxy does NOT serve them.** Its route prefixes are `/llm/`, `/crm/`, `/notification/`, `/outbound-reporting/` (server.py:19-24). Grep for `connector` in `server.py` → none. It answers `404 {"error": "unknown route"}` (server.py, `_dispatch`) for any `/connectors*` request. It is also namespace-firewalled to `fe-signalloom` ingress only, and the connectors UI lives in the `platform`/`dashboard-signalloom` app, not wired to it.

**Net gap:** flipping the toggle to `live` today yields **5 unhandled endpoints → 404s across the entire connector onboarding flow.** The mock is the *only* thing making the connectors UI functional. To close the gap either (a) merge PR #19 / implement the `agent-registry` connectors router at `/api/connectors*`, or (b) extend fake-integration-proxy with a `connectors` route group serving the PR-#19 response shapes documented in connectorsClient.ts:20-29 (providers list, thin create response, `connector_id`-keyed rows, test result without `days_until_expiry`) and open a NetworkPolicy path from the connectors UI namespace. Neither exists now.

## Key file references

- `d2-signalloom/apps/fake-integration-proxy/server.py` — fake proxy (routes :19-24, fixtures :31-36, redaction :39-48, control API :143-174, dispatch/health)
- `d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py`, `test/container-test.sh` — contract tests
- `d2-signalloom/infra/inf-signalloom/base/fake-integration-proxy.yaml` + `base/kustomization.yaml` — deployment
- `d2-signalloom/infra/inf-signalloom/configs/base/fake-integration-proxy-networkpolicy.yaml` + `configs/base/kustomization.yaml` — ingress lockdown
- `olly-replica/apps/cmd/mapping-stub/main.go` — IO mapping stub (routes :618-682, schema validation :496-501/:598-599, ServiceNow :706-857, ES :858-940, metrics :639-671)
- `olly-replica/apps/stubs/README.md` — stub charter
- `olly-replica/components/configs/base/io-mapping-stub.yaml` (in `kustomization.yaml:10`) — deployment
- `olly-replica/apps/sentinel/tests/elk_stub.py` — hermetic ELK/MCP golden fixture (GOLDEN :136, EXPECTED :147, MCP handler :213-249)
- `platform/dashboard/src/api/connectorsClient.ts` (mirror: `d2-signalloom/apps/dashboard-signalloom/src/api/connectorsClient.ts`) — frontend mock/live toggle (:226-228)
- `platform/docs/adr/ADR-ENHC-012-connector-framework.md` — the unbuilt backend spec
