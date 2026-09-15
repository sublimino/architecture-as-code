# SLCD-P5-PRE — Signal Ingest Routing, API Surface, and Topology UI Architecture

**Status:** Complete · **Role:** Preflight · **Date:** 2026-09-15 · **Author:** SLCD-P5-PRE

---

## Executive Summary

This preflight analysis confirms the real `signal-ingest` API surface, the actual dashboard routing behaviour in `dashboard-signalloom`, and the existing Topology/Agent Swarm UI conventions. It resolves the routing ambiguity flagged in SLCD-P1-3 before SLCD-P5-1 (Ingestion pipeline) and SLCD-P5-2 (UI visualization) start implementation against an undecided target.

---

## 1. Actual `/api/` Routing Behaviour & The Routing Gap

### 1.1 Current Reverse Proxy Configuration
Inspection of `d2-signalloom/apps/dashboard-signalloom/nginx.conf:102-108` reveals:

```nginx
location /api/ {
  set $api http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000;
  proxy_pass $api$request_uri;
  proxy_set_header Host $host;
  proxy_set_header Authorization $http_authorization;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

### 1.2 Upstream Architecture & Ingress Gateway
- **FastAPI BFF (`fe-signalloom-api`)**: Listens on port 8000 in namespace `fe-signalloom`. Serves platform APIs, authentication verification, and acts as the Backend-For-Frontend (BFF) proxying selected backend queries to internal services.
- **Go Signal Ingestion Service (`signal-ingest`)**: Listens on port 8082 in namespace `fe-signalloom` (`http://signal-ingest:8082`).
- **Envoy Ingress Gateway**: The Gateway API `HTTPRoute` for `signalloom-api` matches `PathPrefix: /api` and forwards directly to `fe-signalloom-api:8000`.
- **NetworkPolicy Invariant**: `d2-signalloom/apps/signal-ingest/base/networkpolicy.yaml:49-65` (`allow-signal-ingest-ingress`) allows ingress **only** from pods labeled `app.kubernetes.io/name: fe-signalloom` (`fe-signalloom-api` and `supercred-demo-runner`). `dashboard-signalloom` (nginx) is intentionally **not** admitted directly to `signal-ingest`.

### 1.3 The Precise Routing Gap
When a client (or detective host sensor) sends a request to `POST /api/v1/telemetry/coding-agents`:
1. The request enters via Envoy Gateway or `dashboard-signalloom`'s `location /api/`.
2. Both route the request to `fe-signalloom-api:8000` (FastAPI), **not** to `signal-ingest:8082`.
3. FastAPI inspects its registered route table. Because no route is registered for `/api/v1/telemetry/coding-agents`, FastAPI returns **`404 Not Found`** (`{"detail":"Not Found"}`).
4. *Critical diagnostic distinction:* A genuinely unproxied path hitting `dashboard-signalloom` falls through to the SPA catch-all (`nginx.conf:341`, `try_files $uri $uri/ /index.html`) and responds with **`405 Method Not Allowed`** for POST requests. The 404 response proves the request reaches FastAPI on the other side of the reverse proxy, but arrives at the wrong service.

---

## 2. Existing `signal-ingest` API Mounting Conventions

### 2.1 Route Registration Boundary
All production routes in `signal-ingest` must be registered through `NewProtectedRouter` in `d2-signalloom/apps/signal-ingest/api/auth.go`. Bare `http.ServeMux` registration outside `NewProtectedRouter` is strictly forbidden because an unprotected route bypasses SPIFFE JWT-SVID authentication, tenant context injection, and audit logging.

### 2.2 Route Definition Schema
Routes are defined in `api/auth.go:305-328` (`routeDefinitions(metrics http.Handler) []routeDefinition`):

```go
type routeDefinition struct {
    method       string         // "GET", "POST", "DELETE"
    path         string         // OpenAPI route path, e.g. "/api/v1/observations"
    pattern      string         // Go 1.22 ServeMux pattern, e.g. "POST /api/v1/observations"
    permission   Permission     // Required permission enum
    enumeration  bool           // True enables budget rate-limiting and pagination
    actorScoped  bool           // True validates path {id} against principal's ActorIDs
    handler      http.HandlerFunc
}
```

### 2.3 Existing Route Inventory in `signal-ingest`
| Method | Path | Permission | Pattern | Purpose |
|---|---|---|---|---|
| `GET` | `/healthz`, `/health`, `/readyz` | `PermissionHealth` | `GET /readyz` | Kubernetes liveness/readiness probes |
| `POST` | `/api/v1/observations` | `PermissionObservationWrite` | `POST /api/v1/observations` | Signal observation ingestion |
| `GET` | `/api/v1/observations` | `PermissionObservationRead` | `GET /api/v1/observations` | Paginated observation queries |
| `GET` | `/api/v1/actors` | `PermissionActorList` | `GET /api/v1/actors` | Actor listing |
| `GET` | `/api/v1/actors/{id}` | `PermissionActorRead` | `GET /api/v1/actors/{id}` | Actor detail (actor-scoped) |
| `POST` | `/api/v1/actors/{id}/promote` | `PermissionActorWrite` | `POST /api/v1/actors/{id}/promote` | Provisional actor promotion |
| `POST` | `/api/v1/delegations` | `PermissionDelegationWrite` | `POST /api/v1/delegations` | A2A delegation recording |
| `GET` | `/api/v1/stream` | `PermissionStream` | `GET /api/v1/stream` | SSE real-time event stream |
| `POST` | `/api/v1/privacy/erasure/{id}` | `PermissionErasureRequest` | `POST /api/v1/privacy/erasure/{id}` | GDPR Article 17 erasure gate |
| `GET` | `/api/v1/privacy/export/{id}` | `PermissionPrivacyExport` | `GET /api/v1/privacy/export/{id}` | GDPR Article 15/20 data export |

