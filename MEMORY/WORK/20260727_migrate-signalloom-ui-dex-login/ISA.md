---
task: Migrate real Signal Loom UI into cluster with live Dex user/pass login
slug: 20260727_migrate-signalloom-ui-dex-login
effort: E4
phase: observe
progress: 0/28
mode: algorithm
started: 2026-07-27T21:20:00+01:00
updated: 2026-07-27T21:20:00+01:00
---

## Problem

The deployed `dashboard-signalloom` serves a placeholder (`<h1>Signal Loom</h1>`). The real product UI
lives at `/home/andy/src/cp/platform/dashboard/` — a TS/React/Vite Agent-Governance dashboard (Sidebar +
Agents/Compliance/AuditTrail/Settings pages, axios `/api` client, recharts) that authenticates via
**Auth0**. Our local cluster authenticates via **Dex** and its `api_compat` already serves
`/api/agents|compliance|audit|settings` validating Dex RS256 tokens (P2-3). Andy must be able to
port-forward a URL, log in with user/pass, and see the real Signal Loom UI served from the new container
in this k8s cluster.

## Vision

`kubectl port-forward svc/dashboard-signalloom 5173:8080`, open `http://localhost:5173`, get redirected to
a Dex login, sign in as `demo-user@signalloom.local` / `password`, and land on the real Signal Loom
Agent-Governance dashboard — same UI as the platform, now served from our signed container against our
cluster's Dex + api_compat. A Playwright test drives the same login and asserts the UI renders.

## Out of Scope

- Auth0 (external IdP) — replaced by local Dex OIDC; no Auth0 tenant is contacted.
- Real product data — api_compat's local/fake responses are sufficient; empty states are acceptable.
- Production issuer/TLS/hostnames — local demo uses `http://localhost:5173/dex` issuer via port-forward.
- Rewriting api_compat endpoints — they already exist; UI adapts to them, not vice-versa.

## Principles

- Faithful UI — the migrated app is the platform's real dashboard, not a re-creation.
- Single-origin — dashboard nginx proxies `/dex` and `/api` so the browser hits one origin (no CORS).
- Reproduce-first — every failure is seen in a real browser (Interceptor) before it's fixed.
- GitOps-honest — Flux manages dex/fe-signalloom; changes go through source + reconcile (or documented suspend).

## Constraints

- Dex + fe-signalloom are Flux-managed (Kustomizations `infra-configs`, `apps`) — manual edits revert.
- Dex redirect URI `http://localhost:5173/callback` is already registered for client `signalloom-dashboard`.
- Dex issuer must be browser-reachable AND string-match the API's expected issuer; JWKS fetch stays
  cluster-internal (api_compat separates `API_JWT_ISSUER` from `API_JWKS_URL`).
- Container must build `tsc && vite build`; reuse the P2-2 signed-build pipeline for the image.
- API expects token audience `signalloom-api`, authorized-party `signalloom-dashboard`, sub `demo-user`.

## Goal

Replace the placeholder with the migrated platform UI wired to Dex OIDC (Auth0 removed), served single-origin
by the container's nginx (proxying `/dex` + `/api`), deployed to the running kind cluster, so a port-forward
to `localhost:5173` lets a user log in with `demo-user`/`password` and see the real Signal Loom dashboard —
proven by a live Interceptor session and a Playwright login test.

## Criteria

### UI migration
- [ ] ISC-1: Platform `dashboard/src` (pages, views, components, styles, types, api client) copied into the workload.
- [ ] ISC-2: `index.html` title "Signal Loom — Agent Governance" + entry wired; assets present.
- [ ] ISC-3: `tsc && vite build` succeeds inside the container build (no TS errors).
- [ ] ISC-4: Anti: no `@auth0/auth0-react` import remains anywhere in the migrated source.

### Auth swap (Auth0 → Dex OIDC)
- [ ] ISC-5: OIDC provider (react-oidc-context/oidc-client-ts) wraps the app; authority `http://localhost:5173/dex`.
- [ ] ISC-6: `useAuth0()` call-sites satisfied by a compat shim (isAuthenticated/isLoading/loginWithRedirect/getAccessTokenSilently/user).
- [ ] ISC-7: OIDC client_id `signalloom-dashboard`, redirect_uri `http://localhost:5173/callback`, scope includes `audience:server:client_id:signalloom-api`.
- [ ] ISC-8: `/callback` route handles the code exchange and returns the user to `/agents`.
- [ ] ISC-9: API axios interceptor attaches the Dex access/id token as Bearer.
- [ ] ISC-10: Anti: no secret/password is baked into the image or committed.

