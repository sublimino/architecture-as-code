/**
 * Saving a policy publishes only what the engine evaluates.
 *
 * The editor shows the engine's active bundle merged with the static
 * regulatory catalogue, so controls the engine does not evaluate are still
 * visible for context. Before the fix that merged list was what Save sent to
 * POST /policies/bundles, publishing catalogue rules (some of them comment-only
 * CEL that cel-go cannot compile) as if the engine had evaluated them.
 *
 * The bundle POST is intercepted and answered locally, so this spec never
 * changes the live policy store.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

type Rule = { id: string; catalogue_only?: boolean; cel_expression?: string };
type Summary = { framework_id: string; active_bundle?: { rules?: Rule[] } | null };

test.describe("Policy save sends engine rules only", () => {
  test.use({ viewport: { width: 1280, height: 800 } });

  test("CIS save carries exactly the engine's rules under the engine's framework id", async ({ page }) => {
    await login(page, { demoMode: false });

    const listResponse = page.waitForResponse(
      (r) =>
        ["xhr", "fetch"].includes(r.request().resourceType()) &&
        r.request().method() === "GET" &&
        new URL(r.url()).pathname.endsWith("/policies") &&
        r.ok(),
      { timeout: 20_000 },
    );

    const captured: { body: { framework_id: string; rules: Rule[] } | null } = { body: null };
    await page.route(
      (url) => url.pathname.endsWith("/policies/bundles"),
      async (route) => {
        if (route.request().method() !== "POST") return route.continue();
        captured.body = route.request().postDataJSON();
        await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(captured.body) });
      },
    );

    await page.goto(`${config.base}/policies?framework=k8s-cis-benchmark`, { waitUntil: "domcontentloaded" });
    const summaries = (await (await listResponse).json()) as Summary[];
    // Mirror the page: prefer the canonical id, then the lexically first alias.
    const cis = summaries
      .filter((s) => ["k8s-cis-benchmark", "cis-kubernetes"].includes(s.framework_id))
      .sort((a, b) => (a.framework_id === "k8s-cis-benchmark" ? -1 : b.framework_id === "k8s-cis-benchmark" ? 1 : a.framework_id.localeCompare(b.framework_id)));
    const engine = cis[0]?.active_bundle?.rules?.length ? cis[0] : undefined;
    test.skip(!engine, "no active CIS bundle in the policy engine on this cluster");
    const engineIds = new Set(engine!.active_bundle!.rules!.map((r) => r.id));

    await expect(page.getByTestId("cel-editor-workspace")).toBeVisible({ timeout: 15_000 });

    // Every engine rule is in the editor. Whatever else is there is labelled
    // catalogue reference. Since fcf03c38e the CIS catalogue uses the engine's
    // own rule ids, so on a cluster running that bundle there may be no
    // catalogue-only extras at all; the spec no longer requires them, but it
    // still requires that any it finds are labelled and never saved.
    const chips = page.locator('[data-testid^="rule-tab-"]');
    await expect.poll(async () => chips.count(), { timeout: 15_000 }).toBeGreaterThanOrEqual(engineIds.size);
    for (const id of engineIds) await expect(page.getByTestId(`rule-tab-${id}`)).toHaveCount(1);
    const testIds = async (selector: string, prefix: string) =>
      Promise.all((await page.locator(selector).all()).map(async (l) => ((await l.getAttribute("data-testid")) ?? "").replace(prefix, "")));
    const chipIds = await testIds('[data-testid^="rule-tab-"]', "rule-tab-");
    const catalogueOnlyIds = await testIds('[data-testid^="rule-catalogue-only-"]', "rule-catalogue-only-");
    expect([...chipIds].sort()).toEqual([...new Set([...engineIds, ...catalogueOnlyIds])].sort());
    expect(catalogueOnlyIds.filter((id) => engineIds.has(id))).toEqual([]);

    // Edit an engine rule's CEL so Save has something to publish.
    const firstEngineId = [...engineIds][0];
    await page.getByTestId(`rule-tab-${firstEngineId}`).click();
    const textarea = page.getByTestId("cel-code-textarea");
    const original = await textarea.inputValue();
    const edited = `(${original}) && true`;
    await textarea.fill(edited);
    await expect(page.getByTestId("save-policy-btn")).toBeEnabled({ timeout: 10_000 });
    await page.getByTestId("save-policy-btn").click();

    await expect.poll(() => captured.body !== null, { timeout: 15_000 }).toBe(true);
    const body = captured.body!;
    expect(body.framework_id).toBe(engine!.framework_id);
    expect(body.rules.map((r) => r.id).sort()).toEqual([...engineIds].sort());
    expect(body.rules.filter((r) => r.catalogue_only)).toEqual([]);
    expect(body.rules.find((r) => r.id === firstEngineId)?.cel_expression).toBe(edited);
    // No catalogue-reference control shown in the editor was published.
    expect(body.rules.filter((r) => catalogueOnlyIds.includes(r.id))).toEqual([]);
  });
});
