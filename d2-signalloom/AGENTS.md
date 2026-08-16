# AGENTS.md: Signal Loom delivery slice

Signal Loom agent governance platform. Dashboard SPA, FastAPI backend, Dex
OIDC, OpenBao/SPIRE, PostgreSQL/Redis/MinIO, and fake integrations.

## Stack

| Component | Tech | Path |
|-----------|------|------|
| Dashboard SPA | React 18, Vite, TypeScript, nginx | `apps/dashboard-signalloom/` |
| API backend | Python FastAPI | `apps/fe-signalloom/src/` |
| Fake services | Go and Python proxy | `apps/fake-integration-proxy/` |
| Identity | Dex OIDC (local static user) | `infra/inf-signalloom/base/dex.yaml` |
| Secrets and identity | OpenBao, SPIRE | `infra/inf-bao/` |
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
# Port MUST be 5173. Dex issuer and redirect URI are pinned to it.
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

Corner widgets (bottom-right): **ThemeToggle** (Dark / Light / Andy), then
**DemoToggle** (live API or local fixture data).

**Superadmin** is a sidebar toggle below Help & Support. It appears only for
`demo-user` and hides or shows the five marked nav entries. This controls
visibility, not authorization. Every route stays registered and reachable by
direct URL. The eligibility predicate in `src/auth/superadmin.ts` is a
temporary stand-in for the user-authentication table. Replace its body when
RBAC lands.

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
| `cd apps/fake-integration-proxy && PYTHONPATH=. python3 -m unittest discover -s test` | proxy discovery (21). **unittest, not pytest**. | ~2s |
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

## Adding a new dashboard page

See `DESIGN.md` for the visual guide and the full checklist.

## Adding an audited endpoint

**The invariant is not negotiable:** an audit event is a side effect of the
action the API itself performs. It is never content the client supplies, never
a record of an action performed elsewhere, and never written by a browser. A
row records what its writer observed, and nothing else. If a front-end action
needs auditing, it makes an API request and *that* API writes the row.

The corollary that decides the hard cases: **a field that crosses the wire is
a field the next caller can author.** The test for a proposed audit field is
not "is this useful?" but "did the process writing this row observe it?" If
not, it does not go in the row, not even as a nullable.

1. Perform the action; if it is a database write, open the transaction.
2. Write the row from the handler with `actor=principal.actor`, inside that transaction.
   Never use a hardcoded actor. `src/tests/test_audit_event_types.py` fails the build on one.
3. Where there is no transaction to bind to (a subprocess, a mutated cluster), audit
   **before** the side effect and say in the code that ordering is the only guarantee.
4. Claim no outcome you did not observe.
5. New event type → migration widening the `audit_events` CHECK constraint, **and** both
   `EVENT_TYPES` and `EVENT_COLORS` in `src/views/AuditTrail.tsx`.

Full statement, with the worked example of getting it wrong: `docs/signalloom/audit-trail.md`.

## Pitfalls

- **`audit_events` is append-only** (migration 030, `ENABLE ALWAYS` trigger). `UPDATE`,
  `DELETE` and `TRUNCATE` raise `42501`. Reset with `make demo-signalloom-data-reset`.
  This is the only sanctioned destructive path. It lifts the guard and re-arms it in
  one transaction. The app role owns the table and is a superuser, so the guard stops
  the application from rewriting its own history. It does not stop a determined operator.
- **Risk figures default to USD.** The estate reports GBP, so most figures on screen
  are converted and carry the FX table's `as_of` date. This is a per-user setting.
  See `docs/signalloom/display-currency.md`.
