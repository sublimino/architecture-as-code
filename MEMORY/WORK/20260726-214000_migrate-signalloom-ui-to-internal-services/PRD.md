---
task: Plan migration of Signal Loom UI and APIs onto internal services
slug: 20260726-214000_migrate-signalloom-ui-to-internal-services
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-26T21:40:00+01:00
updated: 2026-07-26T21:50:00+01:00
---

## Context

Plan how to bring the React Signal Loom dashboard from the parallel platform
repository into this local D2/Kubernetes demonstration. The target is a
browser-visible dashboard whose API calls, persistence, identity, and external
integrations remain inside the local cluster and use the existing fake
backends. This request is planning only; no application or deployment files
should be changed until the migration boundary is approved.

### Risks

- The dashboard `/api` contract is materially larger than the local FastAPI
  health surface; copying the UI alone cannot produce a working app.
- The dashboard requires Auth0 tokens, while local browser identity is not yet
  defined.
- The fake integration proxy exists, but endpoint-level adapter coverage is not
  yet established.
- Default-deny NetworkPolicies require every new service edge to be explicit.

## Criteria

- [x] ISC-1: Dashboard source location and build system are identified
- [x] ISC-2: Dashboard runtime container port is identified
- [x] ISC-3: Dashboard API base URL mechanism is identified
- [x] ISC-4: Dashboard authentication dependency is identified
- [x] ISC-5: Dashboard API endpoint inventory is identified
- [x] ISC-6: Local frontend namespace is identified
- [x] ISC-7: Local frontend service port is identified
- [x] ISC-8: Existing local API endpoint inventory is identified
- [x] ISC-9: Existing fake integration services are identified
- [x] ISC-10: Required API compatibility boundary is identified
- [x] ISC-11: Dashboard Kubernetes deployment shape is defined
- [x] ISC-12: Internal API routing shape is defined
- [x] ISC-13: Persistence dependency routing is defined
- [x] ISC-14: Authentication strategy for local browser use is defined
- [x] ISC-15: External integration isolation is defined
- [x] ISC-16: End-to-end verification stages are defined

## Decisions

Prefer a separate dashboard deployment and an internal API gateway/adapter
over embedding the SPA into the existing FastAPI discovery portal. Preserve
the dashboard's existing `/api/...` contract where possible, while routing
its downstream calls to local fake services.

### Plan

1. Freeze the dashboard API contract from `dashboard/src/api/*.ts` and map each
   endpoint to an existing local implementation, a thin adapter, or deferred
   scope.
2. Add a local API compatibility service behind the dashboard. Keep browser
   traffic on one origin or `/api` route; never expose databases, OpenBao, or
   fake integrations to the browser.
3. Add a separate `fe-dashboard` image, Deployment, Service, NetworkPolicy,
   and local Gateway HTTPRoute. Keep `fe-signalloom` as the discovery/API
   workload unless mapping proves consolidation safer.
4. Choose local authentication explicitly: deterministic demo-token mode for
   acceptance tests, or a local OIDC provider. Never silently use production
   Auth0 from local builds.
5. Wire API adapters to Postgres, Redis, MinIO, OpenBao, and fake integration
   services, retaining `fake-*` settings in the local overlay.
6. Verify UI loading, auth, API responses, persistence, fake integrations,
   NetworkPolicy enforcement, and browser journeys in separate gates.

## Verification

- `cp/platform/dashboard/package.json` confirms Vite/React and `dashboard/Dockerfile` confirms nginx port 8080.
- `dashboard/src/api/client.ts` and `connectorsClient.ts` confirm `/api` contract and API-base configuration.
- `dashboard/src/auth/Auth0Provider.tsx` and `ProtectedRoute.tsx` confirm Auth0 dependency.
- `d2-signalloom/apps/fe-signalloom/src/main.py` confirms only health/readiness endpoints currently exist.
- `d2-signalloom/apps/fe-signalloom/base/deployment.yaml` confirms local Postgres, Redis, MinIO, and fake adapters.
- `d2-signalloom/infra/inf-signalloom/base/fake-integration-proxy.yaml` confirms internal fake proxy Service on 8080.
- `d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml` confirms default-deny and explicit dependency ingress/egress.
- The resulting plan separates static UI hosting, API compatibility, identity, and fake-service integration.
