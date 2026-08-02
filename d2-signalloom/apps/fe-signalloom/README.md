# fe-signalloom — Signal Loom API Compatibility Layer

The authenticated, tenant-scoped API backend for the Signal Loom Agent-Governance
dashboard. Originally backed by Azure services (Container Apps, Key Vault, Entra);
this local D2 variant serves the same API surface from a local Kind cluster using
PostgreSQL, Dex OIDC, and in-cluster Kubernetes queries.

## Architecture

```
Dashboard (nginx SPA :8080)
    |
    +-- /api/* --> fe-signalloom-api (:8000, this component)
    |                |
    |                +-- asyncpg --> PostgreSQL (inf-signalloom)
    |                |                26 endpoints: agents, compliance, audit,
    |                |                NHI, settings, consent, cookies, api-keys, support
    |                |
    |                +-- httpx --> fake-integration-proxy (inf-signalloom :8080)
    |                |              /agents  --> k8s API (fe-signalloom-agents ns)
    |                |              /crypto-proofs --> k8s API (bao-spire Jobs)
    |                |
    |                +-- fixture fallback (when database_url is empty)
    |
    +-- /dex/* --> Dex OIDC (inf-signalloom, single-origin proxy)
```

## Endpoints (28 total)

| Group | Method | Path | Source |
|-------|--------|------|--------|
| **Agents** | GET | `/api/agents` | Postgres + k8s (merged) |
| | POST | `/api/agents` | Postgres |
| | GET | `/api/agents/{id}` | Postgres |
| | POST | `/api/agents/{id}/transition` | Postgres |
| | POST | `/api/agents/{id}/credentials` | Postgres |
| | GET | `/api/agents/{id}/violations` | Postgres |
| | POST | `/api/agents/violations/{id}/acknowledge` | Postgres |
| | POST | `/api/agents/{id}/compliance/{cid}/reassess` | Postgres |
| **Compliance** | GET | `/api/compliance/summary` | Postgres |
| | GET | `/api/compliance/posture` | Postgres |
| | GET | `/api/compliance/frameworks` | Postgres |
| | GET | `/api/compliance/export` | fixture |
| **Audit** | GET | `/api/audit` | Postgres |
| **NHI** | GET | `/api/nhi/scans` | Postgres |
| | GET | `/api/nhi/discovered` | Postgres |
| | POST | `/api/nhi/discovered/{id}/enroll` | Postgres |
| | POST | `/api/nhi/discovered/{id}/dismiss` | Postgres |
| | GET | `/api/nhi/report/json` | fixture |
| **Settings** | GET | `/api/tenant/settings` | Postgres |
| | PATCH | `/api/tenant/settings/frameworks` | Postgres |
| **Support** | POST | `/api/support` | Postgres |
| **API Keys** | POST | `/api/tenants/{tid}/api-keys/initial` | Postgres |
| | POST | `/api/tenants/{tid}/api-keys/rotate` | Postgres |
| **Consent** | GET | `/api/consent/status` | Postgres |
| | POST | `/api/consent/accept` | Postgres |
| **Cookies** | GET | `/api/cookie-preferences` | Postgres |
| | PATCH | `/api/cookie-preferences` | Postgres |
| **Health** | GET | `/api/health/crypto` | k8s (bao-spire Jobs) |

`GET /api/agents` merges two sources: Postgres-registered agents AND k8s-discovered
agents (podinfo pods in `fe-signalloom-agents` with label `signalloom.ai/agent=true`).
Both sources appear in the same response.

## Auth

Every endpoint requires a **Dex RS256 JWT** (Bearer token):
- `iss` must match `API_JWT_ISSUER` (default: `http://localhost:5173/dex`)
- `aud` must include `API_JWT_AUDIENCE` (default: `signalloom-api`)
- `azp` must equal `API_JWT_AUTHORIZED_PARTY` (default: `signalloom-dashboard`)
- Tenant derived from `API_SUBJECT_TENANTS` map (`sub` claim -> tenant_id)

Demo user: `demo-user@signalloom.local` / `demo-user` via Dex password grant.

## Database

**PostgreSQL** at `database_url` (config.py). Schema: `db/migrations/004_agent_governance_schema.sql`
(13 tables, idempotent). Key tables: `agent_registry`, `governance_frameworks`,
`governance_controls`, `agent_compliance_results`, `agent_violations`, `audit_events`,
`nhi_scans`, `nhi_discovered_accounts`, `tenant_settings`, `tenant_api_keys`,
`consent_events`, `support_requests`, `lifecycle_transitions`.

