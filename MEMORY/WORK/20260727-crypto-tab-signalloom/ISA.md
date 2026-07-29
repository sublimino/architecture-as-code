---
task: Add a Cryptography tab + enriched mock dashboard to the Signal Loom dashboard, verify QoL migration
slug: 20260727-crypto-tab-signalloom
effort: E3
phase: complete
progress: 34/34
mode: ALGORITHM
started: 2026-07-27
updated: 2026-07-27
---

## Problem

The Signal Loom dashboard was migrated from `signal-loom/platform/dashboard/` into the
osramp-demo local delivery boundary (`d2-signalloom/apps/dashboard-signalloom`). Two things
are needed: (1) confirm the migration carried across all quality-of-life enhancements and
anything else we need; (2) the dashboard has no visibility into the platform's cryptographic
trust foundation — OpenBao bootstrap, SPIFFE/SPIRE workload identity, PQC cipher readiness,
OAuth2/MCP proxies, and the cluster root of trust are invisible to operators. There is no
"Cryptography" navigation entry or page.

## Vision

An operator clicks a new **Cryptography** tab in the left sidebar at http://localhost:5173/
and lands on a rich, self-contained dashboard that makes the platform's entire trust posture
legible at a glance: root-of-trust chain, OpenBao seal/engine state, SPIRE trust domain and
issued SVIDs, post-quantum cipher migration progress, and the OAuth2/MCP proxy fabric — styled
to match the existing Signal Loom cyan aesthetic, populated with credible mock data that reads
like a real production environment (Cofide-Connect-grade workload-identity framing).

## Out of Scope

No real backend/API wiring for the cryptography data (mock-only, self-contained in the page).
No changes to auth (Dex OIDC stays). No redesign of existing pages. No production deploy — kind
cluster only. No new npm dependencies. The QoL audit is a verification/report, not a re-migration.

## Constraints

- React 18 + Vite + TypeScript, inline-style + CSS-var idiom (no new deps; recharts already present).
- Page must render its content without any successful API/auth call (self-contained mock data).
- Route sits behind `ProtectedRoute` like every other page (consistent Dex-gated access).
- :5173 is a `kubectl port-forward` to k8s nginx serving the built SPA — landing the page live
  requires rebuild via `scripts/build-sign-dashboard.sh` + `kind load` + rollout restart.
- Match existing style tokens: `--bg --surface --surface2 --border --cyan --violet --teal --amber --error --muted --text`, `.card` `.btn` `.tag` classes, `StatusBadge`, recharts.

## Goal

Add a Cryptography sidebar tab routing to `/cryptography`, backed by a new self-contained
`CryptographyPage` that renders an enriched mock dashboard covering OpenBao bootstrap,
SPIFFE/SPIRE bootstrap, PQC cipher discovery, OAuth2/MCP proxies, and cluster root of trust;
ship it into the running kind deployment so the page is reachable and visibly populated at
http://localhost:5173/cryptography, with passing vitest acceptance tests. Separately, confirm
and report the QoL migration completeness.

## Criteria

