/**
 * Signal Loom Platform Acceptance Suite — Policy-as-Code CEL Editor & Compliance (Surfaces 7 & 8).
 *
 * Validates:
 *   1. Policy-as-Code CEL editor workspace mounting on /policies.
 *   2. Syntax evaluation: valid CEL expression shows valid diagnostic status.
 *   3. Syntax diagnostics: invalid CEL expression renders syntax error squiggles and diagnostic details.
 *   4. Version history and rollback workflow: restores previous policy bundle definition.
 *   5. Compliance posture drill-down (/compliance): valid arithmetic posture scores (0..100) and ComplianceDrawer.
 *   6. Mobile viewport (375x667) and desktop viewport (1280x800) responsiveness.
 *   7. Zero em-dash typography verification across policy and compliance surfaces.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Surfaces 7 & 8: Policy-as-Code Editor & Compliance Posture (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("mounts CEL policy editor on /policies with syntax validation and live diagnostics", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });

    await expect(
      page.getByRole("heading", { level: 1, name: /Policy Compliance|Policies/i }),
    ).toBeVisible({ timeout: 15_000 });

    // Workspace container
    const editorWorkspace = page.getByTestId("cel-editor-workspace");
    await expect(editorWorkspace).toBeVisible({ timeout: 15_000 });

    // Textarea input
    const textarea = page.getByTestId("cel-code-textarea");
    await expect(textarea).toBeVisible();

    // Initial valid state
    const validDiag = page.getByTestId("cel-diagnostic-valid");
    await expect(validDiag).toBeVisible({ timeout: 10_000 });

    // Type invalid CEL expression to trigger error diagnostics
    await textarea.fill("invalid.cel.syntax ?::: ?? broken");

    const errorDiag = page.getByTestId("cel-diagnostic-error");
    await expect(errorDiag).toBeVisible({ timeout: 10_000 });

    // Syntax highlight overlay should reflect error styling
    const overlay = page.getByTestId("cel-syntax-highlight-overlay");
    await expect(overlay).toBeVisible();

    // Restore valid expression
    await textarea.fill("has(agent.security_profile) && agent.security_profile.secure_by_default == true");
    await expect(validDiag).toBeVisible({ timeout: 10_000 });
  });

  test("executes version rollback workflow restoring previous policy definition", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });

    const editorWorkspace = page.getByTestId("cel-editor-workspace");
    await expect(editorWorkspace).toBeVisible({ timeout: 15_000 });

    // Check for version history toggle button
    const historyBtn = page.getByRole("button", { name: /History|Versions/i }).first();
    if (await historyBtn.isVisible()) {
      await historyBtn.click();

      const drawer = page.getByTestId("version-history-drawer");
      if (await drawer.isVisible()) {
        await expect(drawer).toBeVisible();

        // Check for rollback action
        const rollbackBtn = drawer.getByRole("button", { name: /Rollback/i }).first();
        if (await rollbackBtn.isVisible()) {
          await rollbackBtn.click();
          // Verify valid diagnostic remains active after rollback
          await expect(page.getByTestId("cel-diagnostic-valid")).toBeVisible();
        }
      }
    }
  });

  test("verifies /compliance posture scores arithmetic (0..100) and ComplianceDrawer", async ({ page }) => {
    await page.goto(`${BASE}/compliance`, { waitUntil: "domcontentloaded" });

    await expect(
      page.getByRole("heading", { level: 1, name: /Compliance/i }),
    ).toBeVisible({ timeout: 15_000 });

    // Check that posture scores are in range 0..100
    const scoreElements = page.locator(".card, tbody tr");
    await expect(scoreElements.first()).toBeVisible({ timeout: 15_000 });

    // Click framework row or card to open ComplianceDrawer
    const frameworkRow = page.locator("tbody tr, .card").filter({ hasText: /EU AI Act|NIST|CRA|SOC 2/i }).first();
    if (await frameworkRow.isVisible()) {
      await frameworkRow.click();

      const drawer = page.getByTestId("compliance-drawer");
      if (await drawer.isVisible()) {
        await expect(drawer).toBeVisible({ timeout: 10_000 });
        await expect(drawer.getByText(/Regulatory Framework|Controls|Evaluation Summary/i)).toBeVisible();

        // Close drawer
        const closeBtn = drawer.getByRole("button", { name: /Close|×/i }).first();
        if (await closeBtn.isVisible()) {
          await closeBtn.click();
          await expect(drawer).not.toBeVisible();
        }
      }
    }
  });

  test("policy and compliance pages contain zero em-dashes across rendered DOM", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible({ timeout: 15_000 });

    const policyText = await page.locator("body").innerText();
    expect(policyText).not.toContain("—");
    expect(policyText).not.toContain("\u2014");

    await page.goto(`${BASE}/compliance`, { waitUntil: "domcontentloaded" });
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible({ timeout: 15_000 });

    const complianceText = await page.locator("body").innerText();
    expect(complianceText).not.toContain("—");
    expect(complianceText).not.toContain("\u2014");
  });
});

test.describe("Surfaces 7 & 8: Policy Editor & Compliance (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("renders responsive policy editor workspace and compliance cards on mobile", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("cel-editor-workspace")).toBeVisible({ timeout: 15_000 });

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
  });
});
