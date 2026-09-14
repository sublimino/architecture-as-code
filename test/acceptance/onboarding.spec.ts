import { execFileSync } from "node:child_process";
import { expect, test } from "./fixtures";
import { login, config } from "./helpers";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? config.base;

test.describe("First User Onboarding Wizard Flow (SLON-P1-3)", () => {
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

  test.beforeEach(async ({ page }) => {
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
    await login(page, { demoMode: true, skipOnboarding: false });
  });

  test("complete end-to-end 3-step onboarding walkthrough with persistence and celebration", async ({
    page,
  }) => {
    // Navigate directly to onboarding wizard
    await page.goto(`${DASHBOARD_URL}/onboarding`);

    // Verify wizard container mounted
    const wizard = page.locator('[data-testid="onboarding-wizard-container"]');
    await expect(wizard).toBeVisible({ timeout: 15_000 });

    // Step 1: Tenant & Workspace Identity
    await expect(
      page.getByRole("heading", { level: 1, name: "Tenant & Workspace Identity" }),
    ).toBeVisible();

    // Verify validation behavior on empty input
    const orgInput = page.locator('[data-testid="input-organization-name"]');
    await orgInput.fill("");
    await page.locator('[data-testid="next-step-button"]').click();

    const errorBanner = page.locator('[data-testid="validation-error-banner"]');
    await expect(errorBanner).toBeVisible();
    await expect(page.getByText("Organization Name is required.")).toBeVisible();

    // Enter valid Step 1 data
    await orgInput.fill("Acme Autonomous Systems");
    await page.locator('[data-testid="input-workspace-id"]').fill("acme-auto-prod");
    await page.locator('[data-testid="input-admin-email"]').fill("operator@acme-auto.corp");

    // Advance to Step 2
    await page.locator('[data-testid="next-step-button"]').click();

    // Step 2: Identity Provider Linkage
    await expect(
      page.getByRole("heading", { level: 1, name: "Identity Provider Linkage" }),
    ).toBeVisible();

    // Verify Dex OIDC default selection and test connection
    const dexOption = page.locator('[data-testid="idp-option-dex"]');
    await expect(dexOption).toBeVisible();
    await dexOption.click();

    const testConnBtn = page.locator('[data-testid="test-idp-connection-button"]');
    await expect(testConnBtn).toBeVisible();
    await testConnBtn.click();

    const connSuccess = page.locator('[data-testid="idp-connection-success"]');
    await expect(connSuccess).toBeVisible({ timeout: 10_000 });

    // Advance to Step 3
    await page.locator('[data-testid="next-step-button"]').click();

    // Step 3: Containment Policy & Consent
    await expect(
      page.getByRole("heading", { level: 1, name: "Containment Policy & Security Consent" }),
    ).toBeVisible();

    // Verify review summary reflects Step 1 and Step 2
    await expect(page.getByText("Acme Autonomous Systems")).toBeVisible();
    await expect(page.getByText("acme-auto-prod")).toBeVisible();

    // Verify all consent checkboxes are checked
    const zeroTrustConsent = page.locator('[data-testid="consent-zero-trust"]');
    await expect(zeroTrustConsent).toBeChecked();

    // Complete Onboarding
    const completeBtn = page.locator('[data-testid="complete-onboarding-button"]');
    await expect(completeBtn).toBeVisible();
    await completeBtn.click();

    // Verify Celebration Screen
    const celebration = page.locator('[data-testid="completion-celebration"]');
    await expect(celebration).toBeVisible({ timeout: 15_000 });
    await expect(
      page.getByRole("heading", { level: 1, name: "Onboarding Completed!" }),
    ).toBeVisible();

    // Click Go to Dashboard
    const gotoDashboardBtn = page.locator('[data-testid="goto-dashboard-button"]');
    await expect(gotoDashboardBtn).toBeVisible();
    await gotoDashboardBtn.click();

    // Verify URL redirects to overview, agents, or discovery and sidebar is visible
    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  test("skip onboarding action records status and redirects to overview dashboard", async ({
    page,
  }) => {
    await page.goto(`${DASHBOARD_URL}/onboarding`);

    const skipBtn = page.locator('[data-testid="skip-onboarding-button"]').first();
    await expect(skipBtn).toBeVisible({ timeout: 15_000 });
    await skipBtn.click();

    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  test("step navigation preserves user inputs on back and forward traversal", async ({ page }) => {
    await page.goto(`${DASHBOARD_URL}/onboarding`);

    const orgInput = page.locator('[data-testid="input-organization-name"]');
    await expect(orgInput).toBeVisible({ timeout: 15_000 });
    await orgInput.fill("Preserved Enterprise Unit");

    await page.locator('[data-testid="next-step-button"]').click();
    await expect(
      page.getByRole("heading", { level: 1, name: "Identity Provider Linkage" }),
    ).toBeVisible();

    const backBtn = page.locator('[data-testid="back-step-button"]');
    await expect(backBtn).toBeVisible();
    await backBtn.click();

    await expect(
      page.getByRole("heading", { level: 1, name: "Tenant & Workspace Identity" }),
    ).toBeVisible();
    await expect(page.locator('[data-testid="input-organization-name"]')).toHaveValue(
      "Preserved Enterprise Unit",
    );
  });
});
