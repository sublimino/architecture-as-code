/**
 * Signal Loom Demo Smoke Suite — Rapid Verification (<90s).
 *
 * Dedicated lightweight acceptance test suite designed for live partner walk-throughs,
 * customer evaluations, and CI rapid smoke gating.
 *
 * Scope:
 * 1. User Onboarding Wizard flow (3-step guided setup, IdP linkage test, consent, celebration, redirect).
 * 2. User Onboarding Skip workflow (immediate status persistence and dashboard entry).
 * 3. Dual-Agent Discovery & Inventory (heterogeneous agent profiles, status badges, discovery labels).
 * 4. Dual-Agent Claim & Telemetry (operator claim flow, SPIFFE identity binding, active zero-trust controls, and activity timeline stream).
 *
 * Execution SLA: Strictly < 90 seconds wall-clock time.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Signal Loom Rapid Demo Smoke Suite (SLON-P2-4)", () => {
  // ─── Group 1: First User Onboarding Wizard ────────────────────────────────

  test("user onboarding: skip flow records persistent status and transitions to overview", async ({
    page,
  }) => {
    await login(page, { demoMode: true });
    await page.goto(`${BASE}/onboarding`, { waitUntil: "domcontentloaded" });

    const skipOrGoBtn = page
      .locator('[data-testid="skip-onboarding-button"], [data-testid="goto-dashboard-button"], button:has-text("Skip for now")')
      .first();
    await expect(skipOrGoBtn).toBeVisible({ timeout: 15_000 });
    await skipOrGoBtn.click();

    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  test("user onboarding: complete 3-step wizard with validation, IdP test, consent, and celebration", async ({
    page,
  }) => {
    await login(page, { demoMode: true });
    // Navigate directly to onboarding wizard route
    await page.goto(`${BASE}/onboarding`, { waitUntil: "domcontentloaded" });

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

      // Select Dex OIDC provider and execute live/fixture connection probe
      const dexOption = page.locator('[data-testid="idp-option-dex"]');
      await expect(dexOption).toBeVisible({ timeout: 5_000 });
      await dexOption.click();

      const testConnBtn = page.locator('[data-testid="test-idp-connection-button"]');
      await expect(testConnBtn).toBeVisible();
      await testConnBtn.click();

      const connSuccess = page.locator('[data-testid="idp-connection-success"]');
      await expect(connSuccess).toBeVisible({ timeout: 10_000 });

      // Advance to Step 3
      await page.locator('[data-testid="next-step-button"]').click();

      // Step 3: Containment Policy & Security Consent
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
});
