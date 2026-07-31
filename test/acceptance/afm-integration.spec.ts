import { expect, test } from "@playwright/test";
import { login, config, afm } from "./helpers";

const BASE = config.base;

test.describe("AFM integration in Signal Loom", () => {
  test.beforeAll(async ({ request }) => {
    await afm.assertHealthy(request);
  });

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("RBAC Analysis nav item is visible in the sidebar", async ({ page }) => {
    const link = page.getByRole("link", { name: "RBAC Analysis", exact: true });
    await expect(link).toBeVisible();
  });

  test("RBAC Analysis page shows the AFM health indicator", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });

    // Health indicator — should show "AFM connected" (green dot) when AFM is running
    await expect(page.getByText("AFM connected")).toBeVisible({ timeout: 10_000 });
  });

  test("RBAC Analysis page shows the cluster count from AFM", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });

    // Cluster count — should show "N cluster(s)" from the AFM API
    await expect(page.getByText(/\d+ clusters?/)).toBeVisible({ timeout: 10_000 });
  });

  test("AFM iframe loads and renders the dashboard", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });

    // The iframe element must be present with the correct src
    const iframe = page.locator('[data-testid="afm-iframe"]');
    await expect(iframe).toBeVisible({ timeout: 10_000 });
    const src = await iframe.getAttribute("src");
    expect(src).toBe("/dashboard/");

    // Wait for the iframe to finish loading (the loading text should disappear)
    await expect(page.getByText("Loading KubeSec-AFM dashboard")).not.toBeVisible({ timeout: 15_000 });
  });

  test("Open full link opens AFM dashboard in a new tab target", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });

    // "Open full" link should be present and point to /dashboard/
    const openLink = page.getByText("Open full ↗");
    await expect(openLink).toBeVisible();
    const href = await openLink.getAttribute("href");
    expect(href).toBe("/dashboard/");
    const target = await openLink.getAttribute("target");
    expect(target).toBe("_blank");
  });

  test("Reload button refreshes the AFM iframe", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 15_000 });

    // Wait for initial iframe load
    const iframe = page.locator('[data-testid="afm-iframe"]');
    await expect(iframe).toBeVisible({ timeout: 10_000 });

    // Click reload — should show loading state briefly, then iframe reloads
    await page.getByRole("button", { name: "Reload" }).click();

    // Iframe should still be visible after reload
    await expect(iframe).toBeVisible({ timeout: 10_000 });
  });

  test("AFM API is accessible through the /afm/ proxy", async ({ page }) => {
    // Direct API call through the proxy — proves nginx routing works
    const response = await page.request.get(`${BASE}/afm/health`);
    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    expect(body.status).toBe("ok");
  });

  test("AFM clusters endpoint returns data through the proxy", async ({ page }) => {
    const response = await page.request.get(`${BASE}/afm/clusters`);
    expect(response.ok()).toBeTruthy();
    const clusters = await response.json();
    expect(Array.isArray(clusters)).toBeTruthy();
    // Should have seeded clusters from make demo-k8s-afm-up
    expect(clusters.length).toBeGreaterThan(0);
  });

  test("AFM dashboard HTML is served at /dashboard/ (same-origin proxy)", async ({ page }) => {
    const response = await page.request.get(`${BASE}/dashboard/`);
    expect(response.ok()).toBeTruthy();
    const html = await response.text();
    expect(html).toContain("K8s RBAC Attack Explorer");
    // Assets must resolve — a JS chunk should be served, not HTML
    const chunkMatch = html.match(/src="(\/dashboard\/_next\/static\/chunks\/[^"]+)"/);
    expect(chunkMatch).toBeTruthy();
    if (chunkMatch) {
      const chunkResponse = await page.request.get(`${BASE}${chunkMatch[1]}`);
      expect(chunkResponse.ok()).toBeTruthy();
      const contentType = chunkResponse.headers()["content-type"] ?? "";
      expect(contentType).toContain("javascript");
    }
  });
});