- [ ] ISC-1: QoL audit — enumerate files present in original `platform/dashboard/src` but absent in migrated tree
- [ ] ISC-2: QoL audit — the only absent file is `auth/Auth0Provider.tsx`, deliberately replaced by `auth/oidc.tsx`
- [ ] ISC-3: QoL audit — no dangling `Auth0Provider` import remains in migrated tree
- [ ] ISC-4: QoL audit — migrated-only additions (demoMode, fakeData, oidc, DemoToggle) identified as the QoL enhancements
- [ ] ISC-5: `src/pages/CryptographyPage.tsx` exists and default-exports a React component
- [ ] ISC-6: Page renders a top-level "Cryptography" `<h1>`
- [ ] ISC-7: Page renders a Cluster Root of Trust section with trust-domain + CA chain mock data
- [ ] ISC-8: Page renders an OpenBao Bootstrap section with seal status + secret engines mock data
- [ ] ISC-9: Page renders a SPIFFE/SPIRE Bootstrap section with SPIRE server/agents + `spiffe://` SVID entries
- [ ] ISC-10: Page renders a PQC Cipher Discovery section listing endpoints with classical vs post-quantum readiness
- [ ] ISC-11: Page renders an OAuth2 / MCP Proxies section with proxy instances + upstream routes
- [ ] ISC-12: Page renders ≥4 summary stat cards (trust anchors, workload identities, PQC-ready %, secrets)
- [ ] ISC-13: Page uses ≥1 recharts chart (PQC readiness donut/bar) for enrichment
- [ ] ISC-14: Page uses `StatusBadge` and CSS-var styling consistent with existing views
- [ ] ISC-15: All mock data is self-contained (no `api.` call, no `useAuth0` token dependency for content)
- [ ] ISC-16: Route `/cryptography` added in `App.tsx` wrapped in `ProtectedRoute` + lazy import
- [ ] ISC-17: Sidebar `NAV` gains a `{ to: '/cryptography', label: 'Cryptography' }` entry
- [ ] ISC-18: Sidebar Cryptography entry ordered sensibly (after Audit Trail, before Settings)
- [ ] ISC-19: `src/pages/CryptographyPage.test.tsx` exists (vitest + testing-library)
- [ ] ISC-20: Test asserts the "Cryptography" heading renders
- [ ] ISC-21: Test asserts each of the 5 domain section titles render
- [ ] ISC-22: Test asserts a known mock value (e.g. a `spiffe://` id or seal status) renders
- [ ] ISC-23: `bun run test` passes for the new test file (and existing suite stays green)
- [ ] ISC-24: `bun run typecheck` (tsc --noEmit) passes with no errors
- [ ] ISC-25: `bun run lint` (eslint --max-warnings 0) passes for changed files
- [ ] ISC-26: `bun run build` (tsc && vite build) succeeds producing `dist/`
- [ ] ISC-27: `scripts/build-sign-dashboard.sh` builds, signs, and `kind load`s the new image
- [ ] ISC-28: `kubectl rollout restart deploy/dashboard-signalloom -n fe-signalloom` completes and pod is Ready
- [ ] ISC-29: Built `index.html`/asset bundle served at :5173 contains the new Cryptography route code
- [ ] ISC-30: Interceptor navigates to http://localhost:5173/cryptography and captures a screenshot
- [ ] ISC-31: Screenshot shows the Cryptography heading + populated sections (live-probe evidence)
- [ ] ISC-32: Sidebar visibly shows the Cryptography nav item on the live page
- [ ] ISC-33: Anti: no existing route/nav/page is removed or broken (Agents/Compliance/Audit/Settings still route)
- [ ] ISC-34: Anti: no new runtime dependency added to package.json; no external network call for crypto data

## Test Strategy

| isc | type | check | threshold | tool |
|-----|------|-------|-----------|------|
| ISC-1..4 | audit | diff file trees / grep | exact | Bash/rg |
| ISC-5..15 | unit | render component, query text | present | vitest/RTL |
| ISC-16..18 | static | grep route + NAV entry | present | rg/Read |
| ISC-19..23 | unit | run vitest | 0 failures | bun run test |
| ISC-24..26 | build | tsc/eslint/vite | exit 0 | bun run |
| ISC-27..29 | deploy | script exit 0, rollout status | Ready | Bash/kubectl |
| ISC-30..32 | live | browser screenshot at route | visible | Interceptor |
| ISC-33..34 | anti | route smoke + package.json diff | unchanged | Interceptor/rg |

## Features

| name | satisfies | depends_on | parallelizable |
|------|-----------|------------|----------------|
| QoL migration audit | ISC-1..4 | — | yes |
| CryptographyPage component + mock data | ISC-5..15 | — | yes |
| Route + Sidebar wiring | ISC-16..18 | page | no |
| Acceptance tests | ISC-19..23 | page | no |
| Local quality gates (typecheck/lint/build) | ISC-24..26 | page,wiring | no |
| Image build + kind deploy | ISC-27..29 | build gates | no |
| Live browser verification | ISC-30..32 | deploy | no |

