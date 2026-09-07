import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { config, login } from "./helpers";

interface CatalogueEntry {
  id: string;
  port: number;
  expectedExitCode: number;
  source: { kind: string; name: string; namespace: string };
  destination: { kind: string; name: string; namespace: string };
}

const cataloguePath = resolve(
  __dirname,
  "../../d2-signalloom/apps/fake-integration-proxy/network-test-catalogue.json",
);
const expectedCatalogue = (
  JSON.parse(readFileSync(cataloguePath, "utf8")) as { assertions: CatalogueEntry[] }
).assertions;

test.describe("Network security SUPER ADMIN boundary", () => {
  test("an unauthenticated direct route follows the product login boundary", async ({ page }) => {
    await page.goto(`${config.base}/network-tests`, { waitUntil: "domcontentloaded" });

    await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 20_000 });
    expect(page.url()).toContain("/dex/");
  });

  test(
    "the established SUPER ADMIN identity can view live results and start a scan",
    async ({ page }) => {
      await login(page, { demoMode: false });

      const resultsResponse = page.waitForResponse(
        (response) =>
          response.url().includes("/api/network-tests") && response.request().method() === "GET",
      );
      await page.getByRole("link", { name: "Network Tests", exact: true }).click();
      await expect(page).toHaveURL(/\/network-tests$/);

      const response = await resultsResponse;
      expect(response.status()).toBe(200);
      const payload = (await response.json()) as {
        tests: Array<{
          name: string;
          targetPort: number;
          expectedExit: number;
          src: { name: string; namespace: string };
          dst: { name: string; namespace: string };
        }>;
      };
      expect(payload.tests).toHaveLength(26);
      expect(
        payload.tests.map(({ name, targetPort, expectedExit, src, dst }) => ({
          name,
          targetPort,
          expectedExit,
          src,
          dst,
        })),
      ).toEqual(
        expectedCatalogue.map(({ id, port, expectedExitCode, source, destination }) => ({
          name: id,
          targetPort: port,
          expectedExit: expectedExitCode,
          src: { name: source.name, namespace: source.namespace },
          dst: { name: destination.name, namespace: destination.namespace },
        })),
      );
      for (const networkTest of payload.tests) {
        await expect(page.getByText(networkTest.name, { exact: true })).toBeVisible();
      }

      // This browser preference controls navigation visibility only. Clearing it
      // cannot remove authority granted by the validated Dex principal.
      await page.evaluate(() => window.localStorage.setItem("signalloom.superadmin", "false"));
      const scanResponse = page.waitForResponse(
        (candidate) =>
          candidate.url().includes("/api/network-tests/scan") &&
          candidate.request().method() === "POST",
      );
      await page.getByRole("button", { name: /run network test scan now/i }).click();
      expect((await scanResponse).status()).toBe(202);
    },
  );
});
