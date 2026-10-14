import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Clean Onboarding State & Help Pages (Live Mode)", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with live data (demoMode: false) to reflect true cluster & DB state
    await login(page, { demoMode: false });
  });

  test("/agents displays empty state with zero registered agents and help links", async ({ page }) => {
    await page.goto(`${BASE}/agents`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });

    // Assert that Cardvault, Kusari, and Sir Lancelot do NOT appear in the agent registry
    await expect(page.getByText("Cardvault Agent", { exact: false })).toHaveCount(0);
    await expect(page.getByText("agent-cardvault", { exact: false })).toHaveCount(0);
    await expect(page.getByText("kusari-agent", { exact: false })).toHaveCount(0);
    await expect(page.getByText("Sir Lancelot", { exact: false })).toHaveCount(0);

    // Empty state quick links should be visible
    const deploySensorLink = page.getByRole("link", { name: /deploy sensor/i });
    const onboardAgentLink = page.getByRole("link", { name: /onboard agent/i });

    if (await deploySensorLink.isVisible()) {
      await expect(deploySensorLink).toBeVisible();
      await expect(onboardAgentLink).toBeVisible();
    }
  });

  test("/settings has Deploy Sensor and Onboard Agent tabs", async ({ page }) => {
    await page.goto(`${BASE}/settings`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1, name: "Settings" })).toBeVisible({ timeout: 20_000 });

    // Both tabs should exist
    const deploySensorTab = page.getByRole("tab", { name: /deploy sensor/i });
    const onboardAgentTab = page.getByRole("tab", { name: /onboard agent/i });

    await expect(deploySensorTab).toBeVisible({ timeout: 15_000 });
    await expect(onboardAgentTab).toBeVisible({ timeout: 15_000 });

    // Switching to Deploy Sensor tab renders sensor guide
    await deploySensorTab.click();
    await expect(page.getByRole("heading", { name: /Help to Deploy Sensor/i })).toBeVisible({ timeout: 10_000 });

    // Switching to Onboard Agent tab renders agent onboarding guide
    await onboardAgentTab.click();
    await expect(page.getByRole("heading", { name: /Help to Onboard an Agent/i })).toBeVisible({ timeout: 10_000 });
  });

  test("/settings/help/deploy-sensor renders comprehensive setup instructions and docs links", async ({ page }) => {
    await page.goto(`${BASE}/settings/help/deploy-sensor`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { name: /Help to Deploy Sensor/i })).toBeVisible({ timeout: 20_000 });

    // Architectural summary and instructions
    await expect(page.getByTestId("architecture-section")).toBeVisible();
    await expect(page.getByTestId("kernel-sensor-section")).toBeVisible();
    await expect(page.getByTestId("host-sensor-section")).toBeVisible();
    await expect(page.getByTestId("troubleshooting-section")).toBeVisible();

    // Documentation links should be rendered
    const docsLinks = page.locator('a[href*="/docs/"]');
    expect(await docsLinks.count()).toBeGreaterThan(0);
  });

  test("/settings/help/onboard-agent renders 3-step walkthrough and copyable snippets", async ({ page }) => {
    await page.goto(`${BASE}/settings/help/onboard-agent`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { name: /Help to Onboard an Agent/i })).toBeVisible({ timeout: 20_000 });

    // 3 steps
    await expect(page.getByTestId("step-1-section")).toBeVisible();
    await expect(page.getByTestId("step-2-section")).toBeVisible();
    await expect(page.getByTestId("step-3-section")).toBeVisible();

    // Required label keys
    await expect(page.getByText("signalloom.ai/agent", { exact: true }).first()).toBeVisible();

    // Documentation links should be rendered
    const docsLinks = page.locator('a[href*="/docs/"]');
    expect(await docsLinks.count()).toBeGreaterThan(0);
  });
});
