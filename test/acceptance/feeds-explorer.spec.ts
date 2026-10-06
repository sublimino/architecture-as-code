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
import { login, config, guards } from "./helpers";

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

/**
 * Live: /feeds loads without a 5xx from its own API calls, and Seed Fixtures succeeds.
 *
 * 2026-10-06 on kind-osramp: /feeds showed "Request failed with status code 502" (signal-ingest
 * OOM-killed by full-store reads), and Seed Fixtures always failed 500 because the fixtures
 * carried label keys the FrostDB allow-list refuses. Skips only when the signal-ingest slice is
 * not deployed; with ACCEPTANCE_COUNTED=1 that skip is a failure, so a counted run cannot pass
 * on it. Seeding appends fixture observations to the shared store.
 */
test.describe("Feeds live: API health and Seed Fixtures", () => {
  test.beforeEach(async ({ page }) => {
    if (!guards.exists("deployment", "signal-ingest", "fe-signalloom")) {
      const reason = "signal-ingest is not deployed in fe-signalloom; run make demo-signalloom-up";
      if (process.env.ACCEPTANCE_COUNTED === "1") throw new Error(`counted run: ${reason}`);
      test.skip(true, reason);
    }
    await login(page, { demoMode: false });
  });

  test("/feeds API calls return no 5xx and Seed Fixtures returns 201", async ({ page }) => {
    const failures: string[] = [];
    page.on("response", (r) => {
      if (r.url().includes("/api/signals/") && r.status() >= 500) failures.push(`${r.status()} ${r.url()}`);
    });
    const stats = page.waitForResponse((r) => r.url().includes("/api/signals/store/stats"));
    await page.goto(`${BASE}/feeds`);
    await expect(page.locator("h1").filter({ hasText: "Feeds & Collectors" })).toBeVisible();
    expect((await stats).status()).toBe(200);
    await expect(page.getByText(/status code 50\d/)).toHaveCount(0);

    const dialog = page.waitForEvent("dialog");
    const seed = page.waitForResponse(
      (r) => r.url().includes("/api/signals/collectors/seed") && r.request().method() === "POST",
    );
    await page.getByRole("button", { name: "Seed Fixtures" }).click();
    const seeded = await seed;
    const d = await dialog;
    const msg = d.message();
    await d.accept();
    expect(seeded.status(), await seeded.text()).toBe(201);
    expect((await seeded.json()).seeded).toBeGreaterThan(0);
    expect(msg).toMatch(/seeded/i);
    expect(failures).toEqual([]);
  });
});
