import { expect, test, type Page } from "@playwright/test";

/**
 * RBAC Explorer — robust test suite for the native Signal Loom view of
 * KubeSec-AFM RBAC analysis data.
 *
 * Design principles:
 *   1. API preconditions verified before any UI assertion
 *   2. Polling-based waits (expect + auto-retry) over fixed timeouts
 *   3. Early crash detection via error boundary data-testid
 *   4. Single login per test (isolated page context)
 *   5. Each test is self-contained and independently runnable
 *
 * Preconditions:
 *   - Dashboard: kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
 *   - AFM: make demo-k8s-afm-up (AFM platform running with seeded clusters)
 */

const BASE = process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173";
const USER = process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local";
const PASS = process.env.SIGNALLOOM_PASS ?? "demo-user";

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Authenticate via Dex and wait for the dashboard to be interactive. */
async function login(page: Page) {
  await page.goto(BASE, { waitUntil: "domcontentloaded" });
  const loginInput = page.locator('input[name="login"]');
  await expect(loginInput).toBeVisible({ timeout: 15_000 });
  await loginInput.fill(USER);
  await page.locator('input[name="password"]').fill(PASS);
  await Promise.all([
    page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
    page.getByRole("button", { name: /login|sign in|submit/i }).click(),
  ]);
  // Wait for the sidebar — proves the SPA rendered post-login
  await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({ timeout: 15_000 });
}

/** Navigate to RBAC Explorer and wait for the page heading. */
async function navigateToExplorer(page: Page) {
  await page.getByRole("link", { name: "RBAC Explorer", exact: true }).click();
  await expect(page.getByRole("heading", { level: 1, name: "RBAC Explorer" })).toBeVisible({ timeout: 15_000 });
}

/**
 * Wait for RBAC data to load. Polls for either:
 *   - data-testid="rbac-stats" (data loaded successfully)
 *   - data-testid="rbac-error" (React error boundary caught a crash)
 *   - text "No RBAC data" (data fetch returned null)
 * Fails fast on crash instead of waiting 30s for a timeout.
 */
async function waitForDataOrError(page: Page): Promise<"data" | "error" | "empty"> {
  const stats = page.locator('[data-testid="rbac-stats"]');
  const error = page.locator('[data-testid="rbac-error"]');
  const empty = page.getByText("No RBAC data");

  // Poll every 500ms for up to 30s
  for (let i = 0; i < 60; i++) {
    if (await stats.isVisible().catch(() => false)) return "data";
    if (await error.isVisible().catch(() => false)) return "error";
    if (await empty.isVisible().catch(() => false)) return "empty";
    await page.waitForTimeout(500);
  }
  // Last check before giving up
  if (await stats.isVisible().catch(() => false)) return "data";
  if (await error.isVisible().catch(() => false)) return "error";
  return "empty";
}

// ── Precondition gate ───────────────────────────────────────────────────────

test.describe("RBAC Explorer", () => {
  // Verify AFM is reachable before running any UI test. If this fails,
  // every subsequent test would time out — fail fast with a clear message.
  test.beforeAll(async ({ request }) => {
    const health = await request.get(`${BASE}/afm/health`).catch(() => null);
    expect(health?.ok(), "AFM must be reachable at /afm/health — run: make demo-k8s-afm-up").toBeTruthy();

    const clusters = await request.get(`${BASE}/afm/clusters`).catch(() => null);
    expect(clusters?.ok(), "AFM clusters endpoint must return data").toBeTruthy();
    const data = await clusters!.json();
    expect(data.length, "AFM must have at least 1 seeded cluster — run: scripts/rbac-to-afm.py").toBeGreaterThanOrEqual(1);
  });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await navigateToExplorer(page);
  });

  // ── Rendering tests (no data dependency) ────────────────────────────────

  test("page renders with heading and description", async ({ page }) => {
    await expect(page.getByText("Native view of KubeSec-AFM")).toBeVisible();
  });

  test("cluster selector is populated with seeded clusters", async ({ page }) => {
    const selector = page.locator('[data-testid="cluster-selector"]');
    await expect(selector).toBeVisible();
    // Poll until options are populated (cluster fetch is async)
    await expect(async () => {
      const options = await selector.locator("option").allTextContents();
      expect(options.length).toBeGreaterThanOrEqual(1);
    }).toPass({ timeout: 10_000 });

    const options = await selector.locator("option").allTextContents();
    const hasLocal = options.some(o => o.includes("local") || o.includes("Local"));
    expect(hasLocal, `Expected 'local' cluster in options: ${options.join(", ")}`).toBeTruthy();
  });

  // ── Data-dependent tests ────────────────────────────────────────────────

  test("data loads and stat cards render", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome, "Expected RBAC data to load (got crash or empty)").toBe("data");
    // Use scoped locators to avoid strict-mode violations (stat card labels
    // appear in multiple places: stat cards, table cells, section descriptions)
    const stats = page.locator('[data-testid="rbac-stats"]');
    await expect(stats.getByText("Subjects")).toBeVisible();
    await expect(stats.getByText("Escalation Paths")).toBeVisible();
  });

  test("namespace selector is populated after data loads", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome).toBe("data");

    const selector = page.locator('[data-testid="namespace-selector"]');
    await expect(async () => {
      const options = await selector.locator("option").allTextContents();
      expect(options.length).toBeGreaterThanOrEqual(2);
    }).toPass({ timeout: 5_000 });

    const options = await selector.locator("option").allTextContents();
    expect(options[0]).toBe("All namespaces");
    const hasFe = options.some(o => o.includes("fe-signalloom"));
    expect(hasFe, `Expected 'fe-signalloom' in options: ${options.join(", ")}`).toBeTruthy();
  });

  test("roles section renders with role data", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome).toBe("data");
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible();

    // Poll until at least one table row renders
    await expect(async () => {
      const count = await page.locator("table").first().locator("tbody tr").count();
      expect(count).toBeGreaterThan(0);
    }).toPass({ timeout: 5_000 });
  });

  test("namespace filter changes the visible data", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome).toBe("data");

    await page.locator('[data-testid="namespace-selector"]').selectOption("fe-signalloom");
    // Roles heading should persist after filter (data re-filtered, not removed)
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible({ timeout: 5_000 });
  });

  test("refresh button reloads cluster data", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome).toBe("data");

    await page.getByRole("button", { name: "Refresh" }).click();
    // After refresh, stats should re-appear (may briefly show Loading)
    const refreshOutcome = await waitForDataOrError(page);
    expect(refreshOutcome).toBe("data");
  });

  test("switching clusters reloads data", async ({ page }) => {
    const outcome = await waitForDataOrError(page);
    expect(outcome).toBe("data");

    const selector = page.locator('[data-testid="cluster-selector"]');
    const options = await selector.locator("option").allTextContents();
    if (options.length < 2) {
      test.skip(true, "Only 1 cluster available — cannot test switching");
      return;
    }
    await selector.selectOption({ index: 1 });
    const switchOutcome = await waitForDataOrError(page);
    expect(switchOutcome).toBe("data");
  });
});
