/**
 * The instrument for "did the log actually STREAM?".
 *
 * ─── Why this file exists ───────────────────────────────────────────────────
 *
 * Instructor Controls shipped for months without ever streaming. The runner's
 * monitor thread called `proc.stdout.read(8192)` on a BufferedReader, which is
 * a fill-exactly-n read: it blocks until 8192 bytes exist or the pipe closes.
 * A demo phase produces a few hundred bytes a second, so in practice the first
 * and only chunk landed when the process exited — the whole log appeared in one
 * frame, at the end.
 *
 * Nothing caught it, and the reason is the shape of every test we had. They all
 * assert some variant of:
 *
 *     await expect(runLog).toContainText(/deploying agent/i, { timeout: 60_000 })
 *
 * That is a FINAL-STATE assertion. It is exactly as true of a log that dribbled
 * in over ninety seconds as of a log that materialised whole at second
 * eighty-nine. There is no timeout you can pick that separates them, because
 * the property under test is not "the text is eventually there" — it is "the
 * text got there in pieces, while the run was still going".
 *
 * So the assertion has to be TEMPORAL, and a temporal assertion needs samples.
 * This module takes them.
 *
 * ─── Why sampling happens inside the page ──────────────────────────────────
 *
 * The obvious implementation is a Node-side loop of `await locator.count()`
 * every 250ms. It is wrong twice over:
 *
 *   * every sample costs a CDP round trip, so the sample TIMES are the test's
 *     latency, not the page's. On a loaded CI VM that jitter is comparable to
 *     the interval being measured, and the thing being measured is time;
 *   * a Node-side loop cannot read the DOM and the run status in the same
 *     instant. It reads lines, awaits, reads status — and a run that finishes
 *     in between produces a sample that claims output arrived while running
 *     when it did not. That is a FALSE PASS in the one direction that matters.
 *
 * An in-page `setInterval` reads every field synchronously off one DOM, in the
 * same event loop that React renders into. The samples are then hauled out in a
 * single evaluate once the run is over. Sampling cost stays inside the page and
 * the correlation between "these lines were on screen" and "the run was still
 * running" is exact.
 *
 * ─── Why `data-line` and not the element count ─────────────────────────────
 *
 * StreamingLogBlock keeps at most MAX_VISIBLE_LINES (200) nodes in the DOM and
 * drops the oldest off the front. Past that bound the ELEMENT COUNT stops
 * growing — it pins at 200 — while output continues to pour in. An assertion
 * built on the count would therefore go quiet exactly on the long phases, and
 * report "the log stopped growing" about a log that did nothing of the kind.
 *
 * `data-line` is the line's ABSOLUTE position in the stream (the component
 * derives it as `hidden + 1 + i`, which is also why it can key React by it), so
 * it keeps rising under the tail. It is the only monotonic signal on the page.
 *
 * ─── Reading it back ───────────────────────────────────────────────────────
 *
 * The samples cross the boundary once, as JSON, after the run. Nothing is
 * asserted inside the page: an assertion there would report as a page error at
 * a moment nobody is looking, and the whole point of keeping the samples is
 * that a failure can print the entire timeline instead of one boolean.
 */
import { expect, type Locator, type Page } from "@playwright/test";

