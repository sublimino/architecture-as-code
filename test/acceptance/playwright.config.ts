import { defineConfig, devices } from "@playwright/test";

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
      name: "smoke",
      testMatch: /smoke\.spec\.ts|signalloom-login\.spec\.ts|afm-integration\.spec\.ts|afm-frontend\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        channel: "chrome",
        video: "off",
      },
    },
  ],
  reporter: [["list"], ["html", { outputFolder: "playwright-report", open: "never" }]],
});
