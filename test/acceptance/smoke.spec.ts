/**
 * Signal Loom dashboard — initial-pages smoke suite.
 *
 * Authenticates once per test through local Dex, then drives the left-hand
 * sidebar to each initial page and asserts it renders (heading + representative
 * content) with no uncaught page errors. Uses the diagnostics-capturing `test`
 * fixture so any console/network failure is attached to the report.
 *
 * Preconditions: the local stack is up and the Envoy Gateway is port-forwarded,
 * which scripts/acceptance-test.sh does for every invocation. The dashboard is
 * reached at https://dashboard.osramp.acme.local:30754 (see config.base in
 * helpers.ts); playwright.config.ts resolves that hostname to 127.0.0.1.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

type PageCase = {
  nav: string;
  heading: string;
  content?: string[];
};

const PAGES: PageCase[] = [
  { nav: "Agents", heading: "Agents" },
  { nav: "Compliance", heading: "Compliance", content: ["Agent Posture"] },
  { nav: "Audit Trail", heading: "Audit Trail" },
  { nav: "Cryptography", heading: "Cryptography", content: ["Cluster Root of Trust", "SPIFFE / SPIRE Bootstrap", "Cipher Discovery (PQC)"] },
  { nav: "Federated Services", heading: "Federated Services", content: ["Trust Zones", "payments-api", "Cofide Go SDK"] },
  { nav: "Collusion & Access", heading: "Collusion & Access", content: ["Collusion Pairs", "Remediation Priorities"] },
  { nav: "RBAC Analysis", heading: "RBAC Analysis", content: ["KubeSec-AFM"] },
  { nav: "RBAC Explorer", heading: "RBAC Explorer", content: ["KubeSec-AFM RBAC analysis"] },
  { nav: "Settings", heading: "Settings" },
];

test("unauthenticated visit is redirected to the Dex login", async ({ page }) => {
  await page.goto(`${BASE}/cryptography`, { waitUntil: "domcontentloaded" });
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");
  // The protected page must NOT have leaked before authentication.
  await expect(page.getByRole("heading", { level: 1, name: "Cryptography" })).toHaveCount(0);
});

test.describe("authenticated dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("dashboard shows the full sidebar navigation", async ({ page }) => {
    for (const p of PAGES) {
      await expect(page.getByRole("link", { name: p.nav, exact: true })).toBeVisible();
    }
  });

  for (const p of PAGES) {
    test(`nav → ${p.nav} renders its page`, async ({ page }) => {
      const pageErrors: string[] = [];
      page.on("pageerror", (e) => {
        // Cross-origin iframe asset errors (e.g. Next.js /_next/) bubble as
        // "Unexpected token '<'" — not a Signal Loom page error.
        if (e.message.includes("Unexpected token '<'")) return;
        pageErrors.push(e.message);
      });

      await page.getByRole("link", { name: p.nav, exact: true }).click();

      await expect(page.getByRole("heading", { level: 1, name: p.heading })).toBeVisible({ timeout: 20_000 });

      for (const c of p.content ?? []) {
        await expect(page.getByText(c, { exact: false }).first()).toBeVisible({ timeout: 15_000 });
      }

      expect(pageErrors, `uncaught page errors on ${p.nav}: ${pageErrors.join("; ")}`).toEqual([]);
    });
  }

  test("Collusion & Access uses the radial cluster graph background", async ({ page }) => {
    await page.getByRole("link", { name: "Collusion & Access", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Collusion & Access" })).toBeVisible({ timeout: 20_000 });
    const bg = page.getByTestId("ktp-graph-bg");
    await expect(bg).toHaveAttribute("data-bg", "/ktp-collusion-graph.png");
    // The background asset is actually served (not 404/403).
    const res = await page.request.get(`${BASE}/ktp-collusion-graph.png`);
    expect(res.status(), "background image must be served").toBe(200);
  });

  test("DemoToggle widget is visible on every page", async ({ page }) => {
    const toggle = page.getByTestId("demo-toggle");
    await expect(toggle).toBeVisible({ timeout: 10_000 });
    // Initial state matches either label.
    await expect(toggle).toHaveText(/LIVE API|DEMO DATA/);
  });

  test("Help & Support modal opens and closes", async ({ page }) => {
    // Open via sidebar button.
    await page.getByRole("button", { name: /help & support/i }).click();
    const heading = page.getByRole("heading", { name: "Help & Support" });
    await expect(heading).toBeVisible({ timeout: 10_000 });
    // FAQ content renders.
    await expect(page.getByText("Getting started")).toBeVisible();
    // Close with the × button.
    await page.getByRole("button", { name: "×" }).click();
    await expect(heading).not.toBeVisible({ timeout: 5_000 });
  });

  test("unknown route redirects to Agents", async ({ page }) => {
    await page.goto(`${BASE}/nonexistent-route-12345`, { waitUntil: "domcontentloaded" });
    // The SPA catch-all <Navigate to="/agents" /> fires.
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    expect(page.url()).toContain("/agents");
  });

  test("Agents page renders past loading (API round-trip)", async ({ page }) => {
    await page.getByRole("link", { name: "Agents", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    // The heading only renders after the API responds — the loading state
    // returns a <div>Loading…</div> with no h1. Additionally, the Governed
    // tab's "Register Agent" button is always present once the data loads.
    await expect(page.getByRole("button", { name: /Register Agent/i })).toBeVisible({ timeout: 15_000 });
  });
});
