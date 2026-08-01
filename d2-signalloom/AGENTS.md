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
| `make -C d2-signalloom test` | Static topology + BATS (29) | ~10s |
| `bats test/dashboard-routes.bats` | nginx SPA fallback (11, needs :5173) | ~3s |
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
- **nginx proxies**: `/dex/*` → dex:5556, `/api/*` → fe-signalloom-api:8000 (single-origin, no CORS)

## Supply Chain

Dashboard image built by `scripts/build-sign-dashboard.sh`:
- SPDX SBOM + SLSA provenance + cosign signature
- Evidence in `docs/signalloom/evidence/`
- Verified by `bats test/dashboard-supplychain.bats`