**Migrations run at startup.** `db/migrate.py` applies every `db/migrations/*.sql`
in version order before the pool is handed out, recording each in
`schema_migrations` so it runs once, and serialising concurrent replicas behind a
`pg_advisory_lock`. A failing migration aborts startup rather than serving against
a half-migrated schema. The generated bootstrap SQL still seeds fresh clusters via
`/docker-entrypoint-initdb.d` — but that path only fires on an empty data
directory, so the runner is what keeps an *existing* database current. Every
migration must therefore stay idempotent; `tests/test_migrations.py` enforces it.

**Graceful fallback:** if `database_url` is empty, all endpoints return in-memory
fixtures. The demo-toggle (client-side) uses these fixtures independently.

## Data lifecycle (three UI states)

```bash
make demo-signalloom-data-reset            # Truncate all tables -> live-empty UI
make demo-signalloom-data-reset SERVICE=agents  # Reset just the agents domain
make demo-signalloom-data-mock             # Reset + populate 72 rows of demo data
```

| State | How to enter | What the UI shows |
|-------|-------------|-------------------|
| **Demo mode** | Toggle in bottom-right corner | Client-side fixtures (no API needed) |
| **Live empty** | `make demo-signalloom-data-reset` | Real API, empty tables |
| **Mock populated** | `make demo-signalloom-data-mock` | Real API, 5 agents + frameworks + audit etc. |

## Agent discovery

Inert podinfo pods in `fe-signalloom-agents` namespace, labelled:
- `signalloom.ai/agent=true` (stable selector)
- `signalloom.ai/agent-name`, `agent-type`, `framework`, `model`, `state`
- Annotations: `signalloom.ai/agent-display-name`, `model-full`, `description`

```bash
make demo-signalloom-agents-up             # Create 4 random Monty Python agents
make demo-signalloom-agents-down           # Remove ephemeral cohort
make demo-signalloom-agents-list           # List current agents
```

## Crypto health (self-reporting)

`GET /api/health/crypto` surfaces the bao-spire workload identity proofs:
- **Positive proof** (bao-spire-positive-proof Job): correct SPIFFE identity -> OpenBao
- **Negative proof** (bao-spire-negative-proof Job): wrong identity -> denied (fail-closed)

## Testing

```bash
make demo-signalloom-api-test              # Runs tier-1 (contract, hermetic)
make demo-signalloom-api-test TIER=integration  # Tier-1 + tier-2 (needs Postgres)
make demo-signalloom-api-test TIER=e2e     # All three tiers (needs full cluster)
```

- **Tier 1** — hermetic contract tests (35/35): FastAPI TestClient, fixture fallback,
  validates response shapes against `tests/contract.py` (36 Pydantic models matching
  the dashboard's `types/api.ts`).
- **Tier 2** — integration tests: live Postgres (needs `DATABASE_URL`), writes + reads
  real data, validates round-trip contract fidelity.
- **Tier 3** — E2E: real Dex token through the dashboard's nginx proxy (needs
  `SIGNALLOOM_API_BASE` + `SIGNALLOOM_DEX_EMAIL`/`PASSWORD`).

## Development

```bash
# Rebuild + deploy the API image
docker build -t zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest .
kind load docker-image --name osramp zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest
kubectl -n fe-signalloom rollout restart deploy/fe-signalloom

# Schema migrations apply themselves on API startup (src/db/migrate.py).
# To force them without a redeploy, or to inspect what has run:
../../../scripts/signalloom-data.sh migrate
kubectl -n inf-signalloom exec -i deploy/postgresql -- psql -U signalloom -d signalloom \
  -c 'SELECT version, filename, applied_at FROM schema_migrations ORDER BY version'

# Populate mock data
cat src/db/data-mock.sql | kubectl -n inf-signalloom exec -i deploy/postgresql -- psql -U signalloom -d signalloom
```

## Key files

| File | Purpose |
|------|---------|
| `src/api_compat.py` | All 28 endpoints (2282 lines) |
| `src/config.py` | Pydantic Settings (database_url, redis_url, JWT config) |
| `src/main.py` | FastAPI app + routes |
| `src/db/migrations/004_*.sql` | Schema (13 tables) |
| `src/db/migrations/005_*.sql` | Tenant scan-preference columns |
| `src/db/migrate.py` | Startup migration runner (`schema_migrations` ledger) |
| `src/db/data-reset.sql` | Truncate all tables |
| `src/db/data-mock.sql` | 72 rows of realistic demo data |
| `src/tests/contract.py` | 36 consumer contract models |
| `src/tests/test_contract_tier1.py` | Hermetic contract tests (35/35) |
| `base/deployment.yaml` | K8s Deployment (env: JWT, DB, OIDC) |
| `base/agents-namespace.yaml` | Agent inventory namespace |
| `base/agents-rbac.yaml` | RBAC for agent + crypto discovery |
| `base/agents-baseline.yaml` | Flux-managed baseline agent (Sir Lancelot) |
| `Dockerfile` | Python 3.12 + uvicorn |