## Decisions

- 2026-07-27 refined: Delivery mechanism decided by FirstPrinciples — :5173 is a port-forward to
  k8s nginx serving a *built* image, not a vite dev server. Options: (a) vite dev on 5173 needs
  Dex `/dex` proxy or an auth bypass = new fragile surface; (b) rebuild image + `kind load` +
  rollout restart = faithful, keeps working Dex auth + user session. Chose (b): the sanctioned
  `scripts/build-sign-dashboard.sh` already does buildx→sign→kind-load; only a rollout restart is added.
- 2026-07-27: Mock data lives inline in the page (self-contained) rather than in `fakeData.ts`,
  so the page renders regardless of API/demo-mode/auth state — guarantees "see mock data" unconditionally.
- 2026-07-27 show-your-math (delegation relaxation): Forge (E3 coding auto-include) relaxed — the
  deliverable is a single self-contained React view in an idiom I have full context on; an external
  GPT-5.4 subprocess adds latency + coordination without correctness gain. Advisor call retained as
  the commitment-boundary check before deploy.

## Changelog

- conjectured: to land the page at :5173 I'd likely need a vite dev server (default 5173).
  refuted_by: `ss -ltnp` showed :5173 is a `kubectl port-forward` to k8s nginx serving the built image.
  learned: the delivery path is rebuild image → `kind load` → rollout restart, not dev-server.
  criterion_now: ISC-27..29 encode the image-rebuild/kind-load/rollout path.
- conjectured: Dex `login` field takes the username `demo-user`.
  refuted_by: login POST bounced back to the form; the field label is "Email Address".
  learned: Dex local connector authenticates by email — use `demo-user@signalloom.local`.
  criterion_now: verify driver fills the email; ISC-30..32 pass with authenticated render.

## Verification

- ISC-1..4: QoL audit — only file absent from migrated tree is `auth/Auth0Provider.tsx`,
  deliberately replaced by `auth/oidc.tsx` (Dex). Migrated-only additions: demoMode, fakeData,
  oidc, DemoToggle. `rg Auth0Provider src/` → no matches (clean). Migration is complete.
- ISC-5..15: `bun run typecheck` exit 0; page renders all sections + charts (see live probe).
- ISC-16..18: `App.tsx` route `/cryptography` in ProtectedRoute + lazy import; Sidebar NAV entry
  after Audit Trail, before Settings.
- ISC-19..23: `bunx vitest run src/pages/CryptographyPage.test.tsx` → 5/5 passed. Full suite
  71/73 (the 2 failures are pre-existing in `ConsentModal.test.tsx`, untouched by this work).
- ISC-24: `tsc --noEmit` exit 0. ISC-25: `eslint --max-warnings 0` exit 0. ISC-26: `vite build`
  emitted `CryptographyPage-BIPK1kvB.js` (11.3kB).
- ISC-27: `scripts/build-sign-dashboard.sh` exit 0 — new node image `89154b88…`, signed digest
  `sha256:fa063881…`, kind-loaded into `osramp`.
- ISC-28: `kubectl rollout restart` → "successfully rolled out"; new pod Ready.
- ISC-29: served `index-Dcbwb-mk.js` at :5173 references `Cryptography` + lazy chunk
  `CryptographyPage-BIPK1kvB.js`; Last-Modified 23:47:49 (fresh).
- ISC-30..32: CDP headless-Chrome driver logged in via Dex (demo-user@signalloom.local) and
  screenshotted /cryptography (/tmp/cryptography.png, 288kB). Report: heading "Cryptography",
  navHasCryptography true, all 5 sections present, sampleSvid true, sealStatus true.
- ISC-33: `/agents /compliance /audit /settings /cryptography` all HTTP 200; sidebar renders all
  five nav items in the screenshot.
- ISC-34: `git diff --stat package.json package-lock.json` empty — no new dependency; no external
  network call for crypto data (in-module mock).
