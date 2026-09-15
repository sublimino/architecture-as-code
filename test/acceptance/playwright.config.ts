import { defineConfig, devices } from "@playwright/test";

// The Gateway requires SNI hostname *.osramp.acme.local — we resolve
// the hostname to 127.0.0.1 (port-forward) via Chrome's host-resolver.
const gatewayAddress = process.env.GATEWAY_ADDRESS ?? "127.0.0.1";

// Which Chrome to drive. The suite wants the real branded Chrome, but some
// environments (sandboxed shells, minimal CI images) cannot exec
// /opt/google/chrome/chrome and fail every project with EACCES before a single
// assertion runs. PW_CHANNEL=chromium falls back to Playwright's bundled build,
// which is enough for functional E2E; leave it unset to keep real Chrome.
const CHANNEL =
  process.env.PW_CHANNEL === "chromium" || process.env.PW_CHANNEL === "bundled"
    ? undefined
    : (process.env.PW_CHANNEL ?? "chrome");

export default defineConfig({
  testDir: ".",
  // Several SuperCred projects mutate the same demo cluster. The runner
  // deliberately serializes those runs, so parallel Playwright workers would
  // otherwise cancel one project's active phase from another project.
  workers: 1,
  timeout: 30_000,
  retries: 1,
  use: {
    headless: true,
    ignoreHTTPSErrors: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "off",
    // dashboard.osramp.acme.local has no DNS record and no /etc/hosts entry, by
    // design: the Gateway needs the SNI name, and the browser is the only thing
    // that ever has to resolve it. Chrome's --host-resolver-rules is therefore
    // the single reason that hostname resolves anywhere in this suite, and
    // every project drives a browser at it (helpers.ts `config.base`).
    //
    // It used to be repeated in each project's own launchOptions. Five projects
    // carried it and `smoke` did not, so every spec in `smoke` died on
    // net::ERR_NAME_NOT_RESOLVED before its first assertion — CI stage 8b failed
    // 18/18 on both lanes while stage 8 passed against the same cluster minutes
    // earlier. Per-project opt-in makes "forgot it" the default and turns a
    // missing precondition into an unrelated-looking DNS error; declaring it
    // once here makes "works" the default and leaves a new project nothing to
    // forget.
    //
    // NOTE: Playwright merges `use` shallowly per key, so a project that
    // re-declares `launchOptions` REPLACES this rather than extending it. Do not
    // add a project-level `launchOptions` without repeating this argument.
    launchOptions: {
      args: [
        `--host-resolver-rules=MAP dashboard.osramp.acme.local ${gatewayAddress}`,
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-gpu",
        "--disable-gpu-compositing",
        "--disable-gpu-rasterization",
        "--disable-gpu-early-init",
        "--disable-gpu-sandbox",
        "--use-gl=disabled",
        "--disable-software-rasterizer",
        "--disable-dev-shm-usage",
        "--ignore-certificate-errors",
      ],
    },
  },
  projects: [
    {
      name: "setup",
      testMatch: "auth.setup.ts",
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
      },
    },
    {
      name: "chromium",
      testMatch: "signalloom-test-1.spec.ts",
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        storageState: "test-results/.auth-state.json",
      },
      dependencies: ["setup"],
    },
    {
      // The two-window SuperCredential demo.
      //
      // Its own project because it needs BOTH of the things only `chromium`
      // has — the storageState the setup project writes, and a dependency on
      // that setup project — plus a timeout that suits a real demo phase. A
      // spec added to `smoke` gets neither and runs unauthenticated; a spec
      // left on the global 30s timeout fails on a working demo, because step 2
      // alone waits up to 300s for the credential-chain Job.
      name: "supercred-two-window",
      testMatch: /supercred-two-window\.spec\.ts/,
      timeout: 15 * 60_000,
      // The demo mutates one shared cluster and the runner serialises runs
      // process-wide, so a retry would collide with its own leftovers rather
      // than start clean.
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        storageState: "test-results/.auth-state.json",
      },
      dependencies: ["setup"],
    },
    {
      // Full lifecycle proof: UI drives phases 1–5, observes every audience
      // projection, resets, then proves the workflow can start over.
      name: "supercred-ui-lifecycle",
      testMatch: /supercred-ui-lifecycle\.spec\.ts/,
      timeout: 30 * 60_000,
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        storageState: "test-results/.auth-state.json",
      },
      dependencies: ["setup"],
    },
    {
      // The Credential Lifecycle card specifically: that its evidence request
      // is authenticated on the wire, and that the rows re-probe when the
      // instructor runs a phase. Separate from supercred-ui-lifecycle so a
      // failure names the credential-evidence path rather than the whole
      // 30-minute journey.
      name: "supercred-evidence-lifecycle",
      testMatch: /supercred-evidence-lifecycle\.spec\.ts/,
      timeout: 30 * 60_000,
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        storageState: "test-results/.auth-state.json",
      },
      dependencies: ["setup"],
    },
    {
      // Progressive log arrival against the live runner: the log must GROW
      // while a phase is still in flight, and stop following once the
      // instructor scrolls up.
      //
      // Its own project rather than a home in `supercred-ui-lifecycle`, for
      // the reason that project's own comment gives about `smoke`: a failure
      // here must name the streaming path. Sharing a project would bury a
      // streaming regression inside a 30-minute lifecycle journey and make the
      // two impossible to run independently — and the whole reason this defect
      // survived is that its symptom was invisible inside a bigger green test.
      //
      // 15 minutes, not 30: it drives one reset and one phase, not all five.
      // retries:0 like its siblings — it mutates one shared cluster, so a
      // retry would start against its own leftovers rather than clean.
      name: "supercred-log-streaming",
      testMatch: /supercred-log-streaming\.spec\.ts/,
      timeout: 15 * 60_000,
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        storageState: "test-results/.auth-state.json",
      },
      dependencies: ["setup"],
    },
    {
      // The same streaming assertions, against a scripted runner and no
      // cluster at all (harness/server.ts). Runs in ~25s on a laptop.
      //
      // NO storageState and NO `setup` dependency, and both omissions are
      // deliberate: the setup project drives Dex through the Gateway, so
      // depending on it would give this project the cluster requirement it
      // exists to avoid — and `test-results/.auth-state.json` does not exist
      // on a machine that has never run against a cluster, which Playwright
      // reports as a project-level failure rather than a skip.
      //
      // Left out of `smoke` for the same reason: `smoke` is for specs that
      // drive the DASHBOARD and log themselves in. This one boots a bun server
      // and points a page at 127.0.0.1, so it shares none of that project's
      // preconditions and would only inherit the ones it cannot meet.
      name: "supercred-log-streaming-harness",
      testMatch: /supercred-log-streaming-harness\.spec\.ts/,
      // Four scripted runs of 5-13s each, plus a browser launch and a Bun
      // bundle of the real component tree on first request.
      timeout: 3 * 60_000,
      // Deliberately NOT `fullyParallel`, and the reason is a defect rather
      // than a resource — which makes it worth writing down, because on the
      // resource question this project is the ONE here that could parallelise.
      // Each of its tests spawns its own `bun harness/server.ts` on `--port 0`:
      // no cluster, no gateway, no fixed port, no storageState between them.
      // (Every other project drives the one shared demo cluster, where
      // concurrency means two runs mutating the same estate — the same reason
      // those projects set `retries: 0`. Those are not candidates and should
      // not be made into ones.)
      //
      // What actually blocks it is a pre-existing flake in "batched output must
      // FAIL the progressive-arrival assertions" — measured at 3 failures in 5
      // consecutive runs against the UNMODIFIED spec, with no concurrency
      // involved at all. The spec's own header documents the mechanism. Serial
      // mode currently hides it by a side effect nobody wrote down: a failure
      // inside a serial group retries THE WHOLE GROUP, so the batch test's
      // retry re-runs with the streaming test immediately before it, which is
      // the ordering that makes it pass.
      //
      // Measured, this project, three consecutive full runs with `mode:
      // "serial"` removed and everything else identical: 1 outright red, 2
      // green only via retry, and wall clock UP from 32s to 41-47s because of
      // those retries. So there is no speed to be had here until the assertion
      // is reconciled with the 500ms status poll it contradicts.
      use: {
        ...devices["Desktop Chrome"],
        // NO `channel`, and that is the one deliberate difference from every
        // other project here.
        //
        // Everything else drives the dashboard through the Envoy Gateway and
        // wants the real branded Chrome, because that is what an instructor
        // will be running on stage. This project drives a bun server on
        // 127.0.0.1 with no Gateway, no TLS and no SNI, so branded Chrome buys
        // it nothing — and costs it reproducibility, because whether
        // /opt/google/chrome exists, is executable, and can reach the system
        // font cache varies per machine in a way the bundled build does not.
        //
        // That is not hypothetical. The same run rendered correctly under a
        // plain bundled-Chromium launch and rendered with ZERO-HEIGHT TEXT
        // under this config on the same machine — every string present in the
        // DOM, every string laying out at 0x0, a 36px-tall scroll region
        // holding 6470 characters, and a failure message about the log not
        // overflowing its box. A layout assertion is only worth having if the
        // browser it runs in is the same one every time.
        //
        // expectRendersText() in the spec catches the residual case by name, so
        // a machine that still cannot resolve a font fails saying so rather
        // than blaming the component.
        video: "off",
      },
    },
    {
      // Specs that authenticate themselves, per test, via helpers.ts `login()`.
      // The absence of storageState and of a `setup` dependency is deliberate
      // and must stay: smoke.spec.ts's first case asserts that an
      // unauthenticated visit is redirected to Dex, which a pre-seeded auth
      // state would defeat. What was NOT deliberate was the absence of the
      // host-resolver rule — that now comes from the top-level `use`.
      name: "smoke",
      // live-data.spec.ts belongs here and nowhere else: it calls login() per
      // test (with demoMode:false) and needs no storageState, which is exactly
      // this project's contract. A spec that matches NO project is silently
      // skipped by Playwright — exit 0, no warning — so leaving it out would
      // reproduce the very blindness it was written to close.
      testMatch: /smoke\.spec\.ts|navigation\.spec\.ts|signalloom-login\.spec\.ts|afm-integration\.spec\.ts|afm-frontend\.spec\.ts|rbac-analysis\.spec\.ts|rbac-explorer\.spec\.ts|credential-lifecycle\.spec\.ts|live-data\.spec\.ts|kagent-agents\.spec\.ts|distance-latency\.spec\.ts|agent-activity-timeline\.spec\.ts|agent-drilldown-and-selectors\.spec\.ts|agent-claim\.spec\.ts|cloudaudit-dashboard\.spec\.ts|signal-loom-netebpf\.spec\.ts|signal-loom-baoaudit\.spec\.ts|who-authorized\.spec\.ts|sfas-dossier-authorization\.spec\.ts|onboarding\.spec\.ts|smoke-onboarding-agents\.spec\.ts|feeds-explorer\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        video: "off",
      },
    },
    // The static documentation portal. Opt-in on DOCS_BASE_URL, and that gate
    // is load-bearing rather than stylistic: scripts/acceptance-test.sh runs
    // `bunx playwright test` with no --project, so an unconditional docs
    // project would be claimed by `make acceptance-test` and fail 5/5 against
    // a preview server nobody started. Its precondition is a built dist being
    // served, which `make demo-signalloom-up` does not provide, so unlike every
    // other project here it cannot ride the cluster lane. `make
    // docs-render-check` sets DOCS_BASE_URL, builds, serves and runs it.
    //
    // The spec-coverage guard reads this file as text, so the testMatch below
    // is visible to it whether or not the ternary includes the project — the
    // spec reads as wired, which it is whenever it is meant to run.
    ...(process.env.DOCS_BASE_URL ? [{
      // Its own project because it is the one suite here that must NOT touch
      // the cluster.
      //
      // It carries no `dependencies: ["setup"]` and no storageState on purpose:
      // /docs is unauthenticated static HTML, so a Dex auth dependency would
      // make a docs render failure indistinguishable from an auth failure, and
      // would couple an offline check to a live OIDC provider.
      //
      // It also does not use the gateway. docs/signalloom/
      // slon-p3-docs-portal-provenance.md §4 records that every Flux source in
      // the demo cluster is an OCIRepository with no git revision, and that the
      // running docs image was published from a different branch — so a probe
      // of https://dashboard.osramp.acme.local/docs is evidence about the
      // deployed artifact, never about the checked-out tree. docs.spec.ts
      // therefore drives a locally served build via DOCS_BASE_URL.
      name: "docs",
      testMatch: /docs\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        video: "off",
      },
    }] : []),
    // The AgentMaxxing Interactive Demo Console (AMXD-P6-1).
    //
    // Opt-in on AMXD_DEMO_CONSOLE, for exactly the reason the docs project
    // above is opt-in on DOCS_BASE_URL: scripts/acceptance-test.sh runs
    // `bunx playwright test` with no --project, so EVERY project here is
    // claimed by `make acceptance-test`. This one's precondition is not the
    // precondition the cluster projects share. `make demo-signalloom-up`
    // deploys the dashboard IMAGE, and the image currently published to the
    // demo cluster predates this console entirely: probed 2026-09-15, the
    // served bundle carries 0 matches for `AgentMaxxingDemoPage` and lists 33
    // lazy page chunks, none of them this page, while App.tsx:436 registers
    // the route in source. An unconditional project would therefore turn a
    // green `make acceptance-test` red for a reason unrelated to any assertion
    // in the spec — which is precisely the trap the docs project's comment
    // records. AMXD-P6-2 owns the make target that supplies this variable.
    //
    // The spec-coverage guard parses this file as TEXT, so the testMatch below
    // is visible to it whether or not the ternary includes the project: the
    // spec reads as wired, which it is whenever it is meant to run. Prove both
    // directions with `bunx playwright test --list` and
    // `AMXD_DEMO_CONSOLE=1 bunx playwright test --list`.
    ...(process.env.AMXD_DEMO_CONSOLE ? [{
      name: "agentmaxxing-demo-console",
      testMatch: /agentmaxxing-demo-console\.spec\.ts/,
      // Ten minutes, not the global 30s, and not a round number picked for
      // looks. The mock block's auto-play case alone drives three full passes
      // whose dwell floors are contractual: 4 transitions x 4000ms at 1x plus
      // 4 x 2000ms at 2x is 24s of MANDATORY waiting before a single
      // confirmation round-trip is counted, and AMXD-P5-GOV measured the three
      // real passes at 16,120 / 8,105 / 589 ms in a browser. The live block
      // then walks all five stages against the real FastAPI backend through
      // the Gateway and waits on two specific network responses. 30s could not
      // finish the auto-play case on a working console, so the global default
      // would fail this spec for being correct.
      timeout: 10 * 60_000,
      // retries: 0 like the supercred projects, and for their reason: the live
      // block REVOKES a host on the one shared demo cluster. A retry would
      // resume against its own leftovers, where the revoke answers 200 with
      // count:0 and the test fails for an unrelated reason that reads like a
      // denial defect.
      retries: 0,
      use: {
        ...devices["Desktop Chrome"],
        channel: CHANNEL,
        // No storageState and no `dependencies: ["setup"]`, matching `smoke`:
        // every test here authenticates itself through helpers.ts `login()`,
        // and the live block specifically needs `login(page, { demoMode:
        // false })`, which a pre-seeded demo-mode auth state would defeat.
        //
        // No `launchOptions` either — Playwright merges `use` shallowly per
        // key, so re-declaring it would REPLACE the top-level
        // --host-resolver-rules and kill every navigation with
        // net::ERR_NAME_NOT_RESOLVED, exactly as it did to `smoke` (18/18) once
        // before.
        video: "off",
      },
    }] : []),
  ],
  // The junit reporter is added only when CI asks for it by setting
  // PLAYWRIGHT_JUNIT_OUTPUT_FILE, so local runs keep the list + html output
  // unchanged. vm-pipeline.sh has always set that variable for stage 8, but no
  // junit reporter was configured to consume it, so stage8-browser.xml was
  // never written -- and openreports-convert.sh, which expects that file,
  // silently contributed ZERO browser-journey results to the OpenReports
  // artifact. The suite passed, the report just did not contain the most
  // valuable stage. Same shape as the other silent-skip defects: a missing
  // input degraded to nothing rather than to an error.
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
    ...(process.env.PLAYWRIGHT_JUNIT_OUTPUT_FILE
      ? [["junit", { outputFile: process.env.PLAYWRIGHT_JUNIT_OUTPUT_FILE }] as const]
      : []),
  ],
});
