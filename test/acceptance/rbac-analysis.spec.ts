import { expect, test } from "@playwright/test";
import { afm, config, guards, login, getAuthToken } from "./helpers";

test.describe("RBAC analysis importer", () => {
  let importedClusterId: string | undefined;
  // The AFM mutation gate needs the page's Dex bearer; the worker-scoped
  // `request` fixture inherits cookies only, so the test body captures it.
  let bearer: string | undefined;

  test.beforeAll(async ({ request }) => {
    test.skip(!guards.afmDeployed(), "k8s-afm slice not deployed — run: make demo-k8s-afm-up");
    await afm.assertHealthy(request);
  });

  test.afterEach(async ({ request }) => {
    if (!importedClusterId) return;

    expect(bearer, "no OIDC token captured before the import").toBeTruthy();
    const deletion = await request.delete(`${config.base}/afm/clusters/${importedClusterId}`, {
      headers: { Authorization: `Bearer ${bearer}` },
    });
    expect(deletion.ok()).toBeTruthy();
    importedClusterId = undefined;
  });

  test("generates, copies, sends through the gateway, and verifies frontend-agent namespace RBAC", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await login(page, { demoMode: false });

    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible();

    const importer = page.getByTestId("rbac-importer");
    const clusterSelect = importer.getByTestId("importer-cluster-select");
    await expect(clusterSelect).toBeEnabled({ timeout: 15_000 });
    // With one known cluster the panel renders it as static text, not a
    // <select> (RbacImporterPanel, since f4b74cebd); which one appears depends
    // on how many clusters AFM has imported, so assert "local" either way.
    if ((await importer.locator('select[data-testid="importer-cluster-select"]').count()) === 1) {
      await clusterSelect.selectOption("local");
    } else {
      await expect(clusterSelect).toHaveText(/\(local\)$/);
    }

    const namespaceSelect = importer.getByTestId("importer-namespace-select");
    await expect(namespaceSelect.locator('option[value="fe-signalloom-agents"]')).toHaveCount(1);
    await namespaceSelect.selectOption("fe-signalloom-agents");

    await importer.getByTestId("importer-fetch").click();
    const yaml = importer.getByTestId("importer-yaml");
    await expect(yaml).toHaveValue(/namespace: fe-signalloom-agents/);

    await importer.getByTestId("importer-copy").click();
    await expect(importer.getByText("Copied")).toBeVisible();
    const copiedYaml = await page.evaluate(() => navigator.clipboard.readText());
    expect(copiedYaml).toContain("namespace: fe-signalloom-agents");

    bearer = (await getAuthToken(page)) ?? undefined;
    expect(bearer, "no OIDC token in page storage").toBeTruthy();

    // Send goes through fe-signalloom's authenticated import gateway as the
    // signed-in superadmin; AFM's own /clusters/import is closed at nginx
    // (SLTM-P1-1). The id is the panel's own, so it is read off the wire.
    const importRequest = page.waitForRequest(request =>
      request.url().endsWith("/api/v1/afm/clusters/import") && request.method() === "POST",
    );
    await importer.getByTestId("importer-send").click();
    const sent = await importRequest;
    expect(sent.headers()["authorization"]).toBe(`Bearer ${bearer}`);
    const importId = (sent.postDataJSON() as { id?: string }).id;
    expect(importId, "the panel sent no cluster id").toMatch(/^signalloom-/);
    importedClusterId = importId;
    const importResponse = await sent.response();
    expect(importResponse?.status(), await importResponse?.text()).toBe(200);
    await expect(importer.getByText(new RegExp(`Sent ${importId} to AFM`))).toBeVisible();
    await expect(importer.getByTestId("importer-send-loader")).toHaveCount(0);

    await importer.scrollIntoViewIfNeeded();
    await expect(yaml).toHaveValue(copiedYaml);
    await expect(importer.getByTestId("importer-error")).not.toBeVisible();

    const importedRbac = await page.request.get(`${config.base}/afm/clusters/${importId}/rbac`);
    expect(importedRbac.ok()).toBeTruthy();
    expect(await importedRbac.json()).toMatchObject({ subjects: expect.any(Array) });
  });
});
