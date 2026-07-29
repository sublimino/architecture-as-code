# Environment Configuration — Signal Loom Estate

## `SL_ENV` — the universal environment flag

Every component in the Signal Loom estate reads a single environment variable
`SL_ENV` to determine its behaviour tier. This variable propagates through
Kubernetes manifests, Flux Kustomization overlays, and CI/CD.

### Valid values

| Value | When | Behaviour |
| :---- | :---- | :---- |
| `demo` | Local `make demo-signalloom-up` | Fake adapters, mock Postgres data, demo agents, client-side demo toggle visible, relaxed auth |
| `dev` | Developer branch | Real adapters where available, real Postgres, debug logging, client-side demo toggle visible |
| `ci` | CI pipeline (GitHub Actions) | Headless, ephemeral cluster, strict assertions, no demo toggle |
| `uat` | Pre-production acceptance | Real adapters, real IdP (Entra ID), demo toggle hidden, feature flags match prod |
| `prod` | Production | Full stack, all connectors, no demo toggle, production secrets from Vault/OpenBao, mTLS enforced |

### Component behaviour matrix

| Component | What `SL_ENV` controls |
| :---- | :---- |
| **Dashboard (React)** | `VITE_SL_ENV` build-time: hides demo toggle in `ci`/`uat`/`prod`; controls whether `isDemoMode()` defaults to `true` (demo) or `false` (all others) |
| **API (FastAPI)** | `SL_ENV` sets adapter defaults: `demo` → `fake-*` adapters; `dev`/`ci` → configurable; `uat`/`prod` → requires real adapters (fake-* is forbidden) |
| **Dex** | `SL_ENV=demo` → local password only; `uat`/`prod` → remote connectors overlay applied |
| **AFM** | `SL_ENV` controls auto-seed behaviour: `demo` → loads sample clusters at boot; `prod` → live cluster import only |
| **Postgres** | `SL_ENV=demo` → `make demo-signalloom-data-mock` auto-seeds; `prod` → migrations only, no demo data |
| **Flux** | `SL_ENV` selects the Kustomization overlay path (base, dev, uat, prod) |
| **Agents** | `SL_ENV=demo` → deterministic agent cohort (Monty Python theme); `prod` → real discovered agents |
| **NetworkPolicy** | `SL_ENV=demo`/`dev` → relaxed egress; `prod` → strict default-deny + explicit allows only |
| **Signing** | `SL_ENV=demo` → local cosign key; `prod` → keyless OIDC via Fulcio/Rekor |

### Where `SL_ENV` is set

1. **Kubernetes manifests**: as an `env:` entry in every Deployment that needs it
2. **Makefile**: `export SL_ENV ?= demo` at the top (default for local dev)
3. **CI**: `env: SL_ENV: ci` in GitHub Actions workflow
4. **Flux Kustomization**: `postBuild.substituteFrom` referencing a ConfigMap with `SL_ENV`
5. **Dashboard**: `VITE_SL_ENV` in the `.env` / `.env.production` files (build-time)

## Current implementation status

### Implemented

| Component | Status | Notes |
| :---- | :---- | :---- |
| Dashboard `isDemoMode()` | **Working** | localStorage toggle (`sl_demo_mode`), defaults per `VITE_SL_ENV` |
| Dashboard `DemoToggle` | **Working** | Corner widget hidden when `VITE_SL_ENV` is `ci`/`uat`/`prod` |
| Dashboard `fakeData.ts` | **Working** | Client-side fixtures served when demo mode is ON |
| API `adapters.py` | **Working** | `fake-*` backends selected via per-adapter env vars |
| API `api_compat.py` | **Working** | Proxy/fake responses controlled by backend env vars |
| Postgres `signalloom-data.sh` | **Working** | `migrate` + `mock` commands; `make demo-signalloom-data-mock` |
| Dex connectors | **Working** | Base (password only) + overlay (remote connectors) |
| AFM lifecycle | **Working** | `scripts/k8s-afm.sh` with `up`/`down`/`seed`/`test`/`status` |
| Agent cohort | **Working** | `make demo-signalloom-agents-up` deterministic Monty Python agents |

