# Appraisal — In-cluster Auth, Gateway Routing, Demo Runbook

> **SUPERSEDED, 2026-08-14. Retained as a dated record of the migration path — do not
> action the verdicts below.**
>
> This is a read-only appraisal of the cluster as it stood on **2026-07-27**, and its
> headline finding is no longer true. **Auth works.** The dashboard authenticates against
> the in-cluster Dex issuer, and the API validates those tokens; blockers A and B below
> were closed, along with the rest of the contract gap, on 2026-07-28 — see the banner on
> `APPRAISAL.md`.
>
> That matters beyond "the demo logs in now". The Dex token is where `actor` on an audit
> row comes from (`Principal.actor`), so the trust chain this document describes as never
> wired together is the thing attribution now rests on. For the current state read
> [`../signalloom/audit-trail.md`](../signalloom/audit-trail.md) and
> [`../signalloom/dex-oidc-design.md`](../signalloom/dex-oidc-design.md).
>
> The **gateway routing** analysis (§ 2) has not been contradicted and is still the
> clearest account of why same-origin `/api` holds. That, and the reasoning trail, are why
> this file is kept rather than deleted.
>
> The absolute paths below point into a July 2026 worktree that no longer exists, and
> making them repository-relative is not enough to rescue them: `src/auth/Auth0Provider.tsx`
> is gone, along with every trace of `VITE_AUTH0_*`. That directory now holds `oidc.tsx`,
> `ProtectedRoute.tsx` and `superadmin.ts`. Treat every file reference below as naming a
> file that has since been replaced.

Scope: bring the SignalLoom React dashboard up in the Kind cluster. Read-only appraisal.
Root: `/home/andy/src/cp/osramp-demo/worktrees/signalloom-d2-v2.0.0/governor/worktrees/signalloom-d2-v2.5.0/governor/`
Date: 2026-07-27.

---

## TL;DR verdicts

| Area | Verdict |
|------|---------|
| **Auth — can a demo user log in?** | **NO.** Two independent blockers. (1) The dashboard image is built with **zero `VITE_AUTH0_*` values** baked in, so the Auth0 SDK initialises with `domain/clientId/audience = undefined` and cannot start a login. (2) Even if Auth0 were configured, the in-cluster API validates tokens against a **local Dex issuer**, not Auth0 — the dashboard's Auth0 client and the API's Dex trust chain are **never wired together**. There is a real, deployed Dex OIDC stub, but nothing points the dashboard at it. |
| **Gateway — is SPA + `/api` routing correct?** | **YES, routing shape is correct.** Both `/` (SPA) and `/api` (backend) are HTTPRoutes on the **same host** `dashboard.osramp.acme.local`, so the dashboard's same-origin `/api` assumption holds. `/api` is **passed through un-stripped** (no `URLRewrite`/`ReplacePrefixMatch`), which matches the FastAPI backend that serves paths under `/api`. Gateway-API longest-prefix precedence sends `/api/*` to the API and everything else to the SPA. |
| **Runbook — can you walk the demo to a browser?** | **PARTIALLY.** Make targets exist to build/sign/load the dashboard image and Flux deploys it plus both routes. But there is **no Make target that opens the dashboard in a browser** and **no host-port mapping** on the Kind cluster — reaching it requires a manual `kubectl port-forward` of the Envoy gateway plus a `--resolve`/`/etc/hosts` entry for `dashboard.osramp.acme.local`. Combined with the auth blocker, the dashboard renders but every `/api` call 401s and bounces to a dead Auth0 login. |

---

## 1. AUTH

### 1.1 What the dashboard does

Two copies of the dashboard auth code exist and are byte-identical in the relevant logic:

- Platform source: `/home/andy/src/cp/platform/dashboard/src/auth/Auth0Provider.tsx`, `.../src/auth/tenant.ts`
- In-cluster app (the one actually built and deployed): `d2-signalloom/apps/dashboard-signalloom/src/auth/Auth0Provider.tsx`, `.../src/auth/tenant.ts`

`Auth0Provider.tsx` (in-cluster, lines ~41-59) reads three build-time env vars and wraps the app in Auth0's `Auth0ProviderBase`:

