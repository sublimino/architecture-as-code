// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLDC-P4-2 - cockpit DOM contract, top-bar metrics and layout.
 *
 * Companion to agent-cockpit-telemetry.spec.ts (containment transitions);
 * same cluster-free harness. This file pins what an evaluator reads:
 * `#cockpit-cpu-metric` always formats as `N.NNN mCPU`, the top bar counts
 * active and stunned agents, the bar does not push the nav off-screen on a
 * medium viewport, and the frozen badge's rendered HTML is kept as evidence.
 *
 *   cd test/acceptance && bunx playwright test cockpit-telemetry.spec.ts --project=cockpit-telemetry
 */
import { writeFileSync } from "node:fs";
import {
  BADGE,
  CPU,
  CPU_FORMAT,
  TOP_BAR,
  expect,
  resetHarness,
  setPhase,
  test,
} from "./harness/cockpit-telemetry-launch";

test.describe.configure({ mode: "serial" });

test.beforeEach(async ({ request, harness }) => {
  await resetHarness(request, harness);
});

test("#cockpit-cpu-metric is visible and formats as N.NNN mCPU in every state", async ({ page, request, harness }) => {
  await page.goto(harness.url);
  const cpu = page.locator(CPU);
  await expect(cpu).toBeVisible();

  await expect(cpu).toHaveText(CPU_FORMAT);
  await expect(cpu).toHaveText("1.200 mCPU");

  await setPhase(request, harness, "spike");
  await expect(cpu).toHaveText("98.400 mCPU", { timeout: 3000 });
  await expect(cpu).toHaveText(CPU_FORMAT);

  await setPhase(request, harness, "frozen");
  await expect(cpu).toHaveText("0.000 mCPU", { timeout: 3000 });
  await expect(cpu).toHaveText(CPU_FORMAT);
});

test("top bar shows active and stunned counts and aggregate CPU, live", async ({ page, request, harness }) => {
  await page.goto(harness.url);
  const bar = page.locator(TOP_BAR);
  await expect(bar).toBeVisible();
  await expect(bar.getByTestId("metrics-total")).toHaveText("2");
  await expect(bar.getByTestId("metrics-active")).toHaveText("2");
  await expect(bar.getByTestId("metrics-stunned")).toHaveText("0");
  await expect(bar.getByTestId("metrics-cpu")).toHaveText("2.400 mCPU");

  await setPhase(request, harness, "frozen");
  await expect(bar.getByTestId("metrics-stunned")).toHaveText("1", { timeout: 3000 });
  await expect(bar.getByTestId("metrics-active")).toHaveText("1");
  await expect(bar.getByTestId("metrics-cpu")).toHaveText("1.200 mCPU");
});

for (const width of [1440, 1024]) {
  test(`top bar does not push navigation off-screen at ${width}px`, async ({ page, harness }) => {
    await page.setViewportSize({ width, height: 800 });
    await page.goto(harness.url);
    await expect(page.locator(TOP_BAR).getByTestId("metrics-total")).toHaveText("2");

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, "page scrolls horizontally").toBeLessThanOrEqual(0);

    const links = page.getByTestId("harness-nav-link");
    for (let i = 0; i < (await links.count()); i++) {
      const box = await links.nth(i).boundingBox();
      expect(box, `nav link ${i} not laid out`).not.toBeNull();
      expect(box!.x + box!.width).toBeLessThanOrEqual(width);
    }
    const right = await page.getByTestId("harness-nav-right").boundingBox();
    expect(right!.x + right!.width).toBeLessThanOrEqual(width);
    const nav = await page.getByTestId("harness-nav").boundingBox();
    const bar = await page.locator(TOP_BAR).boundingBox();
    expect(bar!.height).toBeLessThanOrEqual(nav!.height);
  });
}

test("frozen cockpit badge DOM snapshot", async ({ page, request, harness }, testInfo) => {
  await page.goto(harness.url);
  await setPhase(request, harness, "frozen");
  await expect(page.locator(CPU)).toHaveText("0.000 mCPU", { timeout: 3000 });
  await expect(page.locator(BADGE)).toHaveText("STUNNED (CGROUP FROZEN)");
  await page.waitForTimeout(800); // let the flatline draw-in animation finish

  const cockpit = page.getByTestId("agent-cockpit-telemetry");
  const html = await cockpit.evaluate((el) => el.outerHTML);
  expect(html).toContain("STUNNED (CGROUP FROZEN)");
  expect(html).toContain("CONTAINED: FROZEN");
  expect(html).toMatch(/id="cockpit-cpu-metric"[^>]*>0\.000 mCPU</);

  const htmlPath = testInfo.outputPath("frozen-cockpit.html");
  writeFileSync(htmlPath, html);
  await testInfo.attach("frozen-cockpit.html", { path: htmlPath, contentType: "text/html" });
  const shot = testInfo.outputPath("frozen-cockpit.png");
  await cockpit.screenshot({ path: shot });
  await testInfo.attach("frozen-cockpit.png", { path: shot, contentType: "image/png" });
  if (process.env.COCKPIT_EVIDENCE_DIR) {
    writeFileSync(`${process.env.COCKPIT_EVIDENCE_DIR}/sldc-p4-2-frozen-cockpit.html`, html);
    await cockpit.screenshot({ path: `${process.env.COCKPIT_EVIDENCE_DIR}/sldc-p4-2-frozen-cockpit.png` });
  }
});
