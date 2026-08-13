/**
 * Progressive log arrival, proven without a cluster — and the negative control
 * that proves the proof.
 *
 * ─── How to run it ─────────────────────────────────────────────────────────
 *
 *   make demo-signalloom-supercred-stream-harness
 *
 * or directly:
 *
 *   cd test/acceptance
 *   bun install
 *   bunx playwright test supercred-log-streaming-harness.spec.ts \
 *     --project=supercred-log-streaming-harness
 *
 * No Kind cluster, no Gateway, no Dex, no GCP, no port-forwards, no
 * `make demo-signalloom-*`. The only external requirement is a Chromium
 * Playwright can launch; `PW_CHANNEL=chromium` uses the bundled one if
 * /opt/google/chrome is not executable in your shell.
 *
 * Two environment traps, both hit while writing this, both of which present as
 * a broken component rather than a broken environment:
 *
 *   * Chrome at /opt/google/chrome/chrome is not executable from some
 *     sandboxed shells — `browserType.launch: spawn … EACCES`. That one at
 *     least names itself. `PW_CHANNEL=chromium` is the documented way out.
 *
 *   * a browser that cannot reach fontconfig lays every string out at ZERO
 *     width and height. The DOM is complete and correct, so the
 *     progressive-arrival assertions pass — and the scroll assertions fail
 *     with a 16px-tall scroll region and a "the log never overflowed its box"
 *     message that reads like a component bug. If that is what you are seeing,
 *     the layout is telling the truth about a machine with no usable fonts:
 *
 *         mkdir -p /tmp/fcfg/cache
 *         printf '%s\n' '<?xml version="1.0"?>' \
 *           '<fontconfig><dir>/usr/share/fonts</dir>' \
 *           '<cachedir>/tmp/fcfg/cache</cachedir></fontconfig>' \
 *           > /tmp/fcfg/fonts.conf
 *         FONTCONFIG_FILE=/tmp/fcfg/fonts.conf make demo-signalloom-supercred-stream-harness
 *
 *     Nothing in the suite compensates for it, deliberately: a spec that
 *     forced its own line heights would stop testing the component's real
 *     layout, which is exactly what the pin/unpin assertions are about.
 *
 * To poke at it by hand:
 *
 *   cd test/acceptance
 *   bun harness/server.ts                 # then open the printed URL
 *   bun harness/server.ts --mode batch    # the defect, reproduced
 *
 * ─── What is real here and what is not ─────────────────────────────────────
 *
 * REAL: SuperCredInstructorPanel, StreamingLogBlock, api/demoRunner.ts, the
 * 500ms poll loop, applyLogChunk's offset de-duplication, drainLog, the theme
 * tokens from styles/themes.ts, and React 18 at the same major the app ships.
 * harness/entry.tsx is a `createRoot` call; it reimplements nothing.
 *
 * NOT REAL: the OIDC token (harness/auth-stub.tsx — the panel uses it for one
 * `Authorization` header and nothing else) and the cluster (harness/server.ts
 * serves /demo-api from a scripted schedule instead of running kubectl).
 *
 * That split is the point. The bug was in how bytes moved from the runner to
 * the DOM, so every component on that path is the shipping one; only the far
 * end of the pipe is scripted, and it is scripted so its timing can be stated
 * rather than hoped for.
 *
 * ─── The one new dependency ────────────────────────────────────────────────
 *
 * `react` and `react-dom` are added to test/acceptance/package.json, pinned to
 * the dashboard's own ^18.3.1, and they are the ONLY additions. Rendering the
 * real component obviously requires React; a fresh worktree has no
 * node_modules under d2-signalloom/apps/dashboard-signalloom, and Bun resolves
 * bare specifiers by walking up from the importing file, so it never finds
 * this directory's copy — harness/server.ts redirects those two resolutions
 * explicitly.
 *
 * This touches test/acceptance/bun.lock, which is this suite's OWN lockfile —
 * not the dashboard's, and not the repo root's. The dashboard's dual
 * bun.lock/package-lock.json pairing (guarded by its lockfileSync.test.ts in
 * CI stage 1b) is untouched, which is the constraint that made adding the
 * dependency here rather than there the right call.
 *
 * ─── Why this file exists ALONGSIDE supercred-log-streaming.spec.ts ────────
 *
 * The live spec is the authority — it is the only thing that can catch a
 * regression in the runner's own pipe handling, which is where the defect
 * actually was. But it needs the full estate, so it runs on a lane measured in
 * tens of minutes and nobody runs it while editing a component. This one runs
 * in about twenty seconds on a laptop, which is the difference between a guard
 * that fires during the change and a guard that fires next week.
 *
 * It also does something the live spec structurally CANNOT: it drives a runner
 * that batches on purpose, and requires the assertions to fail against it.
 *
 * ─── The negative control ──────────────────────────────────────────────────
 *
 * "This test would have caught the bug" is the sort of claim that is only ever
 * checked by the bug coming back. Here it is checked on every run: the second
 * test below points the panel at a runner in `batch` mode — which withholds the
 * log until the run reports terminal, exactly as `proc.stdout.read(8192)` on a
 * BufferedReader did — and asserts that `expectProgressiveArrival()` THROWS.
 *
 * So if someone loosens the shared assertion into something a batched log
 * satisfies, they do not get a quieter suite; they get a red test named
 * "batched output must FAIL the progressive-arrival assertions". Same shape as
 * the `__spec-coverage-guard-probe__` in test/acceptance-spec-coverage.bats:
 * a check whose over-permissiveness is itself checked.
 *
 * ─── Transport: the DEFAULT is a long-poll waiting read ───────────────────
 *
 * `GET /demo-api/runs/{id}/log?offset=N&wait=S` is the default. It is an
 * ordinary short HTTP response that the runner simply holds open until bytes
 * exist, the run ends, or the deadline passes — so delivery lands within
 * milliseconds of the script printing, and nothing between the browser and the
 * runner can swallow it. harness/server.ts implements `wait` rather than
 * answering immediately: a double that ignores it turns the panel's long poll
 * into a hot loop and would let a runner that dropped `wait` handling pass here
 * unnoticed.
 *
 * SSE is opt-in, via `?logTransport=sse` or
 * `localStorage['signalloom.logTransport'] = 'sse'`, because it cannot cover
 * its own worst failure mode: a buffering intermediary ACCEPTS the connection
 * and then delivers nothing. No error fires, so no fallback triggers, and the
 * panel sits silent — indistinguishable from the batching defect this branch
 * exists to fix.
 *
 * Both are covered, asymmetrically and on purpose:
 *
 *   * the first three tests set NO flag and assert the default. Every
 *     assertion reads the rendered DOM, so the temporal property survives a
 *     transport swap — but that virtue is a blind spot for exactly one
 *     question, so `expectDefaultTransport()` also asserts at the request layer
 *     that the run polled `/log` and never opened `/stream`. Without it the
 *     suite would keep passing if SSE quietly became the default;
 *
 *   * the fourth opts in with `?logTransport=sse` and asserts the SAME temporal
 *     property over the stream. It is deliberately secondary: if SSE is removed
 *     tomorrow, deleting that one test leaves progressive arrival fully
 *     asserted. It is not permitted to be the only place the property is
 *     proven.
 *
 * Worth knowing before anyone reads too much into the SSE case: a harness on
 * loopback cannot reproduce a buffering intermediary, so it proves the happy
 * path only. The silent-stall risk that motivated the poll default stays
 * un-testable at this layer — which is an argument for the default, not
 * against the test.
 */
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { join } from "node:path";
import type { Readable } from "node:stream";
import { test, expect } from "@playwright/test";
import {
  expectDefaultTransport,
  expectFollowsTail,
  expectRendersText,
  expectSseTransport,
  expectStreamCarriedOutput,
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

// Serial: each test owns a whole harness process and a whole run, and the
// harness serialises runs the same way the real runner does.
test.describe.configure({ mode: "serial" });

const INSTRUCTOR = '[data-testid="supercred-instructor"]';
const RUN_STEP_1 = '[data-testid="supercred-run-step-1"]';
const RUN_STATUS = '[data-testid="supercred-run-status"]';
// StreamingLogBlock derives every inner test id from its `testId` prop, so the
// prefix is kept as a bare string and the selectors are built from it. Writing
// `` `${RUN_LOG}-line` `` instead produces
// `[data-testid="supercred-run-log"]-line`, which is not a selector — Playwright
// raises a parse error rather than reporting zero matches, which is at least
// loud, but it wastes a run.
const LOG_ID = "supercred-run-log";
const RUN_LOG = `[data-testid="${LOG_ID}"]`;
const RUN_LOG_LINE = `[data-testid="${LOG_ID}-line"]`;

/**
 * 90 lines at 60ms is a ~5.4s run.
 *
 * Long enough that a 500ms poll gets ten or more distinct looks at it — the
 * assertions need at least three — and short enough that three of these plus a
 * browser launch stays under half a minute. Under MAX_VISIBLE_LINES (200), so
 * the DOM keeps every line and `data-line` and the node count agree; the tail
 * behaviour has its own coverage in StreamingLogBlock.test.tsx.
 */
const LINES = 90;
const INTERVAL_MS = 60;

interface Harness {
  url: string;
  // `stdio: ["ignore", "pipe", "pipe"]` gives a child with no stdin, which is
  // ChildProcessByStdio<null, …> rather than ChildProcessWithoutNullStreams.
  child: ChildProcessByStdio<null, Readable, Readable>;
}

/**
 * Start `bun harness/server.ts` and wait until it says it is ready.
 *
 * A process rather than an import: the Playwright runner is Node, and
 * harness/server.ts is Bun-only (`Bun.serve`, `Bun.build`, `import.meta`).
 * Importing it fails at COLLECTION, which Playwright reports as "No tests
 * found" — a green-looking exit that names neither file. See the comment on
 * that file's `import.meta.main` block.
 *
 * The path is resolved from `test.info().config.rootDir` rather than from
 * `__dirname` or `import.meta.url`, because which of those two exists depends
 * on how the runner transpiled this file, and rootDir is true either way.
 *
 * Port 0: the OS picks a free one and the server reports it. Every spec in
 * this suite that hardcoded a port eventually collided with a port-forward.
 */
async function startHarness(
  opts: { mode: "stream" | "batch"; lines: number; intervalMs: number; startDelayMs?: number },
): Promise<Harness> {
  const script = join(test.info().config.rootDir, "harness", "server.ts");
  const child = spawn(
    "bun",
    [
      script,
      "--mode", opts.mode,
      "--port", "0",
      "--lines", String(opts.lines),
      "--interval", String(opts.intervalMs),
      "--start-delay", String(opts.startDelayMs ?? 0),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  const stderr: string[] = [];
  child.stderr.on("data", (buf: Buffer) => stderr.push(buf.toString()));

  const url = await new Promise<string>((resolve, reject) => {
    // The bundle of the real component tree is built before the ready line, so
    // a cold first run spends a few seconds here and then serves instantly.
    const timer = setTimeout(
      () => reject(new Error(`harness did not become ready in 60s. stderr:\n${stderr.join("")}`)),
      60_000,
    );
    let out = "";
    child.stdout.on("data", (buf: Buffer) => {
      out += buf.toString();
      const url = out.match(/^HARNESS_READY (\S+)/m)?.[1];
      if (!url) return;
      clearTimeout(timer);
      resolve(url);
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`harness exited with ${code} before it was ready. stderr:\n${stderr.join("")}`));
    });
  });

  return { url, child };
}

let harness: Harness | null = null;

test.afterEach(() => {
  harness?.child.kill("SIGTERM");
  harness = null;
});

/** Boot the panel against a harness and wait for it to be usable. */
async function openPanel(
  page: import("@playwright/test").Page,
  h: Harness,
  query = "",
): Promise<void> {
  await page.goto(`${h.url}/${query}`, { waitUntil: "domcontentloaded" });
  await expect(page.locator(INSTRUCTOR)).toBeVisible({ timeout: 15_000 });
  // Before ANY measurement is trusted. A browser with no resolvable font
  // builds a perfect DOM and lays every string out at 0x0, which passes the
  // streaming assertions and fails the layout ones with a message blaming the
  // log block. Asserted here so that environment fails as itself.
  await expectRendersText(page);
  // The phase buttons stay disabled until GET /demo-api/status has answered
  // with script_available — clicking before that is a no-op that then reads as
  // "the runner produced nothing".
  await expect(page.locator(RUN_STEP_1)).toBeEnabled({ timeout: 15_000 });
}

test("a phase's output is rendered as it arrives, not in one frame at the end", async ({ page }) => {
  harness = await startHarness({ mode: "stream", lines: LINES, intervalMs: INTERVAL_MS });
  await openPanel(page, harness);

  const transport = watchTransport(page);
  // Installed BEFORE the click, so the recording contains the empty state.
  // Without those leading zero-line samples a log that was ALREADY on screen
  // would be indistinguishable from one that arrived.
  await startLogSampler(page);
  await page.locator(RUN_STEP_1).click();

  await expect(page.locator(RUN_STATUS)).toContainText(/—\s*succeeded/, { timeout: 60_000 });
  // The post-run drain lands after the status flips; wait for the block to be
  // present so the recording covers the whole arrival, not just the part of it
  // that happened to precede the status change.
  await expect(page.locator(RUN_LOG)).toBeVisible({ timeout: 15_000 });

  const samples = await readLogSamples(page);
  test.info().attach("stream-timeline", { body: formatSamples(samples), contentType: "text/plain" });

  expectProgressiveArrival(samples, { what: "the scripted phase 1 (stream mode)" });
  expectFollowsTail(samples, "the scripted phase 1 (stream mode)");
  expectDefaultTransport(transport, "the scripted phase 1 (stream mode)");

  // Independent of the sampler: the block, its caret and its ANSI handling all
  // did their job. The runner emits `[1;36m[supercred][0m`, so an
  // escape byte reaching the DOM would mean stripAnsi silently stopped working.
  await expect(page.locator(RUN_LOG_LINE).last()).toContainText(/phase 1 complete/);
  await expect(page.locator(RUN_LOG)).not.toContainText("\u001B");
});

test("batched output must FAIL the progressive-arrival assertions", async ({ page }) => {
  // The negative control. `batch` withholds the log until the run reports
  // terminal — the old runner's behaviour, reproduced deliberately. Everything
  // else about this test is identical to the one above.
  harness = await startHarness({ mode: "batch", lines: LINES, intervalMs: INTERVAL_MS });
  await openPanel(page, harness);

  await startLogSampler(page);
  await page.locator(RUN_STEP_1).click();

  await expect(page.locator(RUN_STATUS)).toContainText(/—\s*succeeded/, { timeout: 60_000 });
  await expect(page.locator(RUN_LOG)).toBeVisible({ timeout: 15_000 });

  const samples = await readLogSamples(page);
  test.info().attach("batch-timeline", { body: formatSamples(samples), contentType: "text/plain" });

  // First: the harness is not simply broken. The whole log DID arrive, all of
  // it, and the panel rendered it correctly. This is the sentence that makes
  // the failure below mean "too late" rather than "not at all" — and it is the
  // exact reason every pre-existing test passed against the broken runner.
  await expect(page.locator(RUN_LOG_LINE).last()).toContainText(/phase 1 complete/);
  expect(
    Math.max(...samples.map((s) => s.lastLine)),
    "the batch-mode harness must still deliver the full log eventually, or this test " +
      "would be asserting that a broken harness fails, which proves nothing",
  ).toBe(LINES);

  // And now the point: every one of those lines landed after the run was over.
  const inflightLines = samples.filter((s) => s.running).map((s) => s.lastLine);
  expect(
    Math.max(0, ...inflightLines),
    "batch mode must show zero rendered lines while the run is still running — that is " +
      "what the defect looked like",
  ).toBe(0);

  expect(
    () => expectProgressiveArrival(samples, { what: "the scripted phase 1 (batch mode)" }),
    "expectProgressiveArrival() accepted a log that arrived entirely at the end. The " +
      "shared assertion has been weakened into one the original defect satisfies, so " +
      "supercred-log-streaming.spec.ts is now green against a runner that does not " +
      "stream. Restore the strictness rather than deleting this test.",
  ).toThrow();
});

test("scrolling up stops new output yanking the view, and scrolling back down re-follows", async ({
  page,
}) => {
  // A longer run: the viewport is manipulated twice mid-flight and each stretch
  // needs enough samples of its own to say anything.
  harness = await startHarness({ mode: "stream", lines: 150, intervalMs: 80 });
  await openPanel(page, harness);

  const transport = watchTransport(page);
  await startLogSampler(page);
  await page.locator(RUN_STEP_1).click();

  const scroll = logScroll(page);
  // Deep enough that the box is already overflowing (≈15 lines fill its 260px)
  // and enough samples have been taken for "it was following" to mean something.
  await waitForLine(page, 40, { timeout: 30_000 });

  // ── Pinned by default ───────────────────────────────────────────────────
  const beforeScrollUp = await sampleCursor(page);

  // ── The instructor scrolls up to read something ─────────────────────────
  // Assigning scrollTop fires a real `scroll` event, which is what the
  // component's own onScroll listens to — this is the same signal a mouse
  // wheel produces, not a private hook into React state.
  await scroll.evaluate((el) => {
    el.scrollTop = 0;
  });
  const afterScrollUp = await sampleCursor(page);

  // Let a decent stretch of output land while they are reading.
  await waitForLine(page, 110, { timeout: 30_000 });
  const beforeScrollDown = await sampleCursor(page);

  // ── They scroll back to the bottom, and following resumes ───────────────
  await scroll.evaluate((el) => {
    el.scrollTop = el.scrollHeight;
  });
  const afterScrollDown = await sampleCursor(page);

  await expect(page.locator(RUN_STATUS)).toContainText(/—\s*succeeded/, { timeout: 60_000 });
  const samples = await readLogSamples(page);
  test.info().attach("scroll-timeline", { body: formatSamples(samples), contentType: "text/plain" });

  expectFollowsTail(samples.slice(0, beforeScrollUp), "before the instructor scrolled");
  expectHoldsPositionWhileUnpinned(
    samples.slice(afterScrollUp, beforeScrollDown),
    "while the instructor was reading",
  );
  expectFollowsTail(samples.slice(afterScrollDown), "after the instructor scrolled back down");
  expectDefaultTransport(transport, "the scrolling run");
});

test("SSE, when explicitly opted into, delivers the same progressive arrival", async ({ page }) => {
  // SECONDARY. The three tests above are the ones that protect the on-stage
  // path; this one proves the opt-in capability works, over the frame contract
  // api/demoRunner.ts actually parses — `event: log` carrying a
  // DemoRunLogChunk, then `event: end`. A frame with any other name is
  // silently ignored by that client, so a stream that connects and delivers
  // nothing visible is a real failure mode and this is what catches it.
  // startDelayMs: the panel opens the stream and issues a waiting read in the
  // same tick, and whichever lands second is rejected by the cursor guard. If
  // the read wins, the panel shuts its own stream down — deliberate, and it
  // would leave this case measuring the poll while calling itself SSE. A short
  // silence before the first line parks the waiting read (what `wait` is for)
  // and is what a real script's startup looks like anyway.
  harness = await startHarness({
    mode: "stream", lines: LINES, intervalMs: INTERVAL_MS, startDelayMs: 700,
  });
  await openPanel(page, harness, "?logTransport=sse");

  const transport = watchTransport(page);
  await startLogSampler(page);
  await page.locator(RUN_STEP_1).click();

  await expect(page.locator(RUN_STATUS)).toContainText(/—\s*succeeded/, { timeout: 60_000 });
  await expect(page.locator(RUN_LOG)).toBeVisible({ timeout: 15_000 });

  const samples = await readLogSamples(page);
  test.info().attach("sse-timeline", { body: formatSamples(samples), contentType: "text/plain" });

  // First that the opt-in actually took effect. Without this the test would
  // pass identically on the default poll path and quietly assert nothing about
  // SSE at all — the same shape of vacuous pass as a spec no project claims.
  expectSseTransport(transport, "the SSE opt-in run");
  // And that it CARRIED the log rather than merely opening. Opening proves
  // nothing: the panel abandons a stream whose cursor moved under it, and the
  // poll then delivers every byte while /stream still shows one request.
  expectStreamCarriedOutput(transport, samples, "the SSE opt-in run");

  expectProgressiveArrival(samples, { what: "the scripted phase 1 (SSE opt-in)" });
  expectFollowsTail(samples, "the scripted phase 1 (SSE opt-in)");

  await expect(page.locator(RUN_LOG_LINE).last()).toContainText(/phase 1 complete/);
});
