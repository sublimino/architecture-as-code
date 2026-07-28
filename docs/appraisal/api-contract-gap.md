# API Contract Fidelity Appraisal — SignalLoom Dashboard vs Deployed Backend

**Date:** 2026-07-27
**Scope:** Read-only investigation. Consumer = React dashboard. Provider = in-cluster `/api` backend.
**Verdict up front:** The dashboard's real backend contract is served by a **4-endpoint stub** that shares **zero response shapes** with the dashboard's TypeScript types. The rich backend that *does* match the contract (`agent_registry`) is **not deployed and not routed**. The walking demo breaks on nearly every screen beyond a trivial connectivity check.

---

## 1. Topology — what is actually wired

### Consumer
- `/home/andy/src/cp/platform/dashboard/src/api/client.ts` — axios client, all paths prefixed `/api`, `Authorization: Bearer <token>`.
- `/home/andy/src/cp/platform/dashboard/src/types/api.ts` — TS response/request interfaces.
- Signup uses a raw `fetch`, not the axios client: `/home/andy/src/cp/platform/dashboard/src/pages/RedeemInvite.tsx:88` → `POST ${API_BASE}/api/registry/signup`.

### Provider (as routed by the gateway)
- `d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` (HTTPRoute `signalloom-api`): `PathPrefix /api` → backend **`fe-signalloom-api` port 8000**.
- `.../fe-signalloom/base/api-service.yaml:4` Service `fe-signalloom-api` → Deployment `fe-signalloom` (`.../base/deployment.yaml:51`, image `${IMAGE_BASE}/signalloom/apps/fe-signalloom`).
- Entry point: `d2-signalloom/apps/fe-signalloom/src/main.py` → `install_compatibility_api(app)` (line 26). **Only** `api_compat.py` is mounted. No other router.
- The `/api` surface is defined entirely in `d2-signalloom/apps/fe-signalloom/src/api_compat.py` — `APIRouter(prefix="/api")` (line 256) with exactly **4 GET routes**:
  - `GET /api/agents` (line 267) → `AgentsResponse`
  - `GET /api/compliance` (line 272) → `ComplianceResponse`
  - `GET /api/audit` (line 279) → `AuditResponse`
  - `GET /api/settings` (line 284) → `SettingsResponse`
- Plus health only: `/health`, `/livez`, `/readyz` (`main.py:29/35/41`). No OpenAPI/Swagger spec file exists in either tree (FastAPI auto-docs only).

### The backend that actually matches the dashboard — NOT deployed
- `/home/andy/src/cp/platform/services/agent_registry/` is a full FastAPI app (`main.py:162-173` mounts agents, agents_stage1, audit, compliance, support, nhi, connectors, admin_invite_codes, signup, billing, api_keys, consent). Its `response_model` classes are the *same names* the dashboard imports (`AgentListResponse`, `ComplianceSummaryResponse`, `PostureResponse`, `FrameworkResponse`, `ViolationListResponse`, `TransitionResponse`, `ReassessmentResponse`, `NHIDiscoveredResponse`, `TenantSettingsResponse`, `SupportRequestResponse`, `Consent*`, `InitialApiKeyResponse`, `RotateApiKeyResponse`, etc.).
- **This service is referenced only in dashboard code comments**, never in any d2 cluster manifest. Grep for `agent_registry`/`agent-registry` in `d2-signalloom/` returns only source comments (`AgentDetailPage.tsx:403`, `connectorsClient.ts:14`). It is the dashboard's original backend, left behind in the platform monorepo. **The gateway does not route to it.**

### Auth mismatch (cross-cutting, breaks everything)
- Task brief says Auth0 Bearer with tenant claim `https://signalloom.ai/tenant_id`.
- Deployed stub `api_compat.py:154-206` validates a **Dex RS256 ID token** against a JWKS URL, checks `azp == api_jwt_authorized_party`, and maps tenant via `settings.api_subject_tenants[claims["sub"]]` — **not** the Auth0 `https://signalloom.ai/tenant_id` custom claim. If the dashboard mints Auth0 tokens, **all 4 stub endpoints return 401/403** and even the trivial demo dies at the door. (The matching `agent_registry` uses `TokenClaims.tenant_id`.)

---

## 2. Per-endpoint gap table (Provider column = the DEPLOYED `fe-signalloom-api` stub)

