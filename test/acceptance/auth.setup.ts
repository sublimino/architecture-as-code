import { test as setup, expect } from "@playwright/test";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "https://127.0.0.1:18443";

setup("authenticate via Dex", async ({ page }) => {
  // Navigate to the dashboard — it will client-side redirect to Dex for auth
  await page.goto(DASHBOARD_URL);

  // Wait for the client-side OIDC redirect to Dex login form
  await page.waitForURL("**/dex/**", { timeout: 15_000 }).catch(() => {
    // If no redirect, dashboard might already be authenticated
  });

  // If we're on the Dex login page, fill credentials and submit
  const loginInput = page.locator('input[name="login"]');
  if (await loginInput.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await loginInput.fill("demo-user@signalloom.local");
    await page.locator('input[name="password"]').fill("password");
    await page.getByRole("button", { name: /login/i }).click();

    // Wait for redirect back to dashboard after auth callback
    await page.waitForURL(`${DASHBOARD_URL}/**`, { timeout: 15_000 }).catch(() => {
      // May redirect to a different path, that's fine
    });
  }

  // Wait for the dashboard to render (give React time to mount)
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});

  // Save authentication state for other tests
  await page.context().storageState({ path: ".auth/state.json" });
});
