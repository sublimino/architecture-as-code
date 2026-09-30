import { expect, test } from "@playwright/test";
import { loginExpectingDex, config } from "./helpers";

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

  // If the dashboard lands on /login (the signed-out page), click "Sign in with Dex"
  // to proceed to Dex.
  const dexBtn = page.getByRole("button", { name: /sign in with dex/i });
  if (await dexBtn.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await dexBtn.click();
  }

  // After logout the session is cleared and AutoSignIn/Dex button redirects to Dex.
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
  const dexBtn = page.getByRole("button", { name: /sign in with dex/i });
  if (await dexBtn.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await dexBtn.click();
  }
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });

  // Re-login - proves the session was fully cleared and a fresh login works.
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

  // The iframe should load the selected-cluster AFM dashboard.
  const iframe = page.locator('[data-testid="afm-iframe"]');
  await expect(iframe).toBeVisible({ timeout: 10_000 });
  const src = await iframe.getAttribute("src");
  expect(src).not.toBeNull();
  const iframeUrl = new URL(src!, "https://dashboard.osramp.acme.local");
  expect(iframeUrl.pathname).toBe("/dashboard/");
  expect(iframeUrl.searchParams.get("cluster")).toBeTruthy();

  // "Open full" link should be present.
  await expect(page.getByText("Open full ↗")).toBeVisible();

  await page.screenshot({ path: "test-results/signalloom-rbac-analysis.png", fullPage: true });
});

test("expired token on refreshed page forwards to login or refreshes in background", async ({ page }) => {
  // 1. Initial login through Dex
  await loginExpectingDex(page);
  await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({ timeout: 15_000 });

  // 2. Simulate 24h token expiry by backdating expires_at in localStorage
  const modified = await page.evaluate(() => {
    let count = 0;
    for (const key of Object.keys(localStorage)) {
      if (key.startsWith("oidc.user:")) {
        try {
          const item = JSON.parse(localStorage.getItem(key) || "{}");
          // Fast-forward expiration to 24h in the past (86400 seconds)
          item.expires_at = Math.floor(Date.now() / 1000) - 86400;
          localStorage.setItem(key, JSON.stringify(item));
          count++;
        } catch {
          // ignore unparseable keys
        }
      }
    }
    return count;
  });
  expect(modified, "expected at least one oidc.user session key in localStorage").toBeGreaterThan(0);

  // 3. Reload the page with the expired token in localStorage
  await page.reload({ waitUntil: "domcontentloaded" });

  // 4. Either token is refreshed in the background and user stays in dashboard,
  //    or user is forwarded to the Dex login page.
  //    In Signal Loom dashboard (automaticSilentRenew=false), AutoSignIn redirects to /dex/auth
  const loginInput = page.locator('input[name="login"]');
  const dashboardLink = page.getByRole("link", { name: "Agents", exact: true });

  await Promise.race([
    loginInput.waitFor({ state: "visible", timeout: 20_000 }),
    dashboardLink.waitFor({ state: "visible", timeout: 20_000 }),
  ]);

  const isLoginVisible = await loginInput.isVisible();
  const isDashboardVisible = await dashboardLink.isVisible();

  if (isLoginVisible) {
    // User was forwarded to login page
    expect(page.url()).toContain("/dex/auth");
    await page.screenshot({ path: "test-results/signalloom-expired-token-redirect.png", fullPage: true });

    // Verify re-login restores session
    await loginInput.fill(config.user);
    await page.locator('input[name="password"]').fill(config.pass);
    await Promise.all([
      page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
      page.getByRole("button", { name: /login|sign in|submit/i }).click(),
    ]);
    await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({ timeout: 15_000 });
  } else {
    // Token was refreshed in the background
    expect(isDashboardVisible).toBe(true);
    const freshExpiry = await page.evaluate(() => {
      for (const key of Object.keys(localStorage)) {
        if (key.startsWith("oidc.user:")) {
          const item = JSON.parse(localStorage.getItem(key) || "{}");
          return item.expires_at;
        }
      }
      return 0;
    });
    expect(freshExpiry).toBeGreaterThan(Math.floor(Date.now() / 1000));
    await page.screenshot({ path: "test-results/signalloom-token-background-refreshed.png", fullPage: true });
  }
});

test("invalid token on refreshed page triggers unauthorized redirect to login", async ({ page }) => {
  await loginExpectingDex(page);
  await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({ timeout: 15_000 });

  // Corrupt the token and backdate expiry in localStorage
  await page.evaluate(() => {
    for (const key of Object.keys(localStorage)) {
      if (key.startsWith("oidc.user:")) {
        const item = JSON.parse(localStorage.getItem(key) || "{}");
        item.access_token = "invalid-corrupted-token-signature";
        item.id_token = "invalid-corrupted-token-signature";
        item.expires_at = Math.floor(Date.now() / 1000) - 3600;
        localStorage.setItem(key, JSON.stringify(item));
      }
    }
  });

  // Reload page
  await page.reload({ waitUntil: "domcontentloaded" });

  // Expect redirect to Dex login
  const loginInput = page.locator('input[name="login"]');
  await expect(loginInput).toBeVisible({ timeout: 20_000 });
  expect(page.url()).toContain("/dex/auth");
  await page.screenshot({ path: "test-results/signalloom-invalid-token-redirect.png", fullPage: true });
});

