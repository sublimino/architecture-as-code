# SLAAT-P1-2 — API Endpoint Authorization Matrix

Derived from `app.routes` introspection in `test_tenant_authorization_matrix.py`
(`_iter_api_routes` / `_dependant_calls`), not hand-maintained. Covers the
eight routers this card's sweep added: `routers.connectors`, `routers.policies`,
`routers.policy_engine`, `routers.federation`, `routers.discovery`,
`routers.agents`, `external_agent_registration`, `host_enrollment`. The
pre-existing EAP routers (`tenant_isolation`, `scenario_seeding`,
`environment_routing`, `environment_lifecycle`, `environment_teardown`) and
`api_compat`'s own compat-layer routes already have an equivalent matrix via
`test_tenant_isolation.py`'s `EAP_TENANT_BOUND_ROUTES` / `DB_ROUTES` sweeps —
not duplicated here.

| Method | Path (one alias shown; others identical) | Module | Auth dependency | Tenant boundary |
| --- | --- | --- | --- | --- |
| GET | `/api/v1/connectors` | routers.connectors | `authenticated_principal` | per-tenant dict (`_TENANT_CONNECTORS_DATA[tenant_id]`) |
| GET | `/api/v1/connectors/providers` | routers.connectors | `authenticated_principal` | read-only catalog, no tenant data |
| GET | `/api/v1/connectors/status` | routers.connectors | `authenticated_principal` | per-tenant |
| POST | `/api/v1/connectors` | routers.connectors | `authenticated_principal` | per-tenant |
| POST | `/api/v1/connectors/{connector_id}/toggle` | routers.connectors | `authenticated_principal` | per-tenant (deterministic IDs across tenants, isolated by dict key — verified) |
| POST | `/api/v1/connectors/{connector_id}/test` | routers.connectors | `authenticated_principal` | per-tenant |
| DELETE | `/api/v1/connectors/{connector_id}` | routers.connectors | `authenticated_principal` | per-tenant |
| POST | `/api/v1/policies/validate` | routers.policies | **none on the function itself** — see Finding F3 | n/a (stateless CEL syntax check); **unreachable in practice**, shadowed by the authenticated wildcard proxy below |
| POST | `/api/v1/policies/evaluate` | routers.policies | **none on the function itself** — shadowed, see F3 | tenant-scoped policy evaluation; reachable copy is `policy_engine`'s `proxy_policies_route` (authenticated) |
| POST | `/api/v1/policies/bundles` | routers.policies | **none on the function itself** — shadowed, see F3 | tenant-scoped bundle registration; ditto |
| POST | `/api/v1/policies/rollback` | routers.policies | **none on the function itself** — shadowed, see F3 | tenant-scoped rollback; ditto |
| GET/POST | `/api/v1/policies`, `/api/v1/policies/{subpath}` | routers.policy_engine | `authenticated_tenant` (wildcard proxy; dispatches to the functions above with tenant context) | per-tenant |
| GET/POST | `/api/v1/compliance`, `/api/v1/compliance/{subpath}` | routers.policy_engine | `authenticated_tenant` | per-tenant |
| GET/POST | `/v1/federation/*` | routers.federation | `authenticated_tenant` | per-tenant (proxies to signal-ingest with tenant header injected server-side) |
| POST | `/api/v1/discovery/claim` | routers.discovery | `authenticated_principal` | tenant-scoped claim; SPIFFE ID cross-tenant forgery rejected (403) |
| GET | `/api/v1/discovery/workloads` | routers.discovery | `authenticated_principal` | per-tenant |
| GET | `/api/v1/agents` | routers.agents | `authenticated_principal` | per-tenant (`_AGENTS[tenant_id]` / `WHERE tenant_id = $2`) |
| POST | `/api/v1/agents/{agent_id}/transition` | routers.agents | `authenticated_principal` | per-tenant; unknown-ID-for-this-tenant synthesizes a local record rather than 404ing (ambiguous but non-leaking — see dossier) |
| POST | `/api/v1/external-agents/register`, `/registrations` | external_agent_registration | `authenticated_principal` | per-tenant |
| GET | `/api/v1/external-agents/registrations` | external_agent_registration | `authenticated_principal` | per-tenant list |
| GET | `/api/v1/external-agents/{agent_id}` | external_agent_registration | `authenticated_principal` | per-tenant get, 404 on cross-tenant ID |
| POST | `/api/v1/external-agents/registrations/{agent_id}/claim` | external_agent_registration | `authenticated_principal` | per-tenant |
| POST | `/api/v1/external-agents/registrations/{agent_id}/revoke` | external_agent_registration | `authenticated_principal` | per-tenant |
| POST | `/api/v1/external-agents/{agent_id}/token` | host_enrollment | `authenticated_principal` (operator) | per-tenant token issuance/rotation |
| POST | `/api/v1/external-agents/registrations/{agent_id}/revoke` (host) | host_enrollment | `authenticated_principal` (operator) | per-tenant |
| **POST** | **`/api/v1/external-agents/enroll`** | host_enrollment | **none** — authenticates via its own single-use SHA-256-hashed bearer token (compare-and-set), not a Dex JWT | token is bound to one pre-registered `(tenant_id, agent_id)` row; cross-agent redemption rejected (verified) |

## Legend

- **Auth dependency** is read from the live `APIRoute.dependant` tree (including nested sub-dependencies), not from source inspection alone — this is what actually executes.
- **"none on the function itself — shadowed"** means the route object exists and has no dependency, but is unreachable at runtime because an earlier-registered route with a broader path pattern and a real dependency intercepts every request first. See Finding F3 in the dossier for why this is fragile, not a declared contract.
- Every row above is covered by at least one automated test in `test_tenant_authorization_matrix.py` or `test_adversarial_api_security.py`.
