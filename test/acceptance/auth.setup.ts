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

  // Reveal the superadmin-only sidebar links (Cryptography, Federated Services,
  // Collusion & Access, RBAC Analysis, RBAC Explorer). Per
  // dashboard-signalloom/src/auth/superadmin.ts this is a VISIBILITY control that
  // defaults off, not an authorization control — the routes stay registered and
  // reachable regardless. The journey matrix drives the sidebar, so it needs the
  // links rendered. Seeded before storageState so dependent projects inherit it.
  await page.evaluate(() => {
    try {
      window.localStorage.setItem("signalloom.superadmin", "true");
    } catch {
      /* storage unavailable */
    }
  });

  await page.context().storageState({ path: "test-results/.auth-state.json" });
});
