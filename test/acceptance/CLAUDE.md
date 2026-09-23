# Agent guidance — browser acceptance suite

This directory is a Playwright suite. It drives Google Chrome against the
dashboard in a running cluster. It is not a `bun test` suite. Bun is only the
package manager and the `bunx` launcher. The canonical guide is
[`TESTING.md`](../../TESTING.md#browser-acceptance-tests).

## Configuration

[`playwright.config.ts`](playwright.config.ts) defines the projects. Each
project claims its specs with `testMatch`.

- The `setup` project runs [`auth.setup.ts`](auth.setup.ts). It logs in through
  Dex. It writes `test-results/.auth-state.json` and `test-results/.auth-session.json`.
- A project that needs a logged-in session sets `.auth-state.json` as
  `storageState` and declares `dependencies: ["setup"]`.
- The dashboard keeps its token in sessionStorage, which `storageState` does
  not hold. A spec that needs the session imports `test` from
  [`fixtures.ts`](fixtures.ts), which restores `.auth-session.json`.
- The shared `use.launchOptions` maps `dashboard.osramp.acme.local` to the
  Gateway address. Playwright merges `use` shallowly.

CAUTION: Do not add a project-level `launchOptions` without its
`--host-resolver-rules` argument. Every spec in that project then fails with
`net::ERR_NAME_NOT_RESOLVED`.

## Add a spec

1. Add the spec file to this directory.
2. Add the file to the `testMatch` of a project in `playwright.config.ts`.
3. Add a row for the spec to [`SPEC-REGISTRY.tsv`](SPEC-REGISTRY.tsv).
4. Run `bats test/acceptance-spec-coverage.bats` from the repository root.

NOTE: Playwright does not warn about a spec that no project claims. It reports
a smaller total. [`test/acceptance-spec-coverage.bats`](../acceptance-spec-coverage.bats)
compares the registry with the config, the Makefile, and the CI pipeline. CI
stage 1c runs it. The header of `SPEC-REGISTRY.tsv` defines the columns.

## Run the suite

Run the suite from the repository root. A cluster must be running.

```bash
make acceptance-test
scripts/acceptance-test.sh --project <name>
```

[`scripts/acceptance-test.sh`](../../scripts/acceptance-test.sh) runs the
cluster doctor and starts the port-forwards. It forwards the Envoy Gateway to
local port 18443, because Dex pins its callback to that port. It then passes
its arguments to `bunx playwright test`. Use the script. Without its
port-forwards, the specs fail on connection errors, not on assertions.

## Write assertions

- Use web-first assertions, such as `await expect(locator).toBeVisible()`.
  They retry until the timeout.
- Do not add `page.waitForTimeout`. A fixed sleep is slow when the page is
  fast and flaky when the page is slow.
- Put shared helpers in [`helpers.ts`](helpers.ts).