```
const domain    = import.meta.env.VITE_AUTH0_DOMAIN
const clientId  = import.meta.env.VITE_AUTH0_CLIENT_ID
const audience  = import.meta.env.VITE_AUTH0_AUDIENCE
// authorizationParams: redirect_uri = `${origin}/agents`, audience, scope 'openid profile email'
```

`tenant.ts` (lines ~6-13) base64-decodes the JWT payload client-side and reads claim `https://signalloom.ai/tenant_id` (used only for localStorage namespacing; comment states server does the real verification).

The API client (`d2-signalloom/apps/dashboard-signalloom/src/api/client.ts`, lines ~30-33) prefixes every call with `/api` (`const url = path.startsWith('/api') ? path : `/api${path}``) and sends `Authorization: Bearer <token>`. Base URL is `VITE_API_BASE_URL ?? ''` → **empty → same-origin** → `/api/...`.

### 1.2 BLOCKER A — Auth0 config is never injected at build time

`d2-signalloom/apps/dashboard-signalloom/Dockerfile` runs `npm run build` with **no `ARG`/`ENV` for any `VITE_*`** and **no `.env` file is copied**. There is **no `.env`, `.env.production`, or `.env.local`** anywhere under `d2-signalloom/apps/dashboard-signalloom` (only `vite.config.ts`, `tsconfig*`, `eslint.config.mjs`). `scripts/build-sign-dashboard.sh` builds the context with `docker buildx build` and passes **no build args**.

Consequence: Vite statically replaces `import.meta.env.VITE_AUTH0_DOMAIN` etc. with `undefined` at build. At runtime the Auth0 SDK is constructed with `domain=undefined`, `clientId=undefined` → it cannot form an authorize URL. `getAccessTokenSilently()` throws → the request interceptor calls `loginWithRedirect()` → redirect fails. **The demo user cannot authenticate.**

### 1.3 BLOCKER B — dashboard (Auth0) and API (Dex) are on different trust chains

There *is* a real local OIDC stub, deployed in-cluster:

- **Dex** — `d2-signalloom/infra/inf-signalloom/base/dex.yaml`: `ghcr.io/dexidp/dex:v2.41.1`, Deployment + Service `dex` on port 5556, namespace `inf-signalloom`.
  - Issuer: `http://dex.inf-signalloom.svc.cluster.local:5556/dex`
  - Static client `signalloom-dashboard`, redirect URI `http://localhost:5173/callback`, secret `signalloom-dashboard-local-only`.
  - Static client `signalloom-api` (audience), `trustedPeers: [signalloom-dashboard]`.
  - Static user: `demo-user` / `demo-user@signalloom.local`, tenant `tenant-demo`, **bcrypt hash only** (password supplied out-of-band, not in repo).

- **API validation** — `d2-signalloom/apps/fe-signalloom/src/config.py` + `src/api_compat.py`:
  - `config.py:20-22`: `api_jwt_issuer = http://dex.inf-signalloom.svc.cluster.local:5556/dex`, `api_jwt_audience = signalloom-api`, `api_jwt_authorized_party = signalloom-dashboard`.
  - `config.py`: JWKS default `http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys`.
  - `api_compat.py:150-186`: `PyJWKClient(jwks_url)` → `jwt.decode(..., audience=signalloom-api, issuer=<dex>, options={require:[exp,iat,sub]})`, then asserts `azp == signalloom-dashboard`, requires non-empty `sub`. Tenant is derived **only** from a server-side subject map (`API_SUBJECT_TENANTS: demo-user -> tenant-demo`); any client-supplied `tenant_id`/group claim is ignored. Unknown subject → `403 tenant_forbidden`. Missing JWKS config → fail-closed.

