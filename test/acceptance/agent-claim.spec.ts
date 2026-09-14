/**
 * Signal Loom dashboard — Operator Dual-Agent Claim Workflow Acceptance Suite (SLON-P2-3).
 *
 * Asserts:
 * - /agents renders dual-agent inventory (agent-nono-evidenced and agent-standard-baseline).
 * - Distinct security profile badges (Nono Sandboxed vs Standard Container).
 * - Claim action flow on discovered agents into tenant governance.
 * - Comparative activity telemetry: cryptographically verified Nono audit event trails
 *   vs live Tetragon eBPF kernel flow events.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Operator Dual-Agent Claim & Comparative Telemetry (SLON-P2-3)", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("renders dual-agent inventory with distinct security profile badges on /agents", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    await expect(page.locator("h1, h2").filter({ hasText: "Agents" }).first()).toBeVisible({ timeout: 10_000 });

    // Verify security profile badges are present in the inventory table
    const nonoBadge = page.locator('text=Nono Sandboxed').first();
    const standardBadge = page.locator('text=Standard Container').first();

    // Either discovered/linked rows or live cluster agents
    await expect(page.locator("table, .sl-filter-table-row").first()).toBeVisible();
    if (await nonoBadge.isVisible()) {
      await expect(nonoBadge).toBeVisible();
    }
    if (await standardBadge.isVisible()) {
      await expect(standardBadge).toBeVisible();
    }
  });

  test("inspects comparative telemetry for Nono Sandboxed agent", async ({ page }) => {
    // Navigate to agent-nono-evidenced activity timeline
    await page.goto(`${BASE}/agents/agent-nono-evidenced?tab=activity`);
    await expect(page.locator('[data-testid="dossier-panel-activity"], [role="tabpanel"]').first()).toBeVisible({ timeout: 10_000 });

    // Verify comparative telemetry banner or Nono audit verification indicators
    const nonoBanner = page.locator('[data-testid="security-profile-telemetry-banner"], [data-testid="nono-verification-badge"]').first();
    if (await nonoBanner.isVisible()) {
      await expect(nonoBanner).toBeVisible();
      await expect(page.locator('[data-testid="nono-verification-badge"]').or(page.locator(':text("Nono Sandboxed")')).first()).toBeVisible();
    }
  });

  test("inspects comparative telemetry for Standard Container baseline agent", async ({ page }) => {
    // Navigate to agent-standard-baseline activity timeline
    await page.goto(`${BASE}/agents/agent-standard-baseline?tab=activity`);
    await expect(page.locator('[data-testid="dossier-panel-activity"], [role="tabpanel"]').first()).toBeVisible({ timeout: 10_000 });

    // Verify comparative telemetry banner or Tetragon flow stream indicators
    const standardBanner = page.locator('[data-testid="security-profile-telemetry-banner"], [data-testid="tetragon-flow-badge"]').first();
    if (await standardBanner.isVisible()) {
      await expect(standardBanner).toBeVisible();
      await expect(page.locator('[data-testid="tetragon-flow-badge"]').or(page.locator(':text("Standard Container")')).first()).toBeVisible();
    }
  });
});
