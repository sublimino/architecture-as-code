import { test as setup, expect } from "@playwright/test";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "https://dashboard.osramp.acme.local:30754";
const DEX_DEMO_PASSWORD = process.env.DEX_DEMO_PASSWORD ?? "demo-user";

setup("authenticate via Dex", async ({ page }) => {
  await page.goto(DASHBOARD_URL);
  const loginField = page.locator('input[name="login"]');
  await expect(loginField).toBeVisible({ timeout: 15_000 });
  await loginField.fill("demo-user@signalloom.local");
  await page.locator('input[name="password"]').fill(DEX_DEMO_PASSWORD);
  await page.getByRole("button", { name: /sign in|login/i }).click();
  await page.waitForURL(/\/agents/, { timeout: 15_000 });
  await page.waitForLoadState("networkidle");
  await page.context().storageState({ path: "test-results/.auth-state.json" });
});
