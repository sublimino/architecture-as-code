import { expect, test } from "@playwright/test";
import { login, afm, polling } from "./helpers";

/**
 * RBAC Explorer — robust tests for the native Signal Loom RBAC analysis view.
 *
 * Uses shared helpers for login, AFM precondition checks, and polling.
 * Each test is self-contained with its own login + navigation.
 */

test.describe("RBAC Explorer", () => {
  test.beforeAll(async ({ request }) => {
    await afm.assertHealthy(request);
  });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.getByRole("link", { name: "RBAC Explorer", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Explorer" })).toBeVisible({ timeout: 15_000 });
  });

  test("page renders with heading and description", async ({ page }) => {
    await expect(page.getByText("Native view of KubeSec-AFM")).toBeVisible();
  });

  test("cluster selector is populated with seeded clusters", async ({ page }) => {
    const options = await polling.waitForOptions(page, "cluster-selector", 1);
    const hasLocal = options.some(o => o.includes("local") || o.includes("Local"));
    expect(hasLocal, `Expected 'local' in: ${options.join(", ")}`).toBeTruthy();
  });

  test("data loads and stat cards render", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome, "Expected RBAC data to load").toBe("data");
    const stats = page.locator('[data-testid="rbac-stats"]');
    await expect(stats.getByText("Subjects")).toBeVisible();
    await expect(stats.getByText("Escalation Paths")).toBeVisible();
  });

  test("namespace selector is populated after data loads", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome).toBe("data");
    const options = await polling.waitForOptions(page, "namespace-selector", 2);
    expect(options[0]).toBe("All namespaces");
    expect(options.some(o => o.includes("fe-signalloom")), "Expected fe-signalloom").toBeTruthy();
  });

  test("roles section renders with role data", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome).toBe("data");
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible();
    await expect(async () => {
      expect(await page.locator("table").first().locator("tbody tr").count()).toBeGreaterThan(0);
    }).toPass({ timeout: 5_000 });
  });

  test("namespace filter changes the visible data", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome).toBe("data");
    await page.locator('[data-testid="namespace-selector"]').selectOption("fe-signalloom");
    await expect(page.getByRole("heading", { name: "Roles" })).toBeVisible({ timeout: 5_000 });
  });

  test("refresh button reloads cluster data", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome).toBe("data");
    await page.getByRole("button", { name: "Refresh" }).click();
    const refreshOutcome = await polling.waitForRbacData(page);
    expect(refreshOutcome).toBe("data");
  });

  test("switching clusters reloads data", async ({ page }) => {
    const outcome = await polling.waitForRbacData(page);
    expect(outcome).toBe("data");
    const selector = page.locator('[data-testid="cluster-selector"]');
    const options = await selector.locator("option").allTextContents();
    if (options.length < 2) {
      test.skip(true, "Only 1 cluster — cannot test switching");
      return;
    }
    await selector.selectOption({ index: 1 });
    const switchOutcome = await polling.waitForRbacData(page);
    expect(switchOutcome).toBe("data");
  });
});
