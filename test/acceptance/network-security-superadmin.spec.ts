import { test, expect } from "@playwright/test";
import { config, login } from "./helpers";

test.describe("Network security SUPER ADMIN boundary", () => {
  test("an unauthenticated direct route follows the product login boundary", async ({ page }) => {
    await page.goto(`${config.base}/network-tests`, { waitUntil: "domcontentloaded" });

    await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 20_000 });
    expect(page.url()).toContain("/dex/");
  });

  test(
    "the established SUPER ADMIN identity can view live results and start a scan",
    async ({ page }) => {
      await login(page, { demoMode: false });

      const resultsResponse = page.waitForResponse(
        (response) =>
          response.url().includes("/api/network-tests") && response.request().method() === "GET",
      );
      await page.getByRole("link", { name: "Network Tests", exact: true }).click();
      await expect(page).toHaveURL(/\/network-tests$/);

      const response = await resultsResponse;
      expect(response.status()).toBe(200);
      const payload = (await response.json()) as { tests: Array<{ name: string }> };
      expect(payload.tests.length).toBeGreaterThan(0);
      for (const networkTest of payload.tests) {
        await expect(page.getByText(networkTest.name, { exact: true })).toBeVisible();
      }

      // This browser preference controls navigation visibility only. Clearing it
      // cannot remove authority granted by the validated Dex principal.
      await page.evaluate(() => window.localStorage.setItem("signalloom.superadmin", "false"));
      const scanResponse = page.waitForResponse(
        (candidate) =>
          candidate.url().includes("/api/network-tests/scan") &&
          candidate.request().method() === "POST",
      );
      await page.getByRole("button", { name: /run network test scan now/i }).click();
      expect((await scanResponse).status()).toBe(202);
    },
  );
});
