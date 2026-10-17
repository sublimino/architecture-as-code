/**
 * Account type Full: every flag-gated tenant page is in the sidebar, and a page
 * EAP View hides (Signals) renders.
 *
 * Runs by intercepting GET /api/v1/features (accountTypes.serve), never by
 * applying the type to a shared tenant. Design:
 * docs/signalloom/feature-flag-account-types.md.
 */
import { test, expect } from "./fixtures";
import { accountTypes, config, login } from "./helpers";

const TYPE = "full";

test.describe("Account type: Full", () => {
  test("sidebar shows every tenant page and a formerly gated page renders", async ({ page }) => {
    const flags = accountTypes.flags(TYPE);
    await accountTypes.serve(page, flags);
    await login(page, { demoMode: false });

    await page.goto(`${config.base}/agents`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    await accountTypes.expectSidebar(page, flags);

    await page.goto(`${config.base}/signals`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("not-found")).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Signals", exact: true })).toBeVisible({ timeout: 20_000 });
  });
});
