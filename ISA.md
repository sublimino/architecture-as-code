---
task: Fix logged-out redirect loop and silent renewal failure in Signal Loom dashboard
slug: fix-auth-redirect-loop
effort: E3
phase: complete
progress: 40/40
mode: algorithm
started: 2026-09-28T23:34:41+01:00
updated: 2026-09-28T23:45:00+01:00
---

## Problem
Logged-out user sessions on `https://ftna-signalloom.taild4da3.ts.net/` are trapped in an infinite redirect loop between Dex local auth login (`/dex/auth/local/login`) and the dashboard. The dashboard attempts silent renewal (`prompt=none`), which Dex v2.41.1 local connector does not support, redirecting the hidden iframe to an interactive login form that is blocked by Nginx `X-Frame-Options: DENY`. Additionally, the dashboard lacks dedicated `/login` and `/callback` routes in `App.tsx`, causing `/callback` query parameters to be stripped by wildcard route redirects to `/agents`. On `/agents`, `ProtectedRoute` triggers `loginWithRedirect()` synchronously in its render body, and `logout()` immediately redirects to `/` which redirects to `/agents`, making it impossible for a logged-out user to remain resting in a logged-out state.

## Vision
A clean, deterministic OIDC authentication lifecycle with zero redirect looping. Logged-out users land on a dedicated, secure `/login` resting page with an explicit "Sign in with Dex" action. Explicit `/callback` route handling resolves authorization codes and returns users seamlessly to their intended destination without state stomping. Silent renewal is disabled in favor of deterministic explicit re-authentication, respecting strict CSP and frame-ancestors policies.

## Out of Scope
- Modifying Dex server backend code or connector storage (Dex memory storage remains managed via `dex-origin.sh`).
- Relaxing Nginx `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'` headers.
- Altering Dex user credentials or database schemas.

## Principles
- Deterministic Navigation: Never trigger side-effect navigations or redirects in the render body of React components.
- Resting State: A user who logs out must have a stable, non-redirecting resting state (`/login`).
- Strict Frame Security: Never rely on hidden iframe renewals when frame-ancestors are restricted by security policy.
- Clean Auth Route Isolation: Public routes (`/login`, `/callback`, `/redeem-invite`, `/signup`) must never trigger auto-sign-in guards.

## Constraints
- TypeScript and React only; strict type safety in `dashboard-signalloom`.
- Preserve backward compatibility with existing Auth0 shim consumers (`useAuth0`, `useApi`).
- Must pass all existing Vitest suites without regressions.
- Conventional commits with `--no-gpg-sign`.

## Goal
Eliminate auth redirect loops and silent renew failures by disabling automatic silent renewal, introducing dedicated `/login` and `/callback` routes, moving redirects into `useEffect` lifecycle guards, and managing persistent logged-out state via `sessionStorage`.

## Criteria
- [x] ISC-1: `oidcConfig.automaticSilentRenew` is set to `false`.
- [x] ISC-2: `silent_redirect_uri` in `oidcConfig` is aligned or removed to prevent iframe renewal.
- [x] ISC-3: `getAccessTokenSilently` does not invoke `signinSilent()`.
- [x] ISC-4: `getAccessTokenSilently` throws descriptive re-authentication error when token is expired.
- [x] ISC-5: `getAccessTokenSilently` saves return-to path in `localStorage` before initiating re-authentication.
- [x] ISC-6: `PUBLIC_PATHS` in `oidc.tsx` includes `/login`.
- [x] ISC-7: `PUBLIC_PATHS` in `oidc.tsx` includes `/callback`.
- [x] ISC-8: `isPublicRoute('/login')` evaluates to `true`.
- [x] ISC-9: `isPublicRoute('/callback')` evaluates to `true`.
- [x] ISC-10: `isPublicRoute('/callback?code=abc')` evaluates to `true`.
- [x] ISC-11: `hasAuthParams` is exported from `src/auth/oidc.tsx`.
- [x] ISC-12: `LOGGED_OUT_KEY` constant (`signalloom:logged-out`) is defined for tracking manual logout state.
- [x] ISC-13: `logout()` sets `LOGGED_OUT_KEY` to `'true'` in `sessionStorage`.
- [x] ISC-14: `logout()` navigates to `/login` instead of `/`.
- [x] ISC-15: `AutoSignIn` checks `LOGGED_OUT_KEY` in `sessionStorage` and skips redirect when user is logged out.
- [x] ISC-16: `AutoSignIn` skips redirect when current route is public according to `isPublicRoute`.
- [x] ISC-17: `AutoSignIn` uses `triggered.current` ref to prevent repeated redirect loops.
- [x] ISC-18: `handleUnauthorized` in `oidc.tsx` does not invoke `signinSilent()`.
- [x] ISC-19: `handleUnauthorized` skips redirect if current route is public or user is logged out.
- [x] ISC-20: `ProtectedRoute` renders `<AppLoader>` when `isLoading` is true.
- [x] ISC-21: `ProtectedRoute` renders `<AppLoader>` when `hasAuthParams()` is true (callback in flight).
- [x] ISC-22: `ProtectedRoute` renders `<Navigate to="/login" replace />` when `LOGGED_OUT_KEY` is `'true'`.
- [x] ISC-23: `ProtectedRoute` executes `loginWithRedirect` inside a `useEffect` hook instead of during render.
- [x] ISC-24: `ProtectedRoute` guards `loginWithRedirect` with a ref so it triggers at most once per mount.
- [x] ISC-25: Dedicated `LoginPage.tsx` is created at `src/pages/LoginPage.tsx`.
- [x] ISC-26: `LoginPage` displays clear logged-out status and a "Sign in with Dex" action button.
- [x] ISC-27: Clicking "Sign in with Dex" clears `LOGGED_OUT_KEY` and initiates `loginWithRedirect()`.
- [x] ISC-28: Dedicated `CallbackPage.tsx` is created at `src/pages/CallbackPage.tsx`.
- [x] ISC-29: `CallbackPage` renders `<AppLoader label="Completing sign in..." />` while auth is processing.
- [x] ISC-30: `CallbackPage` navigates to `returnTo` (defaulting to `/agents`) upon successful authentication.
- [x] ISC-31: `CallbackPage` renders friendly error message and "Try again" button if authentication fails.
- [x] ISC-32: `App.tsx` registers route for `/login` mapped to `LoginPage`.
- [x] ISC-33: `App.tsx` registers route for `/callback` mapped to `CallbackPage`.
- [x] ISC-34: `oidcSilentRenew.test.ts` asserts `automaticSilentRenew: false`.
- [x] ISC-35: `oidc.test.ts` asserts `/login` and `/callback` are public routes.
- [x] ISC-36: `ProtectedRoute.test.tsx` verifies that logged-out users navigate to `/login`.
- [x] ISC-37: Anti: Logged-out users must never be automatically redirected to `/dex/auth` or `/dex/auth/local/login`.
- [x] ISC-38: Anti: Silent renew iframe requests (`prompt=none`) must never be dispatched to Dex.
- [x] ISC-39: Anti: Route rendering must never trigger side-effect redirects directly in the component render body.
- [x] ISC-40: Vitest test suite (`bun run test -- --run`) passes 100% across all files.

