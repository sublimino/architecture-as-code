import { defineConfig, devices } from "@playwright/test";

// The Gateway requires SNI hostname *.osramp.acme.local — we resolve
// the hostname to 127.0.0.1 (port-forward) via Chrome's host-resolver.
const gatewayAddress = process.env.GATEWAY_ADDRESS ?? "127.0.0.1";

export default defineConfig({
  testDir: ".",
  timeout: 30_000,
  retries: 1,
  use: {
    headless: true,
    ignoreHTTPSErrors: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "setup",
      testMatch: "auth.setup.ts",
      use: {
        ...devices["Desktop Chrome"],
        channel: "chrome",
        launchOptions: {
          args: [`--host-resolver-rules=MAP dashboard.osramp.acme.local ${gatewayAddress}`],
        },
      },
    },
    {
      name: "chromium",
      testMatch: "signalloom-test-1.spec.ts",
      use: {
        ...devices["Desktop Chrome"],
        channel: "chrome",
        storageState: "test-results/.auth-state.json",
        launchOptions: {
          args: [`--host-resolver-rules=MAP dashboard.osramp.acme.local ${gatewayAddress}`],
        },
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
        channel: "chrome",
        storageState: "test-results/.auth-state.json",
        launchOptions: {
          args: [`--host-resolver-rules=MAP dashboard.osramp.acme.local ${gatewayAddress}`],
        },
      },
      dependencies: ["setup"],
    },
    {
      name: "smoke",
      testMatch: /smoke\.spec\.ts|signalloom-login\.spec\.ts|afm-integration\.spec\.ts|afm-frontend\.spec\.ts|rbac-analysis\.spec\.ts|rbac-explorer\.spec\.ts|credential-lifecycle\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        channel: "chrome",
        video: "off",
      },
    },
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
