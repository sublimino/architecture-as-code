/**
 * Acceptance test verifying the Claim Agent Workload modal pre-flight checks,
 * red/green claimability status banner, and objection remediation guidance
 * on the discovered 'test-agent-stunned' workload.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;
const STUNNED_AGENT_ID = "test-agent-stunned";
const CLAIM_ERROR = "Workload 'test-agent-stunned' declares no signalloom.ai/model; refusing to record an invented model";

test.describe("Claim Modal Pre-Flight Verification & Objection Guidance", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with live mode
    await login(page, { demoMode: false });
  });

  test("Claim modal displays Red Blocked status, missing model diagnostic, and copyable remediation", async ({ page }) => {
    const targetUrl = `${BASE}/agents/${STUNNED_AGENT_ID}?tab=onboarding&claim_error=${encodeURIComponent(CLAIM_ERROR)}`;
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

    // 2. Pre-Flight Prerequisites Matrix
    const prereqsMatrix = page.getByTestId("claim-modal-prereqs-matrix");
    await expect(prereqsMatrix).toBeVisible();

    // Model Attribution prerequisite must show UNDECLARED
    const modelPrereq = page.getByTestId("claim-modal-prereq-model");
    await expect(modelPrereq).toBeVisible();
    await expect(modelPrereq).toContainText(/Model Attribution/i);
    await expect(modelPrereq).toContainText(/UNDECLARED/i);

    // 3. Active Onboarding Blocker Diagnostic Alert
    const modalError = page.getByTestId("claim-modal-error");
    await expect(modalError).toBeVisible();
    await expect(modalError).toContainText(/Workload Model Objection: Missing signalloom\.ai\/model/i);
    await expect(modalError).toContainText(CLAIM_ERROR);
    await expect(modalError.locator("code").filter({ hasText: "signalloom.ai/model=" }).first()).toBeVisible();

    // 4. Model input warning and undeclared badge
    const modelWarning = page.getByTestId("claim-modal-model-warning");
    await expect(modelWarning).toBeVisible();
    await expect(modelWarning).toContainText(/Pod in cluster has no signalloom\.ai\/model label/i);

    const undeclaredBadge = page.getByTestId("claim-modal-model-undeclared-badge");
    await expect(undeclaredBadge).toBeVisible();
    await expect(undeclaredBadge).toContainText(/Undeclared/i);

    // 5. Pre-flight blocker advisory
    const blockerAdvisory = page.getByTestId("claim-modal-blocker-advisory");
    await expect(blockerAdvisory).toBeVisible();
    await expect(blockerAdvisory).toContainText(/Pre-flight blockers detected/i);

    // Take screenshot evidence of the open Claim Modal
    await page.screenshot({ path: "/tmp/claim-modal-preflight-verified.png", fullPage: true });

    // 6. Close the modal cleanly
    const cancelBtn = page.getByTestId("claim-modal-cancel-btn");
    await expect(cancelBtn).toBeVisible();
    await cancelBtn.click();
    await expect(modal).toBeHidden();
  });
});
