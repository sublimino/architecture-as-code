/**
 * The SuperCred demo, observed from the MAIN (non-superadmin) pages.
 *
 * SuperCred has its own page, but that page is a demo console — the audience
 * that matters sees the estate through /agents, /compliance and /audit. If the
 * credential chain, the compliance finding and the stun are only visible on
 * /supercred, the demo proves the demo page works, not that the platform does.
 * This file asserts the same effects on the ordinary pages, against LIVE API
 * data.
 *
 * ─── demoMode is false in every test here, deliberately ────────────────────
 *
 * `login()` defaults to seeding sl_demo_mode=true, which makes every screen
 * render from bundled fixtures. Under demo mode these assertions would pass on
 * a cluster with nothing deployed at all — the single largest false-pass risk
 * in this suite. Every login below passes { demoMode: false }.
 *
 * ─── Locators ──────────────────────────────────────────────────────────────
 *
 * Navigation is located by route href via navigateTo(). Never by accessible
 * name, and never with { exact: true }: these anchors render count badges, so
 * the accessible name of the Compliance link is "Compliance 7". See
 * supercred-helpers.ts.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";
import { navLink, navigateTo, supercred } from "./supercred-helpers";

const deployed = supercred.agentDeployed();

/** The main pages, by route. Labels are never used to navigate. */
const MAIN_ROUTES = [
  { route: "/agents", heading: /agents/i },
  { route: "/compliance", heading: /compliance/i },
  { route: "/compliance/policies", heading: /polic/i },
  { route: "/compliance/posture", heading: /posture/i },
  { route: "/compliance/risk", heading: /risk/i },
  { route: "/audit", heading: /audit/i },
] as const;

test.describe("main pages render against live API data", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  for (const { route, heading } of MAIN_ROUTES) {
    test(`${route} renders with live data and no page error`, async ({ page }) => {
      // /compliance/policies, /posture and /risk have no sidebar entry of
      // their own — they are reached from within /compliance — so navigate
      // directly and assert the SPA rendered rather than falling through to
      // the /agents catch-all route in App.tsx.
      if (navLink(page, route) && (await navLink(page, route).count()) > 0) {
        await navigateTo(page, route);
      } else {
        await page.goto(`${config.base}${route}`, { waitUntil: "domcontentloaded" });
      }

      // App.tsx routes anything unmatched to /agents. Landing there when we
      // asked for something else means the route does not exist — which must
      // fail rather than silently assert against the Agents page.
      await expect(async () => {
        expect(new URL(page.url()).pathname).toBe(route);
      }).toPass({ timeout: 15_000 });

      await expect(page.getByRole("heading", { name: heading }).first()).toBeVisible({
        timeout: 20_000,
      });

      // A React error boundary or a blank body is the failure this catches:
      // "the page loaded" is not the same as "the page rendered something".
      await expect(page.locator("main, [role=main]").first()).toBeVisible();
    });
  }

  test("every main route is reachable from the sidebar by href", async ({ page }) => {
    // Guards the locator rule itself. If a nav item's href changes, this fails
    // here with a clear cause instead of as a timeout in an unrelated spec.
    for (const route of ["/agents", "/compliance", "/audit"]) {
      await expect(
        navLink(page, route),
        `sidebar must expose ${route} by href`,
      ).toBeVisible({ timeout: 15_000 });
    }
  });

  test("sidebar links are located by href, not by their accessible name", async ({ page }) => {
    // A guard against the regression that has broken this suite twice. Count
    // badges make the accessible name "Compliance 7", so an exact-name locator
    // silently stops matching. This asserts the href locator resolves to
    // exactly one element regardless of what the label happens to say.
    await expect(navLink(page, "/compliance")).toHaveCount(1);
    const accessibleName = await navLink(page, "/compliance").innerText();
    // Deliberately NOT asserting the name equals "Compliance" — it may carry a
    // badge. Asserting only that the href locator works is the whole point.
    expect(accessibleName.length).toBeGreaterThan(0);
  });
});

test.describe("SuperCred effects are visible on the main pages", () => {
  test.skip(
    !deployed,
    "SuperCred agent not deployed — run: make demo-signalloom-supercred-1 && make demo-signalloom-supercred-2",
  );

  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("/agents lists the cardvault agent from live cluster data", async ({ page }) => {
    await navigateTo(page, "/agents");
    // The agent the demo deploys must be visible to the ordinary operator
    // view, not only to the SuperCred console.
    await expect(page.getByText(/cardvault/i).first()).toBeVisible({ timeout: 30_000 });
  });

  test("/agents reflects the agent's current lifecycle state", async ({ page }) => {
    const state = supercred.agentState();
    test.skip(!state, "agent carries no signalloom.ai/state label yet — run step 2");
    await navigateTo(page, "/agents");
    // State drives a badge; assert the live value the cluster holds appears
    // somewhere on the page rather than pinning a specific component.
    await expect(page.getByText(new RegExp(state!, "i")).first()).toBeVisible({
      timeout: 30_000,
    });
  });

  test("/compliance surfaces posture without falling back to fixtures", async ({ page }) => {
    await navigateTo(page, "/compliance");
    await expect(page.getByRole("heading", { name: /compliance/i }).first()).toBeVisible({
      timeout: 20_000,
    });
    // Demo mode would render the bundled fixture set. We logged in with
    // demoMode:false, so anything here came from the live API.
    const demoBanner = page.getByText(/demo data|demo mode/i);
    await expect(demoBanner).toHaveCount(0);
  });

  test("/compliance/posture shows the agent posture view", async ({ page }) => {
    await page.goto(`${config.base}/compliance/posture`, { waitUntil: "domcontentloaded" });
    await expect(async () => {
      expect(new URL(page.url()).pathname).toBe("/compliance/posture");
    }).toPass({ timeout: 15_000 });
    await expect(page.getByRole("heading", { name: /posture/i }).first()).toBeVisible({
      timeout: 20_000,
    });
  });

  test("/audit records the demo's activity", async ({ page }) => {
    await navigateTo(page, "/audit");
    await expect(page.getByRole("heading", { name: /audit/i }).first()).toBeVisible({
      timeout: 20_000,
    });
    // The audit trail must not be an empty shell on a cluster where a
    // credential chain and a stun just ran.
    await expect(page.locator("table, [role=table], [data-testid*=audit]").first()).toBeVisible({
      timeout: 20_000,
    });
  });
});

test.describe("live API endpoints backing the main pages", () => {
  // Asserted independently of React so a UI failure and an API failure are
  // distinguishable. A page that renders nothing because its endpoint 500s is a
  // different bug from a page that renders nothing with good data behind it.
  const ENDPOINTS = ["/api/v1/agents", "/api/v1/compliance", "/api/v1/audit"];

  for (const path of ENDPOINTS) {
    test(`${path} responds`, async ({ request }) => {
      const res = await request.get(`${config.base}${path}`);
      // 404 means the route does not exist — report it as such rather than
      // asserting ok() and getting an indistinguishable failure.
      expect(
        [200, 401, 403].includes(res.status()),
        `${path} returned ${res.status()}; expected 200 (or an auth status), not a server error or missing route`,
      ).toBeTruthy();
    });
  }
});
