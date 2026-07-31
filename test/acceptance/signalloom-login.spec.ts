import { expect, test } from "@playwright/test";
import { loginExpectingDex } from "./helpers";

test("user logs in with user/pass and sees the Signal Loom dashboard", async ({ page }) => {
  const apiErrors: string[] = [];
  page.on("response", (r) => {
    if (r.url().includes("/api/") && r.status() >= 400) {
      apiErrors.push(`${r.status()} ${r.request().method()} ${r.url()}`);
    }
  });

  await loginExpectingDex(page);

  await page.screenshot({ path: "test-results/signalloom-login.png", fullPage: true });
  expect(apiErrors, `authenticated /api errors: ${apiErrors.join(", ")}`).toEqual([]);
});

test("user can log out and is returned to the Dex login page", async ({ page }) => {
  await loginExpectingDex(page);

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
  await loginExpectingDex(page);

  // Logout.
  await page.getByTitle("Sign out").click();
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });

  // Re-login — proves the session was fully cleared and a fresh login works.
  await loginExpectingDex(page);

  await page.screenshot({ path: "test-results/signalloom-relogin.png", fullPage: true });
  expect(apiErrors, `re-login /api errors: ${apiErrors.join(", ")}`).toEqual([]);
});

test("RBAC Analysis page loads the KubeSec-AFM iframe", async ({ page }) => {
  await loginExpectingDex(page);

  // Navigate to RBAC Analysis via sidebar.
  await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
  await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });
  await expect(page.getByText("KubeSec-AFM").first()).toBeVisible();

  // The iframe should be present and load the AFM dashboard.
  const iframe = page.locator('[data-testid="afm-iframe"]');
  await expect(iframe).toBeVisible({ timeout: 10_000 });
  const src = await iframe.getAttribute("src");
  expect(src).toBe("/dashboard/");

  // "Open full" link should be present.
  await expect(page.getByText("Open full ↗")).toBeVisible();

  await page.screenshot({ path: "test-results/signalloom-rbac-analysis.png", fullPage: true });
});
