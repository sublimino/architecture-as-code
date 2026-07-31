import { test as setup, expect } from "@playwright/test";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "https://127.0.0.1:18443";
const DEX_URL = process.env.SIGNALLOOM_DEX_URL ?? "http://127.0.0.1:15556";

setup("authenticate via Dex", async ({ page }) => {
  // Navigate to the dashboard — it will redirect to Dex for auth
  await page.goto(DASHBOARD_URL);

  // If we're already on the Dex login page (PKCE redirect), fill credentials
  if (page.url().includes("/dex/")) {
    await page.locator('input[name="login"]').fill("demo-user@signalloom.local");
    await page.locator('input[name="password"]').fill("password");
    await page.getByRole("button", { name: /login/i }).click();

    // Wait for redirect back to dashboard after auth
    await page.waitForURL(`${DASHBOARD_URL}/**`, { timeout: 15_000 });
  }

  // Verify dashboard loaded (Estate 95 is the default title)
  await expect(page.getByText("Estate 95", { exact: false }).first()).toBeVisible({
    timeout: 10_000,
  });

  // Save authentication state for other tests
  await page.context().storageState({ path: ".auth/state.json" });
});