### Tech debt — not yet wired to `SL_ENV`

| Component | What's needed | Priority |
| :---- | :---- | :---- |
| Dashboard `.env` | Add `VITE_SL_ENV=demo` to `.env` and wire `DemoToggle` visibility to it | High |
| Dashboard `isDemoMode()` default | When `VITE_SL_ENV=demo`, default `isDemoMode()` to `true` (currently `false` until toggled) | High |
| API deployment | Add `SL_ENV` env var to `fe-signalloom` Deployment; adapters.py should read it and block `fake-*` in `uat`/`prod` | High |
| AFM deployment | Add `SL_ENV` to the `afm-platform` Deployment; auto-seed sample clusters only in `demo` | Medium |
| Dex deployment | Overlay selection driven by `SL_ENV` rather than manual kustomize path choice | Medium |
| Flux Kustomization | Add `SL_ENV` to the `substituteFrom` ConfigMap; use it in targetNamespace/overlay selection | Medium |
| Signing strategy | `SL_ENV=prod` should use keyless OIDC signing; `demo`/`dev` uses local cosign key | Low |
| NetworkPolicy strictness | `SL_ENV=prod` should deny all egress except explicit allows; `demo` can be relaxed | Low |
| Makefile top-level | `export SL_ENV ?= demo` at the top; propagate to all `demo-*` targets | High |
| CI workflow | Set `SL_ENV=ci` in GitHub Actions `env:` block | Medium |
| `make demo-signalloom-demo-up` | Should set `SL_ENV=demo` and run migrations + mock in one shot | High |

## Postgres seed/restore flow

The demo system restores fully from `make`:

```bash
# Full lifecycle (from clean cluster)
make up                         # Cluster + registry + Flux + infra
make demo-signalloom-up         # Deploy Signal Loom via Flux
make demo-signalloom-demo-up    # Seed agents + mock Postgres data

# Just the data layer (on a running cluster)
make demo-signalloom-data-mock  # Reset + populate Postgres with demo data

# Migrations only (no demo data)
scripts/signalloom-data.sh migrate

# Check what's in the database
scripts/signalloom-data.sh status
```

Schema migrations run via `scripts/signalloom-data.sh migrate` (4 migration files
in `d2-signalloom/apps/fe-signalloom/src/db/migrations/`). The mock data is in
`data-mock.sql` (458 lines: 5 agents, 2 frameworks, 6 controls, 30 compliance
results, 10 audit events, 3 violations, NHI scans, tenant settings).

**Note:** `psql` is required on the host for `signalloom-data.sh`. If unavailable,
run via `kubectl exec`:

```bash
kubectl exec -n inf-signalloom deploy/postgresql -- \
  psql -U signalloom -d signalloom -f /dev/stdin < path/to/file.sql
```

## API proxy topology

```
Browser → :5173 (port-forward)
    └─→ nginx (dashboard-signalloom pod, :8080)
         ├─→ /dex/     → dex.inf-signalloom.svc:5556         (Dex OIDC)
         ├─→ /api/     → fe-signalloom-api.fe-signalloom:8000 (FastAPI backend)
         ├─→ /afm/     → afm-platform.fe-k8s-afm:8000        (KubeSec-AFM)
         ├─→ /_next/   → afm-platform.fe-k8s-afm:8000        (AFM Next.js assets)
         └─→ /*        → SPA fallback (index.html)
```

### Data mode switching

- **Demo mode (client-side)**: The `DemoToggle` widget (bottom-right corner)
  flips `isDemoMode()` via localStorage. When ON, `client.ts` short-circuits all
  API calls to `fakeData.ts` fixtures — no HTTP requests are made. When OFF, all
  calls go through nginx → FastAPI.

- **Demo mode (server-side)**: The FastAPI backend uses adapter registries
  (`adapters.py`) with `fake-*` defaults. In `demo`/`dev`, the backend returns
  realistic mock responses from the Postgres demo data. In `prod`, fake adapters
  are forbidden.

- **Full mode**: All API calls go through nginx → FastAPI → Postgres/Redis/MinIO.
  The dashboard demo toggle is hidden. Every adapter is a real integration.