The mismatch: the **API only accepts Dex-issued RS256 ID tokens**, but the **dashboard is wired to Auth0**, requests audience `VITE_AUTH0_AUDIENCE` (not `signalloom-api`), and expects claim `https://signalloom.ai/tenant_id` that Dex does not mint. The dashboard has **no Dex client, no `/callback` route referenced, no OIDC-code flow to Dex**. The Dex design doc (`docs/signalloom/dex-oidc-design.md`) explicitly defers browser login: test `OIDC-BROWSER-001` = "Deferred … Not covered." Existing tests cover the API bearer path and Dex runtime endpoints only — **no test asserts a live dashboard→Dex→API chain**.

### 1.4 Auth verdict + the gap to close

A demo user **cannot** log in today. To make browser login work, someone must EITHER:

- **Path 1 (repoint dashboard at Dex):** replace/augment the Auth0 provider with a generic OIDC client pointed at Dex issuer `.../dex`, client `signalloom-dashboard`, requesting audience `signalloom-api` and `azp=signalloom-dashboard`; expose Dex to the browser on a reachable URL (Dex issuer is a `.svc.cluster.local` name the browser cannot resolve — needs an HTTPRoute or port-forward, and the issuer string must match what the browser uses); register the real callback. This is the design the API already expects. Effort: real code + manifest work.
- **Path 2 (stand up Auth0):** provision an actual Auth0 tenant, bake `VITE_AUTH0_DOMAIN/CLIENT_ID/AUDIENCE` into the image build (Dockerfile `ARG` + build-sign script), add a post-login action minting `https://signalloom.ai/tenant_id`, and **repoint the API** (`api_jwt_issuer/audience/jwks`) at Auth0. Contradicts the in-repo local-only Dex design.

Recommendation for a *local demo*: Path 1. The Dex identity provider, static user, tenant map, and API trust chain are already built and deployed — only the dashboard client and its browser-reachable issuer URL are missing.

---

## 2. GATEWAY

### 2.1 Routes — file read in full

`d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` contains **two** HTTPRoutes (no `hostnames:` field on either — confirmed `grep -c hostnames = 0`):

```
# HTTPRoute signalloom-dashboard
parentRefs: [{name: cluster, namespace: ingress, sectionName: https}]
rules: [{matches: [{path: {type: PathPrefix, value: /}}],
         backendRefs: [{name: dashboard-signalloom, port: 8080}]}]
---
# HTTPRoute signalloom-api
parentRefs: [{name: cluster, namespace: ingress, sectionName: https}]
rules: [{matches: [{path: {type: PathPrefix, value: /api}}],
         backendRefs: [{name: fe-signalloom-api, port: 8000}]}]
```

Both attach to the same Gateway listener (`cluster`/`https`). Neither declares `hostnames`, so both **inherit the Gateway listener hostname** `*.osramp.acme.local`.

### 2.2 The Gateway and host

`d2-infra/components/ingress/configs/base/cluster-gateway.yaml` (a `ResourceSet`):
- `Gateway cluster` in namespace `ingress`, `gatewayClassName: envoy-gateway`.
- Listener `http` :80 hostname `*.${CLUSTER_DOMAIN}` (redirected to https via `http-to-https-redirect` HTTPRoute, 301).
- Listener `https` :443 hostname `*.${CLUSTER_DOMAIN}`, TLS `mode: Terminate`, `certificateRefs: cert-manager/cluster-tls`, `allowedRoutes.namespaces.from: All`.
- A `ReferenceGrant` lets the ingress Gateway read the `cluster-tls` Secret in `cert-manager`.

`${CLUSTER_DOMAIN}` resolves to **`osramp.acme.local`** (`d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml:15`, substituted into manifests by Flux `postBuild.substituteFrom` of ConfigMap `flux-runtime-info`).

### 2.3 TLS / cert-manager

`d2-infra/components/cert-manager/configs/base/cluster-certificate.yaml`: `Certificate cluster`, `dnsNames: ["*.${CLUSTER_DOMAIN}"]` → `*.osramp.acme.local`, `issuerRef: ClusterIssuer cluster-issuer`, `secretName: cluster-tls`. Local issuer is a self-signed/local CA (cert is not publicly trusted → clients must use `--insecure`/`-k`). Gateway terminates TLS with this wildcard cert.

### 2.4 Path routing: `/` vs `/api` — CRITICAL confirmation

