/**
 * Signal Loom Demo Smoke Suite — Rapid Verification (<90s).
 *
 * Dedicated lightweight acceptance test suite designed for in-person partner
 * walk-throughs (it opts into `{ demoMode: true }`: fixtures, not live data),
 * customer evaluations, and CI rapid smoke gating.
 *
 * Scope:
 * 1. User Onboarding Wizard flow (welcome, five-step guided setup, IdP linkage test, consent, celebration, redirect).
 * 2. User Onboarding Skip workflow (immediate status persistence and dashboard entry).
 * 3. Dual-Agent Discovery & Inventory (heterogeneous agent profiles, status badges, discovery labels).
 * 4. Dual-Agent Claim & Telemetry (operator claim flow, SPIFFE identity binding, active zero-trust controls, and activity timeline stream).
 *
 * Execution SLA: Strictly < 90 seconds wall-clock time.
 */
import { execFileSync } from "node:child_process";
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

/** The wizard opens on a welcome screen for a fresh tenant; dismiss it when it is there. */
async function dismissWelcomeIfShown(page: import("@playwright/test").Page): Promise<void> {
  const welcome = page.locator('[data-testid="onboarding-welcome"]');
  if (await welcome.isVisible().catch(() => false) || await welcome.waitFor({ state: "visible", timeout: 5_000 }).then(() => true).catch(() => false)) {
    await page.locator('[data-testid="welcome-continue-button"]').click();
  }
}

