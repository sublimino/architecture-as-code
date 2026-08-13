# AGENTS.md — d2-signalloom (Signal Loom delivery slice)

Signal Loom agent governance platform. Dashboard SPA + FastAPI backend + Dex
OIDC + OpenBao/SPIRE + PostgreSQL/Redis/MinIO + fake integrations.

## Stack

| Component | Tech | Path |
|-----------|------|------|
| Dashboard SPA | React 18 + Vite + TypeScript + nginx | `apps/dashboard-signalloom/` |
| API backend | Python FastAPI | `apps/fe-signalloom/src/` |
| Fake services | Go + Python proxy | `apps/fake-integration-proxy/` |
| Identity | Dex OIDC (local static user) | `infra/inf-signalloom/base/dex.yaml` |
| Secrets/Identity | OpenBao + SPIRE | `infra/inf-bao/` |
| Persistence | PostgreSQL, Redis, MinIO | `infra/inf-signalloom/` |
| Go tools | proof-helper | `proof-helper/` |
| K8s manifests | Kustomize overlays | `apps/fe-signalloom/base/`, `local/` |
| Tests | BATS (35 files) | `test/` |

## Namespaces

| Namespace | Contents |
|-----------|----------|
| `fe-signalloom` | Dashboard SPA, API backend, Gateway HTTPRoutes |
| `fe-signalloom-agents` | Demo agent pods (Monty Python names) |
| `inf-signalloom` | Dex, PostgreSQL, Redis, MinIO, fake-integration-proxy |
| `inf-bao` | OpenBao, SPIRE server/agents |

## Lifecycle

```bash
make demo-signalloom-up           # Build images, sign, push, reconcile Flux
make demo-signalloom-test         # Static topology + Flux readiness
make demo-signalloom-runtime-test # BATS/DETIK runtime assertions
make demo-signalloom-down         # Remove slice, keep foundation
```

## Dashboard Access

```bash
# Port MUST be 5173 — Dex issuer and redirect URI pinned to it
kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
# → http://localhost:5173
#   Email:    demo-user@signalloom.local
#   Password: demo-user

# Via Envoy Gateway (HTTPS)
kubectl -n ingress port-forward svc/envoy-ingress-cluster-* 18443:443
# curl -sk --resolve dashboard.osramp.acme.local:18443:127.0.0.1 https://dashboard.osramp.acme.local:18443/
```

## Dashboard SPA Routes

| Route | Page | Data | Superadmin-only |
|-------|------|------|-----------------|
| `/agents` | Agents (default) | API | |
| `/compliance` | Compliance | API | |
| `/audit` | Audit Trail | API | |
| `/cryptography` | Cryptography | Mock | ✓ |
| `/federated-services` | Federated Services | Mock | ✓ |
| `/collusion-access` | Collusion & Access | Mock | ✓ |
| `/rbac-analysis` | RBAC Analysis + importer | AFM | ✓ |
| `/rbac-explorer` | RBAC Explorer | AFM | ✓ |
| `/supercred` | SuperCred demo | fake-integration-proxy | |
| `/settings` | Settings | API | |

Utility routes (not sidebar-navigable): `/onboarding` (wizard), `/redeem-invite` (signup).

Corner widgets, bottom-right: **ThemeToggle** (Dark / Light / Andy) then **DemoToggle** (live API ↔
local fixture data).

**Superadmin** is a sidebar toggle below Help & Support, rendered only for `demo-user`. It hides or
shows the five marked nav entries. It is **visibility, not authorization** — every route stays
registered and reachable by direct URL. The eligibility predicate in `src/auth/superadmin.ts` is a
temporary stand-in for the user-authentication table; replace its body when RBAC lands.

Full reference: [`docs/signalloom/dashboard-superadmin-themes-importer.md`](../docs/signalloom/dashboard-superadmin-themes-importer.md).

## Testing

| Command | Tests | Time |
|---------|-------|------|
| `make -C d2-signalloom test` | Static topology + BATS (38) | ~10s |
| `bats test/dashboard-routes.bats` | nginx SPA fallback + no-redirect guard (15, needs :5173) | ~3s |
| `bats test/dashboard-route-collisions.bats` | no nginx proxy prefix shadows a SPA route (8) | ~2s |
| `bats test/agent-discovery-rbac.bats` | every discovery namespace has a matching grant (5) | ~2s |
| `bats test/fleet-patch-indexes.bats` | overlay verify-patch indexes still hit an OCIRepository (3) | ~2s |
| `bats ../test/supercred-images.bats` | image build/load guard, no cluster needed (9) | ~3s |
| `cd apps/fake-integration-proxy && PYTHONPATH=. python3 -m unittest discover -s test` | proxy discovery (21) — **unittest, not pytest** | ~2s |
| `bats test/gateway-dashboard.bats` | Envoy Gateway routes (9, needs :18443) | ~3s |
| `bats test/dex-auth.bats test/dex-runtime.bats` | Dex OIDC contract (6) | ~5s |
| `bats test/dashboard-image.bats` | Container build + readyz + SPA fallback | ~30s |
| `bats test/dashboard-supplychain.bats` | SBOM + provenance + signing | ~5s |
| `cd apps/dashboard-signalloom && bun run test` | vitest unit tests | ~2s |
| `cd apps/dashboard-signalloom && bun run typecheck` | tsc --noEmit | ~2s |
| `cd apps/dashboard-signalloom && bun run lint` | eslint --max-warnings 0 | ~2s |
| Playwright (from repo root) `cd test/acceptance && bunx playwright test --project=smoke` | Browser smoke (14) | ~7s |

