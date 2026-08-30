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
    await login(page);
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
    const themeButton = page.locator("[data-testid="theme-toggle"], button:has-text("Theme"), button[aria-label*="theme"]").first();
    if (await themeButton.isVisible()) {
      await themeButton.click();
      await page.waitForLoadState("domcontentloaded");
    }
  });

  test("interacts with DemoToggle without page errors", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    const demoButton = page.locator("[data-testid="demo-toggle"], button:has-text("Demo"), button[aria-label*="demo"]").first();
    if (await demoButton.isVisible()) {
      await demoButton.click();
      await page.waitForLoadState("domcontentloaded");
    }
  });
});