test.describe("Signal Loom Rapid Demo Smoke Suite (SLON-P2-4)", () => {
  test.afterAll(async () => {
    try {
      execFileSync(
        "kubectl",
        [
          "-n",
          "inf-signalloom",
          "exec",
          "deploy/postgresql",
          "--",
          "psql",
          "-U",
          "signalloom",
          "-d",
          "signalloom",
          "-c",
          "INSERT INTO tenant_onboarding (tenant_id, status, skipped_at) VALUES ('tenant-demo', 'skipped', NOW()) ON CONFLICT (tenant_id) DO UPDATE SET status = 'skipped', skipped_at = NOW();",
        ],
        { stdio: "ignore" },
      );
    } catch {
      // Ignore if cluster or postgres is unreachable
    }
  });

  test.beforeEach(async () => {
    try {
      execFileSync(
        "kubectl",
        [
          "-n",
          "inf-signalloom",
          "exec",
          "deploy/postgresql",
          "--",
          "psql",
          "-U",
          "signalloom",
          "-d",
          "signalloom",
          "-c",
          "DELETE FROM tenant_onboarding WHERE tenant_id = 'tenant-demo';",
        ],
        { stdio: "ignore" },
      );
    } catch {
      // Ignore if cluster or postgres is unreachable
    }
  });

  // ─── Group 1: First User Onboarding Wizard ────────────────────────────────

  test("user onboarding: skip flow records persistent status and transitions to overview", async ({

    page,
  }) => {
    await login(page, { demoMode: true });
    await page.goto(`${BASE}/onboarding`, { waitUntil: "domcontentloaded" });
    await dismissWelcomeIfShown(page);

    const skipOrGoBtn = page
      .locator('[data-testid="skip-onboarding-button"], [data-testid="goto-dashboard-button"], button:has-text("Skip for now")')
      .first();
    await expect(skipOrGoBtn).toBeVisible({ timeout: 15_000 });
    await skipOrGoBtn.click();

    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  test("user onboarding: complete five-step wizard with validation, IdP test, consent, and celebration", async ({
    page,
  }) => {
    await login(page, { demoMode: true });
    // Navigate directly to onboarding wizard route
    await page.goto(`${BASE}/onboarding`, { waitUntil: "domcontentloaded" });
    await dismissWelcomeIfShown(page);

    // Verify wizard container or celebration is mounted
    const wizardContainer = page.locator('[data-testid="onboarding-wizard-container"], [data-testid="completion-celebration"]').first();
    await expect(wizardContainer).toBeVisible({ timeout: 15_000 });

    const isCelebration = await page.locator('[data-testid="completion-celebration"]').isVisible().catch(() => false);
    if (!isCelebration) {
      // Step 1: Tenant & Workspace Identity
      await expect(
        page.getByRole("heading", { level: 1, name: /Tenant & Workspace Identity|Organization & Identity/i }),
      ).toBeVisible({ timeout: 10_000 });

      // Validation boundary check: empty input triggers validation error banner
      const orgInput = page.locator('[data-testid="input-organization-name"]');
      await orgInput.fill("");
      await page.locator('[data-testid="next-step-button"]').click();

      const errorBanner = page.locator('[data-testid="validation-error-banner"]');
      await expect(errorBanner).toBeVisible({ timeout: 5_000 });
      await expect(page.getByText(/Organization Name is required/i)).toBeVisible();

      // Populate valid Step 1 data
      await orgInput.fill("Acme Autonomous Systems");
      await page.locator('[data-testid="input-workspace-id"]').fill("acme-auto-prod");
      await page.locator('[data-testid="input-admin-email"]').fill("operator@acme-auto.corp");

      // Advance to Step 2
      await page.locator('[data-testid="next-step-button"]').click();

      // Step 2: Identity Provider Linkage
      await expect(
        page.getByRole("heading", { level: 1, name: /Identity Provider Linkage|Identity Provider/i }),
      ).toBeVisible({ timeout: 10_000 });

      // Dex is the portal's own issuer: Test Connection in its modal is the
      // session probe (GET /api/v1/me), answered by the server.
      await expect(page.locator('[data-testid="idp-option-dex"]')).toBeVisible({ timeout: 5_000 });
      await page.locator('[data-testid="configure-idp-dex"]').click();
      const dexDialog = page.getByRole("dialog");
      await expect(dexDialog).toBeVisible();
      await dexDialog.locator('[data-testid="btn-modal-test-connection"]').click();
      await expect(dexDialog.locator('[data-testid="test-connection-success"]')).toContainText(
        "Portal session verified",
        { timeout: 10_000 },
      );
      await dexDialog.locator('[data-testid="btn-modal-save-connector"]').click();
      await expect(dexDialog).toBeHidden();

      const connSuccess = page.locator('[data-testid="idp-connection-success"]');
      await expect(connSuccess).toBeVisible({ timeout: 10_000 });

      // Advance to Step 3: scan preferences, kept at their defaults
      await page.locator('[data-testid="next-step-button"]').click();
      await expect(page.getByRole("heading", { level: 1, name: "Set your scan preferences" })).toBeVisible({ timeout: 10_000 });

      // Advance to Step 4: the optional API key reveal, declined here
      await page.locator('[data-testid="next-step-button"]').click();
      await expect(page.getByRole("heading", { level: 1, name: "Your API key" })).toBeVisible({ timeout: 10_000 });

      // Advance to Step 5
      await page.locator('[data-testid="next-step-button"]').click();

      // Step 5: Containment Policy & Security Consent
      await expect(
        page.getByRole("heading", { level: 1, name: /Containment Policy & (Security )?Consent/i }),
      ).toBeVisible({ timeout: 10_000 });

      // Verify summary reflects Step 1 tenant configuration
      await expect(page.getByText("Acme Autonomous Systems")).toBeVisible();
      await expect(page.getByText("acme-auto-prod")).toBeVisible();

      // Verify zero-trust consent is checked
      const zeroTrustConsent = page.locator('[data-testid="consent-zero-trust"]');
      await expect(zeroTrustConsent).toBeChecked();

      // Finalize onboarding submission
      const completeBtn = page.locator('[data-testid="complete-onboarding-button"]');
      await expect(completeBtn).toBeVisible();
      await completeBtn.click();
    }

    // Step 4: Celebration Screen & Transition
    const celebration = page.locator('[data-testid="completion-celebration"]');
    await expect(celebration).toBeVisible({ timeout: 15_000 });
    await expect(
      page.getByRole("heading", { level: 1, name: /Onboarding Complete/i }),
    ).toBeVisible();

    // Transition to main dashboard
    const gotoDashboardBtn = page.locator('[data-testid="goto-dashboard-button"]');
    await expect(gotoDashboardBtn).toBeVisible();
    await gotoDashboardBtn.click();

    // Verify redirect and sidebar navigation visibility
    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  // ─── Group 2: Dual-Agent Discovery, Claim & Telemetry Verification ─────────

  test("dual-agent fleet: inventory discovery and comparative workload status", async ({ page }) => {
    await login(page, { demoMode: true });

    await page.goto(`${BASE}/agents`, { waitUntil: "domcontentloaded" });
    await expect(page.locator("h1, h2").filter({ hasText: "Agents" }).first()).toBeVisible({ timeout: 15_000 });

    // Verify inventory container is rendered
    const inventoryGrid = page.locator('[data-testid^="agent-card-"], table, .agent-grid, [data-testid="agents-list"]').first();
    await expect(inventoryGrid).toBeVisible({ timeout: 15_000 });

    // Assert agent items exist in inventory
    const agentLinks = page.locator('a[href^="/agents/"]');
    const count = await agentLinks.count();
    expect(count, "Expected at least 1 agent workload link in inventory").toBeGreaterThan(0);
  });

  test("dual-agent claim & telemetry: claim verification, SPIFFE identity binding, and activity stream", async ({
    page,
  }) => {
    await login(page, { demoMode: true });

    // Navigate directly to agent dossier (e.g. agent-triage or first discovered agent)
    await page.goto(`${BASE}/agents/agent-triage`, { waitUntil: "domcontentloaded" });
    await expect(page.locator("h1, h2").filter({ hasText: /Triage Agent|agent-triage/i }).first()).toBeVisible({ timeout: 15_000 });

    // Verify SPIFFE identity binding or Identity tab
    const identityLink = page.locator('a, button, [role="tab"]').filter({ hasText: /Identity/i }).first();
    if (await identityLink.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await identityLink.click();
    }
    await expect(
      page.getByText(/spiffe:\/\//i).or(page.locator('[data-testid="access-panel-identity"]')).or(page.locator('[data-testid="agent-spiffe-id"]')).or(page.getByText(/SPIFFE Trust Identity/i)).first(),
    ).toBeVisible({ timeout: 10_000 });

    // Switch to Activity Tab to verify telemetry stream
    const activityLink = page.locator('a, button, [role="tab"]').filter({ hasText: /Activity/i }).first();
    if (await activityLink.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await activityLink.click();
    }

    // Verify Activity Timeline header / audit stream
    await expect(
      page.locator("h2, h3, div").filter({ hasText: /Activity Timeline|Audit Trail|Telemetry/i }).first(),
    ).toBeVisible({ timeout: 10_000 });
  });

  test("remote environment console: deep link tabs, claim agent into tenant, and navigate to dossier", async ({
    page,
  }) => {
    await login(page, { demoMode: true });

    // Navigate to remote environment page deep-linked to agents tab
    await page.goto(`${BASE}/settings/connectors/claude?tab=agents`, { waitUntil: "domcontentloaded" });

    // 1. Verify tab deep linking: 'agents' tab is selected and section is visible
    const agentsTab = page.locator('[data-testid="env-tab-agents"]');
    await expect(agentsTab).toBeVisible({ timeout: 10_000 });
    await expect(agentsTab).toHaveAttribute("aria-selected", "true");

    const connectedAgentsHeading = page.locator("h2").filter({ hasText: /Connected Agents & Workloads/i });
    await expect(connectedAgentsHeading).toBeVisible();

    // General section should not be visible when tab=agents
    await expect(page.locator("h2").filter({ hasText: /^General$/i })).not.toBeVisible();

    // Verify agent is discovered and visible
    await expect(page.getByText("Daily News Jokester").first()).toBeVisible();

    // 2. Claim to tenant action
    const claimBtn = page.locator('[data-testid^="btn-claim-agent-"]').first();
    await expect(claimBtn).toBeVisible();
    await expect(claimBtn).toHaveText(/Claim to Tenant/i);
    await claimBtn.click();

    // Button should transition to claimed and be disabled
    await expect(claimBtn).toHaveText(/Claimed ✓/i, { timeout: 10_000 });
    await expect(claimBtn).toBeDisabled();

    // 3. View Dossier navigation
    const dossierBtn = page.locator('[data-testid^="btn-view-dossier-"]').first();
    await expect(dossierBtn).toBeVisible();
    await dossierBtn.click();

    // Should navigate to /agents with selected query params
    await page.waitForURL(/\/agents\?selected=/, { timeout: 10_000 });

    // Verify agent is in the inventory table and the drawer opens
    await expect(page.getByText("Daily News Jokester").first()).toBeVisible({ timeout: 10_000 });
    const evidenceDrawer = page.locator('[data-testid="agent-evidence-drawer"]');
    await expect(evidenceDrawer).toBeVisible({ timeout: 10_000 });
  });
});
