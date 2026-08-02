import { expect, test } from "@playwright/test";
import { afm, config, guards, login } from "./helpers";

test.describe("RBAC analysis importer", () => {
  let importedClusterId: string | undefined;

  test.beforeAll(async ({ request }) => {
    test.skip(!guards.afmDeployed(), "k8s-afm slice not deployed — run: make demo-k8s-afm-up");
    await afm.assertHealthy(request);
  });

  test.afterEach(async ({ request }) => {
    if (!importedClusterId) return;

    const deletion = await request.delete(`${config.base}/afm/clusters/${importedClusterId}`);
    expect(deletion.ok()).toBeTruthy();
    importedClusterId = undefined;
  });

  test("generates, copies, imports, and verifies frontend-agent namespace RBAC", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await login(page);

    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible();

    const importer = page.getByTestId("rbac-importer");
    const clusterSelect = importer.getByTestId("importer-cluster-select");
    await expect(clusterSelect).toBeEnabled({ timeout: 15_000 });
    await clusterSelect.selectOption("local");

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

    const afmFrame = page.frameLocator('[data-testid="afm-iframe"]');
    await afmFrame.getByRole("link", { name: "Import", exact: true }).click();
    await expect(afmFrame.getByRole("heading", { name: "Import RBAC Data" })).toBeVisible();

    const importId = `signalloom-agents-e2e-${Date.now()}`;
    await afmFrame.getByLabel("ID (optional)").fill(importId);
    const importYaml = afmFrame.getByPlaceholder("rbac: { subjects: [], roles: [], bindings: [] }");
    await importYaml.click();
    await page.keyboard.press("Control+V");
    await expect(importYaml).toHaveValue(copiedYaml);

    const importResponse = page.waitForResponse(response =>
      response.url().endsWith("/clusters/import") && response.request().method() === "POST",
    );
    await afmFrame.getByRole("button", { name: "Import", exact: true }).click();
    await expect((await importResponse).ok()).toBeTruthy();
    importedClusterId = importId;
    await expect(afmFrame.getByText(new RegExp(`Imported cluster .*${importId}`))).toBeVisible();
    await expect(afmFrame.getByText("Failed to fetch")).not.toBeVisible();

    await importer.scrollIntoViewIfNeeded();
    await expect(yaml).toHaveValue(copiedYaml);
    await expect(importer.getByTestId("importer-error")).not.toBeVisible();

    const importedRbac = await page.request.get(`${config.base}/afm/clusters/${importId}/rbac`);
    expect(importedRbac.ok()).toBeTruthy();
    expect(await importedRbac.json()).toMatchObject({ subjects: expect.any(Array) });
  });
});