- **Same host** for both routes (`dashboard.osramp.acme.local`, matching the `*.osramp.acme.local` wildcard). The dashboard's same-origin `/api` assumption is therefore **satisfied**: the browser origin is `https://dashboard.osramp.acme.local` and `/api/...` stays on that origin.
- **Precedence:** Gateway API spec mandates longest-matching PathPrefix wins. `/api/agents` matches both `/` and `/api`; `/api` is longer → routed to `fe-signalloom-api:8000`. All other paths (e.g. `/agents`, `/`) → `dashboard-signalloom:8080` (nginx SPA, `try_files ... /index.html`).
- **Prefix is PASSED THROUGH, not stripped.** No `filters`, no `URLRewrite`, no `ReplacePrefixMatch` on the API route. The backend therefore receives the full `/api/agents` path. This is correct: the FastAPI compat app serves its routes under `/api` (the dashboard client hardcodes the `/api` prefix and the API expects it; tests hit `https://.../api/settings`).
- **Verdict: routing is correct** for the dashboard. No mismatch between the client's `/api` prefix and the backend.

### 2.5 How the host resolves locally (no automatic ingress)

The Kind cluster is created with **no `extraPortMappings`** — `scripts/create-kind-cluster.sh` emits a `kind: Cluster` config with only an `extraMounts` entry for the Zot cache. So ports 80/443 are **not** published to the host, and there is **no nip.io / no automatic hostname**. Reaching the gateway requires a manual port-forward + name resolution. The repo's own tests show the exact pattern:

- `scripts/acceptance-test.sh:42-50`: finds the Envoy service (`kubectl -n envoy-gateway-system get service -l gateway.envoyproxy.io/owning-gateway-name=cluster`), `port-forward 18443:443`, sets `DASHBOARD_URL=https://127.0.0.1:18443`.
- `d2-signalloom/test/runtime.bats:46-56`: `kubectl -n ingress port-forward service/<gw> 18443:443` then `curl --resolve dashboard.osramp.acme.local:18443:127.0.0.1 --insecure https://dashboard.osramp.acme.local:18443/`.

So the canonical local URL is **`https://dashboard.osramp.acme.local:18443/`** reached via port-forward of the Envoy gateway to `127.0.0.1:18443` plus a `--resolve` (curl) or `/etc/hosts` (browser) entry `127.0.0.1 dashboard.osramp.acme.local`. The `/api` calls go to the same URL (`https://dashboard.osramp.acme.local:18443/api/...`).

> Note: SNI/Host must be `dashboard.osramp.acme.local` (any name under `*.osramp.acme.local` works) for the wildcard listener + wildcard cert to match. Hitting `https://127.0.0.1:18443` directly will fail hostname matching.

### 2.6 Deployment confirmation (routes + dashboard actually ship)

`signalloom-apps` ResourceSet (`d2-osramp-fleet/tenants/local/signalloom.yaml`) creates an `OCIRepository` `oci://.../signalloom/apps/fe-signalloom` and a Kustomization `path: ./<< inputs.environment >>` = `./local`. `d2-signalloom/apps/fe-signalloom/local/kustomization.yaml` → `../base`, whose `kustomization.yaml` includes `dashboard-deployment.yaml`, `dashboard-service.yaml`, **and** `gateway-route.yaml` (plus `deployment.yaml`/`api-service.yaml` for the API). So the dashboard Deployment/Service and **both** HTTPRoutes are delivered by Flux. Dashboard image = `${IMAGE_BASE}/signalloom/apps/dashboard-signalloom:${ARTIFACT_TAG}` = `zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest`. Dashboard container listens :8080 (nginx-unprivileged), readiness/liveness `/readyz`.

---

## 3. RUNBOOK — exact command sequence

All commands from repo root. `CLUSTER_NAME=osramp` (Makefile default). Prereqs (README): docker, kind, kubectl, kustomize, flux, helm, cosign, jq, crane, bats.

