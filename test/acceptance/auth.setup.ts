import { writeFileSync } from "node:fs";
import { test as setup, expect } from "@playwright/test";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "https://dashboard.osramp.acme.local:30754";
const DEX_DEMO_PASSWORD = process.env.DEX_DEMO_PASSWORD ?? "demo-user";

setup("authenticate via Dex", async ({ page }) => {
  // Get to the Dex form, tolerating both the cookie gate and the SPA's own
  // OIDC redirect.
  //
  // Two things sit between goto() and the login form when the dashboard is
  // published through the ngrok tunnel:
  //
  //   1. The gate. A fresh browser's first request returns an interstitial that
  //      sets _sl_gate and meta-refreshes, so goto() resolves on a page with no
  //      form on it.
  //   2. The SPA. Once loaded it starts its own redirect to /dex/auth/local,
  //      which then redirects again to /dex/auth/local/login where the form
  //      actually lives.
  //
  // A single extra goto() raced step 2 — it interrupted the in-flight OIDC
  // redirect and left the page parked on /dex/auth/local with no form, which
  // reports as "element(s) not found" against the login locator and reads like
  // the app is broken rather than like navigation is still in progress.
  //
  // So: give it a chance to settle, and only re-navigate if it has genuinely
  // stalled. Against the local gateway there is no gate and the first attempt
  // succeeds immediately.
  const loginField = page.locator('input[name="login"]');
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt === 0) {
      await page.goto(DASHBOARD_URL);
    } else {
      await page.goto(DASHBOARD_URL, { waitUntil: "domcontentloaded" });
    }
    try {
      await loginField.waitFor({ state: "visible", timeout: 10_000 });
      break;
    } catch {
      /* gate page or mid-redirect — try again */
    }
  }
  await expect(loginField).toBeVisible({ timeout: 20_000 });
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

  // The OIDC token lives in sessionStorage, not localStorage, so that a shared
  // demo link cannot hand the next visitor the previous one's session (see
  // dashboard-signalloom/src/auth/oidc.tsx). Playwright's storageState captures
  // cookies and localStorage only — sessionStorage is per-tab and is NOT in it.
  //
  // Without this the dependent projects load .auth-state.json, find no token,
  // and every journey test lands back on the Dex login page. Observed as 10 of
  // 11 failing the moment the dashboard moved off localStorage.
  //
  // So dump sessionStorage here and let the journey project replay it into each
  // new context before the app boots (see fixtures.ts).
  const sessionState = await page.evaluate(() => JSON.stringify(window.sessionStorage));
  writeFileSync("test-results/.auth-session.json", sessionState);
});