- **Dex login expects email** (`demo-user@signalloom.local`), not username.
- **`public/` file perms**: must be 644 or higher. nginx uid 101 returns 403 otherwise.
- **ConsentModal.test.tsx**: 2 pre-existing failures (duplicate text matches). Not a regression.
- **Port-forward drops on rollout**: always restart after `rollout restart`.
- **nginx proxies**: `/dex/*` to dex:5556, `/api/*` to fe-signalloom-api:8000 (single-origin, no CORS),
  `/supercred-api/*` to fake-integration-proxy:8080, `/demo-api/*` to supercred-demo-runner:8000,
  `/fleet-api/*` to fleet-manager:8082 (rewritten to `/api`), and seven prefixes to
  afm-platform.fe-k8s-afm:8000 (`/dashboard/`, `/afm/`, `/clusters`, `/metrics/`, `/health`,
  `/jobs`, `/webhooks/`).
- **No proxy prefix may shadow a SPA route.** nginx matches proxy locations before `location /`
  reaches `try_files`. A prefix that shares a name with a client-side route prevents that page
  from rendering. The SuperCred proxy is `/supercred-api/` and not `/supercred/` for this reason.
  Guarded by `test/dashboard-route-collisions.bats`.
- **BATS `skip` reports as `ok`.** A suite with a missing precondition (port-forward down, cluster
  absent) prints all-green but tests nothing. Check for `# skip` before you trust a pass.
  `dashboard-routes.bats` and `gateway-dashboard.bats` both skip silently without their port-forward.
- **Manifest edits need an artifact push, not `kubectl apply`.** Flux reverts hand-applied changes on
  its next reconcile. See the delivery-pipeline section in
  `docs/signalloom/dashboard-superadmin-themes-importer.md`.

### A backend this slice depends on may not be deployed

On two occasions (fleet-manager on 2026-08-12, `afm-platform` on 2026-08-13) a
complete, tested backend sat in the repo undeployed. The dashboard reported
something other than that fact. **Not every service this slice calls is started
by `make demo-signalloom-up`.** Fleet Manager needs `make demo-signalloom-fleet-up`
and `afm-platform` needs `make demo-k8s-afm-up`. Both are opt-in. Both are
consumed by pages that look like ordinary Signal Loom pages.

The symptoms name the wrong thing. Each of the four wiring layers produces a
different symptom. With no nginx `location`, the request falls through to the SPA
catch-all and `index.html` comes back with **200 OK**. `res.ok` is true, so the
client parses HTML as JSON and reports `Unexpected token '<', "<!doctype "... is
not valid JSON`. With the proxy present but a NetworkPolicy short, you get a 504
against a service that is healthy and listening. fleet-manager's ingress admitted
`app.kubernetes.io/part-of: signalloom`, but the dashboard pods do not carry that
label. They have only `app.kubernetes.io/name: dashboard-signalloom`, and the
dashboard had no egress rule for 8082. Server-side, `rbac_correlation.py` reaches
AFM over `httpx` and raises `APIError(503, "afm_unreachable", ...)` with
`[Errno -2] Name or service not known`. This is a visible failure by design, but
it describes DNS rather than the missing deployment.

The obvious diagnosis in each case is wrong. A parse error looks like a bad
response body. The instinct is to fix the client or fall back to demo data.
Neither helps, because nothing that parses `index.html` will produce a
topology. A 504 looks like the backend is slow or down. The instinct is to
check the pod, which is `1/1 Running` and answering `/health` on its own port.
Ask the path the browser uses, from inside the pod that uses it:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

`200 text/html` is the proxy layer. `504` is a NetworkPolicy. A DNS failure is a
missing deployment. `bats test/dashboard-route-collisions.bats` guards two of the
four layers for the dashboard's nginx. It asserts every upstream has a matching
egress rule, and it caught the Fleet gap the moment the proxy was added. Nothing
guards "is it deployed at all". Full checklist, with the namespace and
RoleBinding traps that make this class silent:
[`docs/deploying-a-backend-service.md`](../docs/deploying-a-backend-service.md).

## Supply Chain

Dashboard image built by `scripts/build-sign-dashboard.sh`:
- SPDX SBOM, SLSA provenance, and cosign signature
- Evidence in `docs/signalloom/evidence/`
- Verified by `bats test/dashboard-supplychain.bats`
