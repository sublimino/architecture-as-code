# Signal Loom design-system demo

A standalone, fixture-only React application demonstrating a clearer Signal
Loom information architecture. It is intentionally separate from
`apps/dashboard-signalloom`: no cluster, OIDC provider, API, Flux resource, or
production build is required.

## Run

Requires Bun.

```bash
cd d2-signalloom/design-system-demo
bun install --frozen-lockfile
bun run dev
# http://localhost:4174
```

The application uses BrowserRouter. Vite serves SPA fallbacks during `dev` and
`preview`, so direct route refreshes work locally.

## Quality gates

```bash
bun run typecheck
bun run lint
bun run test
bun run build
bun run test:e2e
```

Playwright starts its own Vite server on `127.0.0.1:4174`. Install Chromium once
if needed:

```bash
bunx playwright install chromium
```

## Debug

```bash
# Vitest watch mode
bun run test:watch

# Playwright browser UI
bun run test:e2e --ui

# Production-like local preview
bun run build && bun run preview
```

Failures retain a Playwright trace. Open one with:

```bash
bunx playwright show-trace test-results/<test>/trace.zip
```

## Product model

- The default navigation exposes Overview, Estate, and Assurance.
- **Superadmin** reveals Trust fabric and Permissions immediately.
- Superadmin is visibility-only, matching the current production behavior; it
  is not an authorization boundary.
- Theme and Superadmin preferences persist in localStorage.
- The trust map supports pointer pan, wheel/pinch zoom, explicit controls,
  selection, reset, scrolling, and a keyboard-operable narrative alternative.
- Every page identifies its static provenance to avoid presenting fixture data
  as runtime evidence.

See [`docs/UI-FLOWS.md`](docs/UI-FLOWS.md) for the test-derived route model,
journeys, production test commands, and false-green gotchas.

## Structure

```text
src/components/   reusable shell, primitives, navigation, graph
src/pages/        route-level compositions
src/data/         typed static scenario fixtures
src/state/        durable presentation preferences
src/styles/       semantic tokens and responsive layout
e2e/              integrated Chromium journeys
docs/             navigation and test-flow evidence
```

This is a design proposal, not a component package. Promote primitives into the
production dashboard only through a deliberate follow-on change.
