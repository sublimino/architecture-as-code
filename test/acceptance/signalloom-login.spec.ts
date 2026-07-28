import { expect, test } from "@playwright/test";

// SLDPB25 — Signal Loom UI migrated into the cluster, authenticated via local Dex.
// Drives the real user/pass login through the port-forwarded single-origin dashboard
// (http://localhost:5173) and asserts the migrated Signal Loom dashboard renders.
//
// Preconditions (see docs): `kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080`.
const BASE = process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173";
const USER = process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local";
const PASS = process.env.SIGNALLOOM_PASS ?? "demo-user";

test("user logs in with user/pass and sees the Signal Loom dashboard", async ({ page }) => {
  const apiErrors: string[] = [];
  page.on("response", (r) => {
    if (r.url().includes("/api/") && r.status() >= 400) {
      apiErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`);
    }
  });

  // 1. Open the app — unauthenticated, it should redirect to the Dex login.
  await page.goto(BASE, { waitUntil: "domcontentloaded" });

  // 2. Dex login form (Dex renders input[name=login] / input[name=password]).
  const login = page.locator('input[name="login"]');
  await expect(login).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");

  // 3. Submit credentials.
  await login.fill(USER);
  await page.locator('input[name="password"]').fill(PASS);
  await Promise.all([
    page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
    page.getByRole("button", { name: /login|sign in|submit/i }).click(),
  ]);

  // 4. Back on the app, authenticated → lands on /agents.
  await page.waitForURL(/\/(agents|compliance|audit|settings)?$|\/agents/, { timeout: 20_000 });

  // 5. The migrated dashboard renders: sidebar nav is visible.
  await expect(
    page.getByText(/agents|compliance|audit trail|settings/i).first(),
  ).toBeVisible({ timeout: 15_000 });

  // 6. Evidence screenshot.
  await page.screenshot({ path: "test-results/signalloom-login.png", fullPage: true });

  // 7. No authenticated /api call should be rejected.
  expect(apiErrors, `authenticated /api errors: ${apiErrors.join(", ")}`).toEqual([]);
});
