# OSRAMP Dashboard — API Surface Appraisal & Walking-Demo Plan

> Author: sensai (for Andy) · 2026-07-27 · Effort E4 · Read-only appraisal.
> Sub-reports: `api-contract-gap.md`, `mocks-proxy-fidelity.md`, `auth-gateway-runbook.md` (this dir).
> Task ISA: `~/.claude/PAI/MEMORY/WORK/osramp-dashboard-api-appraisal/ISA.md`.
>
> **UPDATE 2026-07-28:** The gap identified below has been **CLOSED**. All 28
> dashboard endpoints now serve live data from PostgreSQL (see
> `d2-signalloom/apps/fe-signalloom/README.md`). Consumer-driven contract tests
> (36 Pydantic models, tier-1 35/35 PASS) validate shape fidelity. Agent
> discovery is live (k8s namespace query, 5 Monty Python agents). Crypto-health
> proofs (bao-spire) are surfaced in the Cryptography page. Data lifecycle:
> `make demo-signalloom-data-reset` / `data-mock`. This appraisal is retained
> as historical context for the migration path.

## TL;DR (the one-paragraph verdict)

~~The cluster already proves the **hard** parts end-to-end~~ **RESOLVED.** As of
2026-07-28, all 28 endpoints serve live data from PostgreSQL + k8s. The original
appraisal below documents the gap that existed before the migration.

<details><summary>Original appraisal (historical)</summary>

The cluster already proves the **hard** parts end-to-end: Dex OIDC auth, Envoy Gateway `/api` routing, TLS, tenant scoping, and a same-origin `/api` contract. What is **not** at standard is the API *content*: the service behind `/api` (`fe-signalloom-api`) is the **Discovery Portal wearing a 4-endpoint compatibility mask** (`api_compat.py`), not the Agent-Governance backend the dashboard was built against. The dashboard calls **~31 endpoints**; the shim serves **4**, with **0% response-shape fidelity** and **2 wrong paths**. The real contract-faithful backend (`services/agent_registry`) exists but is **not containerised or routed**. Your blocker for a walking demo is therefore **bounded and specific — a contract-shape gap on ~6 walking endpoints — not a platform rebuild.** A parallel process is already solving UI-migration + Dex login; your remaining move is to bring the `/api` shim up to the dashboard's real contract for the screens you want to walk.

</details>

## Is the proxy/mock API surface "at the correct standard"? — **YES (as of 2026-07-28).**

Two distinct fake surfaces exist; don't conflate them:

| Surface | What it fakes | Standard | Verdict |
|---|---|---|---|
| `api_compat.py` (on `fe-signalloom`) | The dashboard's `/api` (agents/compliance/audit/settings) | 4 hardcoded single-item GETs, 0% shape match, 2 wrong paths | **NOT at standard** — liveness/auth proof only |
| `fake-integration-proxy` | External integration providers (`/llm`,`/crm`,`/notification`,`/outbound-reporting`) | Stateful, redacts secrets/PII, hardened pod, has tests | **At standard** (but wrong surface for the dashboard) |
| `io-mapping-stub` (olly) | Kafka→ServiceNow/ES mapping | 1216-LOC Go, real schema enforcement, prod-adjacent | **Above standard** (unrelated to dashboard) |
| connectors frontend mock | Onboarding wizard connectors | In-memory, resets on reload, 4 hardcoded providers | **Toy-grade by admission** (UI-only) |

## The contract gap (grounded)

**Dashboard contract** — `platform/dashboard/src/api/client.ts` + `types/api.ts`: ~31 endpoints, all `/api`-prefixed, Auth0 Bearer, tenant claim `https://signalloom.ai/tenant_id`.
**Deployed provider** — `d2-signalloom/apps/fe-signalloom/src/api_compat.py` (`APIRouter(prefix="/api")`, L256): exactly `GET /api/agents`, `/api/compliance`, `/api/audit`, `/api/settings` (+ `/health /livez /readyz`), each a hardcoded single item (`build_*_response`, L209-253).

