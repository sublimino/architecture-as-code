// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLDC-P4-2 - live cockpit containment transitions, in a real browser.
 *
 * Needs NO cluster. Drives the real AgentCockpitTelemetry and MetricsTopBar
 * against harness/cockpit-telemetry-server.ts, which scripts the P4-1 SSE
 * producer. The assertion that matters is dynamic, not existential: a
 * non-zero idle reading, a spike, then - after the freeze signal - the exact
 * text `0.000 mCPU` within 3 s, with RSS unchanged. A test that only checked
 * the element exists would pass against a cockpit frozen at page load.
 *
 *   cd test/acceptance && bunx playwright test agent-cockpit-telemetry.spec.ts --project=cockpit-telemetry
 */
import type { ConsoleMessage, Page } from "@playwright/test";
import {
  BADGE,
  CONNECTION,
  CPU,
  FLATLINE,
  MEMORY,
  PILL,
  expect,
  requestLog,
  resetHarness,
  setPhase,
  test,
} from "./harness/cockpit-telemetry-launch";

test.describe.configure({ mode: "serial" });

function collectErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("console", (m: ConsoleMessage) => {
    if (m.type() === "error") errors.push(`console: ${m.text()}`);
  });
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  return errors;
}

test.beforeEach(async ({ request, harness }) => {
  await resetHarness(request, harness);
});

test("idle -> provocation spike -> stun renders an exact 0.000 mCPU flatline within 3 s, memory held", async ({ page, request, harness }) => {
  const errors = collectErrors(page);
  await page.goto(harness.url);

  const cpu = page.locator(CPU);
  await expect(cpu).toHaveText("1.200 mCPU");
  expect(Number.parseFloat((await cpu.textContent()) ?? "0")).toBeGreaterThan(0);
  await expect(page.locator(BADGE)).toHaveText("ACTIVE");
  await expect(page.locator(CONNECTION)).toHaveAttribute("data-connection", "live");

  await setPhase(request, harness, "spike");
  await expect(cpu).toHaveText("98.400 mCPU", { timeout: 3000 });
  await expect(page.locator('[data-testid="cockpit-cpu-path"]')).toHaveAttribute("data-band", "critical");
  const memBefore = await page.locator(MEMORY).textContent();
  expect(memBefore).toBe("42.0 MiB");

  const started = Date.now();
  await setPhase(request, harness, "frozen");
  await expect(cpu).toHaveText("0.000 mCPU", { timeout: 3000 });
  const elapsed = Date.now() - started;
  expect(elapsed, "flatline must render within 3 s of the freeze signal").toBeLessThan(3000);

  await expect(page.locator(BADGE)).toHaveText("STUNNED (CGROUP FROZEN)");
  await expect(page.locator(PILL)).toHaveText("CONTAINED: FROZEN");
  // A perfectly horizontal path has a zero-height box, which Playwright calls
  // "hidden"; assert its geometry instead. It must span the whole sparkline
  // and carry no dash pattern: a pixel-sized dasharray under
  // non-scaling-stroke once cut the rendered line off at half width.
  const flat = page.locator(FLATLINE);
  await expect(flat).toHaveAttribute("d", /^M 0 (\d+) L 600 \1$/);
  await page.waitForTimeout(700); // draw-in animation
  const [flatBox, svgBox] = await Promise.all([
    flat.boundingBox(),
    page.locator('[data-testid="cockpit-sparkline"]').boundingBox(),
  ]);
  expect(flatBox!.width).toBeGreaterThanOrEqual(svgBox!.width - 1);
  expect(await flat.evaluate((el) => getComputedStyle(el).strokeDasharray)).toBe("none");
  await expect(page.locator(MEMORY)).toHaveText(memBefore ?? "");

  // Held, not a single-frame blip: it stays flat across further samples.
  await page.waitForTimeout(1000);
  await expect(cpu).toHaveText("0.000 mCPU");
  await expect(page.locator(MEMORY)).toHaveText("42.0 MiB");

  expect(errors, errors.join("\n")).toEqual([]);
});

test("a stream drop during the freeze does not leave the pre-freeze reading on screen", async ({ page, request, harness }) => {
  await page.goto(harness.url);
  await setPhase(request, harness, "spike");
  await expect(page.locator(CPU)).toHaveText("98.400 mCPU", { timeout: 3000 });
  const before = await requestLog(request, harness);

  // The documented failure: the connection dies as the stun lands.
  const drop = await request.post(`${harness.url}/harness/drop`);
  expect((await drop.json()).dropped).toBeGreaterThan(0);
  await setPhase(request, harness, "frozen");

  // Reconnect (1 s initial backoff) then the new stream reports the freeze.
  await expect(page.locator(CPU)).toHaveText("0.000 mCPU", { timeout: 6000 });
  await expect(page.locator(BADGE)).toHaveText("STUNNED (CGROUP FROZEN)");
  const after = await requestLog(request, harness);
  expect(after.perPodStreams, "cockpit never reconnected").toBeGreaterThan(before.perPodStreams);
});

test("termination is visibly different from freeze: RSS released", async ({ page, request, harness }) => {
  await page.goto(harness.url);
  await expect(page.locator(CPU)).toHaveText("1.200 mCPU");
  await setPhase(request, harness, "terminated");
  await expect(page.locator(BADGE)).toHaveText("TERMINATED (RSS RELEASED)", { timeout: 3000 });
  await expect(page.locator(MEMORY)).toHaveText("0.0 MiB");
  await expect(page.locator(PILL)).toHaveCount(0);
  await expect(page.locator(FLATLINE)).toHaveCount(0);
});

test("streams authenticate with a Bearer header and never put a token in the URL", async ({ page, request, harness }) => {
  await page.goto(harness.url);
  await expect(page.locator(CPU)).toHaveText("1.200 mCPU");
  const log = await requestLog(request, harness);
  expect(log.perPodStreams).toBeGreaterThanOrEqual(1);
  expect(log.estateStreams).toBeGreaterThanOrEqual(1);
  expect(log.unauthenticated).toBe(0);
  expect(log.tokenInUrl).toBe(0);
  expect(log.unmatched).toEqual([]);
});
