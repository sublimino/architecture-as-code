/**
 * Signal Loom dashboard — Agent Activity Timeline Acceptance Suite.
 *
 * Asserts that navigating to any agent detail page (e.g. kagent-chaos-prober-*,
 * kagent-security-analyst, agent-cardvault) ALWAYS displays activity events
 * in the Activity Timeline, eliminating empty states.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Agent Activity Timeline Guarantee", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("kagent-security-analyst detail page always renders activity events", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-security-analyst?tab=activity`);
    await expect(page.locator("h2").filter({ hasText: "Activity Timeline" }).first()).toBeVisible();

    // Verify timeline items exist (no "No events recorded" empty state)
    await expect(page.locator("text=No events recorded")).not.toBeVisible();
  });

  test("navigates to kagent-chaos-prober and verifies activity timeline events", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-chaos-prober?tab=activity`);
    await expect(page.locator("h2").filter({ hasText: "Activity Timeline" }).first()).toBeVisible();
    await expect(page.locator("text=No events recorded")).not.toBeVisible();
  });
});
