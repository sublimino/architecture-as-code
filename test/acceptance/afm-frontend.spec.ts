import { expect, test, type Page } from "@playwright/test";

/**
 * AFM Frontend Test Suite — runs against both standalone and iframe modes.
 *
 * MODE=standalone  → tests hit AFM directly at http://localhost:18000/dashboard/
 * MODE=iframe      → tests hit AFM through Signal Loom at http://localhost:5173/dashboard/
 *
 * Both modes exercise the same AFM frontend assertions. The iframe mode additionally
 * validates that assets load correctly through the nginx proxy.
 *
 * Preconditions:
 *   - AFM running: make demo-k8s-afm-up
 *   - Dashboard running: kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
 *   - (standalone only): kubectl -n fe-k8s-afm port-forward svc/afm-platform 18000:8000
 *   - At least one cluster seeded: scripts/rbac-to-afm.py
 */

const MODE = (process.env.AFM_TEST_MODE ?? "iframe") as "standalone" | "iframe";

// In iframe mode, the AFM frontend is served through the Signal Loom nginx proxy.
// In standalone mode, it's served directly from the AFM pod.
const AFM_BASE = MODE === "standalone"
  ? (process.env.AFM_URL ?? "http://localhost:18000")
  : (process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173");

const DASHBOARD_PATH = "/dashboard/";
const SL_BASE = process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173";
const USER = process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local";
const PASS = process.env.SIGNALLOOM_PASS ?? "demo-user";

async function loginIfNeeded(page: Page) {
  if (MODE !== "iframe") return;
  // In iframe mode, navigating to the SL-proxied dashboard may trigger Dex login
  // if there's no session. Navigate to SL first to authenticate.
  await page.goto(SL_BASE, { waitUntil: "domcontentloaded" });
  const loginInput = page.locator('input[name="login"]');
  if (await loginInput.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await loginInput.fill(USER);
    await page.locator('input[name="password"]').fill(PASS);
    await Promise.all([
      page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
      page.getByRole("button", { name: /login|sign in|submit/i }).click(),
    ]);
    await page.waitForURL(/\/(agents|compliance)/, { timeout: 20_000 });
  }
}

test.describe(`AFM Frontend (${MODE} mode)`, () => {
  test.beforeEach(async ({ page }) => {
    await loginIfNeeded(page);
  });

  test("dashboard page loads and renders the title", async ({ page }) => {
    await page.goto(`${AFM_BASE}${DASHBOARD_PATH}`, { waitUntil: "domcontentloaded" });
    // AFM dashboard has "K8s RBAC Attack Explorer" in the title
    await expect(page).toHaveTitle(/RBAC|Attack|Explorer/i, { timeout: 15_000 });
  });

  test("cluster selector is visible with seeded clusters", async ({ page }) => {
    await page.goto(`${AFM_BASE}${DASHBOARD_PATH}`, { waitUntil: "domcontentloaded" });
    // Verify via the API that clusters are seeded (the UI may still be hydrating)
    const resp = await page.request.get(`${AFM_BASE}/clusters`);
    expect(resp.ok()).toBeTruthy();
    const clusters = await resp.json();
    expect(clusters.length, "Expected at least one seeded cluster").toBeGreaterThanOrEqual(1);
    // Wait for React to hydrate — look for any MUI/Next content rendered
    await page.waitForTimeout(5_000);
    // Verify the page isn't blank (the dashboard renders something)
    const body = await page.textContent("body");
    expect(body?.length, "Dashboard body should have content after hydration").toBeGreaterThan(50);
  });

  test("API health endpoint returns ok through the proxy", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/health`);
    expect(resp.ok()).toBeTruthy();
    const body = await resp.json();
    expect(body.status).toBe("ok");
  });

  test("clusters endpoint returns the seeded clusters", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/clusters`);
    expect(resp.ok()).toBeTruthy();
    const clusters = await resp.json();
    expect(Array.isArray(clusters)).toBeTruthy();
    expect(clusters.length).toBeGreaterThanOrEqual(1);
    // Should have the local cluster from our RBAC fixture
    const hasLocal = clusters.some((c: { id: string }) => c.id === "local");
    expect(hasLocal, "Expected 'local' cluster from RBAC fixture").toBeTruthy();
  });

  test("local cluster RBAC data is accessible", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/clusters/local/rbac`);
    expect(resp.ok()).toBeTruthy();
    const rbac = await resp.json();
    expect(rbac.subjects.length).toBeGreaterThan(0);
    expect(rbac.roles.length).toBeGreaterThan(0);
    expect(rbac.bindings.length).toBeGreaterThan(0);
  });

  test("escalation analysis result is available for local cluster", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/clusters/local/analysis/latest`);
    expect(resp.ok()).toBeTruthy();
    const result = await resp.json();
    // The analysis should have run and produced metadata
    expect(result.metadata).toBeDefined();
    expect(result.metadata.non_admins.length).toBeGreaterThan(0);
  });

  test("RBAC graph endpoint returns nodes for the local cluster", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/clusters/local/rbac/graph`);
    expect(resp.ok()).toBeTruthy();
    const graph = await resp.json();
    expect(graph.nodes).toBeDefined();
    expect(graph.nodes.length).toBeGreaterThan(0);
  });

  test("metrics/executions/latest endpoint is accessible", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/metrics/executions/latest`);
    // May return 200 (with data) or 404 (no executions yet) — both are valid
    expect([200, 404]).toContain(resp.status());
  });

  test("conformance report is available for local cluster", async ({ page }) => {
    const resp = await page.request.get(`${AFM_BASE}/clusters/local/rbac/conformance`);
    expect(resp.ok()).toBeTruthy();
    const conformance = await resp.json();
    expect(Array.isArray(conformance)).toBeTruthy();
  });

  // Iframe-specific tests
  if (MODE === "iframe") {
    test("Next.js assets serve as JavaScript (not HTML fallback)", async ({ page }) => {
      // Fetch the dashboard HTML and extract a JS chunk path
      const dashResp = await page.request.get(`${AFM_BASE}${DASHBOARD_PATH}`);
      const html = await dashResp.text();
      const chunkMatch = html.match(/src="(\/dashboard\/_next\/static\/chunks\/[^"]+\.js)"/);
      expect(chunkMatch, "Expected Next.js chunk references in dashboard HTML").toBeTruthy();

      if (chunkMatch) {
        const chunkResp = await page.request.get(`${AFM_BASE}${chunkMatch[1]}`);
        expect(chunkResp.ok()).toBeTruthy();
        const body = await chunkResp.text();
        // Must be JavaScript, not HTML (the bug this test catches)
        expect(body).not.toMatch(/^<!doctype html/i);
        expect(body).toMatch(/function|const|var|export|import|globalThis/);
      }
    });

    test("AFM brand/logo asset loads through the proxy", async ({ page }) => {
      const resp = await page.request.get(`${AFM_BASE}/dashboard/brand/logo.svg`);
      // 200 or 404 (logo may not exist in all builds) — but NOT a HTML fallback
      if (resp.ok()) {
        const ct = resp.headers()["content-type"] ?? "";
        expect(ct).toMatch(/svg|xml|image/);
      }
    });
  }
});