### 2.4 Specification for New Telemetry Endpoint (SLCD-P5-1)
For SLCD-P5-1, the new telemetry route must be registered in `routeDefinitions` as:

```go
{"POST", "/api/v1/telemetry/coding-agents", "POST /api/v1/telemetry/coding-agents", PermissionObservationWrite, false, false, h.handleCodingAgentTelemetry}
```

---

## 3. Tenant-Context Flow & Isolation Contract

The tenant-context lifecycle in `signal-ingest` enforces strict cryptographic isolation:

```
┌────────────────────────────────────────────────────────┐
│ HTTP Request: Authorization: Bearer <JWT-SVID>          │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ ProtectedRouter.ServeHTTP                              │
│ - JWTAuthenticator.Authenticate(r)                     │
│ - Validates signature via SIGNAL_AUTH_JWKS             │
│ - Resolves SPIFFE ID -> PrincipalBinding (TenantID)    │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ ProtectedRouter.authorize                              │
│ - Verifies principal has required Permission           │
│ - Binds TenantContext{TenantID, Principal} to context  │
│   via WithTenantContext(ctx, tc)                       │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ api/tenant_bridge.go                                   │
│ - TenantClaimFromRequestContext(ctx)                   │
│ - Extracts TenantClaim verbatim from context value     │
│ - ZERO headers, query params, or body fields read      │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ SignalStore / IdentityStore Repository Execution       │
│ - Database queries bound strictly to TenantClaim       │
└────────────────────────────────────────────────────────┘
```

### 3.1 Security Invariants
- `X-SignalLoom-Tenant` is **untrusted and ignored** by `signal-ingest`.
- All ingested `CodingAgentTelemetry` records are stamped with the authenticated `claim.TenantID`.
- A missing or unverified principal fails closed (`401 Unauthorized` / `403 Forbidden`).

---

## 4. Dashboard Topology and UI Component Conventions

### 4.1 Component Inventory & UI Architectures

| Component / Page | Location | UI Engine | Data Fetching Pattern | Data Model |
|---|---|---|---|---|
| `AgentTrustTopologyPage` | `apps/dashboard-signalloom/src/pages/AgentTrustTopologyPage.tsx` | Custom HTML5 Canvas (`TrustTopologyCanvas.tsx`) | `api.trustTopology(token)` -> `GET /api/topology` | `TrustNode` (`kind: 'platform'\|'tenant'\|'project'\|'service'\|'agent'\|'external'`), `TrustEdge` |
| `FleetTopology` | `apps/dashboard-signalloom/src/components/fleet/FleetTopology.tsx` | `@xyflow/react` (React Flow) | `fleetApi.getTopology()` -> `/fleet-api/v1/fleet/topology` | `AgentState` (`state: 'active'\|'stunned'\|'non-compliant'`, `trustProfile`, `team`) |
| `AgentsPage` | `apps/dashboard-signalloom/src/pages/AgentsPage.tsx` | DashKit Table + Filter Controls | `api.agents.list(token)` -> `GET /api/agents` | `AgentResponse`, `AgentListMeta`, `SourceHealthMap` |
| `AgentDetailPage` | `apps/dashboard-signalloom/src/pages/AgentDetailPage.tsx` | Tabbed Dossier (`Overview`, `Identity`, `Access`, `Assessments`, `Activity`) | `api.agents.get(token, id)`, `api.audit.list(token)` | `AgentResponse`, `AuditEventResponse`, `ViolationResponse` |
| `SwarmAgentsPage` | `apps/dashboard-signalloom/src/pages/SwarmAgentsPage.test.tsx` | Swarm Grid View | `FAKE_SWARM_AGENTS` from `api/fakeSwarmData.ts` | `AgentDiscoveryRecord` (`harness: 'claude-code'\|'antigravity'\|'codex'`, `model`) |

