# Dashboard journey matrix

The Estate 95 dashboard is served from `ui/index.html`; it is a client-side
window manager, not a URL router. `ui/estate95.js` registers and opens windows
through `Estate95.open(id)`.

## Routes and windows

| Journey | Window ID | Source |
| --- | --- | --- |
| Dashboard root | `/` / Read Me | `ui/index.html`, `ui/windows/readme.js` |
| OSRAMP Console | `osramp-console` | `ui/windows/osramp-console.js` |
| Control Plane | `control-panel` | `ui/windows/control-panel.js` |
| Agent Registry | `agent-cards` | `ui/windows/agent-cards.js` |
| Orbit approvals | `orbit` | `ui/windows/orbit.js` |
| ServiceNow | `servicenow` | `ui/windows/servicenow.js` |
| Cluster State | `cluster` | `ui/windows/cluster.js` |
| Scoped Terminal | `terminal` | `ui/windows/terminal.js` |
| Pipeline | `pipeline` | `ui/windows/pipeline.js` |
| ADK Studio | `adk-studio` | `ui/windows/adk-studio.js` |
| Eval Lab | `eval-lab` | `ui/windows/eval-lab.js` |
| Eye in the Sky | `grafana` | `ui/windows/grafana.js` |
| Security Sandbox | `security-sandbox` | `ui/windows/security-sandbox.js` |
| Agentic SRE launcher | `agentic-sre` / `/agentic-sre.html` | `ui/windows/agentic-sre.js`, `ui/agentic-sre.html` |

## API journeys

| API | Consumer journey | Failure state |
| --- | --- | --- |
| `GET /api/health` | broker health | broker unavailable |
| `GET /api/steps` | OSRAMP Console / Control Plane | missing lane or fetch failure |
| `POST /api/runs` | action start | rejected action |
| `GET /api/runs/{id}/events` | action stream | exit failure or stream error |
| `GET /api/cluster/overview` | Cluster State | cluster not ready (`503`) |
| `GET /api/incidents` | ServiceNow | empty store or fetch failure |
| `GET /api/incidents/{id}` | broker-supported detail route; dashboard currently renders list data locally | missing incident |
| `GET /api/agent-card/{name}` | Agent Registry | card fetch failure |
| `GET /api/agent-card/live/{name}` | live verification | unavailable or contract mismatch |
| `GET /api/orbit/proposals` | Orbit | sentinel unavailable |
| `POST /api/orbit/approve` | signed approval | missing key or denied approval |
| `POST /api/orbit/reject` | rejection | unknown proposal or rejection failure |
| `GET /api/security/status` | Security Sandbox | scanner unavailable |
| `POST /api/security/scan` | Security Sandbox scan | flagged or failed scan |
| `POST /api/security/probe` | guarded Olly probe | blocked, guard unavailable, or agent unavailable |
| `GET /api/metrics/query` | metrics proxy | Prometheus failure |
| `GET /api/eval-history` | Eval Lab | history fetch failure |
| `GET /api/pipeline/events` | Pipeline SSE | stream failure |
| `GET /api/pipeline/node/{id}` | Pipeline detail | node fetch failure |
| `GET /proxy/adk/*`, `GET /proxy/grafana/*` | embedded ADK/Grafana | proxy refusal, blank frame, or Grafana login |
| `WebSocket /ws/term` | Scoped Terminal | cross-origin `403`, socket closure, or refused executable |

## Authentication and error states

The broker registers handlers directly and has no login/session middleware
(`tools/demo-console/main.go`). Local binding is its access boundary. Grafana
can independently require its `admin` login and reject iframe embedding;
ADK can reject framing. Orbit identity defaults to `estate95-operator` and the
broker signs approvals. The terminal accepts same-origin WebSocket upgrades and
rejects cross-origin ones.

## Critical browser baseline

| Critical flow | Current boundary | Browser coverage | Baseline scope |
| --- | --- | --- | --- |
| Login | Dex owns `/dex/auth`; the local broker has no session middleware. | `signalloom-test-1.spec.ts` — `Dex login token maps demo user to local tenant` | Live Dex and integrated API contract. |
| Dashboard view | The broker serves `ui/index.html`; Estate95 opens windows client-side. | `dashboard-journey.spec.ts` — `renders the Security Sandbox launcher from the dashboard view` | Local broker. |
| Scan initiation | Security Sandbox posts `{text, direction}` to `POST /api/security/scan`. | `dashboard-journey.spec.ts` — `posts selected security text to initiate a scan` | Intercepted scan API request. |
| Results display | Scan response supplies `is_valid`, `scanners`, and optional `sanitized`. | `dashboard-journey.spec.ts` — `renders a flagged scan verdict and scanner result` | Intercepted scan API response. |

## Fake interactions

- Estate desktop controls (Start menu, taskbar, drag, resize, minimize, theme)
  are browser-only interactions (`ui/estate95.js`).
- Orbit Phase 1 records an approved action instead of executing infrastructure
  mutation (`ui/windows/orbit.js`).
- ServiceNow defaults to the in-memory `io-mapping-stub`.
- Agent Registry reference peers and `ui/registry.json` are static metadata.
- Pipeline topology and Security Sandbox preset strings are fixed demo data;
  their event/detail and guard paths remain live where available.

## Dashboard-signalloom SPA routes (React)

The `dashboard-signalloom` workload is a separate React SPA (distinct from the
Estate95 discovery portal above). It is served by nginx at `:8080` with a
history-fallback (`try_files $uri $uri/ /index.html`) and authenticated via
local Dex OIDC at `localhost:5173`.

| Route | Page | Data source | Smoke test |
| --- | --- | --- | --- |
| `/agents` | Agents (default landing) | API `/api/agents` | `smoke.spec.ts` |
| `/agents/:id` | Agent Detail | API `/api/agents/:id` | — |
| `/compliance` | Compliance | API `/api/compliance/*` | `smoke.spec.ts` |
| `/compliance/:fwId` | Framework Detail | API `/api/compliance/frameworks/:id` | — |
| `/audit` | Audit Trail | API `/api/audit` | `smoke.spec.ts` |
| `/cryptography` | Cryptography | Self-contained mock | `smoke.spec.ts` |
| `/federated-services` | Federated Services | Self-contained mock | `smoke.spec.ts` |
| `/collusion-access` | Collusion & Access | Self-contained mock | `smoke.spec.ts` |
| `/settings` | Settings | API `/api/tenant/settings` | `smoke.spec.ts` |
| `/onboarding` | Onboarding Wizard | API `/api/connectors` | — |
| `/redeem-invite` | Redeem Invite | API `/api/invite` | — |
| `*` | Redirect → `/agents` | — | `smoke.spec.ts` |

Static assets: `/favicon.ico` and `/brand/*.png` (icons and the sidebar logo).
Collusion & Access previously carried a `/ktp-collusion-graph.png` backdrop; it
was removed so the page matches its siblings, and `smoke.spec.ts` now asserts its
absence.

BATS runtime coverage: `d2-signalloom/test/dashboard-routes.bats` — SPA
fallback for every route, static assets served, and bundle route references.

## Baseline coverage

`test/acceptance/dashboard-journey.spec.ts` covers client-side window opening,
Grafana's independent login state, the Cluster `503` error state, and Orbit's
record-only approval interaction. It intercepts API/proxy responses so the
assertions do not require a live cluster, but still requires the local broker.
The critical browser baseline adds a source-backed Security Sandbox scan path;
the separate Dex contract remains the authoritative login test because the
dashboard itself deliberately has no login form.
