/**
 * A failed /api/v1/features fetch is an error, not a set of flags.
 *
 * Before the fix the client caught the failure and returned its built-in
 * defaults as if the server had answered, so one 502 at startup turned every
 * gated page whose default is off into "Page Not Found ... disabled for your
 * tenant" for the whole session. The gate must instead show a retryable error,
 * and Retry must recover once the server answers.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const FEATURES = (url: URL) => url.pathname.endsWith("/api/v1/features");

test.describe("Feature flag fetch failure", () => {
  test("a gated page shows a retryable error, never 404, and Retry recovers", async ({ page }) => {
    await login(page, { demoMode: false });

    let failing = true;
    let failedCalls = 0;
    await page.route(FEATURES, async (route) => {
      if (failing) {
        failedCalls += 1;
        await route.fulfill({ status: 502, contentType: "application/json", body: '{"detail":"bad gateway"}' });
        return;
      }
      await route.continue();
    });

    await page.goto(`${config.base}/agents`, { waitUntil: "domcontentloaded" });

    const gateError = page.getByTestId("feature-gate-error");
    await expect(gateError).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId("not-found")).toHaveCount(0);
    await expect(page.getByText("Page Not Found")).toHaveCount(0);
    // The provider retried before giving up rather than failing on one blip.
    expect(failedCalls).toBeGreaterThan(1);

    failing = false;
    await gateError.getByTestId("error-retry").click();

    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId("feature-gate-error")).toHaveCount(0);
    await expect(page.getByTestId("not-found")).toHaveCount(0);
  });
});
