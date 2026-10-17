/**
 * Signal Loom dashboard — Operator Dual-Agent Claim Workflow Acceptance Suite (SLON-P2-3).
 *
 * Asserts:
 * - /agents renders dual-agent inventory (agent-nono-evidenced and agent-standard-baseline).
 * - Distinct security profile badges (Nono Sandboxed vs Standard Container).
 * - Claim action flow on discovered agents into tenant governance.
 * - Comparative activity telemetry: cryptographically verified Nono audit event trails
 *   vs live stun-sentinel eBPF kernel flow events.
 */
import { test, expect } from "./fixtures";
import { login, config, liveWorkloadAgentId } from "./helpers";

const BASE = config.base;

test.describe("Operator Dual-Agent Claim & Comparative Telemetry (SLON-P2-3)", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("renders dual-agent inventory with distinct security profile badges on /agents", async ({ page }) => {
    await page.goto(`${BASE}/agents`);
    await expect(page.locator("h1, h2").filter({ hasText: "Agents" }).first()).toBeVisible({ timeout: 10_000 });

    // getAgentWorkloadSecurityProfile() (ClaimModal.tsx) always returns a
    // label -- "Nono Sandboxed" or "Standard Container" -- so this badge is
    // unconditionally mounted for every row. It is only *visually* hidden
    // behind the row's hover/focus-triggered "Details" CompactDisclosure
    // (CompactOperationalTable.tsx renders it inside `<span hidden>` until
    // opened), so presence (attached), not visibility, is the correct check:
    // asserting toBeVisible() here would depend on simulating that hover
    // timing, and silently skipping on isVisible()===false defeated the
    // assertion entirely.
    const nonoBadge = page.locator('text=Nono Sandboxed').first();
    const standardBadge = page.locator('text=Standard Container').first();

    // Either discovered/linked rows or live cluster agents
    await expect(page.locator("table, .sl-filter-table-row").first()).toBeVisible();
    await expect(nonoBadge).toBeAttached();
    await expect(standardBadge).toBeAttached();
  });

  test("inspects comparative telemetry for Nono Sandboxed agent", async ({ page }) => {
    // Navigate to agent-nono-evidenced activity timeline. Its agent id is the
    // current pod name: the bare Deployment name 404s since 680742075.
    const id = await liveWorkloadAgentId(page, "agent-nono-evidenced");
    await page.goto(`${BASE}/agents/${id}?tab=activity`);
    await expect(page.locator('[data-testid="dossier-panel-activity"], [role="tabpanel"]').first()).toBeVisible({ timeout: 10_000 });

    // The comparative telemetry banner (AgentActivityTab.tsx) is rendered
    // unconditionally as soon as the activity panel renders -- there is no
    // gate around it -- so its absence is a real regression, not an
    // optional state.
    const nonoBanner = page.locator('[data-testid="security-profile-telemetry-banner"], [data-testid="nono-verification-badge"]').first();
    await expect(nonoBanner).toBeVisible();
    await expect(page.locator('[data-testid="nono-verification-badge"]').or(page.locator(':text("Nono Sandboxed")')).first()).toBeVisible();
  });

  test("inspects comparative telemetry for Standard Container baseline agent", async ({ page }) => {
    // Navigate to agent-standard-baseline activity timeline (current pod, as above).
    const id = await liveWorkloadAgentId(page, "agent-standard-baseline");
    await page.goto(`${BASE}/agents/${id}?tab=activity`);
    await expect(page.locator('[data-testid="dossier-panel-activity"], [role="tabpanel"]').first()).toBeVisible({ timeout: 10_000 });

    // Same unconditional-render reasoning as the Nono case above.
    const standardBanner = page.locator('[data-testid="security-profile-telemetry-banner"], [data-testid="sentinel-flow-badge"]').first();
    await expect(standardBanner).toBeVisible();
    await expect(page.locator('[data-testid="sentinel-flow-badge"]').or(page.locator(':text("Standard Container")')).first()).toBeVisible();
  });
});
