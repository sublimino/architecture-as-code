/**
 * The Instructor Controls run log must STREAM, against the live estate.
 *
 * ─── How to run it ─────────────────────────────────────────────────────────
 *
 *   make demo-signalloom-supercred-stream          # cluster required
 *
 * For the same assertions with no cluster at all — a scripted runner, the same
 * real components, and a negative control that reproduces the original defect —
 * see supercred-log-streaming-harness.spec.ts and
 *
 *   make demo-signalloom-supercred-stream-harness  # ~25s, no cluster
 *
 * ─── The defect this exists for ────────────────────────────────────────────
 *
 * Instructor Controls has never streamed. The runner's monitor thread called
 * `proc.stdout.read(8192)` on a BufferedReader, which is a fill-exactly-n read:
 * it blocks until 8192 bytes are available or the pipe closes. A demo phase
 * emits a few hundred bytes a second, so the first chunk that ever came back
 * was the one the closing pipe produced — the entire log, in one frame, at
 * process exit. On stage that is the difference between a live console and a
 * panel that appears to have hung for three minutes and then dumps a wall of
 * text nobody reads.
 *
 * ─── Why it survived every existing test ───────────────────────────────────
 *
 * Because all of them assert FINAL STATE. `supercred-ui-lifecycle` waits for
 * `Step 1 (step) — succeeded`. `supercred-two-window` waits for a revoked
 * badge. The component tests wait for text to appear in a `<pre>`. Every one of
 * those is exactly as true of a log that dribbled in over ninety seconds as of
 * a log that materialised whole at second eighty-nine — and no choice of
 * timeout separates them, because the property is not "the text is eventually
 * there".
 *
 * So the assertions here are TEMPORAL. supercred-stream-helpers.ts records the
 * rendered log from inside the page every 200ms, alongside the run's own status
 * word, and the timeline is asserted afterwards: the log must have grown at
 * least three separate times WHILE the status still read `running`.
 *
 * ─── How this fails if output arrives in one batch at the end ─────────────
 *
 * The panel mounts StreamingLogBlock only when `log !== ''`. Under batched
 * delivery there are therefore ZERO line nodes on the page at every sample
 * taken while the run is running: `growthWhileRunning()` returns an empty
 * array, `expectProgressiveArrival()` fails with `0 < 3`, and the failure
 * message prints the whole timeline — a column of `running / 0 lines` followed
 * by one row with everything in it. The single 0 → N jump is not counted,
 * because by then the status word has already changed.
 *
 * That is not a claim about what would happen. The harness spec drives the same
 * panel against a runner in `batch` mode — which withholds the log until the
 * run reports terminal, exactly as the old runner did — and asserts that
 * `expectProgressiveArrival()` THROWS. Recorded there, on every run.
 *
 * ─── Transport-agnostic on purpose ─────────────────────────────────────────
 *
 * Two branches are changing how the bytes travel: the runner is gaining
 * `GET /demo-api/runs/{id}/stream` (SSE) beside the existing
 * `GET /demo-api/runs/{id}/log?offset=N` poll, and the panel is gaining an SSE
 * client with automatic fallback to the 500ms poll. Nothing in this file names
 * either endpoint. Every assertion reads the rendered DOM, so the spec holds
 * over SSE, over polling, and over the fallback between them — and it will
 * still fail if a future transport regresses to delivering everything at once.
 * A spec that asserted on the SSE frames would pass while the panel showed
 * nothing, which is the class of test that let this ship.
 *
 * ─── Locators ──────────────────────────────────────────────────────────────
 *
 * Navigation is by route href via navigateTo(). Never by accessible name — the
 * sidebar renders count badges, so "Compliance" is really "Compliance 7" and an
 * exact-name locator passes on demo data and fails on live data. See
 * supercred-helpers.ts. Everything inside the panel is located by test id, so
 * the "waiting for output" copy the frontend work is adding cannot break this.
 *
 * ─── Live mode, and mutation ───────────────────────────────────────────────
 *
 * `{ demoMode: false }` everywhere: under demo mode the dashboard renders
 * bundled fixtures, and a fixture log would satisfy nothing here. The two runs
 * below (a reset, then phase 1) mutate one shared cluster, which is why the
 * project sets retries:0 — a retry would start against its own leftovers.
 */
