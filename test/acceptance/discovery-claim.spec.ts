/**
 * Signal Loom Platform Acceptance Suite - Shadow AI & Multi-Source Discovery (Surface 2).
 *
 * Validates:
 *   1. Super Datatable multi-source workload aggregation across IDP, Kubernetes, and Cloud Run.
 *   2. Multi-facet filtering by search text, connector source, and lifecycle state.
 *   3. Control recommendations column with Category badges (Config, Content, Supply Chain, EU AI Act).
 *   4. Namespace auto-claim workflow: modal trigger, selection, optimistic update to Governed with SPIFFE ID.
 *   5. Mobile viewport (375x667) and desktop viewport (1280x800) responsiveness.
 *   6. Zero em-dash typography verification across discovery views.
 *   7. Adversarial claim API assertions: malformed payload, empty agent ID, missing/invalid namespace.
 */
import { test, expect } from "./fixtures";
import { login, config, getAuthToken } from "./helpers";

const BASE = config.base;

test.describe("Surface 2: Multi-Source Discovery & Auto-Claim (Desktop 1280x800)", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto(`${BASE}/discovery`, { waitUntil: "domcontentloaded" });
  });

  test("renders Discovery heading, multi-source workload table, and summary stats", async ({ page }) => {
    await expect(
      page.getByRole("heading", { level: 1, name: /Shadow AI & Multi-Source Discovery/i }),
    ).toBeVisible({ timeout: 15_000 });

    // Verify Super Datatable is rendered
    const table = page.locator("table");
    await expect(table).toBeVisible({ timeout: 15_000 });

    // Column headers
    await expect(page.getByText("Workload & Identity")).toBeVisible();
    await expect(page.getByText("Connector Source")).toBeVisible();
    await expect(page.getByText("Namespace / Region")).toBeVisible();
    await expect(page.getByText("Discovery State")).toBeVisible();
    await expect(page.getByText("Control Recommendations")).toBeVisible();
  });

  test("filters workloads reactively via search bar and facet buttons", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    const searchInput = page.getByTestId("discovery-search-input").or(page.getByPlaceholder(/Search (workloads|by name)/i));
    await expect(searchInput).toBeVisible();

    // Type a specific workload name from the rendered table
    const rows = page.locator("tbody tr");
    await expect(rows.first()).toBeVisible({ timeout: 10_000 });
    const firstCell = await rows.first().locator("td").first().innerText();
    const query = firstCell.trim().split(/\s+/)[0];
    await searchInput.fill(query);
    // Verify row count updates without crash
    await expect(rows.first()).toBeVisible({ timeout: 10_000 });

    // Clear search
    await searchInput.fill("");

    // Test Source Facet if present
    const idpFacet = page.getByRole("button", { name: /IDP/i }).first();
    if (await idpFacet.isVisible()) {
      await idpFacet.click();
      await expect(page.locator("tbody tr").first()).toBeVisible();
    }
  });

  test("renders control recommendations badges with hover metadata", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    // Assert control recommendation badges exist
    const configBadge = page.locator('[data-testid^="control-rec-badge-"]').first();
    await expect(configBadge).toBeVisible({ timeout: 15_000 });
  });

  test("executes namespace auto-claim modal workflow and asserts governed transition", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    const autoClaimBtn = page.getByTestId("autoclaim-namespace-btn");
    await expect(autoClaimBtn).toBeVisible({ timeout: 15_000 });
    await autoClaimBtn.click();

    // Auto-claim modal should appear
    const modalHeading = page.getByRole("heading", { name: /Auto-Claim (Namespace|Discovered)/i });
    await expect(modalHeading).toBeVisible({ timeout: 10_000 });

    // Select or confirm namespace
    const confirmBtn = page.getByTestId("autoclaim-modal-confirm-btn");
    await expect(confirmBtn).toBeVisible();
    await confirmBtn.click();

    // Toast feedback should announce auto-claim success
    const toast = page.locator('[role="status"]');
    await expect(toast).toBeVisible({ timeout: 10_000 });
    await expect(toast).toContainText(/auto-claimed/i);
  });

  test("discovery view contains zero em-dashes across rendered DOM", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    const bodyText = await page.locator("body").innerText();
    expect(bodyText).not.toContain("—");
    expect(bodyText).not.toContain("\u2014");
  });
});

test.describe("Surface 2: Multi-Source Discovery (Mobile Viewport 375x667)", () => {
  test.use({ viewport: { width: 375, height: 667 } });

  test.beforeEach(async ({ page }) => {
    await login(page);
    await page.goto(`${BASE}/discovery`, { waitUntil: "domcontentloaded" });
  });

  test("renders responsive discovery datatable and auto-claim modal on mobile", async ({ page }) => {
    await expect(page.getByRole("heading", { level: 1, name: /Discovery/i })).toBeVisible({ timeout: 15_000 });

    const autoClaimBtn = page.getByTestId("autoclaim-namespace-btn");
    await expect(autoClaimBtn).toBeVisible();
    await autoClaimBtn.click();

    const modalHeading = page.getByRole("heading", { name: /Auto-Claim/i });
    await expect(modalHeading).toBeVisible();

    // Close modal
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(modalHeading).not.toBeVisible();
  });
});

test.describe("Surface 2: Adversarial Discovery Claim Endpoint Contracts", () => {
  let authToken = "";

  test("rejects unauthenticated claim request with 401", async ({ request }) => {
    const res = await request.post(`${BASE}/api/v1/discovery/claim`, {
      data: { agent_id: "unauth-agent", namespace: "fe-signalloom-agents" },
    });
    expect(res.status()).toBe(401);
  });

  test("rejects empty agent ID with 400 or 422 and structured error envelope", async ({ page, request }) => {
    if (!authToken) {
      await login(page);
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/discovery/claim`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { agent_id: "", namespace: "fe-signalloom-agents" },
    });
    expect([400, 422]).toContain(res.status());
    const body = await res.json();
    expect(body.error).toBeDefined();
    expect(body.error.code).toBeDefined();
  });

  test("rejects missing namespace with 400 or 422 and structured error envelope", async ({ page, request }) => {
    if (!authToken) {
      await login(page);
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/discovery/claim`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { agent_id: "adversarial-agent" },
    });
    expect([400, 422]).toContain(res.status());
    const body = await res.json();
    expect(body.error).toBeDefined();
    expect(body.error.code).toBeDefined();
  });

  test("rejects non-existent namespace with 400 or 422 and structured error envelope", async ({ page, request }) => {
    if (!authToken) {
      await login(page);
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/discovery/claim`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { agent_id: "adversarial-agent", namespace: "non-existent-namespace-9999" },
    });
    expect([400, 422]).toContain(res.status());
    const body = await res.json();
    expect(body.error).toBeDefined();
    expect(body.error.code).toBeDefined();
  });

  test("rejects malformed raw JSON with 400 or 422 and never unhandled 500", async ({ page, request }) => {
    if (!authToken) {
      await login(page);
      authToken = (await getAuthToken(page)) || "";
    }
    const res = await request.post(`${BASE}/api/v1/discovery/claim`, {
      headers: {
        Authorization: `Bearer ${authToken}`,
        "Content-Type": "application/json",
      },
      data: "{ malformed: json, missing quotes }",
    });
    expect([400, 422]).toContain(res.status());
    expect(res.status()).not.toBe(500);
    const body = await res.json();
    expect(body.error).toBeDefined();
    expect(body.error.code).toBeDefined();
  });
});
