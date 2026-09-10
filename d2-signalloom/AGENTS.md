# AGENTS.md: Signal Loom Delivery Slice

Signal Loom is an agent governance platform. It provides a React dashboard SPA,
a FastAPI backend, Dex OIDC, OpenBao with SPIRE, and integration proxies.

## Stack

| Component | Technology | Path |
|---|---|---|
| Dashboard SPA | React 18, Vite, TypeScript, nginx | `apps/dashboard-signalloom/` |
| User documentation | Astro Starlight, Mermaid, nginx | `apps/docs-signalloom/` |
| API backend | Python FastAPI | `apps/fe-signalloom/src/` |
| Integration services | Go and Python proxy | `apps/fake-integration-proxy/` |
| Identity | Dex OIDC (local static user) | `infra/inf-signalloom/base/dex.yaml` |
| Secrets and identity | OpenBao, SPIRE | `infra/inf-bao/` |
| Persistence | PostgreSQL, Redis, MinIO | `infra/inf-signalloom/` |
| Go tools | proof-helper | `proof-helper/` |
| Kubernetes manifests | Kustomize overlays | `apps/fe-signalloom/base/`, `local/` |
| Tests | BATS test suites | `test/` |

## Namespaces

| Namespace | Contents |
|---|---|
| `fe-signalloom` | Dashboard SPA, API backend, Gateway HTTPRoutes |
| `fe-signalloom-agents` | Demo agent workloads |
| `inf-signalloom` | Dex, PostgreSQL, Redis, MinIO, fake integration proxy |
| `inf-bao` | OpenBao server, SPIRE server, SPIRE agents |

## Lifecycle

```bash
make demo-signalloom-up           # Build images, sign, push, and reconcile Flux
make demo-signalloom-test         # Run topology and Flux readiness checks
make demo-signalloom-runtime-test # Run BATS and DETIK runtime assertions
make demo-signalloom-down         # Remove slice while keeping foundation
```

## Dashboard Access

```bash
# Port must be 5173. Dex issuer and redirect URIs require this exact port.
kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
# Open: http://localhost:5173
# Login: demo-user@signalloom.local / demo-user

# Connect through Envoy Gateway (HTTPS)
kubectl -n ingress port-forward svc/envoy-ingress-cluster-* 18443:443
# curl -sk --resolve dashboard.osramp.acme.local:18443:127.0.0.1 https://dashboard.osramp.acme.local:18443/
```

## Dashboard Routes

| Route | Page Name | Data Source | Superadmin Only |
|---|---|---|---|
| `/agents` | Agents (default) | API | |
| `/compliance` | Compliance | API | |
| `/audit` | Audit Trail | API | |
| `/cryptography` | Cryptography | Mock | ✓ |
| `/federated-services` | Federated Services | Mock | ✓ |
| `/collusion-access` | Collusion & Access | Mock | ✓ |
| `/rbac-analysis` | RBAC Analysis & Importer | AFM | ✓ |
| `/rbac-explorer` | RBAC Explorer | AFM | ✓ |
| `/supercred` | SuperCred Demo | fake-integration-proxy | |
| `/settings` | Settings | API | |
| `/docs` | User documentation | Static docs container | |

Utility routes: `/onboarding` (wizard) and `/redeem-invite` (user signup).

Controls at bottom-right:
- **ThemeToggle**: Switch between Dark, Light, and Andy themes.
- **DemoToggle**: Switch between live API data and local fixture data.

Superadmin is a navigation toggle. It appears only for `demo-user`. It hides or shows
the five marked navigation entries. It affects UI visibility only. Direct URLs remain
accessible.

Read [`docs/signalloom/dashboard-superadmin-themes-importer.md`](../docs/signalloom/dashboard-superadmin-themes-importer.md)
for details.

## Testing

Run these test commands for this slice:

| Command | Purpose | Duration |
|---|---|---|
| `make -C d2-signalloom test` | Run static topology and BATS tests | ~10s |
| `bats test/dashboard-routes.bats` | Check nginx SPA fallback (requires port 5173) | ~3s |
| `bats test/dashboard-route-collisions.bats` | Check proxy prefixes against SPA routes | ~2s |
| `bats test/agent-discovery-rbac.bats` | Check pod reading grants for discovery namespaces | ~2s |
| `bats test/fleet-patch-indexes.bats` | Check ResourceSet patch indexes | ~2s |
| `bats ../test/supercred-images.bats` | Check image build and load guard (no cluster required) | ~3s |
| `cd apps/fake-integration-proxy && PYTHONPATH=. python3 -m unittest discover -s test` | Run proxy discovery tests | ~2s |
| `bats test/gateway-dashboard.bats` | Check Envoy Gateway routes (requires port 18443) | ~3s |
| `bats test/dex-auth.bats test/dex-runtime.bats` | Check Dex OIDC contract | ~5s |
| `cd test/dex-templates && go test ./...` | Check Dex web template rendering | ~1s |
| `bats test/dex-config-reload.bats` | Check Dex restart on config change | ~1s |
| `bats test/dashboard-image.bats` | Check container image build and health | ~30s |
| `bats test/dashboard-supplychain.bats` | Check SBOM, provenance, and Cosign signature | ~5s |
| `cd apps/dashboard-signalloom && bun run test` | Run Vitest unit tests | ~2s |
| `cd apps/dashboard-signalloom && bun run typecheck` | Run TypeScript typecheck | ~2s |
| `cd apps/dashboard-signalloom && bun run lint` | Run ESLint | ~2s |
| `cd test/acceptance && bunx playwright test --project=smoke` | Run browser smoke tests | ~7s |

## Building the Dashboard Image

```bash
make signalloom-dashboard-image
kubectl -n fe-signalloom rollout restart deploy/dashboard-signalloom
# Note: restart the port-forward after rollout completes
```

### Adding a New Dashboard Page

Read `DESIGN.md` for visual guidelines and component rules.

## Adding an Audited Endpoint

Audit events record actions the API performs directly.
Never accept audit events supplied by the client.
Never write audit events from browser code.
An audit row records only what the server observed.

Rules for auditing:
1. Complete the action. If writing to the database, open a transaction.
2. Write the audit row with `actor=principal.actor` inside the transaction.
   Never use hardcoded actors.
3. If no database transaction exists, write the audit event before the action.
4. Record only observed outcomes.
5. When adding an event type, update the database CHECK constraint, and update
   `EVENT_TYPES` and `EVENT_COLORS` in `src/views/AuditTrail.tsx`.

Read `docs/signalloom/audit-trail.md` for full implementation details.

## Common Pitfalls

- **`audit_events` table is append-only:** Modifying existing rows raises an error (`42501`).
  Use `make demo-signalloom-data-reset` to reset test data.
- **Currency values default to USD:** Convert GBP values using the FX exchange rate table.
- **Dex login requires an email address:** Use `demo-user@signalloom.local`, not a username.
- **File permissions in `public/`:** Set permissions to 644 or higher to prevent 403 errors from nginx.
- **Port-forwards stop on pod rollout:** Always restart port-forwards after `rollout restart`.
- **Proxy prefix collisions:** Nginx proxy paths must not match React Router paths.
  Route `/supercred-api/` avoids shadowing `/supercred`.
- **Silent BATS skips:** A skipped test outputs `ok`. Check logs for `# skip` to verify test execution.
- **Manifest changes require artifact push:** Flux overwrites manual `kubectl apply` changes on reconciliation.

### Diagnose Backend Service Connections

KubeSec-AFM deploys outside `make demo-signalloom-up`:

```bash
make demo-k8s-afm-up
```

Fleet Manager now deploys through the Signal Loom Flux path. Use
`make demo-signalloom-fleet-up` only as a direct-apply test escape hatch.

If a backend service is missing, test the connection from inside the dashboard pod:

```bash
kubectl -n fe-signalloom exec deploy/dashboard-signalloom -- \
  curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  http://localhost:8080/fleet-api/v1/fleet/topology
```

Interpret results:
- `200 application/json` — The service is healthy.
- `200 text/html` — Nginx proxy rule missing; the SPA catch-all returned `index.html`.
- `504 Gateway Timeout` — NetworkPolicy blocked the connection.
- `DNS failure` — The service is not deployed.

Read [`docs/deploying-a-backend-service.md`](../docs/deploying-a-backend-service.md) for more guidance.

## Supply Chain

Build the dashboard image with `scripts/build-sign-dashboard.sh`:
- Generates SPDX SBOM, SLSA provenance, and Cosign signature.
- Stores evidence in `docs/signalloom/evidence/`.
- Tested by `bats test/dashboard-supplychain.bats`.
