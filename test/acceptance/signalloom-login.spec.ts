import { expect, test } from "@playwright/test";
import {
  loginExpectingDex,
  config,
  recordApiCalls,
  expectApiRecovered,
  waitForAuthLanding,
} from "./helpers";

test("user logs in with user/pass and sees the Signal Loom dashboard", async ({ page }) => {
  const calls = recordApiCalls(page);

  await loginExpectingDex(page);

  // The user-visible outcome first: the authenticated shell rendered. A session
  // whose providers took a transient 401 still lands here, which is the whole
  // reason expectApiRecovered tolerates a recovered 4xx.
  await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({
    timeout: 15_000,
  });

  await page.screenshot({ path: "test-results/signalloom-login.png", fullPage: true });
  expectApiRecovered(calls);
});

test("user can log out and is returned to the Dex login page", async ({ page }) => {
  await loginExpectingDex(page);

  // Click the sign-out button in the sidebar.
  await page.getByTitle("Sign out").click();

  // After logout the dashboard either lands on /login (the signed-out page, whose
  // "Sign in with Dex" button must be clicked) or AutoSignIn redirects straight to
  // Dex. isVisible() does not wait, so an immediate probe lost that race whenever
  // the signed-out page was still rendering; wait for whichever appears first.
  const dexBtn = page.getByRole("button", { name: /sign in with dex/i });
  const loginInput = page.locator('input[name="login"]');
  await expect(dexBtn.or(loginInput).first()).toBeVisible({ timeout: 15_000 });
  if (await dexBtn.isVisible()) {
    await dexBtn.click();
  }
  await expect(loginInput).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");

  await page.screenshot({ path: "test-results/signalloom-logout.png", fullPage: true });
});

test("full login → logout → re-login cycle works without errors", async ({ page }) => {
  const calls = recordApiCalls(page);

  // First login.
  await loginExpectingDex(page);

  // Logout. Same race as the logout test above: wait for whichever of the
  // signed-out page's button or the Dex form appears first.
  await page.getByTitle("Sign out").click();
  const dexBtn = page.getByRole("button", { name: /sign in with dex/i });
  const loginInput = page.locator('input[name="login"]');
  await expect(dexBtn.or(loginInput).first()).toBeVisible({ timeout: 15_000 });
  if (await dexBtn.isVisible()) {
    await dexBtn.click();
  }
  await expect(loginInput).toBeVisible({ timeout: 15_000 });

  // Re-login - proves the session was fully cleared and a fresh login works.
  await loginExpectingDex(page);

  await page.screenshot({ path: "test-results/signalloom-relogin.png", fullPage: true });
  expectApiRecovered(calls);
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
  // The expired/corrupted-token transition sits on a "Signing in" spinner while
  // the OIDC client retries, and completed between 20s and 45s when measured on
  // 2026-10-13. The 30s project default fired mid-transition and reported a
  // redirect that was slow, not broken.
  test.setTimeout(120_000);

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

  // The spinner phase is the point of this test, so give the transition the
  // budget it actually needs rather than failing it mid-flight at 20s.
  const { landing } = await waitForAuthLanding(page);
  const isLoginVisible = landing === "dex-login";
  const isDashboardVisible = landing === "dashboard";

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
  // The expired/corrupted-token transition sits on a "Signing in" spinner while
  // the OIDC client retries, and completed between 20s and 45s when measured on
  // 2026-10-13. The 30s project default fired mid-transition and reported a
  // redirect that was slow, not broken.
  test.setTimeout(120_000);

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

  // A corrupted token must never leave the user on the spinner. The only
  // acceptable landing is the Dex login form: unlike an expired token there is
  // nothing to silently renew, so staying in the shell would mean the dashboard
  // kept a session it cannot authenticate.
  const { landing } = await waitForAuthLanding(page);
  expect(landing, "a corrupted token must forward to the Dex login form").toBe("dex-login");
  expect(page.url()).toContain("/dex/auth");
  await page.screenshot({ path: "test-results/signalloom-invalid-token-redirect.png", fullPage: true });
});

