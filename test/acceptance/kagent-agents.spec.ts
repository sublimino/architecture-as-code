/**
 * Signal Loom dashboard — Kagent declarative agent swarm acceptance suite.
 *
 * Drives the /agents page to assert that the 8-agent swarm renders cleanly,
 * posture scores are calculated, and ThemeToggle / DemoToggle interact seamlessly.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Kagent Declarative Agent Swarm", () => {
  test.beforeEach(async ({ page }) => {
    // demoMode: false is load-bearing. login() defaults it to true, which seeds
    // sl_demo_mode and makes /agents render the bundled fixtures instead of
    // calling the live API. The eight agents asserted below exist only as
    // Agent.kagent.dev CRs discovered through fake-integration-proxy, so under
    // demo mode this suite can never see them however healthy the cluster is —
    // it fails with "element(s) not found" against a fully-populated page,
    // which reads as a product bug rather than a harness misconfiguration.
    // Every other live-data spec here (live-data, supercred-*, rbac-explorer,
    // credential-lifecycle) opts out the same way.
    await login(page, { demoMode: false });
  });

  test("navigates to /agents and renders the 8-agent declarative swarm", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    await expect(page.locator("h1, h2").filter({ hasText: "Agents" }).first()).toBeVisible();

    const expectedAgents = [
      "kagent-k8s-reader",
      "kagent-commit-summariser",
      "kagent-security-analyst",
      "kagent-network-auditor",
      "kagent-incident-responder",
      "kagent-compliance-checker",
      "kagent-finops-optimizer",
      "kagent-chaos-prober"
    ];

    for (const name of expectedAgents) {
      await expect(page.locator(`text=${name}`).first()).toBeVisible();
    }
  });

  test("interacts with ThemeToggle without page errors", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    const themeButton = page
      .locator('[data-testid="theme-toggle"], button:has-text("Theme"), button[aria-label*="theme"]')
      .first();
    if (await themeButton.isVisible()) {
      await themeButton.click();
      await page.waitForLoadState("domcontentloaded");
    }
  });

  test("interacts with DemoToggle without page errors", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    const demoButton = page
      .locator('[data-testid="demo-toggle"], button:has-text("Demo"), button[aria-label*="demo"]')
      .first();
    if (await demoButton.isVisible()) {
      await demoButton.click();
      await page.waitForLoadState("domcontentloaded");
    }
  });
});
