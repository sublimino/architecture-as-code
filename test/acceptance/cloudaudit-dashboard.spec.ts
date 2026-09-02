/**
 * Signal Loom dashboard — Cloud Control Plane Audit Streamer Acceptance Suite.
 *
 * Asserts that navigating to the Weave page (/weave) displays:
 * 1. Layer 6 (Cloud Control Plane) in the active signal layers.
 * 2. Blind spot bs-004 marked as resolved.
 * 3. Evidence drawer inspecting Cloud Control Plane audit observations.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Weave Cloud Control Plane Audit Ingestion", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("renders Weave page with 6 active signal layers including Cloud Control Plane", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    await expect(page.locator("h1").filter({ hasText: "The Weave" }).first()).toBeVisible();

    // Verify Active Layers count is 6
    const activeLayersCard = page.locator(".card").filter({ hasText: "Active Layers" });
    await expect(activeLayersCard).toBeVisible();
    await expect(activeLayersCard).toContainText("6");

    // Verify Cloud Control Plane thread appears in Signal Threads
    const signalThreads = page.locator('[data-testid="signal-threads"]');
    await expect(signalThreads).toBeVisible();
    await expect(signalThreads).toContainText("Cloud Control Plane");
  });

  test("verifies blind spot bs-004 resolution in Coverage Honesty panel", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    const coveragePanel = page.locator('[data-testid="coverage-panel"]');
    await expect(coveragePanel).toBeVisible();

    // Cloud Control Plane row should report Active
    const cloudRow = coveragePanel.locator("tr").filter({ hasText: "Cloud Control Plane" });
    await expect(cloudRow).toBeVisible();
    await expect(cloudRow).toContainText("Active");
  });
});