| Endpoint | Method | Dashboard expects (type) | Backend implements? (yes/partial/no + file:line) | Response shape matches? | Notes |
|---|---|---|---|---|---|
| `/api/agents` | GET | `AgentListResponse` `{agents: AgentResponse[], total}` | **partial** — `api_compat.py:267` | **NO** | Stub returns `AgentsResponse {tenant_id, agents:[{id,name,status:"ready"|"offline"}]}`. No `total`; agent objects lack `type, owner, tenant_id, lifecycle_state, eu_ai_act_risk_class, compliance_summary, created_at`. One hard-coded fake agent. |
| `/api/agents` | POST (register) | `AgentCreateRequest` → `AgentResponse` | **no** — route is GET-only | n/a | POST → 405 (`method_not_allowed`). Cannot register agents. |
| `/api/agents/{id}/credentials` | POST | `IssueCredentialResponse` | **no** | n/a | 404. Show-once credential minting absent. |
| `/api/agents/{id}` | GET | `AgentResponse` | **no** — only collection `/agents` exists | n/a | 404. Agent detail page has no data source. |
| `/api/agents/{id}/transition` | POST | `TransitionRequest` → `TransitionResponse` | **no** | n/a | 404. Lifecycle transitions impossible. |
| `/api/agents/{agentId}/violations` | GET | `ViolationListResponse` | **no** | n/a | 404. |
| `/api/agents/violations/{violationId}/acknowledge` | POST | `{status}` | **no** | n/a | 404. |
| `/api/agents/{agentId}/compliance/{controlId}/reassess` | POST | `ReassessmentResponse` | **no** | n/a | 404. |
| `/api/compliance/summary` | GET | `ComplianceSummaryResponse` `{total_agents, agents_assessed, controls_passing/failing/pending, posture_score}` | **no** — stub has `/api/compliance` not `/compliance/summary` | **NO** | 404. Path mismatch: stub exposes `GET /api/compliance` (flat control list), dashboard calls `/api/compliance/summary`. Dashboard landing rollup is empty. |
| `/api/compliance/posture` | GET | `PostureResponse` | **no** | n/a | 404. |
| `/api/compliance/frameworks` | GET | `FrameworkResponse[]` | **no** | n/a | 404. |
| `/api/compliance/export?format=` | GET | `unknown` (json/pdf/both) | **no** | n/a | 404. |
| *(stub-only)* `/api/compliance` | GET | *(not called by dashboard)* | yes — `api_compat.py:272` returns `ComplianceResponse {tenant_id, controls:[{id,status,evidence}]}` | orphan | Provider serves a shape the dashboard never requests. |
| `/api/audit?page&limit&from&to&agent&type` | GET | `AuditListResponse` `{events:AuditEventResponse[], total, page, limit}` | **partial** — `api_compat.py:279` | **NO** | Stub returns `AuditResponse {tenant_id, events:[{id,event_type,occurred_at,actor}]}`. Missing `total, page, limit`; event lacks `timestamp, agent_id, agent_name, detail`; field is `occurred_at` not `timestamp`. Query params ignored. One fake event. |
| `/api/nhi/scans` | GET | `NHIScanListResponse` | **no** | n/a | 404. NHI discovery screen dead. |
| `/api/nhi/discovered?page&limit&status` | GET | `NHIDiscoveredResponse` | **no** | n/a | 404. |
| `/api/nhi/discovered/{accountId}/enroll` | POST | `{account_id,status}` | **no** | n/a | 404. |
| `/api/nhi/discovered/{accountId}/dismiss` | POST | `{account_id,status}` | **no** | n/a | 404. |
| `/api/nhi/report/json` | GET | `unknown` | **no** | n/a | 404. |
| `/api/tenant/settings` | GET | `TenantSettingsResponse` `{tenant_id, org_name, plan_tier, agent_count, billing_tier, api_key_status, selected_frameworks, consent_required, cookie_preferences}` | **no** — stub has `/api/settings` not `/tenant/settings` | **NO** | 404. Path mismatch. Stub `GET /api/settings` returns `SettingsResponse {tenant_id, settings:[{key,value}]}` — a generic KV list, none of the expected fields. |
| `/api/tenant/settings/frameworks` | PATCH | `{selected_frameworks}` → `TenantSettingsResponse` | **no** | n/a | 404. Framework selection cannot be saved. |
| *(stub-only)* `/api/settings` | GET | *(not called)* | yes — `api_compat.py:284` | orphan | Orphan KV endpoint; dashboard calls `/api/tenant/settings`. |
| `/api/support` | POST | `SupportRequestCreate` → `SupportRequestResponse` | **no** | n/a | 404. |
| `/api/tenants/{tenantId}/api-keys/initial` | POST | `InitialApiKeyResponse` | **no** | n/a | 404. |
| `/api/tenants/{tenantId}/api-keys/rotate` | POST | `RotateApiKeyResponse` | **no** | n/a | 404. |
| `/api/consent/status` | GET | `ConsentStatusResponse` | **no** | n/a | 404. Consent gate has no backend; may block app entry if the UI hard-requires it. |
| `/api/consent/accept` | POST | `ConsentAcceptRequest` → `ConsentAcceptResponse` | **no** | n/a | 404. |
| `/api/cookie-preferences` | GET | `CookiePreferencesResponse` | **no** | n/a | 404. |
| `/api/cookie-preferences` | PATCH | `{analytics}` → `CookiePreferencesResponse` | **no** | n/a | 404. |
| `/api/registry/signup` | POST | raw fetch (invite redemption, `RedeemInvite.tsx:88`) | **no** | n/a | 404. Onboarding/invite redemption dead. |

