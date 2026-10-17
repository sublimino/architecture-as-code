/**
 * Acceptance test verifying the Claim Agent Workload modal pre-flight checks,
 * red/green claimability status banner, and reactive objection resolution
 * on discovered agent workloads in Signal Loom.
 */
import { execFileSync } from "node:child_process";
import { test, expect } from "./fixtures";
import { login, config, guards, liveWorkloadAgentId } from "./helpers";

const BASE = config.base;

/**
 * The remediation test owns its workload. It used to read `test-agent-stunned`,
 * a pod test/kagent-adversarial.bats creates without a model label and deletes
 * in its teardown, and expected someone to have labelled it by hand; so it
 * passed or failed on whichever ran last. This pod is created without a model,
 * shown Blocked, labelled the way the modal's remediation tells the operator
 * to, and shown Claimable after a refresh. It is deleted however the test ends.
 */
const FIXTURE_NS = "fe-signalloom-agents";
const FIXTURE_POD = "acceptance-claim-preflight";
const FIXTURE_MODEL = "claude-3-5-sonnet";
const CLAIM_ERROR = `Workload '${FIXTURE_POD}' declares no signalloom.ai/model; refusing to record an invented model`;

function kubectl(args: string[], input?: string): string {
  return execFileSync("kubectl", ["--request-timeout=30s", ...args], {
    input,
    stdio: ["pipe", "pipe", "pipe"],
  }).toString();
}

function applyUnmodeledFixturePod(): void {
  kubectl(["-n", FIXTURE_NS, "delete", "pod", FIXTURE_POD, "--ignore-not-found", "--wait=true"]);
  kubectl(
    ["apply", "-f", "-"],
    JSON.stringify({
      apiVersion: "v1",
      kind: "Pod",
      metadata: {
        name: FIXTURE_POD,
        namespace: FIXTURE_NS,
        labels: {
          "signalloom.ai/agent": "true",
          "signalloom.ai/framework": "custom",
          "signalloom.ai/tenant": "tenant-demo",
        },
      },
      spec: { containers: [{ name: "agent", image: "ghcr.io/stefanprodan/podinfo:6.7.1" }] },
    }),
  );
  kubectl(["-n", FIXTURE_NS, "wait", "--for=condition=Ready", `pod/${FIXTURE_POD}`, "--timeout=120s"]);
}

test.describe("Claim Modal Pre-Flight Verification & Reactive Objection Resolution", () => {
  test.beforeEach(async ({ page }) => {
    // Authenticate with live mode
    await login(page, { demoMode: false });
  });

  test("Unmodeled discovered workload displays Red Blocked status, missing model diagnostic, and copyable remediation", async ({ page }) => {
    // The netassert generic fixture declares no model; its id is its current pod name.
    const unmodeledAgentId = await liveWorkloadAgentId(page, "netassert-generic-agent-fixture");
    const targetUrl = `${BASE}/agents/${unmodeledAgentId}?tab=onboarding`;
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
    await expect(claimabilityStatus).toContainText(/Claim Blocked\s*[:—]\s*Action Required/i);
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
    test.skip(!guards.exists("namespace", FIXTURE_NS), `namespace ${FIXTURE_NS} not present`);
    test.setTimeout(240_000);
    test.info().annotations.push({ type: "fixture", description: `${FIXTURE_NS}/${FIXTURE_POD}, deleted after the test` });
    applyUnmodeledFixturePod();
    try {
      // Navigate with initial claim_error URL param simulating stale state before modal open
      const targetUrl = `${BASE}/agents/${FIXTURE_POD}?tab=onboarding&claim_error=${encodeURIComponent(CLAIM_ERROR)}`;
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

      // Before the fix: the workload declares no model, so the claim is blocked.
      await expect(page.getByTestId("claim-modal-claimability-status")).toContainText(/Blocked/i);
      await expect(page.getByTestId("claim-modal-prereq-model")).toContainText(/UNDECLARED/i);

      // The operator applies the fix the modal offers, out of band.
      kubectl(["-n", FIXTURE_NS, "label", "pod", FIXTURE_POD, `signalloom.ai/model=${FIXTURE_MODEL}`, "--overwrite"]);

      // Clicking refresh triggers live refresh against cluster
      await modalRefreshBtn.click();

      // 1. Overall Claimability Status Banner: Green Claimable state
      const claimabilityStatus = page.getByTestId("claim-modal-claimability-status");
      await expect(claimabilityStatus).toBeVisible();
      await expect(claimabilityStatus).toContainText(/Claimable\s*[:—]\s*Ready for Governance/i);
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
    } finally {
      kubectl(["-n", FIXTURE_NS, "delete", "pod", FIXTURE_POD, "--ignore-not-found", "--wait=false"]);
    }
  });
});
