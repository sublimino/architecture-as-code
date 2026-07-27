# SignalLoom dashboard API contract inventory

## Scope and method

This is the source-backed inventory for dashboard calls made by the local
SignalLoom implementation at the integration baseline `d51bfc6`. The card
names `cp/platform/dashboard/src/api/` as a React source directory, but that
directory is not present in this repository. The effective dashboard is the
Estate95 plain-JavaScript client under `ui/`, served by the Go broker in
`tools/demo-console/`. This document therefore inventories every `/api/*`
request found in those client files; it does not claim a React implementation
exists.

`handler` names the broker's local serving function. `Backing` identifies the
adapter, fake service, static contract, or in-memory persistence that supplies
the response. `Needs implementation` is used only where a client call has no
confirmed local serving path; none were found at this baseline.

## Client-call inventory

| Method | Endpoint | Client evidence | Request shape | Response shape | Local handler | Backing | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `GET` | `/api/health` | `ui/agentic-sre.html:pingBroker` | none | `{ok:boolean, ns:string}` | `main.go` inline registration (`:1398`) | static broker health response | served |
| `GET` | `/api/steps` | `ui/windows/osramp-console.js:open` | none | `{lanes:[...]}` | `main.go` inline registration (`:1374`) | `ui/steps.json` static persistence | served |
| `POST` | `/api/runs` | `ui/estate95.js:runAction` | JSON `{action:string}` | `{id:string}` | `main.go:handleRuns` | action lookup from `ui/steps.json`; `console.runs` in-memory state | served |
| `GET` | `/api/runs/{id}/events` | `ui/estate95.js:runAction` | path `{id}` | SSE messages containing `line:string` or `exit:number` | `main.go:handleEvents` | `console.runs` in-memory state | served |
| `GET` | `/api/cluster/overview` | `ui/windows/cluster.js:load` | none | `{pods:[...], flux:[...], ready:boolean}` | `main.go:handleClusterOverview` | live `kubectl` adapter | served |
| `GET` | `/api/incidents` | `ui/windows/servicenow.js:load`; `ui/agentic-sre.html` | none | incident array | `main.go:handleIncidents` | `io-mapping-stub` in-memory fake service | served |
| `GET` | `/api/agent-card/{name}` | `ui/windows/agent-cards.js:load`; `ui/agentic-sre.html` | path `{name}` | AgentCard JSON | `main.go:handleAgentCardCommitted` | `olly-replica/contracts/*.json` static contracts | served |
| `GET` | `/api/agent-card/live/{name}` | `ui/windows/agent-cards.js:verifyLive`; `ui/agentic-sre.html` | path `{name}` | AgentCard JSON | `main.go:handleAgentCardLive` | Sentinel well-known proxy for `olly-sentinel`; static contracts otherwise | served |
| `GET` | `/api/orbit/proposals` | `ui/windows/orbit.js:load`; `ui/orbit-alerts.js`; `ui/agentic-sre.html` | query `state=proposed` | proposal array | `orbit.go:registerOrbit` | Sentinel `/orbit/proposals` proxy | served |
| `POST` | `/api/orbit/approve` | `ui/windows/orbit.js:decide`; `ui/agentic-sre.html` | JSON `{proposal_id:string, approved_by:string}` | approval JSON | `orbit.go:registerOrbit` | broker signing plus Sentinel proxy | served |
| `POST` | `/api/orbit/reject` | `ui/windows/orbit.js:decide`; `ui/agentic-sre.html` | JSON `{proposal_id:string, rejected_by:string}` | rejection JSON | `orbit.go:registerOrbit` | Sentinel rejection proxy | served |
| `GET` | `/api/eval-history` | `ui/windows/eval-lab.js:load` | none | `{runs:[...], scorecard:[...], note:string}` | `main.go:handleEvalHistory` | `.adk/eval_history/*.json` persistence | served |
| `GET` | `/api/pipeline/node/{id}` | `ui/windows/pipeline.js:inspectNode`; `ui/agentic-sre.html` | path `{id}` | `{id,title,kind,source,lines:[...]}` | `main.go:handlePipelineNode` | Kafka, pod-log, ELK, or ticket adapters | served |
| `GET` | `/api/pipeline/events` | `ui/windows/pipeline.js` | none | SSE `hello`, `stage`, `decision`, `ticket`, `ping` events | `main.go:handlePipelineEvents` | Kafka/rpk adapter plus ticket polling | served |
| `GET` | `/api/metrics/query` | `ui/agentic-sre.html:prom` | query `q:string`, optional `time` | Prometheus query JSON | `metrics.go:registerMetrics` | monitoring Prometheus adapter | served |
| `GET` | `/api/security/status` | `ui/windows/security-sandbox.js:refreshStatus` | none | `{guard_reachable:boolean, detail:string, scanners:[...]}` | `security.go:registerSecurity` | LLM Guard health adapter | served |
| `POST` | `/api/security/scan` | `ui/windows/security-sandbox.js` scan handler | JSON `{text:string, direction:string}` | `{is_valid:boolean, scanners:[...], sanitized?:string, direction:string}` | `security.go:registerSecurity` | LLM Guard adapter | served |
| `POST` | `/api/security/probe` | `ui/windows/security-sandbox.js` probe handler | JSON `{message:string, llm_guard_enabled:boolean}` | guarded agent response JSON | `security.go:registerSecurity` | LLM Guard plus Olly/Sentinel adapter | served |

## Explicit exclusions and waivers

- `GET /api/incidents/{id}` is registered by the broker for compatibility, but
  no dashboard client call was found. It is not an inventory row because this
  card inventories client calls, not every broker route. It uses the same
  `main.go:handleIncidents` and `io-mapping-stub` backing as `/api/incidents`.
- `/proxy/{adk|grafana}/...` and `/ws/term` are non-`/api/*` dashboard
  transports. They remain in `tools/demo-console/testdata/dashboard-api-contracts.json`
  for broker-contract coverage but are outside this inventory's endpoint set.
- No client call needs implementation and no client-call waiver is claimed at
  this baseline.

## Validation relationship

`tools/demo-console/dashboard_contracts_test.go` validates the repository
fixture and verifies that each `/api/*` fixture endpoint has a complete row in
this document. Run it with:

```bash
(cd tools/demo-console && go test ./...)
```
