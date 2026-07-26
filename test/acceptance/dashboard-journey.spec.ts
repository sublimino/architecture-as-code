import { expect, test } from "@playwright/test";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "http://127.0.0.1:8675";

const proposal = {
  id: "proposal-fixture-1",
  action: "restart-workload",
  rationale: "Fixture approval journey",
  created_at: "2026-07-26T00:00:00Z",
};

test.describe("Estate 95 dashboard journeys", () => {
  test("opens Agent Registry from the desktop route", async ({ page }) => {
    await page.route("**/api/agent-card/olly-sentinel", (route) =>
      route.fulfill({ contentType: "application/json", body: "{}" }),
    );

    await page.goto(DASHBOARD_URL);
    await page.locator('.desk-icon[title="Agent Registry"]').dblclick();
    await expect(page.getByText("Agent Registry · 4 agents")).toBeVisible();
  });

  test("keeps Grafana authentication independent from the broker", async ({ page }) => {
    await page.route("**/proxy/grafana/**", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: '<h1>Welcome to Grafana</h1><input data-testid="data-testid Username input field">',
      }),
    );

    await page.goto(DASHBOARD_URL);
    await page.locator('.desk-icon[title="Eye in the Sky"]').dblclick();
    await page.getByRole("button", { name: "Open dashboard" }).click();
    const grafana = page.frameLocator("iframe");
    await expect(grafana.getByRole("heading", { name: "Welcome to Grafana" })).toBeVisible();
    await expect(grafana.getByTestId("data-testid Username input field")).toBeVisible();
  });

  test("shows cluster-not-ready error for unavailable cluster API", async ({ page }) => {
    await page.route("**/api/cluster/overview", (route) =>
      route.fulfill({ status: 503, contentType: "application/json", body: '{"detail":"not ready"}' }),
    );

    await page.goto(DASHBOARD_URL);
    await page.locator('.desk-icon[title="Cluster State"]').dblclick();
    await expect(page.getByText("Cluster not ready").first()).toBeVisible();
    await expect(page.getByText("Still polling. This pane will fill in once the cluster answers.").first()).toBeVisible();
  });

  test("records Orbit approval without infrastructure mutation", async ({ page }) => {
    await page.route("**/api/orbit/proposals?state=proposed", (route) =>
      route.fulfill({ contentType: "application/json", body: JSON.stringify([proposal]) }),
    );
    await page.route("**/api/orbit/approve", (route) =>
      route.fulfill({ contentType: "application/json", body: JSON.stringify({ approved_by: "fixture-operator", proposal: { approval: { state: "approved" } } }) }),
    );

    await page.goto(DASHBOARD_URL);
    await page.locator('.desk-icon[title="Orbit: Action Approvals"]').dblclick();
    await page.getByRole("button", { name: "Approve & sign" }).click();
    await expect(page.getByText("Decisions this session")).toBeVisible();
    await expect(page.getByText("approved")).toBeVisible();
  });
});
