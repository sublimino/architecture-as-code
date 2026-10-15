/**
 * Acceptance test verifying the Claim Agent Workload modal pre-flight checks,
 * red/green claimability status banner, and reactive objection resolution
 * on discovered agent workloads in Signal Loom.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;
const UNMODELED_AGENT_ID = "netassert-generic-agent-fixture-545f77f844-g2hx9";
const REMEDIATED_AGENT_ID = "test-agent-stunned";
const CLAIM_ERROR = "Workload 'test-agent-stunned' declares no signalloom.ai/model; refusing to record an invented model";

test.describe("Claim Modal Pre-Flight Verification & Reactive Objection Resolution", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with live mode
    await login(page, { demoMode: false });
  });

  test("Unmodeled discovered workload displays Red Blocked status, missing model diagnostic, and copyable remediation", async ({ page }) => {
    const targetUrl = `${BASE}/agents/${UNMODELED_AGENT_ID}?tab=onboarding`;
    await page.goto(targetUrl, { waitUntil: "domcontentloaded" });

    // Verify Onboarding tab is displayed
    const onboardingTab = page.getByTestId("agent-onboarding-tab");
    await expect(onboardingTab).toBeVisible({ timeout: 15_000 });

    // Open the Claim Agent Workload modal
    const openClaimBtn = page.getByTestId("onboarding-open-claim-btn");
    await expect(openClaimBtn).toBeVisible({ timeout: 10_000 });
    await openClaimBtn.click();

    // Verify Claim Modal is open
    const modal = page.getByTestId("claim-modal");
    await expect(modal).toBeVisible({ timeout: 10_000 });

    // 1. Overall Claimability Status Banner: Red Blocked state
    const claimabilityStatus = page.getByTestId("claim-modal-claimability-status");
    await expect(claimabilityStatus).toBeVisible();
    await expect(claimabilityStatus).toContainText(/Claim Blocked — Action Required/i);
    await expect(claimabilityStatus).toContainText(/Blocked/i);

    // 2. Pre-Flight Prerequisites Matrix: Model Attribution must show UNDECLARED
    const modelPrereq = page.getByTestId("claim-modal-prereq-model");
    await expect(modelPrereq).toBeVisible();
    await expect(modelPrereq).toContainText(/AI Model Attribution/i);
    await expect(modelPrereq).toContainText(/UNDECLARED/i);
    await expect(modelPrereq).toContainText(/Workload in cluster declares no signalloom\.ai\/model/i);
    await expect(modelPrereq.locator("code").filter({ hasText: "signalloom.ai/model=" }).first()).toBeVisible();

    // 3. Model input warning and undeclared badge
    const modelWarning = page.getByTestId("claim-modal-model-warning");
    await expect(modelWarning).toBeVisible();
    await expect(modelWarning).toContainText(/Pod in cluster has no signalloom\.ai\/model label/i);

    const undeclaredBadge = page.getByTestId("claim-modal-model-undeclared-badge");
    await expect(undeclaredBadge).toBeVisible();
    await expect(undeclaredBadge).toContainText(/Undeclared/i);

    // 4. Pre-flight blocker advisory
    const blockerAdvisory = page.getByTestId("claim-modal-blocker-advisory");
    await expect(blockerAdvisory).toBeVisible();
    await expect(blockerAdvisory).toContainText(/Pre-flight blockers detected/i);

    // Take screenshot evidence of unmodeled blocked state
    await page.screenshot({ path: "/tmp/claim-modal-unmodeled-blocked.png", fullPage: true });

    // 5. Close the modal cleanly
    const cancelBtn = page.getByTestId("claim-modal-cancel-btn");
    await expect(cancelBtn).toBeVisible();
    await cancelBtn.click();
    await expect(modal).toBeHidden();
  });

  test("Reactive workload refresh auto-clears objection when kubectl fix is applied, turning Green Claimable", async ({ page }) => {
    // Navigate with initial claim_error URL param simulating stale state before modal open
    const targetUrl = `${BASE}/agents/${REMEDIATED_AGENT_ID}?tab=onboarding&claim_error=${encodeURIComponent(CLAIM_ERROR)}`;
    await page.goto(targetUrl, { waitUntil: "domcontentloaded" });

    const onboardingTab = page.getByTestId("agent-onboarding-tab");
    await expect(onboardingTab).toBeVisible({ timeout: 15_000 });

    // Verify Onboarding tab refresh button exists
    const onboardingRefreshBtn = page.getByTestId("onboarding-refresh-btn").first();
    await expect(onboardingRefreshBtn).toBeVisible();

    // Open the Claim Agent Workload modal
    const openClaimBtn = page.getByTestId("onboarding-open-claim-btn");
    await expect(openClaimBtn).toBeVisible({ timeout: 10_000 });
    await openClaimBtn.click();

    // Verify Claim Modal is open
    const modal = page.getByTestId("claim-modal");
    await expect(modal).toBeVisible({ timeout: 10_000 });

    // Verify manual Refresh button exists in modal preflight header
    const modalRefreshBtn = page.getByTestId("claim-modal-refresh-btn");
    await expect(modalRefreshBtn).toBeVisible();

    // Clicking refresh triggers live refresh against cluster
    await modalRefreshBtn.click();

    // 1. Overall Claimability Status Banner: Green Claimable state
    const claimabilityStatus = page.getByTestId("claim-modal-claimability-status");
    await expect(claimabilityStatus).toBeVisible();
    await expect(claimabilityStatus).toContainText(/Claimable — Ready for Governance/i);
    await expect(claimabilityStatus).toContainText(/Claimable/i);

    // 2. Pre-Flight Prerequisites Matrix: Model must be VERIFIED with claude-3-5-sonnet
    const modelPrereq = page.getByTestId("claim-modal-prereq-model");
    await expect(modelPrereq).toBeVisible();
    await expect(modelPrereq).toContainText(/AI Model Attribution/i);
    await expect(modelPrereq).toContainText(/VERIFIED/i);
    await expect(modelPrereq).toContainText(/claude-3-5-sonnet/i);

    // 3. Tenant boundary prerequisite must be ALIGNED
    const tenantPrereq = page.getByTestId("claim-modal-prereq-tenant");
    await expect(tenantPrereq).toBeVisible();
    await expect(tenantPrereq).toContainText(/Tenant Boundary/i);
    await expect(tenantPrereq).toContainText(/ALIGNED/i);

    // 4. Missing model error alert MUST NOT be visible (auto-cleared)
    const modalError = page.getByTestId("claim-modal-error");
    await expect(modalError).toBeHidden();

    // 5. URL query params MUST NOT contain claim_error or error
    expect(page.url()).not.toContain("claim_error");
    expect(page.url()).not.toContain("error=");

    // Take screenshot evidence of remediated claimable modal
    await page.screenshot({ path: "/tmp/claim-modal-preflight-verified.png", fullPage: true });

    // 6. Close the modal cleanly
    const cancelBtn = page.getByTestId("claim-modal-cancel-btn");
    await expect(cancelBtn).toBeVisible();
    await cancelBtn.click();
    await expect(modal).toBeHidden();
  });
});
