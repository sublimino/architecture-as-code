/**
 * Account type EAP View (read-only): the sidebar shows Discovery, Agents and
 * Policies and no other flag-gated tenant page, and a disabled page's route
 * 404s rather than rendering.
 *
 * Runs by intercepting GET /api/v1/features (accountTypes.serve), never by
 * applying the type to a shared tenant. Design:
 * docs/signalloom/feature-flag-account-types.md.
 */
import { test, expect } from "./fixtures";
import { accountTypes, config, login } from "./helpers";

const TYPE = "eap_view";

test.describe("Account type: EAP View (read-only)", () => {
  test("sidebar matches the preset and a gated page is unreachable", async ({ page }) => {
    const flags = accountTypes.flags(TYPE);
    await accountTypes.serve(page, flags);
    await login(page, { demoMode: false });

    await page.goto(`${config.base}/agents`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    await accountTypes.expectSidebar(page, flags);

    expect(flags.page_signals).toBe(false);
    await page.goto(`${config.base}/signals`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("not-found")).toBeVisible({ timeout: 20_000 });
  });
});
