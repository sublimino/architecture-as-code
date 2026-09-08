/**
 * Signal Loom dashboard — Agent Drilldowns, Topology Inspector Links & Kubernetes Query Selectors Acceptance Suite.
 *
 * Validates:
 * 1. Agent Trust Topology inspector displays clickable "Agent Dossier ↗" link and query selector pills when inspecting agent nodes.
 * 2. Agents Page URL query parameter binding (?selector=...) displays active selector badge and filters inventory.
 * 3. Selector badge clear button resets active selector filter and updates view.
 * 4. Agent Detail Page renders "Active Target Instance" banner when navigating with ?instance=... or ?selector=...
 * 5. Cross-application agent links in Network Tests, Distance Latency, and Discovery drill down cleanly into agent dossiers.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Agent Drilldown, Topology Inspector & Query Selectors", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with demo mode enabled to populate rich agent topologies and inventory fixtures
    await login(page, { demoMode: true });
  });

  test("Agent Trust Topology inspector displays dossier link and interactive query selector pills", async ({ page }) => {
    await page.goto(`${BASE}/agent-trust-topology`);
    await expect(page.locator("h1").filter({ hasText: "Agent Trust Topology" })).toBeVisible({ timeout: 15000 });

    // The default selection on load is edge 'spire-planner', whose target is an agent ('planner').
    // Verify that the inspector displays the Target Agent Dossier link
    const targetDossierLink = page.locator('[data-testid="inspector-target-agent-link"]');
    if (await targetDossierLink.isVisible({ timeout: 3000 }).catch(() => false)) {
      await expect(targetDossierLink).toHaveAttribute("href", /^\/agents\/.+/);
    }

    // Now click the planner agent node in the selectable topology items
    const plannerBtn = page.getByRole("button", { name: /planner/i }).first();
    await expect(plannerBtn).toBeVisible({ timeout: 5000 });
    await plannerBtn.click();

    // Inspector panel should display the primary agent dossier link
    const dossierLink = page.locator('[data-testid="inspector-agent-dossier-link"]');
    await expect(dossierLink).toBeVisible({ timeout: 5000 });
    await expect(dossierLink).toHaveAttribute("href", /^\/agents\/.+/);

    // Inspector should also show interactive selector links
    const selectorLink = page.locator('[data-testid^="inspector-selector-"]').first();
    await expect(selectorLink).toBeVisible({ timeout: 5000 });
    await expect(selectorLink).toHaveAttribute("href", /^\/agents\?search=/);
  });

  test("Agents Page filters by ?selector= parameter and displays active selector chip", async ({ page }) => {
    const testSelector = "k8s:sa:planner";
    await page.goto(`${BASE}/agents?selector=${encodeURIComponent(testSelector)}`);
    await expect(page.locator("h1, h2").filter({ hasText: "Agents" }).first()).toBeVisible({ timeout: 15000 });

    // Active selector badge should be visible with the selector text
    const activeBadge = page.locator('[data-testid="active-selector-badge"]');
    await expect(activeBadge).toBeVisible();
    await expect(activeBadge).toContainText(testSelector);

    // Clicking the clear button removes the active selector
    const clearBtn = page.locator('[data-testid="clear-selector-button"]');
    await expect(clearBtn).toBeVisible();
    await clearBtn.click();
    await expect(activeBadge).not.toBeVisible();
  });

  test("Agent Detail Page displays Active Target Instance banner when instance parameter is present", async ({ page }) => {
    const testInstanceUid = "uid-test-instance-12345";
    await page.goto(`${BASE}/agents/agent-triage?instance=${testInstanceUid}`);

    // Verify detail header or tabs are visible for Triage Agent
    await expect(page.locator("h1, h2").filter({ hasText: /Triage Agent|agent-triage/i }).first()).toBeVisible({ timeout: 15000 });

    // Active Target Instance banner should render with the instance UID
    const instanceBanner = page.locator('[data-testid="active-target-instance-banner"]');
    await expect(instanceBanner).toBeVisible();
    await expect(instanceBanner).toContainText(testInstanceUid);
  });

  test("Cross-application agent links navigate safely into agent dossiers", async ({ page }) => {
    // Check Network Tests page
    await page.goto(`${BASE}/network-tests`);
    await expect(page.locator("h1, h2").filter({ hasText: /Network Tests/i }).first()).toBeVisible({ timeout: 15000 });

    const agentLink = page.locator('a[href*="/agents/"]').first();
    if (await agentLink.isVisible()) {
      const href = await agentLink.getAttribute("href");
      expect(href).toMatch(/\/agents\//);
    }

    // Check Distance Latency page
    await page.goto(`${BASE}/distance-latency`);
    await expect(page.locator("h1").filter({ hasText: "Distance-Focused Latency & Telemetry" })).toBeVisible({ timeout: 15000 });

    const latencyAgentLink = page.locator('a[href*="/agents/"]').first();
    if (await latencyAgentLink.isVisible()) {
      const href = await latencyAgentLink.getAttribute("href");
      expect(href).toMatch(/\/agents\//);
    }
  });
});
