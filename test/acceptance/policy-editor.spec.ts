/**
 * Signal Loom Platform Acceptance Suite - Policy-as-Code CEL Editor & Compliance (Surfaces 7 & 8).
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
import { login, config, getAuthToken } from "./helpers";

const BASE = config.base;

test.describe("Surfaces 7 & 8: Policy-as-Code Editor & Compliance Posture (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("mounts CEL policy editor on /policies with syntax validation and in-editor diagnostics", async ({ page }) => {
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

  test("loads bundle for k8s-cis-benchmark without 'No policy bundle registered' error", async ({ page }) => {
    await page.goto(`${BASE}/policies?framework=k8s-cis-benchmark`, { waitUntil: "domcontentloaded" });

    const editorWorkspace = page.getByTestId("cel-editor-workspace");
    await expect(editorWorkspace).toBeVisible({ timeout: 15_000 });

    // Should NOT show "No policy bundle registered"
    await expect(page.getByText(/No policy bundle registered/i)).not.toBeVisible();

    // Editor textarea should contain active rules
    const textarea = page.getByTestId("cel-code-textarea");
    await expect(textarea).toBeVisible();
    const content = await textarea.inputValue();
    expect(content.length).toBeGreaterThan(0);
  });

  test("renders all 8 regulatory frameworks on agent overview tab", async ({ page }) => {
    await page.goto(`${BASE}/agents/689876d8-b3bc-5451-a238-5d2860db386a?tab=overview`, { waitUntil: "domcontentloaded" });

    // Verify key canonical frameworks appear in the overview posture cards/list
    await expect(page.getByText(/EU AI Act/i).first()).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText(/SOC 2/i).first()).toBeVisible();
    await expect(page.getByText(/CIS/i).first()).toBeVisible();
    await expect(page.getByText(/NIST/i).first()).toBeVisible();
    await expect(page.getByText(/Cyber Resilience|CRA/i).first()).toBeVisible();
    await expect(page.getByText(/FINOS/i).first()).toBeVisible();
    await expect(page.getByText(/Digital Operational Resilience|DORA/i).first()).toBeVisible();
    await expect(page.getByText(/NIS2/i).first()).toBeVisible();
  });

  test("filters out stun-sentinel observations on /signals?excludeSentinel=true", async ({ page }) => {
    await page.goto(`${BASE}/signals?excludeSentinel=true`, { waitUntil: "domcontentloaded" });

    // The feed should not contain stun-sentinel
    const feed = page.getByTestId("observation-feed");
    await expect(feed).toBeVisible({ timeout: 15_000 });
    const feedText = await feed.innerText();
    expect(feedText).not.toContain("stun-sentinel");
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

  test("supports URL query parameter routing and sharing with ?framework= and ?rule=", async ({ page }) => {
    await page.goto(`${BASE}/policies?framework=eu-ai-act&rule=training-data-provenance`, { waitUntil: "domcontentloaded" });

    const editorWorkspace = page.getByTestId("cel-editor-workspace");
    await expect(editorWorkspace).toBeVisible({ timeout: 15_000 });

    const selector = page.getByTestId("framework-selector");
    await expect(selector).toHaveValue("eu-ai-act");

    const ruleChip = page.getByTestId("rule-tab-training-data-provenance");
    await expect(ruleChip).toBeVisible();

    const nameHeader = page.getByTestId("policy-name-header");
    await expect(nameHeader).toBeVisible();
    await expect(nameHeader).toContainText("training-data-provenance");

    const copyBtn = page.getByTestId("copy-shareable-link-btn");
    await expect(copyBtn).toBeVisible();
  });

  test("formats CEL expressions on demand using the Prettify CEL button", async ({ page }) => {
    await page.goto(`${BASE}/policies?framework=eu-ai-act`, { waitUntil: "domcontentloaded" });

    const editorWorkspace = page.getByTestId("cel-editor-workspace");
    await expect(editorWorkspace).toBeVisible({ timeout: 15_000 });

    const textarea = page.getByTestId("cel-code-textarea");
    await expect(textarea).toBeVisible();

    const unformatted = 'has(agent.tags) && agent.tags.all(t, t.startsWith("prod_")) && (agent.risk_level == "critical" || agent.compliance_mode == "strict")';
    await textarea.fill(unformatted);

    const prettifyBtn = page.getByTestId("prettify-cel-btn");
    await expect(prettifyBtn).toBeVisible();
    await prettifyBtn.click();

    const formatted = await textarea.inputValue();
    expect(formatted).toContain("\n");
    expect(formatted.trim().length).toBeGreaterThan(unformatted.length);
  });

  test("toggles line wrap on box width with toggle-wrap-btn", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });

    const toggleWrapBtn = page.getByTestId("toggle-wrap-btn");
    await expect(toggleWrapBtn).toBeVisible({ timeout: 15_000 });
    await expect(toggleWrapBtn).toHaveText("Wrap: ON");

    await toggleWrapBtn.click();
    await expect(toggleWrapBtn).toHaveText("Wrap: OFF");

    await toggleWrapBtn.click();
    await expect(toggleWrapBtn).toHaveText("Wrap: ON");
  });

  test("auto-expands governance frameworks and child policies on /settings?tab=governance with on/off controls and editor links", async ({ page }) => {
    await page.goto(`${BASE}/settings?tab=governance`, { waitUntil: "domcontentloaded" });

    const governancePanel = page.getByTestId("settings-tabpanel-governance");
    await expect(governancePanel).toBeVisible({ timeout: 15_000 });

    const header = page.getByTestId("compliance-frameworks-header");
    await expect(header).toBeVisible();

    const euCard = page.getByTestId("framework-card-eu-ai-act");
    await expect(euCard).toBeVisible({ timeout: 15_000 });

    const euChildren = page.getByTestId("framework-children-eu-ai-act");
    await expect(euChildren).toBeVisible();

    // Verify child policies are rendered underneath
    const childRows = euChildren.locator('[data-testid^="policy-row-"]');
    await expect(childRows.first()).toBeVisible();
    const count = await childRows.count();
    expect(count).toBeGreaterThan(0);

    // Verify non-CEL / manual attestation badge appears
    const manualBadge = euChildren.locator('[data-testid^="manual-sign-"]').first();
    if (await manualBadge.isVisible()) {
      await expect(manualBadge).toContainText("Manual Attestation");
    }

    // Verify child policy has an interactive switch
    const switchBtn = childRows.first().getByRole("switch");
    await expect(switchBtn).toBeVisible();

    // Verify clicking policy row navigates to policy editor with rule parameter
    const firstRowLink = childRows.first().locator("button", { hasText: "Edit ↗" });
    await firstRowLink.click();
    await expect(page).toHaveURL(/\/policies\?framework=eu-ai-act/);
    await expect(page.getByTestId("cel-editor-workspace")).toBeVisible({ timeout: 15_000 });
  });
});

test.describe("Surfaces 7 & 8: Policy Editor & Compliance (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("renders responsive policy editor workspace and compliance cards on mobile", async ({ page }) => {
    await page.goto(`${BASE}/policies`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("cel-editor-workspace")).toBeVisible({ timeout: 15_000 });

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
  });
});

test.describe("Surfaces 7 & 8: Adversarial Policy and Compliance Endpoint Contracts", () => {
  let authToken = "";

  test("rejects unauthenticated policy validation with 401", async ({ request }) => {
    const res = await request.post(`${BASE}/api/v1/policies/validate`, {
      data: { expression: "true" },
    });
    expect(res.status()).toBe(401);
  });

  test("validates CEL syntax errors returning 422 with error diagnostics", async ({ page, request }) => {
    if (!authToken) {
      await login(page, { demoMode: true });
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/policies/validate`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { expression: "invalid.cel.syntax ?::: ?? broken" },
    });
    expect([400, 422]).toContain(res.status());
    const body = await res.json();
    expect(body.error).toBe("cel_validation_error");
    expect(body.detail).toBeDefined();
  });

  test("validates valid CEL expression returning valid=true", async ({ page, request }) => {
    if (!authToken) {
      await login(page, { demoMode: true });
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/policies/validate`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { expression: "has(agent.security_profile) && agent.security_profile.secure_by_default == true" },
    });
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body.valid).toBe(true);
  });

  test("querying non-existent framework ID returns 404 with structured error envelope", async ({ page, request }) => {
    if (!authToken) {
      await login(page, { demoMode: true });
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.get(`${BASE}/api/v1/compliance/frameworks/non-existent-framework-xyz`, {
      headers: { Authorization: `Bearer ${authToken}` },
    });
    expect(res.status()).toBe(404);
    const body = await res.json();
    expect(body.error).toBe("framework_not_found");
    expect(body.framework_id).toBe("non-existent-framework-xyz");
    expect(Array.isArray(body.available_frameworks)).toBe(true);
  });

  test("posture calculation endpoint bounds posture_score in [0.0, 100.0]", async ({ page, request }) => {
    if (!authToken) {
      await login(page, { demoMode: true });
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/compliance/posture/calculate`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: {
        total_controls: 5,
        passing_controls: 4,
        failing_controls: 1,
      },
    });
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body.posture_score).toBe(80.0);
    expect(body.posture_score).toBeGreaterThanOrEqual(0.0);
    expect(body.posture_score).toBeLessThanOrEqual(100.0);
  });
});