import { test, expect } from "./fixtures";
import { login } from "./helpers";
import { navigateTo, newAuthedContext } from "./supercred-helpers";
import {
  currentLastLine,
  expectFollowsTail,
  expectHoldsPositionWhileUnpinned,
  expectProgressiveArrival,
  formatSamples,
  logScroll,
  readLogSamples,
  sampleCursor,
  startLogSampler,
  waitForLine,
} from "./supercred-stream-helpers";

// Serial, and long: a reset and a phase against a real cluster. The project
// entry raises the timeout too; this restates it at the file so a future move
// between projects cannot silently reinstate the global 30s and report a
// working demo as a failure — the same reason supercred-two-window does.
test.describe.configure({ mode: "serial", timeout: 15 * 60_000 });

const RUN_STATUS = '[data-testid="supercred-run-status"]';
const RUN_STEP_1 = '[data-testid="supercred-run-step-1"]';
const RESET = '[data-testid="supercred-reset"]';
const RESET_CONFIRM = '[data-testid="supercred-reset-confirm"]';
const SCRIPT_UNAVAILABLE = '[data-testid="supercred-script-unavailable"]';
// StreamingLogBlock builds its inner ids from its `testId` prop; keep the
// prefix as a string so the selectors below are valid CSS.
const LOG_ID = "supercred-run-log";
const RUN_LOG = `[data-testid="${LOG_ID}"]`;

/** A phase against a real cluster can sit on one kubectl wait for minutes. */
const PHASE_TIMEOUT = 10 * 60_000;

type Page = import("@playwright/test").Page;

/**
 * Open the instructor panel and refuse to proceed against a runner that cannot
 * run anything.
 *
 * Deliberately an assertion and not a `test.skip()`. This spec is reached by
 * its own make target, so whoever invoked it meant to; a skip here would report
 * green for a demo runner that is down, which is the failure mode
 * SPEC-REGISTRY.tsv exists to stamp out one level up. `supercred-ui-lifecycle`
 * takes the same position.
 */
async function openInstructor(page: Page): Promise<void> {
  await login(page, { demoMode: false });
  await navigateTo(page, "/supercred");
  await expect(page.locator('[data-testid="supercred-instructor"]')).toBeVisible({ timeout: 30_000 });
  await expect(
    page.locator(SCRIPT_UNAVAILABLE),
    "the demo runner must be up and holding the demo script — run: make demo-signalloom-up",
  ).toHaveCount(0, { timeout: 30_000 });
}

/**
 * The cheap, decisive check, independent of the sampler.
 *
 * Waits for the log block to appear, then asserts the run is STILL running.
 * Under batched delivery the block first appears after the run is over, so this
 * fails within a second of the phase ending and names the property directly —
 * no timeline to read. It is deliberately not the only check: it cannot tell
 * "three lines then a two-minute silence" from real streaming, which is what
 * the timeline assertions are for.
 */
async function expectLogVisibleWhileRunning(page: Page, what: string): Promise<void> {
  await expect(page.locator(RUN_LOG), `${what}: the log block must appear during the run`).toBeVisible({
    timeout: PHASE_TIMEOUT,
  });
  await expect(
    page.locator(RUN_STATUS),
    `${what}: the run had already finished by the time any output was rendered — that is ` +
      `batched delivery, not streaming`,
  ).toContainText(/—\s*running/);
}