### Container + single-origin serving
- [ ] ISC-11: nginx serves the SPA (history fallback) AND proxies `/dex/` → dex svc, `/api/` → fe-signalloom-api svc.
- [ ] ISC-12: `/readyz` still returns 200.
- [ ] ISC-13: Image builds + is cosign-signed via the P2-2 pipeline (evidence produced).
- [ ] ISC-14: Image loaded into kind and the Deployment rolls to it.

### Cluster wiring (Flux-managed)
- [ ] ISC-15: Dex issuer set to `http://localhost:5173/dex` in source (dex.yaml) and reconciled/applied.
- [ ] ISC-16: `API_JWT_ISSUER` set to `http://localhost:5173/dex`; `API_JWKS_URL` stays cluster-internal.
- [ ] ISC-17: NetworkPolicy permits dashboard egress to dex (inf-signalloom) + fe-signalloom-api.
- [ ] ISC-18: dex + fe-signalloom + dashboard pods Running/Ready after changes.
- [ ] ISC-19: Anti: no other workload's config or namespace is mutated beyond what login needs.

### LIVE verification (the acceptance gate)
- [ ] ISC-20: `port-forward svc/dashboard-signalloom 5173:8080` established; `http://localhost:5173` serves the SPA.
- [ ] ISC-21: `http://localhost:5173/dex/.well-known/openid-configuration` reachable through the proxy.
- [ ] ISC-22: Interceptor: open localhost:5173 → redirected to Dex login form.
- [ ] ISC-23: Interceptor: submit `demo-user@signalloom.local` / `password` → redirected back authenticated.
- [ ] ISC-24: Interceptor: the Signal Loom dashboard (Sidebar + Agents page) renders — screenshot captured.
- [ ] ISC-25: Interceptor: no uncaught console error / no failed `/api` 401 after login.

### Test + landing
- [ ] ISC-26: Playwright FE test logs in with user/pass and asserts the dashboard UI is visible.
- [ ] ISC-27: Changes committed to integration, scoped; evidence + screenshot recorded.
- [ ] ISC-28: Advisor consulted at commitment boundary; final gaps addressed.

## Test Strategy

| isc | type | check | tool |
|-----|------|-------|------|
| ISC-3/13/14 | container | build + sign + kind load + rollout | Bash docker/cosign/kubectl |
| ISC-11/12/21 | proxy | curl /readyz, /dex/.well-known, /api | Bash curl |
| ISC-20..25 | live UI | real browser login flow | Interceptor |
| ISC-26 | e2e | playwright login test | Bash npx playwright |
| ISC-15..18 | cluster | kubectl get/apply + reconcile | Bash kubectl/flux |

## Features

| name | satisfies | depends_on | parallelizable |
|------|-----------|------------|----------------|
| ui-copy | ISC-1,2 | — | me |
| auth-swap | ISC-4..10 | ui-copy | Anvil |
| nginx-single-origin | ISC-11,12 | — | Anvil/me |
| cluster-issuer-netpol | ISC-15..19 | — | me |
| build-deploy | ISC-13,14,18 | auth-swap,nginx | me |
| live-verify | ISC-20..25 | build-deploy | me (Interceptor) |
| fe-test | ISC-26 | live-verify | me/Forge |

## Decisions

- 2026-07-27: Classifier said E3; escalated to E4 (context override) — live deploy + Dex OIDC swap +
  browser verification + cross-repo migration + Flux-managed cluster changes are cross-cutting.
- 2026-07-27: Single-origin topology at localhost:5173 (nginx proxies /dex + /api) chosen over multi-port
  port-forwards to eliminate CORS and match the pre-registered redirect URI. Dex issuer → localhost:5173/dex;
  API_JWT_ISSUER matches; API_JWKS_URL stays cluster-internal (pod-reachable) — resolves issuer split-horizon.
- 2026-07-27: Auth0 replaced with react-oidc-context + a useAuth0-compat shim to minimize page churn.

## Changelog

## Verification