```bash
# 0. (optional) install toolchain the demo expects
./scripts/setup.sh

# 1. Create the shared cluster foundation (Kind + Zot registry + signing keys +
#    push foundation artifacts + Flux bootstrap + wait + healthcheck).
#    Does NOT start any demo. Ends by printing the demo-help menu.
make up

# 2. Start the SignalLoom demo (Phase 1 lifecycle). This target chains:
#      push-local-signalloom  -> push SignalLoom OCI artifacts to in-cluster Zot
#      signalloom-spire-helper-> build+load the SPIRE proof helper image
#      signalloom-images      -> build fe-signalloom image AND build-sign-dashboard.sh
#                                 (builds/signs/loads dashboard-signalloom:latest)
#      scripts/signalloom-local.sh up (SIGNALLOOM_SKIP_PREPARE=1)
#                                 -> activates signalloom-infra ResourceSet (Dex, Bao),
#                                    then signalloom-apps ResourceSet
#                                    (fe-signalloom API + dashboard + BOTH HTTPRoutes)
make demo-signalloom-up

# 3. (optional) verify Flux reconciled the SignalLoom slice
make demo-signalloom-test        # config render + Flux readiness
# make demo-signalloom-runtime-test   # BATS/DETIK runtime assertions
# make demo-signalloom-test-1         # full Playwright + BATS + pytest gate

# 4. Confirm dashboard + API + Dex pods are Ready
kubectl get pods -n fe-signalloom
kubectl get pods -n inf-signalloom          # expect the `dex` pod Ready
kubectl get httproute -n fe-signalloom      # signalloom-dashboard + signalloom-api

# 5. REACH THE DASHBOARD IN A BROWSER  (no Make target exists for this — manual)
# 5a. Port-forward the Envoy gateway 443 -> localhost:18443
GW=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=cluster \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward "svc/${GW}" 18443:443 &
# 5b. Make the hostname resolve for the BROWSER (curl can use --resolve instead)
echo '127.0.0.1 dashboard.osramp.acme.local' | sudo tee -a /etc/hosts
# 5c. Open (self-signed cert -> accept the browser warning):
#     https://dashboard.osramp.acme.local:18443/
# curl smoke test (SPA):
curl -k --resolve dashboard.osramp.acme.local:18443:127.0.0.1 \
  https://dashboard.osramp.acme.local:18443/
# curl smoke test (API path passthrough — expect 401 without a valid Dex token):
curl -k --resolve dashboard.osramp.acme.local:18443:127.0.0.1 \
  https://dashboard.osramp.acme.local:18443/api/settings
```

### 3.1 Make targets — present vs missing (dashboard-specific)

| Capability | Target | Status |
|------------|--------|--------|
| Create Kind cluster | `make cluster` / `make up` | Present |
| In-cluster registry | `make registry` (via `make up`) | Present |
| Flux bootstrap | `make bootstrap-local` (via `make up`) | Present |
| Build+sign+load dashboard image | `make signalloom-dashboard-image` (also inside `make signalloom-images`) | Present (`scripts/build-sign-dashboard.sh`) |
| Deploy dashboard + API + routes | `make demo-signalloom-up` | Present (Flux ResourceSet `signalloom-apps`) |
| Dex OIDC stub deploy | via `signalloom-infra` (inside `demo-signalloom-up`) | Present |
| Verify Flux / runtime | `make demo-signalloom-test` / `-runtime-test` / `-test-1` | Present |
| **Open/port-forward the dashboard for a human** | — | **MISSING.** No `make dashboard-open`/`dashboard-forward`. Only `scripts/acceptance-test.sh` (Playwright) sets up the 18443 forward, and it tears it down on exit. Manual step 5 required. |
| **Bake `VITE_AUTH0_*` into dashboard build** | — | **MISSING.** Dockerfile/build script pass no build args; no `.env`. |
| **Wire dashboard browser login to Dex (or Auth0)** | — | **MISSING.** No dashboard OIDC-code flow to Dex; `OIDC-BROWSER-001` deferred. |
| Host port mapping (80/443 → host) | — | **MISSING by design.** Kind config has no `extraPortMappings`; port-forward is the only path. |

### 3.2 Flagged broken / blocking steps for a live browser demo

