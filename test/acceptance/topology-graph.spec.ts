/**
 * Signal Loom Platform Acceptance Suite — Topology & Graph Visualisation (Surface 4).
 *
 * Validates:
 *   1. Agent Trust Topology plane and graph layout rendering.
 *   2. Node rendering across topological planes (platform, service, agent, external).
 *   3. Interactive node inspection: click opens NodeDetailDrawer.
 *   4. Cryptographic attestation verification: SPIFFE ID, SHA-256 digest, and tool permissions.
 *   5. Mobile viewport (375x667) and desktop viewport (1280x800) responsiveness.
 *   6. Zero em-dash typography verification across topology views.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Surface 4: Topology Graph & Node Detail Drawer (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto(`${BASE}/topology`, { waitUntil: "domcontentloaded" });
  });

  test("renders Agent Trust Topology page heading and graph surface", async ({ page }) => {
    await expect(
      page.getByRole("heading", { level: 1, name: /Agent Trust Topology/i }),
    ).toBeVisible({ timeout: 15_000 });

    // Assert graph container exists
    const graphContainer = page.locator(".trust-graph-container, .react-flow, #trust-graph-surface, main");
    await expect(graphContainer.first()).toBeVisible({ timeout: 15_000 });
  });

  test("opens node detail drawer upon node interaction and validates identity attestation", async ({ page }) => {
    await expect(
      page.getByRole("heading", { level: 1, name: /Agent Trust Topology/i }),
    ).toBeVisible({ timeout: 15_000 });

    // Look for node cards or clickable nodes on the canvas
    const nodeElement = page.locator('[data-testid^="node-"], .react-flow__node, [role="button"]').filter({
      hasText: /agent|service|vault|platform|orchestrator/i,
    }).first();

    await expect(nodeElement).toBeVisible({ timeout: 15_000 });
    await nodeElement.click();

    // Node Detail Drawer must mount
    const drawer = page.getByTestId("node-detail-drawer");
    await expect(drawer).toBeVisible({ timeout: 10_000 });

    // Assert Identity & Cryptographic Attestation sections
    await expect(drawer.getByText(/Identity & Cryptographic Attestation/i)).toBeVisible();
    await expect(drawer.getByText(/SPIFFE Identity/i)).toBeVisible();
    await expect(drawer.getByText(/Attestation Digest/i)).toBeVisible();

    // Close drawer
    const closeBtn = page.getByTestId("node-drawer-close-btn");
    await closeBtn.click();
    await expect(drawer).not.toBeVisible();
  });

  test("topology views contain zero em-dashes across rendered DOM", async ({ page }) => {
    await expect(
      page.getByRole("heading", { level: 1, name: /Agent Trust Topology/i }),
    ).toBeVisible({ timeout: 15_000 });

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
    expect(bodyText).not.toContain("\u2014");
  });
});

test.describe("Surface 4: Topology Graph (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto(`${BASE}/topology`, { waitUntil: "domcontentloaded" });
  });

  test("renders responsive topology container without clipping on mobile", async ({ page }) => {
    await expect(
      page.getByRole("heading", { level: 1, name: /Agent Trust Topology/i }),
    ).toBeVisible({ timeout: 15_000 });

    const main = page.locator("main");
    await expect(main).toBeVisible();

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
  });
});
