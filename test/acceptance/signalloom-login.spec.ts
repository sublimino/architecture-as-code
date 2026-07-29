import { expect, test } from "@playwright/test";

// SLDPB25 — Signal Loom UI migrated into the cluster, authenticated via local Dex.
// Drives the real user/pass login through the port-forwarded single-origin dashboard
// (http://localhost:5173) and asserts the migrated Signal Loom dashboard renders.
//
// Preconditions (see docs): `kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080`.
const BASE = process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173";
const USER = process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local";
const PASS = process.env.SIGNALLOOM_PASS ?? "demo-user";

async function loginViaDex(page: import("@playwright/test").Page) {
  await page.goto(BASE, { waitUntil: "domcontentloaded" });
  const loginInput = page.locator('input[name="login"]');
  await expect(loginInput).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");
  await loginInput.fill(USER);
  await page.locator('input[name="password"]').fill(PASS);
  await Promise.all([
    page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
    page.getByRole("button", { name: /login|sign in|submit/i }).click(),
  ]);
  await page.waitForURL(/\/(agents|compliance|audit|settings)?$|\/agents/, { timeout: 20_000 });
  await expect(
    page.getByText(/agents|compliance|audit trail|settings/i).first(),
  ).toBeVisible({ timeout: 15_000 });
}

test("user logs in with user/pass and sees the Signal Loom dashboard", async ({ page }) => {
  const apiErrors: string[] = [];
  page.on("response", (r) => {
    if (r.url().includes("/api/") && r.status() >= 400) {
      apiErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`);
    }
  });

  await loginViaDex(page);

  await page.screenshot({ path: "test-results/signalloom-login.png", fullPage: true });
  expect(apiErrors, `authenticated /api errors: ${apiErrors.join(", ")}`).toEqual([]);
});

test("user can log out and is returned to the Dex login page", async ({ page }) => {
  await loginViaDex(page);

  // Click the sign-out button in the sidebar.
  await page.getByTitle("Sign out").click();

  // After logout the session is cleared and AutoSignIn redirects to Dex.
  const loginInput = page.locator('input[name="login"]');
  await expect(loginInput).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");

  await page.screenshot({ path: "test-results/signalloom-logout.png", fullPage: true });
});

test("full login → logout → re-login cycle works without errors", async ({ page }) => {
  const apiErrors: string[] = [];
  page.on("response", (r) => {
    if (r.url().includes("/api/") && r.status() >= 400) {
      apiErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`);
    }
  });

  // First login.
  await loginViaDex(page);

  // Logout.
  await page.getByTitle("Sign out").click();
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });

  // Re-login — proves the session was fully cleared and a fresh login works.
  await loginViaDex(page);

  await page.screenshot({ path: "test-results/signalloom-relogin.png", fullPage: true });
  expect(apiErrors, `re-login /api errors: ${apiErrors.join(", ")}`).toEqual([]);
});

test("RBAC Analysis page loads the KubeSec-AFM iframe", async ({ page }) => {
  await loginViaDex(page);

  // Navigate to RBAC Analysis via sidebar.
  await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
  await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText("KubeSec-AFM").first()).toBeVisible();

  // The iframe should be present and load the AFM dashboard.
  const iframe = page.locator('iframe[title="KubeSec-AFM Dashboard"]');
  await expect(iframe).toBeVisible({ timeout: 10_000 });

  // Wait for the iframe to finish loading (src should be /afm/dashboard/).
  await iframe.waitFor({ state: "attached", timeout: 10_000 });
  const src = await iframe.getAttribute("src");
  expect(src).toContain("/afm/dashboard");

  // "Open in new tab" link should be present.
  await expect(page.getByText("Open in new tab")).toBeVisible();

  await page.screenshot({ path: "test-results/signalloom-rbac-analysis.png", fullPage: true });
});
