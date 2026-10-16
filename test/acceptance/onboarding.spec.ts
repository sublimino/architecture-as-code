import { execFileSync } from "node:child_process";
import { expect, test } from "./fixtures";
import { login, config } from "./helpers";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? config.base;

/**
 * The wizard opens on a welcome screen for a tenant with no saved progress
 * (OnboardingWizard.tsx showWelcome); the step container and the skip
 * control render only after it. Every flow below starts by dismissing it.
 */
async function dismissWelcome(page: import("@playwright/test").Page): Promise<void> {
  await expect(page.locator('[data-testid="onboarding-welcome"]')).toBeVisible({ timeout: 15_000 });
  await page.locator('[data-testid="welcome-continue-button"]').click();
  await expect(page.locator('[data-testid="onboarding-wizard-container"]')).toBeVisible({ timeout: 15_000 });
}

test.describe("First User Onboarding Wizard Flow (SLON-P1-3)", () => {
  test.afterAll(async () => {
    const kubeconfigPath = process.env.KUBECONFIG || (require("fs").existsSync("/tmp/osramp-kubeconfig.yaml") ? "/tmp/osramp-kubeconfig.yaml" : undefined);
    const execOpts: import("node:child_process").ExecFileSyncOptions = {
      stdio: "ignore",
      env: kubeconfigPath ? { ...process.env, KUBECONFIG: kubeconfigPath } : process.env,
    };
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
        execOpts,
      );
    } catch {
      // Ignore if cluster or postgres is unreachable
    }
  });

  test.beforeEach(async ({ page }) => {
    const kubeconfigPath = process.env.KUBECONFIG || (require("fs").existsSync("/tmp/osramp-kubeconfig.yaml") ? "/tmp/osramp-kubeconfig.yaml" : undefined);
    const execOpts: import("node:child_process").ExecFileSyncOptions = {
      stdio: "ignore",
      env: kubeconfigPath ? { ...process.env, KUBECONFIG: kubeconfigPath } : process.env,
    };
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
        execOpts,
      );
    } catch {
      // Ignore if cluster or postgres is unreachable
    }
    await login(page, { demoMode: true, skipOnboarding: false });
  });

  test("complete end-to-end five-step onboarding walkthrough with persistence and celebration", async ({
    page,
  }) => {
    // Navigate directly to onboarding wizard
    await page.goto(`${DASHBOARD_URL}/onboarding`);
    await dismissWelcome(page);

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

    // Dex is the portal's own issuer: its modal has no fields, and Test
    // Connection is the session probe (GET /api/v1/me), not a connector test.
    await expect(page.locator('[data-testid="idp-option-dex"]')).toBeVisible();
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
    await expect(page.getByRole("heading", { level: 1, name: "Set your scan preferences" })).toBeVisible();

    // Advance to Step 4: the optional API key reveal, declined here
    await page.locator('[data-testid="next-step-button"]').click();
    await expect(page.getByRole("heading", { level: 1, name: "Your API key" })).toBeVisible();

    // Advance to Step 5
    await page.locator('[data-testid="next-step-button"]').click();

    // Step 5: Containment Policy & Consent
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
    await dismissWelcome(page);

    const skipBtn = page.locator('[data-testid="skip-onboarding-button"]').first();
    await expect(skipBtn).toBeVisible({ timeout: 15_000 });
    await skipBtn.click();

    await page.waitForURL(/\/(overview|agents|discovery)/, { timeout: 15_000 });
    await expect(page.locator("nav a[href='/agents'], nav a[href='/discovery']").first()).toBeVisible({ timeout: 10_000 });
  });

  test("step navigation preserves user inputs on back and forward traversal", async ({ page }) => {
    await page.goto(`${DASHBOARD_URL}/onboarding`);
    await dismissWelcome(page);

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

  test("links Claude (Anthropic) and OpenAI read-only providers in Identity Provider Linkage with connection test", async ({ page }) => {
    await page.goto(`${DASHBOARD_URL}/onboarding`);
    await dismissWelcome(page);

    // Step 1: Advance past Tenant Identity
    const orgInput = page.locator('[data-testid="input-organization-name"]');
    await expect(orgInput).toBeVisible({ timeout: 15_000 });
    await orgInput.fill("Signal Loom AI Governance Corp");
    await page.locator('[data-testid="next-step-button"]').click();

    // Step 2: Identity Provider Linkage
    await expect(
      page.getByRole("heading", { level: 1, name: "Identity Provider Linkage" }),
    ).toBeVisible();

    // Each AI provider opens the real modal with the fields the backend
    // declares (wizard_config), tests through the connector API, and saves.
    // This suite runs with demo mode on, so the verdict comes from the
    // connectors simulator and must say so.
    for (const [id, key] of [
      ["claude", "sk-ant-api03-acceptance-test-key"],
      ["openai", "sk-proj-acceptance-test-key"],
    ] as const) {
      await expect(page.locator(`[data-testid="idp-option-${id}"]`)).toBeVisible({ timeout: 10_000 });
      await page.locator(`[data-testid="configure-idp-${id}"]`).click();
      const dialog = page.getByRole("dialog");
      await expect(dialog).toBeVisible();
      await expect(dialog.locator('[data-testid="tab-auth-oidc"]')).toHaveCount(0);
      await dialog.locator('[data-testid="wizard-field-api_key"]').fill(key);
      await dialog.locator('[data-testid="btn-modal-test-connection"]').click();
      await expect(dialog.locator('[data-testid="test-connection-success"]')).toContainText("Demo data", {
        timeout: 10_000,
      });
      await dialog.locator('[data-testid="btn-modal-save-connector"]').click();
      await expect(dialog).toBeHidden({ timeout: 10_000 });
      await expect(page.locator(`[data-testid="configured-tag-${id}"]`)).toBeVisible();
      await expect(page.locator('[data-testid="idp-connection-success"]')).toBeVisible();
    }

    // Advance to Step 3 with OpenAI selected
    await page.locator('[data-testid="next-step-button"]').click();

    // Step 3: Scan preferences
    await expect(page.getByRole("heading", { level: 1, name: "Set your scan preferences" })).toBeVisible();
  });

  test("configures connector via modal in Settings and runs Onboarding flow inside Settings", async ({ page }) => {
    // 1. Visit Settings Connectors tab
    await page.goto(`${DASHBOARD_URL}/settings?tab=connectors`);
    await expect(page.locator('[data-testid="settings-tabpanel-connectors"]')).toBeVisible({ timeout: 15_000 });

    // Verify Claude connector row and Configure button
    const configureClaudeBtn = page.locator('[data-testid="configure-connector-claude"]');
    await expect(configureClaudeBtn).toBeVisible({ timeout: 15_000 });
    await configureClaudeBtn.click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();
    await expect(page.getByRole("heading", { name: /Configure Anthropic Claude/i })).toBeVisible();

    // Fields come from the provider's wizard_config, including the admin key.
    await expect(dialog.locator('[data-testid="wizard-field-admin_api_key"]')).toBeVisible();
    await dialog.locator('[data-testid="wizard-field-api_key"]').fill("sk-ant-api03-acceptance-test-key");

    // Demo mode: the verdict is the connectors simulator's and says so.
    await dialog.locator('[data-testid="btn-modal-test-connection"]').click();
    await expect(dialog.locator('[data-testid="test-connection-success"]')).toContainText("Demo data", {
      timeout: 10_000,
    });

    await dialog.locator('[data-testid="btn-modal-save-connector"]').click();
    await expect(dialog).toBeHidden({ timeout: 10_000 });

    // 2. Visit Settings General tab and check Onboarding & Initial Setup card
    await page.goto(`${DASHBOARD_URL}/settings?tab=general`);
    await expect(page.locator('[data-testid="settings-tabpanel-general"]')).toBeVisible({ timeout: 15_000 });

    const launchOnboardingBtn = page.locator('[data-testid="btn-launch-onboarding-in-settings"]');
    await expect(launchOnboardingBtn).toBeVisible();
    await launchOnboardingBtn.click();

    // Verify URL switched to tab=onboarding and panel is rendered
    await expect(page).toHaveURL(/tab=onboarding/);
    await expect(page.locator('[data-testid="settings-tabpanel-onboarding"]')).toBeVisible();

    // Verify Onboarding Wizard is mounted inside settings
    await expect(page.locator('[data-testid="onboarding-wizard-container"]')).toBeVisible();
    await expect(page.locator('[data-testid="onboarding-progress-header"]')).toBeVisible();
  });

  test("executes connector scan now, verifies sync logs modal with telemetry, and inspects remote environment console page", async ({ page }) => {
    // 1. Visit Settings Connectors tab
    await page.goto(`${DASHBOARD_URL}/settings?tab=connectors`);
    await expect(page.locator('[data-testid="settings-tabpanel-connectors"]')).toBeVisible({ timeout: 15_000 });

    // 2. Ensure Claude connector is configured/connected
    const configureBtn = page.locator('[data-testid="configure-connector-claude"]');
    await expect(configureBtn).toBeVisible();
    await configureBtn.click();

    const dialog = page.getByRole("dialog");
    await expect(dialog).toBeVisible();

    // Fill in API key and save
    await dialog.locator('[data-testid="wizard-field-api_key"]').fill("sk-ant-api03-acceptance-test-key");
    await dialog.locator('[data-testid="wizard-field-workspace_id"]').fill("wrkspc_01CyCigBbDRSLTzSCyyHQ7eT");

    const saveBtn = page.locator('[data-testid="btn-modal-save-connector"]');
    await saveBtn.click();
    await expect(dialog).not.toBeVisible({ timeout: 10_000 });

    // 3. Test Scan Now action
    const scanBtn = page.locator('[data-testid="scan-connector-claude"]');
    await expect(scanBtn).toBeVisible();
    await scanBtn.click();
    // After scan completes, button is ready again
    await expect(scanBtn).toBeEnabled({ timeout: 10_000 });

    // 4. Test See Log / Sync Logs Modal
    const viewLogsBtn = page.locator('[data-testid="view-logs-claude"]');
    await expect(viewLogsBtn).toBeVisible();
    await viewLogsBtn.click();

    const logsModal = page.locator('[data-testid="sync-logs-modal"]');
    await expect(logsModal).toBeVisible({ timeout: 10_000 });
    await expect(logsModal).toContainText(/Sync & Telemetry Logs/i);
    await expect(logsModal).toContainText(/Anthropic Claude/i);

    // Verify search and level filter exist
    await expect(page.locator('[data-testid="sync-log-search"]')).toBeVisible();
    await expect(page.locator('[data-testid="sync-log-level-filter"]')).toBeVisible();
    await expect(page.locator('[data-testid="btn-copy-sync-logs"]')).toBeVisible();

    // Close logs modal
    const closeLogsBtn = page.locator('[data-testid="btn-close-sync-logs"]');
    await closeLogsBtn.click();
    await expect(logsModal).not.toBeVisible();

    // 5. Navigate to Remote Environment Console Page
    const viewEnvBtn = page.locator('[data-testid="view-environment-claude"]');
    await expect(viewEnvBtn).toBeVisible();
    await viewEnvBtn.click();

    // Verify on Remote Environment Console page
    await expect(page).toHaveURL(/\/settings\/connectors\/claude/);
    const envPage = page.locator('[data-testid="remote-environment-page"]');
    await expect(envPage).toBeVisible({ timeout: 15_000 });

    // Verify header, ID, and credits
    await expect(page.locator('[data-testid="env-title"]')).toContainText("cloud-dev");
    await expect(page.locator('[data-testid="env-badge-id"]')).toContainText("env_01CyCigBbDRSLTzSCyyHQ7eT");
    await expect(page.locator('[data-testid="env-credit-balance"]')).toContainText("US$23.57");

    // Verify Network Egress & CEL Governance section
    await expect(page.locator('[data-testid="network-egress-section"]')).toBeVisible();
    await expect(page.locator('[data-testid="package-managers-badge"]')).toContainText("ENABLED");
    await expect(page.locator('[data-testid="mcp-servers-badge"]')).toContainText("ENABLED");
    await expect(page.locator('[data-testid="allowed-hosts-list"]')).toContainText("0/16");
    await expect(page.locator('[data-testid="cel-policy-card"]')).toBeVisible();

    // Verify Back to Connectors link
    const backBtn = page.locator('[data-testid="link-back-connectors"]');
    await expect(backBtn).toBeVisible();
    await backBtn.click();
    await expect(page).toHaveURL(/tab=connectors/);
  });
});


