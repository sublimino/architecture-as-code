/**
 * Acceptance test verifying the Agent Onboarding Guide and 2-column Claim Modal
 * with pre-flight checks and tenant objection handling on Kusari agent workload.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;
const KUSARI_AGENT_ID = "agent-kusari-847cc7d984-mwg8c";

test.describe("Kusari Agent Onboarding Guide & Claim Modal Pre-Flight Checks", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with live mode
    await login(page, { demoMode: false });
  });

  test("Overview tab shows unclaimed banner with onboarding and pre-flight claim links", async ({ page }) => {
    await page.goto(`${BASE}/agents/${KUSARI_AGENT_ID}?tab=overview`, { waitUntil: "domcontentloaded" });
    
    // Check that the page loads
    await expect(page.locator("h1")).toContainText(/kusari/i, { timeout: 15_000 });

    // Look for the unclaimed banner
    const unclaimedBanner = page.getByTestId("overview-unclaimed-banner");
    await expect(unclaimedBanner).toBeVisible({ timeout: 10_000 });

    // Verify both action links exist
    const viewGuideBtn = page.getByTestId("overview-view-onboarding-btn");
    const openClaimBtn = page.getByTestId("overview-open-claim-modal-btn");
    await expect(viewGuideBtn).toBeVisible();
    await expect(openClaimBtn).toBeVisible();

    // Clicking the guide button switches to Onboarding tab
    await viewGuideBtn.click();
    await expect(page.getByTestId("agent-onboarding-guide-tab")).toBeVisible({ timeout: 10_000 });
  });

  test("Onboarding tab displays pre-flight diagnostic matrix, tenant objection, and remediation runbook", async ({ page }) => {
    await page.goto(`${BASE}/agents/${KUSARI_AGENT_ID}?tab=onboarding`, { waitUntil: "domcontentloaded" });

    // Tab content is visible
    const guideTab = page.getByTestId("agent-onboarding-guide-tab");
    await expect(guideTab).toBeVisible({ timeout: 15_000 });

    // Pre-flight matrix
    await expect(page.getByTestId("onboarding-preflight-matrix")).toBeVisible();
    await expect(page.getByTestId("preflight-check-tenant-boundary")).toBeVisible();
    await expect(page.getByTestId("preflight-check-spiffe-identity")).toBeVisible();
    await expect(page.getByTestId("preflight-check-ebpf-sentinel")).toBeVisible();
    await expect(page.getByTestId("preflight-check-cel-admission")).toBeVisible();

    // Remediation runbook
    await expect(page.getByTestId("onboarding-remediation-runbook")).toBeVisible();
    await expect(page.getByTestId("onboarding-runbook-step-1")).toBeVisible();
    await expect(page.getByTestId("onboarding-runbook-step-2")).toBeVisible();
    await expect(page.getByTestId("onboarding-runbook-step-3")).toBeVisible();

    // Verify copyable kubectl command contains tenant label fix
    await expect(page.locator("pre").filter({ hasText: "signalloom.ai/tenant=" })).toBeVisible();
  });

  test("Claim Agent Workload modal displays 2-column layout with right-hand pre-flight diagnostics", async ({ page }) => {
    await page.goto(`${BASE}/agents/${KUSARI_AGENT_ID}?tab=overview`, { waitUntil: "domcontentloaded" });
    
    // Open claim modal
    const openClaimBtn = page.getByTestId("overview-open-claim-modal-btn");
    await expect(openClaimBtn).toBeVisible({ timeout: 10_000 });
    await openClaimBtn.click();

    // Verify claim dialog is visible
    const dialog = page.locator('dialog[open], [role="dialog"], [data-testid="claim-modal-dialog"]');
    await expect(dialog.first()).toBeVisible({ timeout: 10_000 });

    // Verify right-hand info panel
    const infoPanel = page.getByTestId("claim-modal-info-panel");
    await expect(infoPanel).toBeVisible({ timeout: 10_000 });

    // Verify workload profile and security checklist
    await expect(page.getByTestId("claim-modal-profile-header")).toBeVisible();
    await expect(page.getByTestId("claim-modal-invariants-checklist")).toBeVisible();

    // Close modal
    const closeBtn = page.getByTestId("claim-modal-cancel-btn");
    if (await closeBtn.isVisible()) {
      await closeBtn.click();
    }
  });
});
