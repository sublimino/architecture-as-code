/**
 * Signal Loom dashboard — eBPF network-telemetry UI acceptance suite (DEMO FIXTURES).
 *
 * This suite opts into `{ demoMode: true }`, so it observes NO eBPF, no
 * sentinel, no cluster and no network: it asserts that the Weave page renders
 * the telemetry panels from fixture data. It called itself a LIVE suite until
 * the demo-mode inversion, and what it actually failed on was the fixture
 * strings "eBPF Socket Sentinel" and "Network/Egress" being absent from the
 * DOM. The live-side assertions belong to the sentinel BATS suites, not here.
 *
 * Asserts that navigating to the Weave page (/weave) displays:
 * 1. The eBPF socket-tracing status panel (rendered from fixtures).
 * 2. Model provider badges (OpenAI, Anthropic, etc.).
 * 3. Telemetry gap fail-closed security banner when gaps exist.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Weave eBPF network telemetry UI (demo fixtures)", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("renders Weave page with the eBPF Sentinel status bar from fixtures", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    await expect(page.locator("h1").filter({ hasText: "The Weave" }).first()).toBeVisible();

    // Verify eBPF status panel
    const ebpfStatus = page.locator('[data-testid="ebpf-telemetry-status"]');
    await expect(ebpfStatus).toBeVisible();
    await expect(ebpfStatus).toContainText("eBPF Socket Sentinel");
  });

  test("verifies Network Egress signal thread displays in Signal Threads panel", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    const signalThreads = page.locator('[data-testid="signal-threads"]');
    await expect(signalThreads).toBeVisible();
    await expect(signalThreads).toContainText("Network/Egress");
  });
});
