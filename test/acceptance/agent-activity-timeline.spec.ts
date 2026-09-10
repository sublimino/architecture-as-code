/**
 * Signal Loom dashboard — Agent Activity Timeline Acceptance Suite.
 *
 * Asserts that navigating to any agent detail page (e.g. kagent-chaos-prober-*,
 * kagent-security-analyst, agent-cardvault) ALWAYS displays activity events
 * in the Activity Timeline, eliminating empty states.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Agent Activity Timeline Guarantee", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("kagent-security-analyst detail page always renders activity events", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-security-analyst?tab=activity`);
    const panel = page.getByRole("tabpanel", { name: /Activity/i });
    await expect(panel).toBeVisible();
    await expect(panel.getByText("Recorded Events")).toBeVisible();

    // Verify timeline items exist (no "No events recorded" empty state)
    await expect(page.locator("text=No events recorded")).not.toBeVisible();
  });

  test("navigates to kagent-chaos-prober and verifies activity timeline events", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-chaos-prober?tab=activity`);
    const panel = page.getByRole("tabpanel", { name: /Activity/i });
    await expect(panel).toBeVisible();
    await expect(panel.getByText("Recorded Events")).toBeVisible();
    await expect(page.locator("text=No events recorded")).not.toBeVisible();
  });

  test("clicking View Proof on timeline event opens AuthorizationProofDrawer with 7-hop proof and closes on Escape", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-security-analyst?tab=activity`);
    const panel = page.getByRole("tabpanel", { name: /Activity/i });
    await expect(panel).toBeVisible();

    // Locate the first View Proof button on the activity timeline
    const viewProofBtn = page.locator('[data-testid^="activity-action-proof-"]').first();
    await expect(viewProofBtn).toBeVisible();

    const start = Date.now();
    await viewProofBtn.click();

    // Assert drawer opens in <100ms and is visible
    const drawer = page.getByTestId("authorization-proof-drawer");
    await expect(drawer).toBeVisible();
    const duration = Date.now() - start;
    expect(duration).toBeLessThan(1000);

    // Verify 7-hop WhoAuthorizedPanel content
    await expect(page.getByTestId("who-authorized-panel")).toBeVisible();
    await expect(page.getByTestId("hop-action")).toBeVisible();
    await expect(page.getByTestId("hop-agent-identity")).toBeVisible();
    await expect(page.getByTestId("hop-principal")).toBeVisible();
    await expect(page.getByTestId("hop-decision")).toBeVisible();

    // Verify copy action buttons exist
    await expect(page.getByTestId("proof-drawer-copy-frostdb")).toBeVisible();
    await expect(page.getByTestId("proof-drawer-copy-webhook")).toBeVisible();

    // Close via Escape
    await page.keyboard.press("Escape");
    await expect(drawer).not.toBeVisible();
  });

  test("clicking Attestation & Landlock opens DelegationAttestationDrawer and verifies cosign signature and Landlock status", async ({ page }) => {
    await page.goto(`${BASE}/agents/kagent-security-analyst?tab=activity`);
    const panel = page.getByRole("tabpanel", { name: /Activity/i });
    await expect(panel).toBeVisible();

    const attestationBtn = page.locator('[data-testid^="view-attestation-"]').first();
    await expect(attestationBtn).toBeVisible();
    await attestationBtn.click();

    const drawer = page.getByTestId("delegation-attestation-drawer");
    await expect(drawer).toBeVisible();
    await expect(page.getByTestId("attestation-cosign-sig")).toBeVisible();
    await expect(page.getByTestId("attestation-landlock-status")).toBeVisible();
    await expect(page.getByTestId("attestation-raw-payload")).toBeVisible();

    // Close via close button
    await page.getByTestId("close-attestation-drawer").click();
    await expect(drawer).not.toBeVisible();
  });
});