1. **Login is dead (BLOCKER A + B).** After step 5 the SPA loads, but the first `/api` call → 401 → `loginWithRedirect()` against an unconfigured Auth0 (empty domain) → no usable login. Fix required before any authenticated screen renders. See §1.4.
2. **No browser-facing Dex.** Dex issuer is `dex.inf-signalloom.svc.cluster.local:5556` — unreachable and unresolvable from the host browser. Even Path-1 (repoint to Dex) needs an HTTPRoute/port-forward exposing Dex on a browser-reachable issuer URL that matches the token `iss`.
3. **Manual hostname + TLS friction.** Requires `/etc/hosts` edit and accepting a self-signed cert. Not automated; easy to get wrong (must use the `*.osramp.acme.local` name, not `127.0.0.1`, for SNI/host match).
4. **No single "open dashboard" target.** A human validator has to reconstruct the port-forward from `acceptance-test.sh`. `HUMAN_VALIDATION.md` only lists Grafana/frontend/Archivista/Olly on `127.0.0.1:1x000` port-forwards — it does **not** cover the gateway-fronted dashboard at 18443.
5. **Redirect URI mismatch (if Path 2 attempted).** Dex's registered dashboard redirect is `http://localhost:5173/callback` (Vite dev), but the deployed dashboard's Auth0 `redirect_uri` is `${origin}/agents`. Neither matches a browser hitting `https://dashboard.osramp.acme.local:18443` — callback registration must be fixed for whichever IdP path is chosen.

---

## Key file references

| Concern | Path | Lines |
|---------|------|-------|
| Dashboard Auth0 provider (in-cluster) | `d2-signalloom/apps/dashboard-signalloom/src/auth/Auth0Provider.tsx` | ~41-59 |
| Tenant claim decode | `d2-signalloom/apps/dashboard-signalloom/src/auth/tenant.ts` | ~6-13 |
| Dashboard API client (`/api` prefix, same-origin) | `d2-signalloom/apps/dashboard-signalloom/src/api/client.ts` | ~28-45 |
| Dashboard Dockerfile (no VITE args) | `d2-signalloom/apps/dashboard-signalloom/Dockerfile` | all |
| Dashboard build/sign script (no build args) | `scripts/build-sign-dashboard.sh` | all |
| Dex OIDC stub (Secret/Deployment/Service) | `d2-signalloom/infra/inf-signalloom/base/dex.yaml` | all |
| API JWT validation | `d2-signalloom/apps/fe-signalloom/src/api_compat.py` | 150-186 |
| API issuer/audience/azp config | `d2-signalloom/apps/fe-signalloom/src/config.py` | 20-22 |
| Dex OIDC design + deferred browser test | `docs/signalloom/dex-oidc-design.md` | contract + Auth test cases |
| Gateway routes (`/` + `/api`) | `d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` | all |
| kustomization (routes shipped) | `d2-signalloom/apps/fe-signalloom/base/kustomization.yaml` | all |
| Dashboard deployment/service | `d2-signalloom/apps/fe-signalloom/base/dashboard-deployment.yaml`, `dashboard-service.yaml` | all |
| nginx SPA fallback | `d2-signalloom/apps/dashboard-signalloom/nginx.conf` | all |
| Cluster Gateway + TLS | `d2-infra/components/ingress/configs/base/cluster-gateway.yaml` | all |
| Cluster cert | `d2-infra/components/cert-manager/configs/base/cluster-certificate.yaml` | all |
| CLUSTER_DOMAIN / IMAGE_BASE values | `d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml` | 12-18 |
| SignalLoom Flux ResourceSets | `d2-osramp-fleet/tenants/local/signalloom.yaml` | signalloom-infra/-apps |
| Kind cluster create (no port map) | `scripts/create-kind-cluster.sh` | all |
| Demo lifecycle | `scripts/signalloom-local.sh` | `up()` |
| Local reach pattern (port-forward + resolve) | `scripts/acceptance-test.sh` (42-51), `d2-signalloom/test/runtime.bats` (46-64) | — |
| `make up` / `demo-signalloom-up` | `Makefile` | 22-31, 231-246 |
