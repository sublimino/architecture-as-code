/**
 * Public documentation route checks through the Envoy Gateway.
 */
import { expect, test } from "./fixtures";
import { config } from "./helpers";

const DOCS = `${config.base}/docs`;

test("documentation quick start remains beneath the docs prefix", async ({ page }) => {
  const failed: string[] = [];
  page.on("response", (response) => {
    if (response.status() >= 400) failed.push(`${response.status()} ${response.url()}`);
  });

  await page.goto(`${DOCS}/`);
  await expect(page.getByRole("heading", { name: "Govern agents through evidence" })).toBeVisible();
  await page.getByRole("link", { name: "Start the platform" }).click();
  await expect(page).toHaveURL(/\/docs\/start\/quick-start\/$/);
  await expect(page.getByRole("heading", { name: "Quick start", level: 1 })).toBeVisible();
  expect(failed).toEqual([]);
});

test("documentation renders its Mermaid evidence diagram", async ({ page }) => {
  await page.goto(`${DOCS}/`);
  await expect(page.locator(".mermaid svg")).toBeVisible();
});

test("unknown documentation paths return a real 404", async ({ page }) => {
  const response = await page.goto(`${DOCS}/this-page-does-not-exist/`);
  expect(response?.status()).toBe(404);
  await expect(page.locator("#root")).toHaveCount(0);
});
