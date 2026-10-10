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
    await expect(selectorLink).toHaveAttribute("href", /^\/agents\?(selector|search)=/);
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

    // Check Discovery page
    await page.goto(`${BASE}/discovery`);
    await expect(page.locator("h1, h2").filter({ hasText: /Non-Human Identities|Discovery/i }).first()).toBeVisible({ timeout: 15000 });
    const discoveryAgentLink = page.locator('[data-testid^="discovery-agent-link-"]').first();
    if (await discoveryAgentLink.isVisible({ timeout: 4000 }).catch(() => false)) {
      const href = await discoveryAgentLink.getAttribute("href");
      expect(href).toMatch(/\/agents\//);
    }

    // Verify clicking workload name opens the in-context DiscoveredWorkloadDrawer
    const workloadNameBtn = page.locator('[data-testid^="discovery-workload-name-"]').first();
    await expect(workloadNameBtn).toBeVisible({ timeout: 10000 });
    await workloadNameBtn.click();
    const drawer = page.locator('[data-testid="discovered-workload-drawer"]');
    await expect(drawer).toBeVisible({ timeout: 5000 });
    await expect(drawer.locator('[data-testid="drawer-workload-name"]')).toBeVisible();
    await expect(drawer.locator('[data-testid="drawer-control-recommendations"]')).toBeVisible();

    // Drawer close button should dismiss the drawer
    await drawer.locator('[data-testid="drawer-close-btn"]').click();
    await expect(drawer).not.toBeVisible();

    // Check Audit Trail page
    await page.goto(`${BASE}/audit`);
    await expect(page.locator("h1, h2").filter({ hasText: /Audit Trail/i }).first()).toBeVisible({ timeout: 15000 });
    const auditAgentLink = page.locator('a[data-testid^="audit-agent-link-"]').first();
    if (await auditAgentLink.isVisible({ timeout: 4000 }).catch(() => false)) {
      const href = await auditAgentLink.getAttribute("href");
      expect(href).toMatch(/\/agents\//);
    }

    // Check Design System page renders AgentDeepLink gallery specimens
    await page.goto(`${BASE}/design-system`);
    await expect(page.locator('[data-testid="ds-section-agent-deep-link"]')).toBeVisible({ timeout: 15000 });
    await expect(page.locator('[data-testid="ds-agentdeeplink-link"]')).toBeVisible();
    await expect(page.locator('[data-testid="ds-agentdeeplink-badge"]')).toBeVisible();
    await expect(page.locator('[data-testid="ds-agentdeeplink-chip"]')).toBeVisible();
    await expect(page.locator('[data-testid="ds-agentdeeplink-pill"]')).toBeVisible();
    await expect(page.locator('[data-testid="ds-agentdeeplink-subtle"]')).toBeVisible();
  });

  test("Discovery Account Detail route falls back gracefully without 404", async ({ page }) => {
    // Navigate directly to the account detail URL mentioned in user report
    await page.goto(`${BASE}/discovery/accounts/tenant-demo:nhi-1`);

    // Page must NOT show unhandled error or 404
    await expect(page.locator("text=Failed to load account details")).not.toBeVisible({ timeout: 10000 });

    // Should display the discovery drawer fallback link and return button
    const drawerLink = page.locator('[data-testid="open-in-discovery-drawer-link"]');
    await expect(drawerLink).toBeVisible({ timeout: 10000 });
    await expect(drawerLink).toHaveAttribute("href", /\/discovery\?workload=/);

    // Clicking the link navigates to /discovery?workload=... and opens the drawer
    await drawerLink.click();
    await expect(page).toHaveURL(/\/discovery\?workload=/);
    const drawer = page.locator('[data-testid="discovered-workload-drawer"]');
    await expect(drawer).toBeVisible({ timeout: 5000 });
  });
});

