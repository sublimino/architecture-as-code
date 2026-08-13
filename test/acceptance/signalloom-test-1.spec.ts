import { expect, test } from "./fixtures";

// CI/local-kind default: Gateway port-forwarded to :30754 via host-resolver-rules (resolves
// to 127.0.0.1 anywhere). Matches Dex issuer + redirect URI + auth.setup.ts.
const DASHBOARD_URL =
  process.env.DASHBOARD_URL ?? "https://dashboard.osramp.acme.local:30754";
const API_URL = process.env.SIGNALLOOM_API_URL ?? DASHBOARD_URL;
const DEX_URL = process.env.SIGNALLOOM_DEX_URL ?? "http://127.0.0.1:15556";
const DEX_DEMO_PASSWORD = process.env.DEX_DEMO_PASSWORD ?? "demo-user";

test.setTimeout(Number(process.env.SIGNALLOOM_TEST_TIMEOUT ?? 30_000));

// Nav links are located by route href, not by link label. The sidebar renders
// both "Compliance" (/compliance) and "Policy Compliance" (/compliance/policies),
// so a label lookup is ambiguous under Playwright's substring name matching.
// Href is also stable against the failing-control and agent-count badges that
// render inside the Compliance and Agents links, which change the accessible
// name to "Compliance 7" / "Agents 12" whenever those counts are non-zero.
// Each journey is [name, href, h1, bodyMarker?].
//
// The h1 is asserted by role, NOT with getByText, and that distinction is the
// whole point of this matrix. Until now every marker here was a bare
// getByText(title).first(), and for seven of the eight journeys the title was
// ALSO the sidebar's own label for that route — "Compliance", "Audit Trail",
// "Cryptography", "Federated Services", "Collusion", "Settings", and "Agents"
// for the root. getByText matches the whole document, the sidebar renders on
// every route, and .first() takes whatever comes earliest in the DOM, which is
// the nav link. Those seven assertions therefore passed whenever the sidebar
// rendered — including when the route body rendered nothing at all, and
// including when the app had redirected away from the route under test
// entirely. They could not fail. Only the Agents journey, whose marker lives
// solely in page content, was capable of catching the onboarding-gate
// regression, and it was the only one that did.
//
// A heading lookup closes that hole without inventing per-page markers. Nav
// links are links, not headings, so the sidebar cannot satisfy it; and the
// onboarding wizard — the specific thing that used to hide behind these
// assertions — has its own h1 of "Welcome to Signal Loom", so a gated route
// now fails here instead of passing on the strength of the sidebar.
//
// bodyMarker is for content that proves the page did more than print its
// title. Only /agents carries one today: "Register Agent" is a real control
// rendered by GovernedTab's toolbar, so it is absent whenever the tab is
// showing its loading or error state rather than the governed list.
const pages = [
  ["Dashboard root", null, "Agents", "Register Agent"],
  ["Agents", "/agents", "Agents", "Register Agent"],
  ["Compliance", "/compliance", "Compliance"],
  ["Audit Trail", "/audit", "Audit Trail"],
  ["Cryptography", "/cryptography", "Cryptography"],
  ["Federated Services", "/federated-services", "Federated Services"],
  ["Collusion & Access", "/collusion-access", "Collusion & Access"],
  ["Settings", "/settings", "Settings"],
] as const;

test.describe("SignalLoom TEST-1 dashboard matrix", () => {
  for (const [journey, href, h1, bodyMarker] of pages) {
    test(`${journey} opens through the integrated dashboard`, async ({ page }) => {
      await page.goto(DASHBOARD_URL);
      // The sidebar is the readiness signal here and nothing more — it says the
      // SPA has authenticated and mounted. It deliberately does NOT stand in for
      // the route body, which is what the h1 below is for.
      await expect(page.locator("nav a[href='/agents']")).toBeVisible({ timeout: 10_000 });
      // Onboarding is dismissed once in auth.setup.ts, before storageState is
      // captured, so by here the gate is already suppressed for every journey.
      // This stays as a fallback for a context that somehow arrives without it,
      // but it must not be relied on: isVisible() is an instantaneous check and
      // "Skip for now" renders ~470ms after the gate above resolves, so on a
      // gated context it reads false and does nothing. That race is exactly how
      // the onboarding redirect went unnoticed.
      const skipOnboarding = page.getByRole("button", { name: "Skip for now" });
      if (await skipOnboarding.isVisible().catch(() => false)) {
        await skipOnboarding.click();
      }
      if (href !== null) {
        // Locate by href, NOT by accessible name with exact:true.
        //
        // Both approaches disambiguate "Compliance" from the newer "Policy
        // Compliance" sidebar link today, but exact:true is a trap: the
        // Compliance and Agents links render failing-control and agent-count
        // badges inside them, so the accessible name becomes "Compliance 7" /
        // "Agents 12" the moment those counts are non-zero — and an exact
        // match then silently stops matching. Href is stable against both.
        await page.locator(`nav a[href="${href}"]`).click();
      }
      await expect(page.getByRole("heading", { level: 1, name: h1 })).toBeVisible();
      if (bodyMarker !== undefined) {
        await expect(page.getByText(bodyMarker, { exact: false }).first()).toBeVisible();
      }
    });
  }

});

test.describe("SignalLoom TEST-1 Dex and API contracts", () => {
  test("Dex login token maps demo user to local tenant", async ({ page, request }) => {
    // The auth.setup project already authenticated via Dex. This test verifies
    // the resulting token is accepted by the API and returns agent data for the
    // demo tenant.
    //
    // The token lives in sessionStorage, not localStorage: this surface is
    // shared as a public demo link, and a localStorage token outlived the
    // browser, so the next person to open it inherited the previous session
    // (dashboard-signalloom/src/auth/oidc.tsx). localStorage is still checked
    // as a fallback so the assertion is about the API accepting the token, not
    // about which store it came from.
    await page.goto(DASHBOARD_URL);
    await page.waitForURL(/\/agents/, { timeout: 15_000 });

    const idToken = await page.evaluate(() => {
      for (const store of [sessionStorage, localStorage]) {
        for (const [key, value] of Object.entries(store)) {
          if (key.startsWith("oidc.user:")) {
            try { return JSON.parse(value as string).id_token; } catch { /* skip */ }
          }
        }
      }
      return null;
    });
    expect(idToken).toBeTruthy();

    // Verify the token is accepted by the API (200, not 401).
    const api = await request.get(`${API_URL}/api/agents`, {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    expect(api.status()).toBe(200);
  });

  test("dashboard sign out clears the session and redirects to Dex", async ({ page }) => {
    await page.goto(DASHBOARD_URL);
    await page.locator('button[title="Sign out"]').click();
    await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  });

});