test("a reset streams its teardown output while it is still running", async ({ browser }) => {
  // Reset first, for two reasons: it needs no precondition (it is the verified
  // teardown, valid from any state), and it leaves the estate clean for the
  // phase-1 run below. It is also reliably talkative — kubectl delete across
  // several namespaces — which is what a progressive-arrival assertion needs.
  const context = await newAuthedContext(browser, { demoMode: false, superadmin: true });
  try {
    const page = await context.newPage();
    await openInstructor(page);

    await startLogSampler(page);
    await expect(page.locator(RESET)).toBeVisible({ timeout: 30_000 });
    await page.locator(RESET).click();
    await page.locator(RESET_CONFIRM).click();

    await expectLogVisibleWhileRunning(page, "the reset");
    await expect(page.locator(RUN_STATUS)).toContainText(/Step\s+5\s+\(reset\)\s+—\s+succeeded/, {
      timeout: PHASE_TIMEOUT,
    });
    // The post-run drain lands after the status word flips, so give it a moment
    // to be recorded rather than reading the timeline mid-drain.
    await expect(page.locator(`${RUN_LOG}-status`)).toHaveText(/succeeded/i, { timeout: 30_000 });

    const samples = await readLogSamples(page);
    test.info().attach("reset-timeline", { body: formatSamples(samples), contentType: "text/plain" });

    expectProgressiveArrival(samples, { what: "the reset" });
    expectFollowsTail(samples, "the reset");
  } finally {
    await context.close();
  }
});

test("phase 1 follows the tail, and stops following once the instructor scrolls up", async ({
  browser,
}) => {
  const context = await newAuthedContext(browser, { demoMode: false, superadmin: true });
  try {
    const page = await context.newPage();
    await openInstructor(page);

    await startLogSampler(page);
    await page.locator(RUN_STEP_1).click();
    await expectLogVisibleWhileRunning(page, "phase 1");

    const scroll = logScroll(page);

    // Enough output for the box to be overflowing before anything is asserted
    // about where it is scrolled to — under that, "pinned to the bottom" and
    // "has never scrolled" are the same reading and prove nothing.
    await waitForLine(page, 20, { timeout: PHASE_TIMEOUT });
    const beforeScrollUp = await sampleCursor(page);

    // ── The instructor scrolls up to read something ─────────────────────────
    // Assigning scrollTop fires a real `scroll` event, which is the same signal
    // a wheel produces and the one StreamingLogBlock's own onScroll listens to.
    await scroll.evaluate((el) => {
      el.scrollTop = 0;
    });
    const afterScrollUp = await sampleCursor(page);

    // Wait for MORE lines rather than for a fixed line number: a live phase
    // emits whatever kubectl emits, and an absolute target is a guess that
    // fails the suite on a healthy but quiet run.
    await waitForLine(page, (await currentLastLine(page)) + 15, { timeout: PHASE_TIMEOUT });
    const beforeScrollDown = await sampleCursor(page);

    // ── They scroll back down, and following resumes ────────────────────────
    await scroll.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
    const afterScrollDown = await sampleCursor(page);
    await waitForLine(page, (await currentLastLine(page)) + 10, { timeout: PHASE_TIMEOUT });

    await expect(page.locator(RUN_STATUS)).toContainText(/Step\s+1\s+\(step\)\s+—\s+succeeded/, {
      timeout: PHASE_TIMEOUT,
    });

    const samples = await readLogSamples(page);
    test.info().attach("phase-1-timeline", { body: formatSamples(samples), contentType: "text/plain" });

    // The whole run still has to have streamed — the scrolling is an extra
    // property on top, not a replacement for the one that matters.
    expectProgressiveArrival(samples, { what: "phase 1" });

    expectFollowsTail(samples.slice(0, beforeScrollUp), "phase 1, before the instructor scrolled");
    expectHoldsPositionWhileUnpinned(
      samples.slice(afterScrollUp, beforeScrollDown),
      "phase 1, while the instructor was reading",
    );
    expectFollowsTail(
      samples.slice(afterScrollDown),
      "phase 1, after the instructor scrolled back down",
    );
  } finally {
    await context.close();
  }
});
