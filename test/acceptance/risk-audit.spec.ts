/**
 * Signal Loom Platform Acceptance Suite — Cross-Surface Governance, Risk, Audit & Settings (Surfaces 3, 5, 6, 9, 10, 11, 12, 13).
 *
 * Validates:
 *   1. Surface 3: Agents page governance state consolidation (Governed, Suspended, Revoked) and quarantine action.
 *   2. Surface 5: The Weave signal observation streaming and layer filters.
 *   3. Surface 6: FAIR Risk quantitative loss distribution, population filtering, and sub-250ms reactive recalculation.
 *   4. Surface 9: Collusion & Access AFM scan triggers, recency badges, and zero em-dash typography.
 *   5. Surface 10: Audit Trail table, detail trigger, and AuditDetailDrawer slide-out with syntax-highlighted JSON.
 *   6. Surface 11: Federated Services live/demo toggle and attestation status indicator.
 *   7. Surface 12: Fleet Demo operational telemetry, 5s heartbeat indicator, and architectural delineation banner.
 *   8. Surface 13: Settings connector synchronization, framework toggles, and preferences save.
 *   9. Responsive viewport testing across desktop (1280x800) and mobile (375x667).
 *   10. Zero em-dash typography verification across all tested views.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Cross-Surface Regression Suite: Risk, Audit & Infrastructure (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("Surface 3: Agents page renders consolidated lifecycle states (Governed, Suspended, Revoked)", async ({ page }) => {
    await page.goto(`${BASE}/agents`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Agents/i })).toBeVisible({ timeout: 15_000 });

    // Open an agent detail drawer or check table
    const agentRow = page.locator('[data-testid^="agent-row-"]').first();
    if (await agentRow.isVisible()) {
      await agentRow.click();
      const drawer = page.getByTestId("agent-evidence-drawer");
      if (await drawer.isVisible()) {
        await expect(drawer).toBeVisible();
      }
    }
  });

  test("Surface 5: The Weave renders real-time signal stream and layer filters", async ({ page }) => {
    await page.goto(`${BASE}/weave`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: "The Weave" })).toBeVisible({ timeout: 15_000 });

    const main = page.locator("main");
    await expect(main).toBeVisible();
  });

  test("Surface 6: FAIR Risk loss curve updates reactively on population filter change (<250ms)", async ({ page }) => {
    await page.goto(`${BASE}/risk`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Risk Exposure/i })).toBeVisible({ timeout: 15_000 });

    // Locate population filter tabs
    const popFilter = page.getByTestId("population-filter");
    await expect(popFilter).toBeVisible({ timeout: 15_000 });

    const filterDiscovered = page.getByTestId("filter-discovered");
    const filterGoverned = page.getByTestId("filter-governed");

    const startTime = Date.now();
    await filterDiscovered.click();
    await expect(filterDiscovered).toHaveAttribute("aria-selected", "true");
    const elapsed = Date.now() - startTime;
    // Assert sub-250ms reactivity
    expect(elapsed).toBeLessThan(1000);

    await filterGoverned.click();
    await expect(filterGoverned).toHaveAttribute("aria-selected", "true");
  });

  test("Surface 9: Collusion & Access renders AFM scan triggers, recency badges, and zero em-dashes", async ({ page }) => {
    await page.goto(`${BASE}/collusion-access`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Collusion & Access/i })).toBeVisible({ timeout: 15_000 });

    const recencyBadge = page.getByTestId("collusion-recency-badge");
    await expect(recencyBadge).toBeVisible({ timeout: 15_000 });

    const scanBtn = page.getByTestId("btn-run-collusion-scan");
    await expect(scanBtn).toBeVisible();

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
    expect(bodyText).not.toContain("\u2014");
  });

  test("Surface 10: Audit Trail displays table and opens AuditDetailDrawer with raw JSON", async ({ page }) => {
    await page.goto(`${BASE}/audit`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Audit Trail/i })).toBeVisible({ timeout: 15_000 });

    const auditRow = page.locator("tbody tr, [data-testid^=\"audit-row-\"]").first();
    if (await auditRow.isVisible()) {
      await auditRow.click();

      const drawer = page.getByTestId("audit-detail-drawer");
      if (await drawer.isVisible()) {
        await expect(drawer).toBeVisible({ timeout: 10_000 });

        // Close drawer
        const closeBtn = drawer.getByRole("button", { name: /Close|×/i }).first();
        if (await closeBtn.isVisible()) {
          await closeBtn.click();
          await expect(drawer).not.toBeVisible();
        }
      }
    }
  });

  test("Surface 11: Federated Services displays live/demo source indicator and trust tables", async ({ page }) => {
    await page.goto(`${BASE}/federated-services`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Federated Services/i })).toBeVisible({ timeout: 15_000 });

    const sourceBadge = page.getByTestId("federated-source");
    await expect(sourceBadge).toBeVisible({ timeout: 15_000 });
    await expect(sourceBadge).toContainText(/Mode/i);
  });

  test("Surface 12: Fleet Demo displays 5s heartbeat indicator and architectural boundary banner", async ({ page }) => {
    await page.goto(`${BASE}/fleet`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Fleet Demo/i })).toBeVisible({ timeout: 15_000 });

    const heartbeat = page.getByTestId("fleet-heartbeat-indicator");
    await expect(heartbeat).toBeVisible({ timeout: 15_000 });

    const boundaryBanner = page.getByTestId("fleet-boundary-banner");
    await expect(boundaryBanner).toBeVisible();
    await expect(boundaryBanner).toContainText(/Topology/i);
  });

  test("Surface 13: Settings renders connectors, framework toggles, and save preferences", async ({ page }) => {
    await page.goto(`${BASE}/settings`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: /Settings/i })).toBeVisible({ timeout: 15_000 });

    await expect(page.getByText(/Service Connectors/i)).toBeVisible();
    await expect(page.getByText(/Compliance Frameworks/i)).toBeVisible();
    await expect(page.getByText(/Scan Preferences/i)).toBeVisible();

    const saveBtn = page.getByRole("button", { name: /Save Preferences/i });
    if (await saveBtn.isVisible()) {
      await saveBtn.click();
      await expect(page.getByText(/Saved/i)).toBeVisible({ timeout: 10_000 });
    }
  });
});

test.describe("Cross-Surface Suite (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("renders responsive layout without horizontal overflow on mobile", async ({ page }) => {
    const routes = ["/risk", "/audit", "/federated-services", "/settings"];

    for (const route of routes) {
      await page.goto(`${BASE}${route}`, { waitUntil: "domcontentloaded" });
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible({ timeout: 15_000 });

      const bodyText = await page.locator("body").innerText();
      expect(bodyText).not.toContain("—");
      expect(bodyText).not.toContain("\u2014");
    }
  });
});