## Building the Dashboard Image

```bash
make signalloom-dashboard-image    # or: scripts/build-sign-dashboard.sh
# then:
kubectl -n fe-signalloom rollout restart deploy/dashboard-signalloom
# restart port-forward (it dies on rollout)
```

## Adding a New Dashboard Page

See `DESIGN.md` in this directory for the full visual guide. Summary:

1. `src/pages/MyPage.tsx` — default-export component using DashKit
2. Lazy-import in `App.tsx`
3. Route in `App.tsx` wrapped in `ProtectedRoute`
4. Nav entry in `Sidebar.tsx` NAV array (before Settings)
5. Test at `src/pages/MyPage.test.tsx`
6. Add route to `smoke.spec.ts` PAGES array
7. Rebuild image → rollout restart → restart port-forward

## Pitfalls

- **Dex login expects email** (`demo-user@signalloom.local`), not username
- **`public/` file perms**: must be 644+ (nginx uid 101 → 403 otherwise)
- **ConsentModal.test.tsx**: 2 pre-existing failures (duplicate text matches) — not a regression
- **Port-forward drops on rollout**: always restart after `rollout restart`
- **nginx proxies**: `/dex/*` → dex:5556, `/api/*` → fe-signalloom-api:8000 (single-origin, no CORS),
  `/supercred-api/*` → fake-integration-proxy:8080, `/demo-api/*` → supercred-demo-runner:8000,
  `/fleet-api/*` → fleet-manager:8082 (rewritten to `/api`), and seven prefixes to
  afm-platform.fe-k8s-afm:8000 (`/dashboard/`, `/afm/`, `/clusters`, `/metrics/`, `/health`,
  `/jobs`, `/webhooks/`)
- **No proxy prefix may shadow a SPA route.** nginx matches proxy locations before `location /`
  reaches `try_files`, so a prefix sharing a name with a client-side route means that page can never
  render. This is why the SuperCred proxy is `/supercred-api/` and not `/supercred/`. Guarded by
  `test/dashboard-route-collisions.bats`.
- **BATS `skip` reports as `ok`.** A suite whose precondition is missing (port-forward down, cluster
  absent) prints all-green while testing nothing. Check for `# skip` before trusting a pass —
  `dashboard-routes.bats` and `gateway-dashboard.bats` both skip silently without their port-forward.
- **Manifest edits need an artifact push, not `kubectl apply`.** Flux reverts hand-applied changes on
  its next reconcile. See the delivery-pipeline section in
  `docs/signalloom/dashboard-superadmin-themes-importer.md`.

### A backend this slice depends on may simply not be deployed

Twice in two days — fleet-manager on 2026-08-12, `afm-platform` on 2026-08-13 — a
complete, tested backend sat in the repo undeployed, and the dashboard reported
something other than that fact. **Not every service this slice calls is brought up
by `make demo-signalloom-up`**: Fleet Manager needs `make demo-signalloom-fleet-up`
and `afm-platform` needs `make demo-k8s-afm-up`, both opt-in, both consumed by
pages that look like ordinary Signal Loom pages.

The symptoms name the wrong thing, and each of the four wiring layers produces a
different one. With no nginx `location`, the request falls through to the SPA
catch-all and `index.html` comes back with **200 OK** — `res.ok` is true, so the
client parses HTML as JSON and reports `Unexpected token '<', "<!doctype "... is
not valid JSON`. With the proxy present but a NetworkPolicy short, you get a 504
against a service that is healthy and listening: fleet-manager's ingress admitted
`app.kubernetes.io/part-of: signalloom`, which the dashboard pods do not carry —
they are labelled only `app.kubernetes.io/name: dashboard-signalloom` — and the
dashboard had no egress rule for 8082. Server-side, `rbac_correlation.py` reaches
AFM over `httpx` and raises `APIError(503, "afm_unreachable", ...)` carrying
`[Errno -2] Name or service not known`, which is a visible failure by design but
still describes DNS rather than the missing deployment.

The obvious diagnosis in each case is wrong. A parse error looks like a bad
response body, so the instinct is to fix the client or fall back to demo data —
neither can help, because nothing that parses `index.html` will ever produce a
topology. A 504 looks like the backend being slow or down, so the instinct is to
check the pod — which is `1/1 Running` and answering `/health` on its own port.
Ask the path the browser uses, from inside the pod that uses it:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

`200 text/html` is the proxy layer, `504` is a NetworkPolicy, a DNS failure is a
missing deployment. `bats test/dashboard-route-collisions.bats` guards two of the
four layers for the dashboard's own nginx — it asserts every upstream has a
matching egress rule, and it caught the Fleet gap the moment the proxy was added.
Nothing guards "is it deployed at all". Full checklist, with the namespace and
RoleBinding traps that make this class silent:
[`docs/deploying-a-backend-service.md`](../docs/deploying-a-backend-service.md).

## Supply Chain

Dashboard image built by `scripts/build-sign-dashboard.sh`:
- SPDX SBOM + SLSA provenance + cosign signature
- Evidence in `docs/signalloom/evidence/`
- Verified by `bats test/dashboard-supplychain.bats`
