# Signal Loom dashboard UI migration — real product UI with local Dex login

<!-- machine-tag: SLDPB25-P2-2-UI-MIGRATION-2026-07-27 -->
<!-- scope: local-demo migration and single-origin login topology -->

## What this delivers

The `dashboard-signalloom` workload now serves the **real Signal Loom
Agent-Governance UI** (migrated from the platform repo `~/src/cp/platform/dashboard`)
instead of the earlier placeholder. A user opens a port-forwarded URL, logs in
with a username/password against the cluster's local **Dex**, and sees the same
UI as the upstream platform — Sidebar, Agents, Compliance, Audit Trail, Settings —
served from the signed container and backed by the local compatibility API.

Terminology (the names are historically confusing):

| Workload | Role | Tech | Port |
| --- | --- | --- | --- |
| `dashboard-signalloom` | **Front-end SPA** (the UI you log into) | React + Vite + nginx | 8080 |
| `fe-signalloom` (Service `fe-signalloom-api`) | **Backend API** ("discovery portal") | Python / FastAPI | 8000 |

Despite the `fe-` prefix, `fe-signalloom` is the API backend; the SPA is the front end.

## Run it

```bash
# 1. Port-forward the dashboard (local port MUST be 5173 — issuer + redirect are pinned to it)
kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080

# 2. Open the app; you are redirected to the Dex login page
#    http://localhost:5173
#    Email:    demo-user@signalloom.local
#    Password: demo-user
```

The automated equivalent is `test/acceptance/signalloom-login.spec.ts`
(Playwright, real Chrome): it drives the full login and asserts the dashboard
renders with authenticated `/api` data and no console/API errors.

## Architecture — single origin, no CORS

```
                          browser (localhost:5173)
                                   │
                    ┌──────────────┴───────────────┐
                    ▼                               ▼
        dashboard-signalloom (nginx :8080)
        ├─ /                → SPA (React history fallback)
        ├─ /readyz          → 200 "ready"
        ├─ /dex/*  proxy →  dex.inf-signalloom:5556       (OIDC: discovery/auth/token/keys)
        └─ /api/*  proxy →  fe-signalloom-api:8000        (compatibility API, Dex-token authed)
```

Serving the SPA, Dex, and the API from **one origin** removes CORS entirely and
lets Dex's issuer be `http://localhost:5173/dex` — browser-reachable through the
proxy. See `dex-oidc-design.md` § "end-to-end local login enablement" for the
issuer split-horizon and the public-PKCE-client details.

## Auth: Auth0 → Dex OIDC

The upstream app authenticates via Auth0 (`@auth0/auth0-react`). For the local
demo it is swapped to Dex OIDC with **no application-code churn to the pages**:

- `src/auth/oidc.tsx` — an `OidcProvider` (react-oidc-context) plus a `useAuth0()`
  **compatibility shim** that maps react-oidc-context's API onto the exact shape
  every page already consumed (`isAuthenticated`, `isLoading`, `loginWithRedirect`,
  `getAccessTokenSilently`, `logout`, `user`). Pages only changed their import path.
- `AutoSignIn` triggers `signinRedirect` once when unauthenticated (the library
  does not auto-redirect); an explicit `metadata` block avoids an intermittent
  discovery-fetch hang so the redirect is deterministic.
- The Dex access/ID token (audience `signalloom-api`) is attached as a bearer to
  `/api` by the shared axios instance.

## Resilience fixes

| Issue | Root cause | Fix |
| --- | --- | --- |
| ~300 req/s refetch storm to the API | The shim returned **new callback references every render** (Auth0's SDK returned stable ones); those refs are deps of each view's fetch `useCallback` → fetch `useEffect`, so every fetch re-rendered and re-fetched. | Stabilise the shim with `useCallback`/`useMemo` (matches Auth0's referential stability). Verified: 3076×/10s → 1×/10s per endpoint. |
| Duplicate concurrent GET fan-out | No request de-duplication. | `src/api/client.ts` coalesces identical **in-flight** GETs onto one promise. |
| `/api` 401 for valid Dex tokens | API required `typ == "JWT"`; Dex ID tokens omit `typ`. | Accept an absent `typ` (still reject a wrong one); `alg == RS256` mandatory. |
| Dex crash-loop | Bare `/healthz` 404s under a path-based issuer. | Liveness probes a served path. |
| Login redirect flaky/hung | OIDC discovery fetch intermittently stalled. | Provide OIDC `metadata` explicitly; one-shot `signinRedirect` guard. |

## Container & supply chain

The image is built and signed by `scripts/build-sign-dashboard.sh`
(`make signalloom-dashboard-image`): `npm ci` → `vite build` → unprivileged
`nginx-unprivileged:1.27` on 8080, with an SPDX SBOM, SLSA provenance, and a
cosign signature on the resolved digest. See `evidence/README.md`.

## Verification status

- Typecheck (`tsc --noEmit`): clean.
- Live (real Chrome): Dex login → `demo-user` → dashboard renders with data;
  1 request per endpoint; zero console errors; zero `/api` 4xx/5xx.
- Automated: `test/acceptance/signalloom-login.spec.ts`.

## Local-demo boundaries (not production)

Public PKCE client, checked-in demo bcrypt password, in-memory ephemeral Dex,
and the `localhost:5173` issuer are **local-demo-only**. A hosted deployment
must restore externally-managed credentials, a stable HTTPS issuer/hostname,
and admission-time signature enforcement (deferred to P2-GOV / P3-1).