/** One reading of the log block, taken inside the page. */
export interface LogSample {
  /** ms since the sampler was installed. */
  t: number;
  /** How many line nodes were in the DOM. Pins at MAX_VISIBLE_LINES. */
  lines: number;
  /** `data-line` of the last node: absolute position in the stream. Monotonic. */
  lastLine: number;
  /** Characters of rendered text. Grows even when a partial last line is extended. */
  chars: number;
  /** The run's own status word, read from supercred-run-status. */
  status: string;
  /** True while that status word is `running`. */
  running: boolean;
  /** Whether the in-flight caret was on screen — i.e. `streaming` was true. */
  caret: boolean;
  /** Whether PixelLoader was mounted, which the panel does iff `running`. */
  progress: boolean;
  /** Scroll geometry of the log's scroll region, for the follow/unpin checks. */
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

/** How far from the bottom still counts as pinned. Mirrors StreamingLogBlock. */
export const PIN_THRESHOLD_PX = 24;

/** Where the sampler parks its readings. Namespaced so nothing else collides. */
const SAMPLES_KEY = "__slLogSamples";

/**
 * Start recording the log block, in the page, every `intervalMs`.
 *
 * Install this BEFORE clicking the phase button. The samples it takes in the
 * gap are `running: false, lines: 0` and are meaningful: they are the proof
 * that the block was empty at t=0, so a later non-zero reading is arrival and
 * not something that was already on screen.
 */
export async function startLogSampler(
  page: Page,
  opts: { testId?: string; intervalMs?: number } = {},
): Promise<void> {
  const testId = opts.testId ?? "supercred-run-log";
  const intervalMs = opts.intervalMs ?? 200;

  await page.evaluate(
    ({ testId, intervalMs, key }: { testId: string; intervalMs: number; key: string }) => {
      const w = window as unknown as Record<string, unknown>;
      // Re-installing would silently double the sample rate and interleave two
      // timelines into one array, which reads as impossible growth.
      if (w[key]) return;
      const samples: unknown[] = [];
      w[key] = samples;
      const started = performance.now();

      const read = () => {
        const lineNodes = document.querySelectorAll(`[data-testid="${testId}-line"]`);
        const last = lineNodes[lineNodes.length - 1] as HTMLElement | undefined;
        const scroll = document.querySelector(`[data-testid="${testId}-scroll"]`) as HTMLElement | null;
        const statusNode = document.querySelector('[data-testid="supercred-run-status"]');
        // "Step 1 (step) — running · started …". The em dash is the panel's own
        // separator and the word after it is DemoRunView.status verbatim.
        const status = statusNode?.textContent?.match(/—\s*([a-z_]+)/)?.[1] ?? "";
        samples.push({
          t: Math.round(performance.now() - started),
          lines: lineNodes.length,
          lastLine: last ? Number(last.dataset.line ?? 0) : 0,
          chars: scroll?.textContent?.length ?? 0,
          status,
          running: status === "running",
          caret: document.querySelector(`[data-testid="${testId}-caret"]`) !== null,
          progress: document.querySelector('[data-testid="supercred-run-progress"]') !== null,
          scrollTop: scroll ? Math.round(scroll.scrollTop) : 0,
          scrollHeight: scroll ? Math.round(scroll.scrollHeight) : 0,
          clientHeight: scroll ? Math.round(scroll.clientHeight) : 0,
        });
      };

      read();
      w[`${key}__timer`] = window.setInterval(read, intervalMs);
    },
    { testId, intervalMs, key: SAMPLES_KEY },
  );
}

/** Stop the recorder and hand back everything it saw. Safe to call twice. */
export async function readLogSamples(page: Page): Promise<LogSample[]> {
  return page.evaluate((key: string) => {
    const w = window as unknown as Record<string, unknown>;
    const timer = w[`${key}__timer`];
    if (typeof timer === "number") {
      window.clearInterval(timer);
      delete w[`${key}__timer`];
    }
    return (w[key] as LogSample[] | undefined) ?? [];
  }, SAMPLES_KEY);
}

/**
 * How many samples have been taken so far.
 *
 * This is how a mid-run interaction is placed on the timeline. Splitting the
 * samples at the index returned here gives "before I scrolled" and "after I
 * scrolled" as two exact halves of one continuous recording — which is the only
 * way to say "output kept arriving AND the view stopped following it" about the
 * same stretch of time. Wall-clock correlation from the Node side would be
 * approximate in the one dimension the whole spec is about.
 */
export async function sampleCursor(page: Page): Promise<number> {
  return page.evaluate((key: string) => {
    const w = window as unknown as Record<string, unknown>;
    return ((w[key] as unknown[] | undefined) ?? []).length;
  }, SAMPLES_KEY);
}

/**
 * The absolute position of the last rendered line right now, or 0 for none.
 *
 * Exists so a live spec can wait for "fifteen MORE lines" rather than for line
 * fifteen. A phase against a real cluster does not emit a knowable number of
 * lines — it emits whatever kubectl says — so an absolute target is a guess
 * that fails the suite on a healthy but quiet run.
 */
export async function currentLastLine(page: Page, testId = "supercred-run-log"): Promise<number> {
  return page.evaluate((id: string) => {
    const nodes = document.querySelectorAll(`[data-testid="${id}-line"]`);
    const last = nodes[nodes.length - 1] as HTMLElement | undefined;
    return last ? Number(last.dataset.line ?? 0) : 0;
  }, testId);
}

/**
 * Block until the log has rendered at least `minLastLine` lines.
 *
 * Used to get INTO the middle of a run before touching the scrollbar. Reads
 * `data-line` rather than counting nodes, for the tail reason above.
 */
export async function waitForLine(
  page: Page,
  minLastLine: number,
  opts: { testId?: string; timeout?: number } = {},
): Promise<void> {
  const testId = opts.testId ?? "supercred-run-log";
  await expect
    .poll(
      () =>
        page.evaluate((id: string) => {
          const nodes = document.querySelectorAll(`[data-testid="${id}-line"]`);
          const last = nodes[nodes.length - 1] as HTMLElement | undefined;
          return last ? Number(last.dataset.line ?? 0) : 0;
        }, testId),
      {
        message: `the log must reach line ${minLastLine} while the run is in flight`,
        timeout: opts.timeout ?? 60_000,
      },
    )
    .toBeGreaterThanOrEqual(minLastLine);
}

/** Throw the whole timeline away so the next run in the same page starts clean. */
export async function resetLogSampler(page: Page): Promise<void> {
  await readLogSamples(page);
  await page.evaluate((key: string) => {
    const w = window as unknown as Record<string, unknown>;
    delete w[key];
  }, SAMPLES_KEY);
}

/** A readable dump of the timeline, attached to every failure below. */
export function formatSamples(samples: LogSample[]): string {
  const head = "     t(ms)  lines  lastLine  chars  status     caret  scrollTop/Height/Client";
  const rows = samples.map(
    (s) =>
      `  ${String(s.t).padStart(7)}${String(s.lines).padStart(7)}` +
      `${String(s.lastLine).padStart(10)}${String(s.chars).padStart(7)}  ` +
      `${(s.status || "—").padEnd(11)}${s.caret ? "yes" : "no "}    ` +
      `${s.scrollTop}/${s.scrollHeight}/${s.clientHeight}`,
  );
  return [head, ...rows].join("\n");
}

/**
 * The strictly-increasing readings of `lastLine` taken WHILE the run was
 * running, in order.
 *
 * Each entry is a distinct moment at which more of the log was on screen than
 * at any earlier in-flight moment. Three of them is three separate arrivals
 * before the end — which is the definition of streaming, and which a single
 * end-of-run flush can produce at most one of.
 */
export function growthWhileRunning(samples: LogSample[]): LogSample[] {
  const growth: LogSample[] = [];
  let high = 0;
  for (const s of samples) {
    if (!s.running) continue;
    if (s.lastLine > high) {
      high = s.lastLine;
      growth.push(s);
    }
  }
  return growth;
}

export interface ProgressiveArrivalOptions {
  /**
   * How many distinct in-flight growth observations are required.
   *
   * Three, and not two, because two is what a HALF-fixed runner produces: one
   * flush partway through and one at the end still yields two rising readings
   * while being no more streamed than before. Three requires output to have
   * been arriving across the run rather than at a boundary.
   */
  minGrowthSamples?: number;
  /** Names the subject in failure output — "phase 1", "reset", "the harness run". */
  what?: string;
}

/**
 * Assert the log arrived progressively, and say exactly how it did not if it
 * did not.
 *
 * ─── What a batched log looks like here, precisely ─────────────────────────
 *
 * The panel mounts StreamingLogBlock only when `log !== ''`. If every byte
 * lands in one frame at process exit, then at every sample taken while the
 * status read `running` there are ZERO line nodes on the page — the block does
 * not exist yet. `growthWhileRunning()` filters to in-flight samples and looks
 * for rising `lastLine`; over a batched run every in-flight sample has
 * `lastLine: 0`, so the returned array is EMPTY and the first assertion below
 * fails with `0 < 3`. The single 0 → N jump happens after `running` went false
 * and is never considered.
 *
 * That is checked, not merely reasoned about:
 * supercred-log-streaming-harness.spec.ts drives the harness in `batch` mode —
 * which reproduces the old runner's behaviour exactly, withholding the log
 * until the run reports terminal — and asserts that THIS FUNCTION THROWS. If
 * someone weakens the checks below into something a batched log satisfies, that
 * negative-control test goes red.
 */
export function expectProgressiveArrival(
  samples: LogSample[],
  opts: ProgressiveArrivalOptions = {},
): void {
  const minGrowth = opts.minGrowthSamples ?? 3;
  const what = opts.what ?? "the run";
  const timeline = `\n${formatSamples(samples)}`;

  const growth = growthWhileRunning(samples);
  expect(
    growth.length,
    `${what}: the log must grow at least ${minGrowth} times WHILE the run is still ` +
      `running. Got ${growth.length}. Zero means nothing was on screen until the run ` +
      `was over — output was batched, which is the regression this spec exists for. ` +
      `One means a single flush. Timeline:${timeline}`,
  ).toBeGreaterThanOrEqual(minGrowth);

  // Redundant with the above given growthWhileRunning's contract, and kept
  // because it is the assertion a reader looks for: real lines, not an empty
  // block, were on screen mid-run.
  expect(
    growth[0]?.lastLine ?? 0,
    `${what}: the first in-flight reading must show at least one rendered line.` +
      timeline,
  ).toBeGreaterThan(0);

  // The caret is the panel's own claim that output is still coming. It renders
  // only when StreamingLogBlock's `streaming` prop is true, which the panel
  // wires straight to `running`. Seeing it WITH lines already on screen is
  // independent evidence of the same fact: the block was live, not a corpse
  // rendered after the fact.
  const liveCaret = samples.filter((s) => s.running && s.lines > 0 && s.caret);
  expect(
    liveCaret.length,
    `${what}: the in-flight caret must be on screen alongside rendered lines at least ` +
      `once. It renders only while the panel considers the run active, so its absence ` +
      `means the lines appeared after the run ended.` + timeline,
  ).toBeGreaterThan(0);
}

// ── Which transport actually carried the bytes ──────────────────────────────

/**
 * Count the log requests the page makes, split by transport.
 *
 * ─── Why an acceptance spec cares about the wire at all ────────────────────
 *
 * It normally should not, and everything else in this module deliberately does
 * not: the assertions read the rendered DOM precisely so they hold over any
 * transport. This one exists because "which transport is the default" is now a
 * DECISION rather than an implementation detail, and an undefended decision
 * drifts.
 *
 * The 500ms offset poll (`GET /demo-api/runs/{id}/log?offset=N`) is the
 * default and is what runs on stage. SSE
 * (`GET /demo-api/runs/{id}/stream`) is opt-in behind an explicit flag,
 * because it cannot cover its own worst failure mode: a buffering intermediary
 * ACCEPTS the connection and then delivers nothing. No error fires, so no
 * fallback triggers, and the panel sits silent — which is indistinguishable
 * from the bug this whole branch exists to fix, and worse, would be introduced
 * by the fix for it.
 *
 * ─── What the assertion buys ───────────────────────────────────────────────
 *
 * Without it, this suite would keep passing if someone made SSE the default,
 * because the DOM assertions cannot tell the two apart — which is their virtue
 * everywhere else and their blind spot here. With it, flipping the default
 * turns the acceptance layer red, and re-pointing it becomes a deliberate edit
 * with a reviewer, rather than a silent change of what "proven on stage" means.
 *
 * Install before the run starts. Counts requests, not responses, so a
 * connection that opens and then delivers nothing still registers — that being
 * exactly the failure the poll default is guarding against.
 */
export interface TransportWatch {
  polls: () => number;
  streams: () => number;
  describe: () => string;
}

export function watchTransport(page: Page): TransportWatch {
  const polls: string[] = [];
  const streams: string[] = [];
  page.on("request", (request) => {
    const path = new URL(request.url()).pathname + new URL(request.url()).search;
    if (/\/demo-api\/runs\/[^/]+\/log(\?|$)/.test(path)) polls.push(path);
    if (/\/demo-api\/runs\/[^/]+\/stream(\?|$)/.test(path)) streams.push(path);
  });
  return {
    polls: () => polls.length,
    streams: () => streams.length,
    describe: () =>
      `${polls.length} poll request(s) to /log, ${streams.length} to /stream` +
      (streams.length ? `\nstream requests: ${streams.slice(0, 5).join(", ")}` : ""),
  };
}

/**
 * Assert the run was carried by the DEFAULT transport: the offset poll, and
 * not SSE.
 *
 * If this fails with stream requests > 0, nothing is necessarily broken — but
 * the default has moved, and the spec that protects the on-stage path must be
 * re-pointed on purpose. Do not delete this to make it pass.
 */
export function expectDefaultTransport(watch: TransportWatch, what = "the run"): void {
  expect(
    watch.polls(),
    `${what}: the default transport is the 500ms offset poll, so the page must have ` +
      `requested /demo-api/runs/{id}/log at least once. It requested none, which means ` +
      `the log reached the DOM by some route this spec is not watching. ${watch.describe()}`,
  ).toBeGreaterThan(0);

  expect(
    watch.streams(),
    `${what}: SSE is opt-in behind an explicit flag and this spec sets no flag, so ` +
      `/demo-api/runs/{id}/stream must never be requested. It was. Either the panel now ` +
      `opts in by default — in which case the on-stage path has changed and this spec ` +
      `must be re-pointed deliberately — or the flag is leaking. ${watch.describe()}`,
  ).toBe(0);
}

/**
 * The inverse, for the secondary case that opts INTO SSE.
 *
 * Only `streams() > 0` is asserted. The poll count is deliberately NOT required
 * to be zero: the panel's post-run drain calls the log endpoint on every path,
 * SSE or not, so requiring zero would fail against a perfectly healthy stream —
 * and worse, it would fail in a way that looks like "SSE is not being used"
 * when the truth is "the drain ran, as designed".
 *
 * This is the weaker assertion of the pair, and that asymmetry is on purpose.
 * The default path is what runs on stage; the opt-in path is a capability.
 */
export function expectSseTransport(watch: TransportWatch, what = "the run"): void {
  expect(
    watch.streams(),
    `${what}: this case opts into SSE, so the page must have opened ` +
      `/demo-api/runs/{id}/stream at least once. It did not — the opt-in did not take ` +
      `effect, and what was actually measured is the default poll path wearing an SSE ` +
      `label. ${watch.describe()}`,
  ).toBeGreaterThan(0);
}

/**
 * Assert the STREAM actually carried the output, not merely that it opened.
 *
 * ─── Why opening is not enough ─────────────────────────────────────────────
 *
 * SuperCredInstructorPanel treats an open stream as worthless until a frame
 * lands: `streamLiveRef` is set in `onChunk`, never on connect, precisely
 * because a buffering proxy opens a response instantly and then holds every
 * frame. It also hands the stream its own shutdown when the cursor moved
 * underneath it — `onChunk` returning false — which happens whenever a waiting
 * read was still in flight as the stream opened. Both are deliberate, and both
 * end with the POLL delivering every byte while `/stream` still shows one
 * request.
 *
 * So `expectSseTransport()` alone is a test that passes while proving nothing:
 * it would go green on an SSE connection that was opened, rejected and
 * abandoned within 200ms. Observed exactly that here before this existed.
 *
 * ─── The counting argument ─────────────────────────────────────────────────
 *
 * Every distinct growth observation needs a delivery behind it: lines cannot
 * appear without bytes arriving, and bytes arrive either in a poll response or
 * in a stream frame. One poll response can deliver many lines, so it can
 * account for at most ONE growth step in the sampled timeline — a second step
 * needs a second delivery.
 *
 * Therefore `growthSteps > pollRequests` proves at least
 * `growthSteps - pollRequests` steps were delivered by the stream. It is a
 * strict inequality on counts, needs no clock alignment between the in-page
 * sampler and Node's request listener, and cannot be satisfied by the poll path
 * alone at any polling rate.
 *
 * The panel's own behaviour gives this enormous margin when the stream is
 * genuinely live: the poll loop skips issuing a request entirely while
 * `streamLiveRef` is set, so a healthy stream leaves two or three poll
 * requests against twenty-odd growth steps. A stream that died leaves them
 * equal.
 */
export function expectStreamCarriedOutput(
  watch: TransportWatch,
  samples: LogSample[],
  what = "the run",
): void {
  const growth = growthWhileRunning(samples);
  expect(
    growth.length,
    `${what}: the log grew ${growth.length} time(s) while running but the page made ` +
      `${watch.polls()} poll request(s). Since one poll response can account for at most ` +
      `one growth step, the stream carried nothing — it opened and was then abandoned, ` +
      `which is what happens when a waiting read moves the cursor under it (the panel's ` +
      `onChunk returns false and the stream shuts itself down) or when frames never ` +
      `arrive. The log still filled, over the poll fallback, so every other assertion ` +
      `here passes; this is the one that notices. ${watch.describe()}` +
      `\n${formatSamples(samples)}`,
  ).toBeGreaterThan(watch.polls());
}

// ── Preflight: can this browser measure text at all? ────────────────────────

/**
 * Fail early, and by name, if the browser lays every string out at zero size.
 *
 * ─── Why this exists ───────────────────────────────────────────────────────
 *
 * A Chromium that cannot resolve any font — no reachable fontconfig, an
 * unwritable cache directory, a renderer sandbox with no font access — still
 * builds a complete and correct DOM. `textContent.length` is right, every node
 * is present, the streaming assertions all pass. What it does not do is produce
 * line boxes: every element measures 0x0.
 *
 * The log block then has a scrollHeight of 36px while holding 6470 characters,
 * and `expectFollowsTail()` fails with "the log never overflowed its box".
 * That message is true, and it points at the component, and the component is
 * fine. Two people have now lost time to it.
 *
 * So the layout precondition is asserted as a precondition, before anything is
 * concluded from a measurement. Same discipline as
 * scripts/acceptance-test.sh's Gateway preflight: a missing environment
 * capability should fail as itself, not as a downstream assertion about
 * something else.
 *
 * Measured on a string this module injects and removes, not on the app's own
 * markup, so it holds whatever the page under test happens to be rendering and
 * cannot be defeated by the app styling that text to zero on purpose.
 */
export async function expectRendersText(page: Page): Promise<void> {
  const box = await page.evaluate(() => {
    const probe = document.createElement("span");
    probe.textContent = "font metrics probe 0123456789";
    // Inline, unstyled, and out of flow so it cannot disturb the layout it is
    // about to measure — but NOT display:none, which would legitimately be 0x0.
    probe.style.cssText = "position:absolute;left:-9999px;top:0;white-space:pre";
    document.body.appendChild(probe);
    const rect = probe.getBoundingClientRect();
    probe.remove();
    return { width: rect.width, height: rect.height };
  });

  expect(
    Math.min(box.width, box.height),
    `this browser cannot measure text: a 29-character string laid out at ` +
      `${Math.round(box.width)}x${Math.round(box.height)}. The DOM is fine and the ` +
      `components are fine — no font is resolvable, so nothing has a line box, and every ` +
      `layout assertion below would fail with a message about the log block instead.\n\n` +
      `On Linux this is usually fontconfig being unreachable or its cache unwritable:\n\n` +
      `    mkdir -p /tmp/fcfg/cache\n` +
      `    printf '%s\\n' '<?xml version="1.0"?>' \\\n` +
      `      '<fontconfig><dir>/usr/share/fonts</dir>' \\\n` +
      `      '<cachedir>/tmp/fcfg/cache</cachedir></fontconfig>' > /tmp/fcfg/fonts.conf\n` +
      `    FONTCONFIG_FILE=/tmp/fcfg/fonts.conf make demo-signalloom-supercred-stream-harness\n\n` +
      `Nothing in this suite compensates for it deliberately: a spec that forced its own ` +
      `line heights would stop testing the component's real layout, which is the whole ` +
      `subject of the pin/unpin assertions.`,
  ).toBeGreaterThan(0);
}

/** The scroll region of a log block. */
export function logScroll(page: Page, testId = "supercred-run-log"): Locator {
  return page.locator(`[data-testid="${testId}-scroll"]`);
}

/** True when a sample shows the view sitting at the bottom of its content. */
export function isPinned(s: LogSample): boolean {
  return s.scrollHeight - s.scrollTop - s.clientHeight < PIN_THRESHOLD_PX;
}

/** True once there is more content than fits, so scroll position means anything. */
export function overflows(s: LogSample): boolean {
  return s.scrollHeight > s.clientHeight + PIN_THRESHOLD_PX;
}

/**
 * Assert the box followed the tail while the instructor left it alone.
 *
 * Guarded on `overflows`: with less content than the box is tall, scrollTop is
 * 0, scrollHeight equals clientHeight, and "pinned to the bottom" is
 * VACUOUSLY true — the check would pass against a component with the follow
 * behaviour deleted. So samples that cannot distinguish are excluded, and the
 * assertion then requires that some remain.
 */
export function expectFollowsTail(samples: LogSample[], what = "the run"): void {
  const timeline = `\n${formatSamples(samples)}`;
  const meaningful = samples.filter((s) => s.running && s.lines > 0 && overflows(s));
  expect(
    meaningful.length,
    `${what}: the log never overflowed its box while running, so "scrolled to the ` +
      `bottom" could not be told apart from "has not scrolled at all". Nothing was ` +
      `proven. Drive a phase that produces more output.` + timeline,
  ).toBeGreaterThan(0);

  const adrift = meaningful.filter((s) => !isPinned(s));
  expect(
    adrift.length,
    `${what}: ${adrift.length} of ${meaningful.length} in-flight samples showed the ` +
      `view away from the bottom while nobody had scrolled it. New output must keep ` +
      `the tail in view.` + timeline,
  ).toBe(0);
}

/**
 * Assert that after the instructor scrolled up, output kept coming and the view
 * did NOT get dragged back down.
 *
 * The first half of that is not optional garnish. "The view stayed where I put
 * it" is trivially true of a log that stopped producing, and a component that
 * had crashed, stalled or finished would satisfy it perfectly. So growth is
 * required over the same stretch of samples: the view has to be visibly
 * RESISTING something.
 *
 * Stated as "did not return to the bottom" rather than "scrollTop never
 * changed" on purpose. Past MAX_VISIBLE_LINES the block drops nodes off the
 * front, Chrome's scroll anchoring compensates, and scrollTop legitimately
 * moves by a few pixels on a view that has not budged relative to the content.
 * Pinning is what the user perceives and what the component actually decides
 * on, so pinning is what is asserted.
 */
export function expectHoldsPositionWhileUnpinned(samples: LogSample[], what = "the run"): void {
  const timeline = `\n${formatSamples(samples)}`;
  const inflight = samples.filter((s) => s.running && s.lines > 0);
  expect(
    inflight.length,
    `${what}: no in-flight samples after the scroll, so nothing was observed at all.` +
      timeline,
  ).toBeGreaterThan(0);

  const first = inflight.at(0);
  const last = inflight.at(-1);
  expect(
    last?.lastLine ?? 0,
    `${what}: output must keep arriving after the instructor scrolls up, or "the view ` +
      `stayed put" proves nothing — a dead log also stays put.` + timeline,
  ).toBeGreaterThan(first?.lastLine ?? 0);

  const yanked = inflight.filter((s) => isPinned(s));
  expect(
    yanked.length,
    `${what}: the view was dragged back to the bottom in ${yanked.length} of ` +
      `${inflight.length} samples after the instructor scrolled up. New output must not ` +
      `move the viewport away from what they are reading.` + timeline,
  ).toBe(0);
}