### 4.2 Data Model Differences: In-Cluster Microservice Agents vs Coding Agents
- **In-Cluster Microservice Agents** (e.g. `planner`, `triage`, `risk-reader`): Represent Kubernetes Deployments/Pods running within tenant namespaces with SPIFFE IDs, ServiceAccounts, and OpenBao KV roles.
- **Passive Detective Coding Agents** (discovered by `agentmaxxing-host-sensor`): Represent autonomous coding agent execution loops running on developer workstations or CI runners (`claude`, `antigravity`, `codex`, `cpai`, `opencode`, `hermes`, `aider`).
  - Key attributes: Active Kanban task (`task_id`, `shortcode`, `role`, `elapsed_s`), process metrics (`pid`, `comm`, `rss_bytes`, `cpu_ticks`), execution telemetry (`step_count`, `tokens_in`, `tokens_out`, tool histograms), outbound inference endpoints (`api.anthropic.com`, `egress_bytes`), zero-customer-payload privacy badge.

### 4.3 UI Specification for SLCD-P5-2 (`CodingAgentsTab.tsx`)
1. **Location**: `d2-signalloom/apps/dashboard-signalloom/src/components/CodingAgentsTab.tsx`.
2. **Mounting**: Integrated into the Agent Dossier / Agents Page navigation, or as a dedicated tab/view in Agent Topology & Swarm views.
3. **Card Structure**:
   - **Header**: Harness icon/badge (`claude` / `antigravity` / `codex` / `cpai`) + Process Comm & PID (`comm: agy (PID: 1234)`).
   - **Kanban Task Strip**: Active Task badge (`SLCD-P5-1`), role (`implementation`), turn count, elapsed time.
   - **Metrics Grid**: Step count, token usage (`tokens_in` / `tokens_out`), and tool invocation histogram (`view_file: 8`, `run_command: 3`).
   - **Network Attribution**: Inferred model provider endpoint (`api.anthropic.com`) and egress bytes.
   - **Privacy Boundary Indicator**: Certified "Zero Customer Payload" guarantee chip confirming metadata-only posture.
4. **Data Fetching Pattern**:
   - `api.codingAgentTelemetry(token)` querying `GET /api/v1/telemetry/coding-agents` via `src/api/client.ts`.
   - Fallback to `FAKE_CODING_AGENT_TELEMETRY` fixtures when in demo mode or when backend is unreachable.

---

## 5. Concrete Routing Decision for SLCD-P5-1

### 5.1 Evaluated Architecture Options

| Option | Architecture | Ingress Gateway Impact | NetworkPolicy Impact | Recommendation |
|---|---|---|---|---|
| **Option 1: BFF Proxy in `fe-signalloom-api`** | Mount `POST /api/v1/telemetry/coding-agents` in `signal-ingest`. In `fe-signalloom-api` (FastAPI), add a router matching `/api/v1/telemetry` that proxies requests to `http://signal-ingest:8082`. | **Zero impact**: Gateway `HTTPRoute` already forwards `/api` to `fe-signalloom-api:8000`. | **Zero impact**: NetworkPolicy already permits `fe-signalloom-api` -> `signal-ingest:8082`. | **RECOMMENDED (Selected)** |
| **Option 2: Dedicated Nginx Location (`/telemetry-api/`)** | Add `location /telemetry-api/` in `nginx.conf` routing directly to `signal-ingest:8082`. | **Requires changes**: Gateway HTTPRoute must be modified to expose `/telemetry-api`. | **Breaks policy**: Requires modifying `signal-ingest` NetworkPolicy to admit `dashboard-signalloom` pod. | **Rejected** (violates zero-trust network boundaries) |
| **Option 3: Specific `location /api/v1/telemetry/` in Nginx** | Add specific `/api/v1/telemetry/` block in `nginx.conf` pointing to `signal-ingest:8082`. | **Bypassed**: Gateway routes `/api` to `fe-signalloom-api`, so external traffic bypasses nginx entirely. | **Breaks policy**: Requires admitting nginx pod. | **Rejected** (inconsistent gateway vs internal routing) |

### 5.2 Explicit Architectural Decision
**P5-1 shall follow Option 1:**
1. In `signal-ingest`: Register `POST /api/v1/telemetry/coding-agents` in `api/auth.go` and implement the handler in `api/telemetry_handler.go`.
2. In `fe-signalloom-api`: Register `/api/v1/telemetry/coding-agents` in FastAPI (e.g. `src/coding_agent_telemetry.py` or `src/signal_fusion.py`) and proxy requests to `http://signal-ingest:8082/api/v1/telemetry/coding-agents`, forwarding the `Authorization` bearer token and `X-SignalLoom-Contract` header.
3. In `wire_contract_test.go`: Update `TestCodingAgentWireContract_RoutingGapIsStillOpen` and `docs/signalloom/slcd-p1-3-wire-contract.md` once the route is verified closed.

---

## 6. Preflight Checklist for Phase 5 Implementation Cards

- [x] Routing gap root cause and resolution architecture confirmed.
- [x] Ingestion API surface and `ProtectedRouter` registration pattern inventoried.
- [x] Tenant context derivation and isolation bridge verified.
- [x] Dashboard topology and agent swarm UI conventions mapped for coding agent rendering.
- [x] Concrete decision documented and flagged for P5-1 and P5-2.
- [x] Baseline test suites verified (`acceptance-spec-coverage.bats` 7/7 pass, Go tests pass).

**Phase 5 is safe to start.**