- **Coverage:** path hit ~6% (only `/agents`,`/audit` collide), **shape hit 0%**, **27 endpoints → 404**.
- **Wrong paths (break the landing page):** dashboard wants `GET /api/compliance/summary` + `GET /api/tenant/settings`; shim serves `/api/compliance` + `/api/settings`.
- **Shape breaks on the 2 "present":** `/api/agents` is missing `total` and every governance field the Agents view reads (`lifecycle_state`, `compliance_summary{…}`, `eu_ai_act_risk_class`, `created_at`) → the view likely throws on `agent.compliance_summary.passing`. `/api/audit` uses `occurred_at` not `timestamp`, missing `total/page/limit/agent_id/detail`.
- **Missing (404):** agent register/detail/transition/credentials, violations + acknowledge, reassess, compliance posture, frameworks, all NHI, tenant settings write, support, api-key rotate/reveal, consent, cookie-prefs, `/registry/signup`.
- **Connectors live-mode:** flipping `VITE_CONNECTORS_API_MODE=live` → 5 more 404s (`/api/connectors*`); nothing in-cluster serves them; "PR #19" unmerged. **Keep connectors on `mock` for the demo.**

## Auth — the fatal-but-already-being-solved blocker

- Dashboard uses `@auth0/auth0-react`; the deployed image was built with **no `VITE_AUTH0_*`** args → SDK can't form an authorize URL. And the Auth0 SDK redirect targets the issuer directly — but the backend trusts **Dex** (`iss dex…:5556/dex`, `aud signalloom-api`, `azp signalloom-dashboard`, tenant from `sub` map `demo-user→tenant-demo`), a cluster-internal DNS the browser can't reach. So Auth0-as-shipped is **structurally dead** for this cluster.
- **This is already owned** by `MEMORY/WORK/20260727_migrate-signalloom-ui-dex-login`: it removes Auth0, wires Dex OIDC, and serves **single-origin nginx proxying `/dex` + `/api`** (browser hits one origin — dissolves the Dex-DNS problem), port-forward `localhost:5173`, login `demo-user` / `password`.
- **Good news on white-screen risk (Cato-confirmed, StrictMode-safe):** the dashboard's two on-mount effects are defensively coded — consent check is flag-gated (`VITE_CONSENT_MODAL_ENABLED`, default off) **and** fails open (`App.tsx` consent effect ~L75-90, terminal `catch { setConsentRequired(false) }`); the api-key reveal early-returns when the tenant claim is absent and swallows errors (`App.tsx` reveal effect ~L93-110). Both are idempotent under React StrictMode double-invoke. So a 404 on those does **not** blank the app. The render gate is purely `isAuthenticated`.

## Recommendation — Path A (thin-slice), not Path B (full backend)

Advisor-confirmed. **A** = bring `api_compat.py` to the dashboard's real contract for the walking screens + let the parallel process finish Dex login. **B** = containerise/route `services/agent_registry` — that *doubles* the auth problem (agent_registry was built for Auth0, would now need Dex server-side validation) plus new Dockerfile/image/Flux/state — a 2-week answer, not tonight.

**Your concrete work items for a semi-walking demo (bounded):**
1. **Fix the 2 paths** in `api_compat.py`: `/api/compliance` → `/api/compliance/summary`; `/api/settings` → `/api/tenant/settings`. (Paths beat shapes — a 404 kills even a perfect payload.)
2. **Match shapes** for the walking screens against `types/api.ts`: `AgentListResponse{agents:AgentResponse[],total}` (populate `compliance_summary`, `lifecycle_state`, `eu_ai_act_risk_class`, `created_at`), `ComplianceSummaryResponse`, `PostureResponse`, `AuditListResponse{events[],total,page,limit}` with `timestamp/agent_id/detail`, `TenantSettingsResponse`, `FrameworkResponse[]`.
3. **Add `GET /api/compliance/posture` and `GET /api/frameworks`** (Compliance view reads both) — a few more hardcoded fixtures.
4. **Mint the tenant claim** `https://signalloom.ai/tenant_id=tenant-demo` in the Dex token (cheap client-side scoping insurance), even though the backend derives tenant from `sub`.
5. **Demo hygiene:** set React Query (if used) `retry:false` / accept the self-signed cert first / keep connectors on `mock`.
6. **Coordinate image ownership:** ONE process rebuilds/pushes the `dashboard-signalloom` image tonight (last-write-wins race is the highest-probability demo-killer). The Dex-login process owns the dashboard image + `api_compat.py`; hand them items 1-4 or explicitly split.

**Screens that will WALK after items 1-3:** Agents (list), Compliance (summary + posture + frameworks), Audit Trail, Settings.
**Screens to leave un-clicked (still 404):** Agent detail/register/transition, Onboarding/connectors wizard, Redeem invite, NHI, support, api-key rotate.

## Ownership / coordination note

- **Do not edit** `d2-signalloom/apps/dashboard-signalloom/**` or `api_compat.py` without coordinating — both are in flight in the Dex-login process.
- This appraisal + runbook are the handoff artifact: it tells that process exactly which contract shapes to emit so their post-login screens render real data instead of blanks.
