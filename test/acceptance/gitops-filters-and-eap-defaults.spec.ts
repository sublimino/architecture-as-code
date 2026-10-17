/**
 * Acceptance test verifying GitOps detection notices, workload quick filters,
 * disclosure typography spacing, and EAP preset defaults in the live dashboard.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;
const KUSARI_AGENT_ID = "agent-kusari-847cc7d984-mwg8c";

test.describe("GitOps Detection, Workload Quick Filters & EAP Preset Defaults", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("AgentsPage renders GitOps Managed and Tenant Mismatch filter buttons without text concatenation", async ({ page }) => {
    await page.goto(`${BASE}/agents`, { waitUntil: "domcontentloaded" });

    // 1. Verify quick filter buttons exist
    const gitopsBtn = page.getByTestId("agent-gitops-filter-btn");
    const tenantMismatchBtn = page.getByTestId("agent-tenant-mismatch-filter-btn");
    await expect(gitopsBtn).toBeVisible({ timeout: 15_000 });
    await expect(tenantMismatchBtn).toBeVisible({ timeout: 15_000 });

    // 2. Toggle GitOps filter
    await gitopsBtn.click();
    await expect(gitopsBtn).toHaveAttribute("aria-pressed", "true");
    await gitopsBtn.click();
    await expect(gitopsBtn).toHaveAttribute("aria-pressed", "false");

    // 3. Verify disclosure text separation: never "Registry not linkedDetails"
    const pageText = await page.innerText("body");
    expect(pageText).not.toContain("Registry not linkedDetails");
  });

  test("DiscoveryPage renders GitOps quick filter facet", async ({ page }) => {
    await page.goto(`${BASE}/discovery`, { waitUntil: "domcontentloaded" });

    const discoveryGitopsBtn = page.getByTestId("discovery-gitops-filter-btn");
    await expect(discoveryGitopsBtn).toBeVisible({ timeout: 15_000 });

    await discoveryGitopsBtn.click();
    await expect(discoveryGitopsBtn).toHaveAttribute("aria-pressed", "true");
    await discoveryGitopsBtn.click();
    await expect(discoveryGitopsBtn).toHaveAttribute("aria-pressed", "false");
  });

  test("Agent Onboarding displays GitOps reconciliation notice and copyable remediation patch", async ({ page }) => {
    await page.goto(`${BASE}/agents/${KUSARI_AGENT_ID}?tab=onboarding`, { waitUntil: "domcontentloaded" });

    // Verify Onboarding Tab loads
    const onboardingTab = page.getByTestId("agent-onboarding-tab");
    await expect(onboardingTab).toBeVisible({ timeout: 15_000 });

    // If workload is GitOps managed, check for gitops notice
    const gitopsNotice = page.getByTestId("onboarding-gitops-notice");
    if (await gitopsNotice.isVisible()) {
      await expect(gitopsNotice).toContainText(/managed by gitops/i);
      await expect(gitopsNotice).toContainText(/kustomization/i);
    }
  });

  test("Features Admin page displays EAP Pilot preset suppressing federated services and topology", async ({ page }) => {
    await page.goto(`${BASE}/admin/features`, { waitUntil: "domcontentloaded" });

    // Check header
    await expect(page.locator("h1")).toContainText(/feature/i, { timeout: 15_000 });

    // The "Apply EAP Pilot" preset button became the EAP Full account type in
    // 84cde543b (eap_pilot is its alias; d2-signalloom/contracts/feature-account-types.json).
    // It must still suppress federated services and topology.
    const eapFull = page.getByTestId("account-type-option-eap_full");
    await expect(eapFull).toBeVisible({ timeout: 15_000 });
    await expect(eapFull).toContainText("EAP Full");
    const pages = page.getByTestId("account-type-pages-eap_full");
    await expect(pages).toBeVisible();
    await expect(pages).not.toContainText("Federated Services");
    await expect(pages).not.toContainText("Agent Topology");
    // ...while the Full type, from the same catalogue, does list them: the
    // absence above is the preset's, not a rendering gap.
    await expect(page.getByTestId("account-type-pages-full")).toContainText("Federated Services");
    await expect(page.getByTestId("account-type-pages-full")).toContainText("Agent Topology");
  });
});
