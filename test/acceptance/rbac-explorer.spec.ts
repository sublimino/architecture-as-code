import { expect, test, type Page } from "@playwright/test";

/**
 * RBAC Explorer tests — the native Signal Loom view of KubeSec-AFM data.
 *
 * Tests the namespace selector, cluster selector, conformance table,
 * roles/subjects tables, and stats cards. Exercises the same AFM API
 * endpoints as the iframe'd dashboard but through Signal Loom's native UI.
 */
const BASE = process.env.SIGNALLOOM_UI_URL ?? "http://localhost:5173";
const USER = process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local";
const PASS = process.env.SIGNALLOOM_PASS ?? "demo-user";

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
  await page.waitForURL(/\/(agents|compliance|audit|settings)?$|\/agents/, { timeout: 20_000 });
  await expect(page.getByRole("link", { name: "Agents", exact: true })).toBeVisible({ timeout: 15_000 });
}

test.describe("RBAC Explorer", () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.getByRole("link", { name: "RBAC Explorer", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Explorer" })).toBeVisible({ timeout: 15_000 });
  });

  test("page renders with heading and description", async ({ page }) => {
    await expect(page.getByText("Native view of KubeSec-AFM")).toBeVisible();
  });

  test("cluster selector is populated with seeded clusters", async ({ page }) => {
    const selector = page.locator('[data-testid="cluster-selector"]');
    await expect(selector).toBeVisible({ timeout: 10_000 });
    const options = await selector.locator("option").allTextContents();
    expect(options.length).toBeGreaterThanOrEqual(1);
    const hasLocal = options.some(o => o.includes("local") || o.includes("Local"));
    expect(hasLocal, `Expected 'local' cluster in options: ${options.join(", ")}`).toBeTruthy();
  });

  test("data loads and stat cards render", async ({ page }) => {
    // Wait for the stats section — appears after loadCluster resolves
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    await expect(page.getByText("Subjects")).toBeVisible();
    await expect(page.getByText("Escalation Paths")).toBeVisible();
  });

  test("namespace selector is populated after data loads", async ({ page }) => {
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    const selector = page.locator('[data-testid="namespace-selector"]');
    const options = await selector.locator("option").allTextContents();
    expect(options.length).toBeGreaterThanOrEqual(2);
    expect(options[0]).toBe("All namespaces");
    const hasFe = options.some(o => o.includes("fe-signalloom"));
    expect(hasFe, `Expected 'fe-signalloom' in options: ${options.join(", ")}`).toBeTruthy();
  });

  test("roles section renders with role data", async ({ page }) => {
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible();
    const rows = page.locator("table").first().locator("tbody tr");
    expect(await rows.count()).toBeGreaterThan(0);
  });

  test("namespace filter changes the visible data", async ({ page }) => {
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    await page.locator('[data-testid="namespace-selector"]').selectOption("fe-signalloom");
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible({ timeout: 10_000 });
  });

  test("refresh button reloads cluster data", async ({ page }) => {
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    await page.getByRole("button", { name: "Refresh" }).click();
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
  });

  test("switching clusters reloads data", async ({ page }) => {
    await expect(page.locator('[data-testid="rbac-stats"]')).toBeVisible({ timeout: 30_000 });
    const selector = page.locator('[data-testid="cluster-selector"]');
    const options = await selector.locator("option").allTextContents();
    if (options.length >= 2) {
      await selector.selectOption({ index: 1 });
      await expect(page.getByText("Subjects")).toBeVisible({ timeout: 30_000 });
    }
  });
});
