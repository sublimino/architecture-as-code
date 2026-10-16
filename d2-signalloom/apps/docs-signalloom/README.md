# Signal Loom documentation service

This Astro Starlight service follows the framework and visual approach used by
the sibling `native-cloud` repository. It does not copy native-cloud content or
custom components because that repository does not currently declare a
repository-wide code licence.

## Local commands

```bash
bun install
bun run check
bun run build
bun run build:dev-docs
```

NOTE: The directory has two lockfiles, [`bun.lock`](bun.lock) and
[`package-lock.json`](package-lock.json). The [`Dockerfile`](Dockerfile) runs
`npm ci`, so `package-lock.json` controls the image build.

The user build uses `/docs` as its Astro base path.
The [engineering build](dev-docs/astro.config.mjs) uses `/dev-docs` and the title **Signal Loom Engineering**.
Both builds share the [CSS source](src/styles/custom.css) and public assets.
The existing nginx image serves both sites and exposes `/readyz` for Kubernetes probes.

## Engineering portal

The engineering portal has developer, support engineer, and security engineer onboarding paths.
Security assessment instructions are read-only. Their findings inform a separate remediation plan.
Neither site adds access control.

The two architecture pages now live in the engineering portal.
Their old user documentation URLs return permanent redirects.

Run these commands from the repository root.

```bash
make docs-dev-build
make docs-dev-lint
make docs-dev-test
make docs-render-check
make signalloom-docs-image
```

WARNING: Approve the current dashboard source before a live docs rollout.
The proxy build also publishes dashboard changes in the checkout.

After approval, run `make demo-signalloom-docs-up ORIGIN=https://ftna-signalloom.taild4da3.ts.net`.
This command rebuilds the two images and restarts only their deployments.
It then restores the Tailnet forwarder.

The build gate checks an adapted STE-Code subset in [ste-check.mjs](scripts/ste-check.mjs).
The [tests](scripts/ste-check.test.mjs) cover sentence limits, word choices, code exclusions, and semicolons.
Editorial review must still check technical meaning, terminology, and command safety.

`make docs-lint` also checks engineering Markdown, including new files.
`make docs-render-check` builds both portals and checks links and browser output.

## Source relationship

- Reference implementation: the `native-cloud` repository, checked out next to
  this repository (`../native-cloud` from the repository root)
- Shared framework: Astro Starlight
- Adapted design cue: the orange accent palette

TODO: Add explicit code and content licences to native-cloud before shared custom
source is reused or redistributed.