## Test Strategy
- ISC-1..19 | unit | `bun run test -- --run src/auth/oidc.test.ts src/auth/oidcSilentRenew.test.ts` | 100% pass | Vitest
- ISC-20..24, 36 | unit | `bun run test -- --run src/auth/ProtectedRoute.test.tsx` | 100% pass | Vitest
- ISC-25..31 | unit | `bun run test -- --run src/pages/LoginPage.test.tsx src/pages/CallbackPage.test.tsx` | 100% pass | Vitest
- ISC-32..33 | unit | `bun run test -- --run src/App.test.tsx` | 100% pass | Vitest
- ISC-34..35 | unit | `bun run test -- --run src/auth/oidcSilentRenew.test.ts src/auth/oidc.test.ts` | 100% pass | Vitest
- ISC-37..40 | integration | `bun run test -- --run` in `dashboard-signalloom` | 192/192 files, 3455/3455 passed | Vitest

## Features
- feat-auth-config: Update `oidcConfig` to disable silent renewal and export `hasAuthParams`, `LOGGED_OUT_KEY`.
- feat-auth-guards: Harden `AutoSignIn` and `ProtectedRoute` against render-time and logged-out redirect loops.
- feat-pages: Implement `LoginPage` and `CallbackPage` components with explicit actions and error recovery.
- feat-routes: Register `/login` and `/callback` in `App.tsx` routing table.
- feat-tests: Update and extend Vitest tests for silent renew removal, public routes, and route protection.

## Decisions
- 2026-09-28: Disabled `automaticSilentRenew` because Dex v2.41.1 local connector does not support `prompt=none` and Nginx CSP disallows iframes (`frame-ancestors 'none'`).
- 2026-09-28: Introduced `sessionStorage` key `signalloom:logged-out` so explicit logout keeps the user at `/login` rather than auto-bouncing back to Dex.
- 2026-09-28: Single developer execution within dashboard-signalloom; delegation floor relaxed with show-your-math justification (self-contained TypeScript/React changes).
- 2026-09-28: Refactored `LoginPage` and `CallbackPage` styling to strictly adhere to design system CSS tokens (`--surface`, `--border`, `--cyan`, `--violet`, `--error`, `--on-accent`), satisfying `cssVarUsage.test.ts`.

## Changelog
- 2026-09-28: Initial ISA scaffolded for auth redirect loop and silent renewal fix.
- 2026-09-28: Implemented OIDC config changes, route guards, LoginPage, CallbackPage, and updated all tests. All 40 criteria verified green.

## Verification
- Vitest suite: 192 test files passed (3,455 tests passed, 3 skipped, 0 failed) in 15.66s.
- Bundle build: `bun run build` built successfully in 2.93s (`dist/assets/LoginPage-BTq-pPd4.js`, `dist/assets/CallbackPage-BjOunkJc.js`).
- Supply chain & container deployment: `scripts/build-sign-dashboard.sh` built, signed with cosign, generated SBOM/SLSA provenance, loaded into Kind cluster `osramp`, and rolled out to pod `fe-signalloom/dashboard-signalloom` verified with `cat /etc/osramp-build-id` and HTTP 200 response on `/login`.