---

## 3. Summary verdict

**Contract coverage of the DEPLOYED backend (`fe-signalloom-api` stub):**
- Dashboard calls **~31 distinct endpoints** (28 axios methods + signup + 2 orphan-adjacent paths).
- Deployed stub implements **4 GET routes**, of which only **3 path-collide** with dashboard calls (`/api/agents`, `/api/audit`, and — by path — nothing else; `/api/compliance` and `/api/settings` are orphans the dashboard never calls).
- **Path-level hit rate ≈ 6%** (2 of 31 dashboard endpoints share a path: `/api/agents`, `/api/audit`).
- **Shape-level hit rate = 0%.** Of those 2 path collisions, **neither response shape matches** the dashboard's TS type (missing `total`/pagination, missing every governance field, wrong field names).
- Net: **effectively 0% of the dashboard's contract is correctly served.**

**Is the backend real or a stub?**
- **Stub.** `api_compat.py` is explicitly titled a "compatibility API for the local D2 dashboard" and returns **hard-coded single-item fixtures** (`build_agents_response`, `build_compliance_response`, `build_audit_response`, `build_settings_response` — all synthesize one fake record from the tenant id). No DB reads for these payloads (the pool only backs `/readyz`). It is a health/connectivity shim, not the product API.
- The **real** API (`platform/services/agent_registry`) exists and matches the contract but is **not deployed and not routed** in the d2 cluster.

**What breaks the walking demo (in order of blast radius):**
1. **Auth scheme mismatch (fatal, global).** Deployed stub validates **Dex RS256** tokens with `azp`/`sub`→tenant mapping (`api_compat.py:183,203`), not Auth0 `https://signalloom.ai/tenant_id`. If the dashboard sends Auth0 tokens, **every** `/api` call 401/403s and nothing renders.
2. **Wrong backend deployed.** The gateway points at the stub, not `agent_registry`. Even with matching auth, 27 of 31 endpoints are 404.
3. **Path renames on the two "present" endpoints.** Dashboard wants `/compliance/summary` and `/tenant/settings`; stub serves `/compliance` and `/settings` → 404 on the exact calls the landing page makes.
4. **Shape breaks on `/api/agents` and `/api/audit`.** Even where paths collide, the dashboard will fail to parse: no `total`, no pagination, agent objects missing `lifecycle_state`/`compliance_summary`/`eu_ai_act_risk_class`, audit events missing `timestamp`/`agent_id`/`detail`.
5. **Whole feature areas absent:** agent register/detail/transition/credentials, violations + acknowledge, reassess, compliance posture/frameworks/export, all NHI discovery, tenant settings write, support, API-key issue/rotate, consent + cookie preferences, invite signup. Any click past the initial page 404s.

**Bottom line:** The deployed `fe-signalloom-api` is a connectivity/health stub with 4 fixture endpoints and a different auth model. It is not a partial implementation of the dashboard contract — it is a different, thinner API. To make the walking demo work you must either (a) deploy/route the `agent_registry` service (which already matches the contract, subject to confirming its auth is Auth0-compatible), or (b) expand `api_compat.py` to implement the missing ~29 endpoints with the exact TS shapes — and in both cases **reconcile the auth scheme** (Dex vs Auth0 `https://signalloom.ai/tenant_id`).

---

## 4. Key file references
- Consumer client: `/home/andy/src/cp/platform/dashboard/src/api/client.ts`
- Consumer types: `/home/andy/src/cp/platform/dashboard/src/types/api.ts`
- Consumer signup: `/home/andy/src/cp/platform/dashboard/src/pages/RedeemInvite.tsx:88`
- Gateway route: `d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` (HTTPRoute `signalloom-api`, `/api` → `fe-signalloom-api:8000`)
- Deployed provider entry: `d2-signalloom/apps/fe-signalloom/src/main.py:26`
- Deployed provider routes + fixtures + auth: `d2-signalloom/apps/fe-signalloom/src/api_compat.py` (routes 267/272/279/284; fixtures 209-253; auth 154-206)
- Undeployed matching backend: `/home/andy/src/cp/platform/services/agent_registry/main.py:162-173` and `routers/{agents,agents_stage1,compliance,nhi,support,api_keys,consent,...}.py`
- No OpenAPI/Swagger spec file in either tree (FastAPI runtime docs only).
