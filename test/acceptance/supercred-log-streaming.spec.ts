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
 * ─── This asserts the DEFAULT transport: the 500ms offset poll ─────────────
 *
 * `GET /demo-api/runs/{id}/log?offset=N` is the default and is what runs on
 * stage, so it is what the acceptance layer protects. This spec sets no
 * transport flag and never opts into SSE.
 *
 * SSE (`GET /demo-api/runs/{id}/stream`) is being built, but behind an
 * explicit opt-in, because it cannot cover its own worst failure mode: a
 * buffering intermediary ACCEPTS the connection and then delivers nothing. No
 * error fires, so no fallback triggers, and the panel sits silent — which is
 * indistinguishable from the very defect this branch exists to fix. In front of
 * customers, the proven path stays the default.
 *
 * Two consequences for how this file is written:
 *
 *   * every assertion still reads the rendered DOM and names no endpoint, so
 *     the temporal property survives if the transport is ever swapped, and a
 *     spec asserting on SSE frames could never pass while the panel showed
 *     nothing — the class of test that let this ship;
 *
 *   * BUT that virtue is a blind spot for exactly one question, so
 *     `expectDefaultTransport()` additionally asserts the run really did poll
 *     `/log` and really did NOT open `/stream`. Without it this suite would go
 *     on passing if SSE quietly became the default, because the DOM cannot tell
 *     them apart. With it, moving the default turns the acceptance layer red
 *     and re-pointing it is a deliberate edit rather than drift.
 *
 * A secondary case that opts INTO SSE and asserts the same temporal property is
 * wanted, and is not here yet: the opt-in flag does not exist on this branch,
 * and a guessed flag name that silently never opts in is precisely the
 * silent-skip failure test/acceptance-spec-coverage.bats exists to prevent. It
 * is a new test case rather than new machinery — the harness already serves
 * SSE and every assertion above is transport-agnostic. When it lands it must
 * stay clearly secondary: if SSE is later removed, the assertions above are the
 * ones that must survive.
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
  expectDefaultTransport,
  expectFollowsTail,
  expectHoldsPositionWhileUnpinned,
  expectProgressiveArrival,
  formatSamples,
  logScroll,
  readLogSamples,
  sampleCursor,
  startLogSampler,
  waitForLine,
  watchTransport,
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
  // phase-1 run below.
  //
  // It is talkative ENOUGH for progressive arrival and no more, which is why
  // this test asserts arrival and transport but NOT expectFollowsTail. Measured
  // against the live estate: a reset of a fully deployed estate renders 11
  // lines / 554 chars, and one of an already-clean estate renders 5 / 316. The
  // log block auto-sizes to its content up to roughly 260px, so it first
  // overflows at ~16 lines — a reset never reaches that from any starting
  // state. expectFollowsTail is explicitly guarded on `overflows` and fails
  // closed rather than passing vacuously, so asserting it here could only ever
  // fail, whatever the component did. That is what its own message means by
  // "Drive a phase that produces more output."
  //
  // No coverage is lost: tail-following is asserted on phase 1 below, which
  // renders ~80 lines and overflows comfortably. What this test uniquely owns
  // is the temporal claim in its title, and that is asserted in full.
  const context = await newAuthedContext(browser, { demoMode: false, superadmin: true });
  try {
    const page = await context.newPage();
    await openInstructor(page);

    const transport = watchTransport(page);
    await startLogSampler(page);
    await expect(page.locator(RESET)).toBeVisible({ timeout: 30_000 });
    await page.locator(RESET).click();
    await page.locator(RESET_CONFIRM).click();

    await expectLogVisibleWhileRunning(page, "the reset");
    await expect(page.locator(RUN_STATUS)).toContainText(/Step\s+5\s+\(reset\)\s+—\s+succeeded/, {
      timeout: PHASE_TIMEOUT,
    });
    // The post-run drain lands after the status word flips, so wait for the log
    // block to be present rather than reading the timeline mid-drain. Matches
    // the harness spec's wait exactly: `${RUN_LOG}-status` was a string-concat
    // slip that produced `[data-testid="supercred-run-log"]-status`, a selector
    // no element can ever match, so this line could only ever time out.
    await expect(page.locator(RUN_LOG)).toBeVisible({ timeout: 30_000 });

    const samples = await readLogSamples(page);
    test.info().attach("reset-timeline", { body: formatSamples(samples), contentType: "text/plain" });

    expectProgressiveArrival(samples, { what: "the reset" });
    expectDefaultTransport(transport, "the reset");
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

    const transport = watchTransport(page);
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
    //
    // AWAITING that event is load-bearing, not tidiness. The assignment moves
    // the viewport synchronously, but the browser DELIVERS `scroll`
    // asynchronously, at frame time. StreamingLogBlock only learns it has been
    // unpinned in its onScroll handler, so between the assignment and the
    // event there is a window in which `pinnedRef` still reads true — and its
    // useLayoutEffect, which DOES run synchronously on commit, will re-pin the
    // view to the bottom if a log chunk lands inside it. The unpin is then lost
    // entirely: the following scroll event observes the re-pinned position and
    // records `pinned` all over again.
    //
    // That window is the difference between this test passing and failing, and
    // it is a race the TEST creates rather than a property of the component.
    // Observed here: run phase 1 against an already-deployed estate and output
    // is slow enough at the 20-line mark that the event always wins; run it
    // straight after a reset and lines 20→38 arrive inside one 200ms tick, the
    // commit wins, and every one of the 19 in-flight samples reads pinned.
    // A real instructor's wheel emits a stream of scroll events over many
    // frames, so they unpin on the next tick; a single scripted assignment gets
    // exactly one chance and has to wait for it.
    await scroll.evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          el.addEventListener("scroll", () => resolve(), { once: true });
          el.scrollTop = 0;
        }),
    );
    const afterScrollUp = await sampleCursor(page);

    // Wait for MORE lines rather than for a fixed line number: a live phase
    // emits whatever kubectl emits, and an absolute target is a guess that
    // fails the suite on a healthy but quiet run.
    await waitForLine(page, (await currentLastLine(page)) + 15, { timeout: PHASE_TIMEOUT });
    const beforeScrollDown = await sampleCursor(page);

    // ── They scroll back down, and following resumes ────────────────────────
    // Awaited for the same reason as the scroll up, in the mirror direction:
    // until the event lands the component still believes it is unpinned, so a
    // chunk committing in the window leaves the view where it is and the
    // follows-tail assertion below reads a viewport that never caught up.
    await scroll.evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          el.addEventListener("scroll", () => resolve(), { once: true });
          el.scrollTop = el.scrollHeight;
        }),
    );
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
    expectDefaultTransport(transport, "phase 1");
  } finally {
    await context.close();
  }
});
