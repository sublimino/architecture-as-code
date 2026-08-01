import { test, expect } from "./fixtures";
import { guards } from "./helpers";

/**
 * Simple browser-driven acceptance tests for the OSRAMP demo cluster.
 *
 * Prerequisites:
 *   - kind-osramp cluster running with all components deployed
 *   - Port-forwards active (managed by scripts/acceptance-test.sh):
 *     - 13000 → monitoring/grafana
 *     - 18082 → backend/archivista
 *     - 18000 → fe-signalloom/fe-signalloom
 *     - 18080 → olly-replica/customer-portal
 *
 * Run: ./scripts/acceptance-test.sh
 */

const GRAFANA_URL = "http://127.0.0.1:13000";
const ARCHIVISTA_URL = "http://127.0.0.1:18082";
const SIGNALLOOM_URL = "http://127.0.0.1:18000";
const OLLY_PORTAL_URL = "http://127.0.0.1:18080";

test.describe("Grafana", () => {
  test.beforeAll(() => {
    test.skip(
      !guards.grafanaDeployed(),
      "monitoring slice not deployed — run with ENABLE_OBSERVABILITY=true",
    );
  });

  test("dashboard loads and shows login page", async ({ page }) => {
    const response = await page.goto(GRAFANA_URL);
    expect(response?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { name: "Welcome to Grafana" })
    ).toBeVisible({ timeout: 10_000 });
  });

  test("login form is present", async ({ page }) => {
    await page.goto(GRAFANA_URL);
    await expect(
      page.getByTestId("data-testid Username input field")
    ).toBeVisible({ timeout: 10_000 });
  });
});

test.describe("Archivista API", () => {
  test.beforeAll(() => {
    test.skip(
      !guards.archivistaDeployed(),
      "osramp-apps backend not deployed — run: make demo-osramp-up",
    );
  });

  test("root endpoint is reachable", async ({ request }) => {
    const response = await request.get(`${ARCHIVISTA_URL}/`);
    // Archivista may redirect or serve a page
    expect(response.status()).toBeLessThan(500);
  });

  test("GraphQL endpoint responds", async ({ request }) => {
    const response = await request.post(`${ARCHIVISTA_URL}/query`, {
      headers: { "Content-Type": "application/json" },
      data: { query: "{ __schema { queryType { name } } }" },
    });
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body).toHaveProperty("data");
  });
});

test.describe("SignalLoom Frontend", () => {
  test("app is reachable", async ({ page }) => {
    const response = await page.goto(SIGNALLOOM_URL);
    // SignalLoom may serve on a sub-path; 404 from the app is still "reachable"
    expect(response?.status()).toBeLessThan(500);
  });

  test("page renders content", async ({ page }) => {
    await page.goto(SIGNALLOOM_URL);
    const body = await page.textContent("body");
    expect(body?.length).toBeGreaterThan(0);
  });
});

test.describe("Olly Customer Portal", () => {
  test.beforeAll(() => {
    test.skip(
      !guards.ollyDeployed(),
      "olly-replica slice not deployed — run: make demo-olly-up",
    );
  });

  test("portal responds", async ({ page }) => {
    const response = await page.goto(OLLY_PORTAL_URL);
    // Portal may serve on root or redirect
    expect(response?.status()).toBeLessThan(500);
  });

  test("portal renders content", async ({ page }) => {
    await page.goto(OLLY_PORTAL_URL);
    const body = await page.textContent("body");
    expect(body?.length).toBeGreaterThan(0);
  });
});
