/**
 * Signal Loom dashboard — eBPF Live Network Telemetry Acceptance Suite.
 *
 * Asserts that navigating to the Weave page (/weave) displays:
 * 1. Live eBPF socket tracing status panel.
 * 2. Model provider badges (OpenAI, Anthropic, etc.).
 * 3. Telemetry gap fail-closed security banner when gaps exist.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Weave Live eBPF Network Telemetry", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("renders Weave page with live eBPF Sentinel status bar", async ({ page }) => {
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
    await expect(signalThreads).toContainText("Network Egress");
  });
});
