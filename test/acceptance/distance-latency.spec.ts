/**
 * Signal Loom dashboard — Distance-Focused Latency & Telemetry acceptance suite.
 *
 * Drives the /distance-latency page to assert that:
 *   1. Page header, telemetry stat cards, and 4-act demonstration runner render cleanly.
 *   2. The spatial distance topology matrix displays trust domains and RTT latencies.
 *   3. The FrostDB columnar telemetry stream displays live ingested records and CEL benchmarks.
 *   4. Act buttons trigger execution without uncaught errors or UI regressions.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Distance-Focused Latency & Telemetry Demo", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("navigates to /distance-latency and renders all demo components", async ({ page }) => {
    await page.goto(`${BASE}/distance-latency`);
    await expect(page.locator("h1").filter({ hasText: "Distance-Focused Latency & Telemetry" })).toBeVisible();

    // Stat cards
    await expect(page.locator("text=Topology Tiers").first()).toBeVisible();
    await expect(page.locator("text=eBPF Resolution").first()).toBeVisible();
    await expect(page.locator("text=FrostDB Telemetry").first()).toBeVisible();
    await expect(page.locator("text=CEL Evaluation").first()).toBeVisible();

    // 4 Acts
    await expect(page.locator('[data-testid="dl-act-row-1"]')).toBeVisible();
    await expect(page.locator('[data-testid="dl-act-row-2"]')).toBeVisible();
    await expect(page.locator('[data-testid="dl-act-row-3"]')).toBeVisible();
    await expect(page.locator('[data-testid="dl-act-row-4"]')).toBeVisible();

    // Topology Matrix
    await expect(page.locator("text=Spatial Distance & Latency Matrix").first()).toBeVisible();
    await expect(page.locator('[data-testid="topology-node-kagent-chaos-prober"]')).toBeVisible();

    // FrostDB Feed
    await expect(page.locator("text=FrostDB High-Cardinality Columnar Stream & Real-Time CEL Governance").first()).toBeVisible();
  });

  test("executes Act 1 (Spatial Topology Discovery)", async ({ page }) => {
    await page.goto(`${BASE}/distance-latency`);
    const act1Btn = page.locator('[data-testid="run-act-1-btn"]');
    await expect(act1Btn).toBeVisible();
    await act1Btn.click();
    await page.waitForTimeout(1000);
  });
});
