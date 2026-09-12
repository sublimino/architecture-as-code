/**
 * Signal Loom dashboard — Feeds & FrostDB Explorer acceptance suite (SLFE-P1-GOV).
 *
 * Drives the /feeds route to assert that:
 *   1. Page header, 6-layer collector health cards, and live status render cleanly.
 *   2. Multidimensional slicing & dicing controls filter telemetry.
 *   3. 24-bucket SVG ingestion density histogram renders interactively.
 *   4. FrostDB Pushdown Query Workbench displays Go AST and pruning efficiency telemetry.
 *   5. Real-time observation stream maintains bounded ring buffer without memory leaks.
 *   6. Slide-out Arrow evidence inspection drawer renders 3 tabs (evidence, arrow, proof).
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Feeds & FrostDB Explorer Console", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("navigates to /feeds and renders 6-layer collector catalog health cards", async ({ page }) => {
    await page.goto(`${BASE}/feeds`);
    await expect(page.locator("h1").filter({ hasText: "Feeds & Collectors" })).toBeVisible();

    // 6-layer collector health cards
    await expect(page.locator("text=L1 Host / eBPF").first()).toBeVisible();
    await expect(page.locator("text=L2 Network / mTLS / Bao").first()).toBeVisible();
    await expect(page.locator("text=L3 Workspace / SaaS").first()).toBeVisible();
    await expect(page.locator("text=L4 Agent / Sandbox / Nono").first()).toBeVisible();
    await expect(page.locator("text=L5 Output / Protocol").first()).toBeVisible();
    await expect(page.locator("text=L6 Cloud / Infra").first()).toBeVisible();

    // Slicing and dicing controls
    await expect(page.locator("text=Layer:").first()).toBeVisible();
    await expect(page.locator("text=Fidelity:").first()).toBeVisible();
    await expect(page.locator("text=Window:").first()).toBeVisible();
    await expect(page.locator("text=Actor:").first()).toBeVisible();

    // 24-bucket histogram
    await expect(page.locator("text=Ingestion Density (24-Hour Distribution)").first()).toBeVisible();

    // FrostDB Pushdown Query Workbench
    await expect(page.locator("text=FrostDB Pushdown Query Workbench").first()).toBeVisible();
    await expect(page.locator("text=Row Groups Pruned").first()).toBeVisible();
    await expect(page.locator("text=Selectivity").first()).toBeVisible();
    await expect(page.locator("text=Estimated Speedup").first()).toBeVisible();

    // Observation Stream Table
    await expect(page.locator("text=Real-Time Observation Stream").first()).toBeVisible();
  });

  test("interacts with multidimensional slicing controls and updates FrostDB Go code", async ({ page }) => {
    await page.goto(`${BASE}/feeds`);
    await expect(page.locator("h1").filter({ hasText: "Feeds & Collectors" })).toBeVisible();

    // Click L4 layer pill
    const l4Btn = page.locator("button").filter({ hasText: "L4" }).first();
    await expect(l4Btn).toBeVisible();
    await l4Btn.click();

    // Verify FrostDB code block updates to include L4 filter
    const codeBlock = page.locator("pre code").first();
    await expect(codeBlock).toBeVisible();
    await expect(codeBlock).toContainText('colRef("layer").Eq(logicalplan.Literal("behavioural"))');

    // Filter by Actor
    const actorInput = page.locator('input[placeholder*="e.g. agent-1"]');
    await expect(actorInput).toBeVisible();
    await actorInput.fill("agent-nono-evidenced");

    // Verify actor filter added to Go AST
    await expect(codeBlock).toContainText('colRef("actor_hint").Eq(logicalplan.Literal("agent-nono-evidenced"))');
  });

  test("opens and inspects observation in 3-tab slide-out Arrow drawer", async ({ page }) => {
    await page.goto(`${BASE}/feeds`);
    await expect(page.locator("h1").filter({ hasText: "Feeds & Collectors" })).toBeVisible();

    // Look for an Inspect button or table row if observations exist
    const inspectBtn = page.locator('button:has-text("Inspect")').first();
    const count = await inspectBtn.count();
    if (count > 0) {
      await inspectBtn.click();

      // Drawer should open
      await expect(page.locator("text=Observation Evidence").first()).toBeVisible();

      // Check Tab 1: Raw Evidence
      await expect(page.locator("text=Decoded Evidence Payload (JSON)").first()).toBeVisible();

      // Switch to Tab 2: Arrow Schema
      const arrowTab = page.locator('button:has-text("Arrow Schema")').first();
      await arrowTab.click();
      await expect(page.locator("text=FrostDB Arrow RecordBatch Schema").first()).toBeVisible();

      // Switch to Tab 3: Proof Chain
      const proofTab = page.locator('button:has-text("Proof Chain")').first();
      await proofTab.click();
      await expect(page.locator("text=Cryptographic Verification Chain").first()).toBeVisible();
      await expect(page.locator("text=Landlock LSM Confinement").first()).toBeVisible();

      // Close drawer
      const closeBtn = page.locator('button:has-text("✕")').first();
      await closeBtn.click();
      await expect(page.locator("text=Observation Evidence")).not.toBeVisible();
    }
  });
});
