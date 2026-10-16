/**
 * Acceptance test verifying the Agent Onboarding Guide and 2-column Claim Modal
 * with pre-flight checks and tenant objection handling on Kusari agent workload.
 */
import { test, expect } from "./fixtures";
import { login, config, getAuthToken } from "./helpers";

const BASE = config.base;
test.describe("Kusari Agent Onboarding Guide & Claim Modal Pre-Flight Checks", () => {
  let kusariAgentId = "";

  test.beforeEach(async ({ page }) => {
    // Authenticate with live mode
    await login(page, { demoMode: false });
    // The agent id is a pod name and changes on every rollout, so it is read
    // from the live API. A missing agent or a failed request fails here with
    // the reason, instead of falling back to a stale hard-coded pod id.
    const token = await getAuthToken(page);
    const res = await page.request.get(`${BASE}/api/agents`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
    expect(res.ok(), `GET /api/agents returned HTTP ${res.status()}`).toBe(true);
    const data = await res.json();
    const list: { id?: unknown }[] = Array.isArray(data) ? data : data.agents || [];
    const match = list.find((a) => typeof a.id === "string" && a.id.startsWith("agent-kusari"));
    expect(match, "no agent-kusari* workload in GET /api/agents").toBeTruthy();
    kusariAgentId = match!.id as string;
  });

  test("Overview tab shows unclaimed banner with onboarding and pre-flight claim links", async ({ page }) => {
    await page.goto(`${BASE}/agents/${kusariAgentId}?tab=overview`, { waitUntil: "domcontentloaded" });

    // Check that the agent dossier loads
    await expect(page.locator("h1")).toContainText(/kusari/i, { timeout: 15_000 });

    // Look for the unclaimed banner
    const unclaimedBanner = page.getByTestId("overview-unclaimed-banner");
    await expect(unclaimedBanner).toBeVisible({ timeout: 15_000 });

    // Verify action links exist
    const viewGuideBtn = page.getByTestId("overview-view-onboarding-btn");
    const openClaimBtn = page.getByTestId("overview-open-claim-modal-btn");
    await expect(viewGuideBtn).toBeVisible();
    await expect(openClaimBtn).toBeVisible();

    // Clicking the guide button switches to Onboarding tab
    await viewGuideBtn.click();
    await expect(page.getByTestId("agent-onboarding-tab")).toBeVisible({ timeout: 15_000 });
  });

  test("Onboarding tab displays pre-flight diagnostic matrix, tenant objection, and remediation runbook", async ({ page }) => {
    await page.goto(`${BASE}/agents/${kusariAgentId}?tab=onboarding`, { waitUntil: "domcontentloaded" });

    // Tab container is visible
    const guideTab = page.getByTestId("agent-onboarding-tab");
    await expect(guideTab).toBeVisible({ timeout: 15_000 });

    // Pre-flight matrix heading and diagnostic cards
    await expect(page.getByRole("heading", { name: /Pre-Flight Verification Matrix/i })).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("onboarding-diag-tenant")).toBeVisible();
    await expect(page.getByTestId("onboarding-diag-spiffe")).toBeVisible();
    await expect(page.getByTestId("onboarding-diag-sensor")).toBeVisible();
    await expect(page.getByTestId("onboarding-diag-policy")).toBeVisible();

    // 3-step remediation procedure
    await expect(page.getByRole("heading", { name: /3-Step Workload Claim & Onboarding Procedure/i })).toBeVisible();
    await expect(page.getByText(/Verify Tenant and Workload Identification/i)).toBeVisible();
    await expect(page.getByText(/Configure Model & Token Budget Allocation/i)).toBeVisible();
    await expect(page.getByText(/Continuous Governance & Telemetry Attestation/i)).toBeVisible();

    // Verify copyable kubectl command contains tenant label fix
    await expect(page.locator("code").filter({ hasText: "signalloom.ai/tenant=" }).first()).toBeVisible();
  });

  test("Claim Agent Workload modal displays 2-column layout with right-hand pre-flight diagnostics", async ({ page }) => {
    await page.goto(`${BASE}/agents/${kusariAgentId}?tab=overview`, { waitUntil: "domcontentloaded" });

    // Open claim modal
    const openClaimBtn = page.getByTestId("overview-open-claim-modal-btn");
    await expect(openClaimBtn).toBeVisible({ timeout: 15_000 });
    await openClaimBtn.click();

    // Verify claim dialog is visible
    const modal = page.getByTestId("claim-modal");
    await expect(modal).toBeVisible({ timeout: 10_000 });

    // Verify right-hand info panel
    const infoPanel = page.getByTestId("claim-modal-info-panel");
    await expect(infoPanel).toBeVisible({ timeout: 10_000 });

    // Verify tenant boundary pre-flight check in modal
    await expect(page.getByTestId("claim-modal-tenant-mismatch-warning")).toBeVisible();

    // Close modal
    const closeBtn = page.getByTestId("claim-modal-cancel-btn");
    await expect(closeBtn).toBeVisible();
    await closeBtn.click();
    await expect(modal).toBeHidden();
  });
});
