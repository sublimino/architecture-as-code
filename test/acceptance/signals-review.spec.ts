/**
 * Signal Loom Platform Acceptance Suite - /signals decision review (live).
 *
 * Proves the human review round-trip end to end on a real cluster: a
 * superadmin logs in, opens /signals, records a verdict with a note on the
 * first unreviewed decision, and the verdict is still there after a reload.
 * The dashboard holds no review state of its own, so a verdict that survives
 * a reload was stored by signal-ingest through the gateway proxy.
 *
 * Skips, rather than fails, when the window holds no unreviewed decision: a
 * quiet cluster is not a defect. Run `make kusari-synth-seed` first so the
 * store holds recent decisions.
 */
import { test, expect } from "./fixtures";
import { login } from "./helpers";

const NOTE = `acceptance review ${new Date().toISOString()} true positive, rule matched a seeded Kusari fixture`;

test.describe("/signals: a human can review a decision and the verdict persists", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("records a verdict through the gateway and reads it back after reload", async ({ page }) => {
    await page.goto("/signals");
    await expect(page.getByTestId("signals-page")).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId("signals-unreachable")).toHaveCount(0);

    await page.getByTestId("signals-tab-decisions").click();
    // Decide skip-or-run from the 90m answer itself. The old 15 s waitFor on a
    // form that a quiet store never renders ran the 30 s test budget out before
    // its catch could skip, so "nothing to review" reported as a timeout; and a
    // DOM check alone can read the stale 10m list while the 90m fetch is in flight.
    const decisions90m = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes("/signals/policy/decisions") &&
        new URL(r.url()).searchParams.get("window") === "90m",
      { timeout: 20_000 },
    );
    await page.getByTestId("window-btn-90m").click();
    const answer = await decisions90m;
    expect(answer.ok(), `GET ${answer.url()} returned ${answer.status()}`).toBeTruthy();
    const listed = ((await answer.json()) ?? []) as { review?: unknown }[];
    test.skip(
      !listed.some((d) => d.review === null),
      "no unreviewed decision in the 90m window; seed the store first (make kusari-synth-seed)",
    );

    const forms = page.getByTestId("decision-review-form");
    await expect(forms.first()).toBeVisible({ timeout: 15_000 });
    const form = forms.first();
    const card = page.locator('[data-testid^="decision-card-"]').filter({ has: form }).first();
    const cardId = await card.getAttribute("data-testid");
    expect(cardId).toBeTruthy();

    await form.getByTestId("verdict-btn-true_positive").click();
    await form.getByTestId("review-note").fill(NOTE);
    await expect(form.getByTestId("review-submit")).toBeEnabled();
    await form.getByTestId("review-submit").click();

    const settled = page.getByTestId(cardId!);
    await expect(settled.getByTestId("decision-reviewer")).toBeVisible({ timeout: 15_000 });
    await expect(settled.getByTestId("decision-review-form")).toHaveCount(0);

    await page.reload();
    await expect(page.getByTestId("signals-page")).toBeVisible({ timeout: 20_000 });
    await page.getByTestId("signals-tab-decisions").click();
    await page.getByTestId("window-btn-90m").click();
    const after = page.getByTestId(cardId!);
    await expect(after).toBeVisible({ timeout: 15_000 });
    await expect(after.getByTestId("decision-verdict-badge")).toHaveText(/true positive/i);
    await expect(after).toContainText(NOTE);
    await expect(after.getByTestId("decision-review-form")).toHaveCount(0);
  });
});
