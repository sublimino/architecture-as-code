// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Coding-agent topology, rendered — SLCD-P6-3.
 *
 * ─── How to run it ─────────────────────────────────────────────────────────
 *
 *   cd test/acceptance
 *   bun install --frozen-lockfile
 *   bunx playwright test coding-agent-topology.spec.ts \
 *     --project=coding-agent-topology
 *
 * ─── Its precondition, stated once ─────────────────────────────────────────
 *
 * NO Kind cluster, NO Gateway, NO Dex, NO GCP, NO port-forwards, NO
 * `make demo-signalloom-*`. The spec spawns its own
 * `bun harness/coding-agents-server.ts` on `--port 0`.
 *
 * What it DOES need, and nothing else:
 *
 *   1. `bun` on PATH (the harness is a Bun process; the runner is Node).
 *   2. `test/acceptance/node_modules` with react + react-dom installed —
 *      the harness bundles the REAL component tree.
 *   3. A Chromium Playwright can launch. `PW_CHANNEL=chromium` uses the
 *      bundled build if /opt/google/chrome/chrome is not executable in your
 *      shell, which is the documented escape for `browserType.launch: spawn …
 *      EACCES` in sandboxed shells.
 *
 * That precondition is named here, in SPEC-REGISTRY.tsv, and in
 * docs/signalloom/slcd-p6-3-acceptance-spec.md, and those three must agree.
 * SLCD-P6-4 owns wiring it into a CI stage and a make target; this file owns
 * stating what such a lane would have to provide.
 *
 * Confusing this spec's precondition with a sibling slice's is the failure this
 * paragraph exists to prevent: an acceptance test that SKIPS on an unmet
 * readiness guard reads as a pass and proves nothing. There is no skip in this
 * file. If the harness cannot start, every test here fails and says so.
 *
 * ─── Why a harness rather than the demo cluster ────────────────────────────
 *
 * Six rendered states are in scope. Five are unreachable against the shared
 * estate without mutating it — empty, error, the 422 WITHHELD aggregate, an
 * `unknown` classification, and two tenants — and the sixth would not work
 * either, because `make demo-signalloom-up` deploys the PUBLISHED dashboard
 * image. SPEC-REGISTRY.tsv's row for agentmaxxing-demo-console.spec.ts records
 * that trap being measured on 2026-09-15: a served bundle carrying zero matches
 * for a page App.tsx registers in source. CodingAgentsTab is newer still.
 *
 * harness/coding-agents-server.ts carries the full argument.
 *
 * ─── What this proves that the existing tests do not ───────────────────────
 *
 * CodingAgentsTab.test.tsx replaces `api/client` with `vi.mock`, so it asserts
 * the component against a mock of its own data layer: no HTTP, no `/api`
 * prefixing, no Bearer header, no real CSS, no second tenant. P5-1 proves
 * tenant scoping at the API layer, which structurally cannot see a CLIENT-side
 * state-sharing bug.
 *
 * Here the client is the shipping one, the stylesheet is the app's own, and
 * the isolation assertion runs in two real browser contexts.
 *
 * ─── Assertion discipline ──────────────────────────────────────────────────
 *
 * Every assertion below reads a `data-testid`, a `data-*` attribute, an ARIA
 * role, or rendered text. NONE reads a computed style, a colour, a pixel
 * dimension or a screenshot. A card whose accent colour changes must not
 * redden this file; a card that stops rendering its task id must.
 *
 * Two consequences of that rule are worth stating because they look like
 * mistakes:
 *
 *   * `role` is asserted as the LOWER-CASE `implementation`. The card applies
 *     `text-transform: uppercase`, which is presentation only — `textContent`,
 *     which is what Playwright compares by default, still holds the original.
 *
 *   * `"12m 34s"` is a LITERAL, not `formatElapsed(754)`. Re-deriving the
 *     expectation with the component's own helper would make the assertion
 *     agree with any formatter, including a broken one. See the arithmetic in
 *     harness/coding-agents-fixtures.ts.
 */
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { join } from "node:path";
import type { Readable } from "node:stream";
import { test as base, expect, type APIRequestContext, type Page } from "@playwright/test";
import {
  ACME_CLAUDE,
  ACME_UNKNOWN,
  GLOBEX_CODEX,
  SERVED_AGGREGATE,
  TENANTS,
  cardTestId,
} from "./harness/coding-agents-fixtures";

// ───────────────────────────────────────────────────────────────────────────
// Selectors. Every one of these is a semantic hook the component declares.
// ───────────────────────────────────────────────────────────────────────────

const TAB = '[data-testid="coding-agents-tab"]';
const GRID = '[data-testid="coding-agents-grid"]';
const TENANT_BANNER = '[data-testid="harness-tenant"]';
const LOAD_STATE = '[data-testid="loading-state"], [data-testid="coding-agents-load-state"]';
const LOAD_REASON = '[data-testid="loading-state-reason"], [data-testid="coding-agents-load-state-reason"]';

/**
 * Card test ids are EXACT, never `^=`.
 *
 * CodingAgentCard builds its id from `session_id.slice(0, 8)`, and a
 * prefix-match selector over ids that share a stem also matches nested
 * elements whose ids extend it. The fixtures give each record a distinct
 * eight-character stem precisely so exact matching is possible here.
 */
const CLAUDE_CARD = `[data-testid="${cardTestId(ACME_CLAUDE)}"]`;
const UNKNOWN_CARD = `[data-testid="${cardTestId(ACME_UNKNOWN)}"]`;
const GLOBEX_CARD = `[data-testid="${cardTestId(GLOBEX_CODEX)}"]`;

// ───────────────────────────────────────────────────────────────────────────
// The harness process.
// ───────────────────────────────────────────────────────────────────────────

interface Harness {
  url: string;
  // `stdio: ["ignore", "pipe", "pipe"]` gives a child with no stdin, which is
  // ChildProcessByStdio<null, …> rather than ChildProcessWithoutNullStreams.
  child: ChildProcessByStdio<null, Readable, Readable>;
}

/**
 * Start `bun harness/coding-agents-server.ts` and wait until it says so.
 *
 * A PROCESS rather than an import: the Playwright runner is Node, and that file
 * is Bun-only (`Bun.serve`, `Bun.build`, `import.meta`). Importing it fails at
 * COLLECTION, which Playwright reports as "No tests found" — a green-looking
 * exit naming neither file. The header of harness/server.ts records the same
 * thing being hit for real one directory over.
 *
 * The path comes from the runner config's `rootDir` rather than `__dirname` or
 * `import.meta.url`, because which of those exists depends on how the runner
 * transpiled this file and rootDir is true either way.
 *
 * Port 0: the OS picks a free one and the server reports it. Every spec in this
 * suite that hard-coded a port eventually collided with a port-forward.
 */
async function launchHarness(rootDir: string): Promise<Harness> {
  const script = join(rootDir, "harness", "coding-agents-server.ts");
  const child = spawn("bun", [script, "--port", "0"], { stdio: ["ignore", "pipe", "pipe"] });

  const stderr: string[] = [];
  child.stderr.on("data", (buf: Buffer) => stderr.push(buf.toString()));

  const url = await new Promise<string>((resolve, reject) => {
    // The bundle of the real component tree is built before the ready line, so
    // a cold first run spends a few seconds here and then serves instantly.
    const timer = setTimeout(
      () =>
        reject(
          new Error(
            `coding-agents harness did not become ready in 90s. stderr:\n${stderr.join("")}`,
          ),
        ),
      90_000,
    );
    let out = "";
    child.stdout.on("data", (buf: Buffer) => {
      out += buf.toString();
      // Its OWN ready prefix, not the one harness/server.ts prints — matching
      // the wrong line would attach this spec to the wrong process.
      const found = out.match(/^CODING_AGENTS_HARNESS_READY (\S+)/m)?.[1];
      if (!found) return;
      clearTimeout(timer);
      resolve(found);
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(
        new Error(
          `coding-agents harness exited with ${code} before it was ready. stderr:\n${stderr.join("")}`,
        ),
      );
    });
  });

  return { url, child };
}

/**
 * One harness per WORKER, not per test.
 *
 * The expensive part is `Bun.build` over the real component tree, and it is
 * cached per process — so a per-test harness would pay it once per test. The
 * state that makes tests independent is not the process, it is the store
 * inside it, and `beforeEach` clears that. `resetHarness` also asserts the
 * clear took effect, so a control plane that silently stopped resetting fails
 * as itself rather than as a mysterious extra card in the next test.
 */
const test = base.extend<Record<string, never>, { harness: Harness }>({
  harness: [
    async ({}, use, workerInfo) => {
      const harness = await launchHarness(workerInfo.config.rootDir);
      await use(harness);
      harness.child.kill("SIGTERM");
    },
    { scope: "worker" },
  ],
});

// Serial, and the reason is state rather than resources: every test in this
// file drives the same harness store. `workers: 1` is already set estate-wide,
// so this costs nothing and documents the dependency.
test.describe.configure({ mode: "serial" });

// ───────────────────────────────────────────────────────────────────────────
// Control-plane helpers.
// ───────────────────────────────────────────────────────────────────────────

interface SeedOptions {
  records?: unknown[];
  aggregate?: unknown | null;
  listStatus?: number;
}

async function seed(
  request: APIRequestContext,
  harness: Harness,
  tenant: string,
  options: SeedOptions,
): Promise<void> {
  const res = await request.post(`${harness.url}/harness/state`, {
    data: {
      tenant,
      records: options.records ?? [],
      aggregate: options.aggregate ?? null,
      listStatus: options.listStatus ?? 200,
    },
  });
  expect(res.status(), "harness refused a seed").toBe(200);
}

/**
 * Clear every tenant, AND prove the clear happened.
 *
 * Fixture cleanup that is not verified is the documented failure mode for this
 * card: a second run sees a growing set of stale cards, and either the suite
 * goes flaky or its count assertions quietly stop meaning anything. Asserting
 * the post-reset state is empty makes "cleanup regressed" a red test in the
 * NEXT `beforeEach` rather than a confusing assertion failure three tests
 * later.
 */
async function resetHarness(request: APIRequestContext, harness: Harness): Promise<void> {
  const res = await request.post(`${harness.url}/harness/reset`);
  expect(res.status(), "harness refused a reset").toBe(200);
  const after = await (await request.get(`${harness.url}/harness/state`)).json();
  expect(after, "reset left tenant state behind — repeated runs would accumulate").toEqual({});
}

interface RequestLog {
  total: number;
  list: number;
  aggregate: number;
  byTenant: Record<string, number>;
  unmatched: string[];
}

async function requestLog(request: APIRequestContext, harness: Harness): Promise<RequestLog> {
  return (await request.get(`${harness.url}/harness/requests`)).json();
}

/** Open the tab as a given tenant. The tenant travels in the URL and ends up in the Bearer header. */
async function openAs(page: Page, harness: Harness, tenant: string): Promise<void> {
  await page.goto(`${harness.url}/?tenant=${encodeURIComponent(tenant)}`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.locator(TAB)).toBeVisible({ timeout: 20_000 });
  // The identity actually in play, in the DOM. Without it, a cross-tenant leak
  // and a harness pointed at the wrong tenant look identical in a failure.
  await expect(page.locator(TENANT_BANNER)).toHaveAttribute("data-tenant", tenant);
}

test.beforeEach(async ({ request, harness }) => {
  await resetHarness(request, harness);
});

// ───────────────────────────────────────────────────────────────────────────
// 1. The spec is not testing demo fixtures.
// ───────────────────────────────────────────────────────────────────────────

test("the tab reaches the harness over real HTTP, not api/fakeData.ts fixtures", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE],
    aggregate: SERVED_AGGREGATE,
  });
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(CLAUDE_CARD)).toBeVisible({ timeout: 20_000 });

  const log = await requestLog(request, harness);

  // This is the assertion that keeps every other one in this file honest.
  //
  // api/fakeData.ts:927-928 registers fake routes for BOTH telemetry paths. If
  // demo mode were on in the harness bundle, `req()` would short-circuit to
  // those fixtures and issue NO HTTP request at all — and because the fixtures
  // are populated and plausible, the card assertions below would still pass.
  // The suite would be green and would be proving nothing about the wire.
  //
  // Demo mode is off because one string in one `define` says `development`
  // rather than `demo`. A regression there is silent everywhere except here.
  expect(log.list, "no list request reached the harness — the bundle is serving demo fixtures").toBeGreaterThan(0);
  expect(log.aggregate, "no aggregate request reached the harness").toBeGreaterThan(0);
  expect(log.byTenant[TENANTS.a], "the harness saw no request carrying this tenant's token").toBeGreaterThan(0);

  // A path the client asked for that no route answered is contract drift —
  // api/client.ts prefixes `/api`, and a change on either side shows up here.
  expect(log.unmatched, "the tab requested a path the harness does not serve").toEqual([]);
});

// ───────────────────────────────────────────────────────────────────────────
// 2. Detection rendering + exact fixture-to-DOM session metadata.
// ───────────────────────────────────────────────────────────────────────────

test("a detected agent renders a card whose session metadata matches the seeded record exactly", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE],
    aggregate: SERVED_AGGREGATE,
  });
  await openAs(page, harness, TENANTS.a);

  await expect(page.locator(GRID)).toBeVisible({ timeout: 20_000 });
  await expect(page.locator(`${GRID} > *`)).toHaveCount(1);

  const card = page.locator(CLAUDE_CARD);
  await expect(card).toBeVisible();

  // ── Identity ──
  //
  // Asserted field by field rather than as one blob. A card that swapped
  // task_id and shortcode would pass a single "contains both strings" check
  // and fail here, which is the point: the documented failure mode for this
  // card is a silent API-to-DOM mapping swap that a presence assertion cannot
  // see.
  await expect(card).toContainText("Kanban Task:");
  await expect(card).toContainText(ACME_CLAUDE.event.kanban.task_id); // SLCD-P6-3
  await expect(card).toContainText(`#${ACME_CLAUDE.event.kanban.shortcode}`); // #4d5c9
  // Lower case: `text-transform: uppercase` is presentation, and Playwright
  // compares `textContent`.
  await expect(card).toContainText(ACME_CLAUDE.event.kanban.role); // implementation

  // ── Elapsed, as a literal ──
  //
  // 754 seconds. NOT formatElapsed(754) — see this file's header.
  await expect(card).toContainText("Elapsed: 12m 34s");
  await expect(card).toContainText(`Step: ${ACME_CLAUDE.event.metrics.step_count}`); // 21

  // ── Process attribution ──
  await expect(card).toContainText(
    `comm: ${ACME_CLAUDE.event.process.comm} (PID: ${ACME_CLAUDE.event.process.pid})`,
  );
  await expect(card).toContainText(ACME_CLAUDE.event.host_id!);

  // ── Network egress. 45000 / 1024 = 43.9 KB, and no locale is involved. ──
  await expect(card).toContainText(ACME_CLAUDE.event.network.inference_endpoint);
  await expect(card).toContainText("43.9 KB egress");

  // ── Tool histogram ──
  //
  // Every NON-ZERO entry, and the header total. 9 + 4 + 2 = 15; the fixture's
  // other eleven entries are zero and must NOT appear, because the card
  // filters them out and a chip for a zero count would mean that filter broke.
  await expect(card).toContainText("Tool Invocation Histogram (15 calls)");
  await expect(card).toContainText("view_file:9");
  await expect(card).toContainText("run_command:4");
  await expect(card).toContainText("grep_search:2");
  await expect(card).not.toContainText("write_to_file:");
  await expect(card).not.toContainText("search_web:");

  // ── The Zero-Customer-Payload invariant, asserted in the UI that claims it ──
  await expect(card.locator('[data-testid="zero-payload-chip"]')).toContainText(
    "Zero Customer Payload",
  );

  // ── Toolbar count. Derived from the SAME records, so it must agree. ──
  await expect(page.locator(TAB)).toContainText("Showing 1 of 1 detected agents");
});

// ───────────────────────────────────────────────────────────────────────────
// 3. Harness classification — verified vs unknown.
// ───────────────────────────────────────────────────────────────────────────

test("a known harness and an unclassified one render as distinct, semantically labelled cards", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE, ACME_UNKNOWN],
    aggregate: SERVED_AGGREGATE,
  });
  await openAs(page, harness, TENANTS.a);

  await expect(page.locator(GRID)).toBeVisible({ timeout: 20_000 });
  await expect(page.locator(`${GRID} > *`)).toHaveCount(2);

  // The classification is carried by `data-harness`, which is the attribute
  // the card publishes for exactly this purpose. Asserting the accent colour
  // instead would redden on a palette change and stay green on a
  // misclassification — the wrong way round.
  await expect(page.locator(CLAUDE_CARD)).toHaveAttribute("data-harness", "claude");
  await expect(page.locator(UNKNOWN_CARD)).toHaveAttribute("data-harness", "unknown");

  // And the label a human reads agrees with the attribute a machine reads.
  await expect(page.locator(UNKNOWN_CARD)).toContainText("unknown");
  await expect(page.locator(UNKNOWN_CARD)).toContainText("UNATTRIBUTED");

  // An unattributed process has no inference endpoint. The card renders the
  // word `none` rather than an empty gap, and 0 bytes rather than "NaN B".
  await expect(page.locator(UNKNOWN_CARD)).toContainText("none");
  await expect(page.locator(UNKNOWN_CARD)).toContainText("0 B egress");

  // The two really are different cards with different classifications — a
  // component that rendered one harness for every record would pass both
  // attribute assertions above if it happened to render `claude` twice and the
  // second card were simply missing. The count assertion above plus this
  // inequality closes that.
  const harnesses = await page.locator(`${GRID} > [data-harness]`).evaluateAll((els) =>
    els.map((el) => el.getAttribute("data-harness")),
  );
  expect(harnesses.slice().sort()).toEqual(["claude", "unknown"]);

  // The harness filter counts them separately, which is the same fact read
  // through a different code path.
  await expect(page.locator(TAB)).toContainText("Showing 2 of 2 detected agents");
});

// ───────────────────────────────────────────────────────────────────────────
// 4. The k-anonymity aggregate: served vs WITHHELD.
// ───────────────────────────────────────────────────────────────────────────

test("the anonymity cohort is reported when the server computes it and withheld when it refuses", async ({
  page,
  request,
  harness,
}) => {
  const cohort = () => page.locator(".card").filter({ hasText: "Anonymity Cohort" });

  // ── Served ──
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE, ACME_UNKNOWN],
    aggregate: SERVED_AGGREGATE,
  });
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(GRID)).toBeVisible({ timeout: 20_000 });
  await expect(cohort()).toContainText("5 entities");
  await expect(cohort()).toContainText("avg skew 17.5ms");

  // ── Refused (HTTP 422, cohort under the k=5 floor) ──
  //
  // A FRESH page load, not a reseed of the open one. `fetchTelemetry` uses
  // Promise.allSettled and only calls setAggregate on the fulfilled branch, so
  // a later refusal leaves the previously-served figure on screen. That is the
  // component's real behaviour; testing the withheld path therefore has to
  // start from a mount that never saw an aggregate.
  await resetHarness(request, harness);
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE, ACME_UNKNOWN],
    aggregate: null,
  });
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(GRID)).toBeVisible({ timeout: 20_000 });

  await expect(cohort()).toContainText("Withheld");
  await expect(cohort()).toContainText("below k=5 anonymity floor");

  // The regression P5-GOV fixed, asserted as an absence with teeth.
  //
  // The card used to fall back to `${stats.totalSessions} sessions` — a
  // client-side count of the rows already in hand — under a heading asserting
  // k-anonymity. Two records are seeded, so a reintroduced fallback would read
  // "2 sessions": the UI answering the exact question the 422 exists to refuse.
  await expect(cohort()).not.toContainText("2 sessions");
  await expect(cohort()).not.toContainText("2 entities");

  // And the cards themselves are unaffected — the refusal is about the
  // aggregate, not about the listing.
  await expect(page.locator(`${GRID} > *`)).toHaveCount(2);
});

// ───────────────────────────────────────────────────────────────────────────
// 5. Empty state.
// ───────────────────────────────────────────────────────────────────────────

test("a tenant with no telemetry renders the empty state, not an empty grid", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, { records: [], aggregate: null });
  await openAs(page, harness, TENANTS.a);

  // The kicker and the unfiltered body. The component has TWO empty bodies —
  // one for "nothing reported" and one for "nothing matches your filter" — and
  // asserting the kicker alone would not tell them apart. No filter is set
  // here, so the unfiltered copy is the correct one.
  await expect(page.locator(TAB)).toContainText("No coding agents found", { timeout: 20_000 });
  await expect(page.locator(TAB)).toContainText(
    "No external workstation coding agents are currently reporting telemetry",
  );

  // "Loaded and found nothing" is not "an empty table". The grid element must
  // be absent, not present-and-childless — LoadingState.tsx's own header calls
  // conflating those two the bug it exists to prevent.
  await expect(page.locator(GRID)).toHaveCount(0);
  await expect(page.locator(TAB)).toContainText("Showing 0 of 0 detected agents");

  // Empty is not an error: no alert, and the cohort is withheld rather than
  // reading zero.
  await expect(page.locator(`${LOAD_STATE}[data-status="error"]`)).toHaveCount(0);
  await expect(page.locator(".card").filter({ hasText: "Anonymity Cohort" })).toContainText(
    "Withheld",
  );
});

// ───────────────────────────────────────────────────────────────────────────
// 6. Error state.
// ───────────────────────────────────────────────────────────────────────────

test("a failing telemetry call renders the error state, and Retry does not fabricate success", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE],
    aggregate: SERVED_AGGREGATE,
    listStatus: 500,
  });
  await openAs(page, harness, TENANTS.a);

  const alert = page.locator(`${LOAD_STATE}[data-status="error"]`);
  await expect(alert).toBeVisible({ timeout: 20_000 });
  // role=alert, not aria-live: LoadingState.tsx sets one or the other and never
  // both, because some screen readers announce an assertive live region twice.
  await expect(alert).toHaveAttribute("role", "alert");

  // The reason is shown VERBATIM and never replaced with a generic string —
  // LoadingState's contract. axios reports the status in its message, so the
  // seeded 500 has to be readable in the DOM.
  await expect(page.locator(LOAD_REASON)).toContainText("500");

  // An error is not an empty state and not a stale grid.
  await expect(page.locator(GRID)).toHaveCount(0);
  await expect(page.locator(TAB)).not.toContainText("No coding agents found");

  // ── Retry, while still broken ──
  //
  // The negative half, and the one that makes the positive half mean
  // something: a Retry that optimistically cleared the error would turn this
  // green with no data behind it.
  const before = (await requestLog(request, harness)).list;
  await page.getByRole("button", { name: "Retry" }).click();
  await expect
    .poll(async () => (await requestLog(request, harness)).list, { timeout: 15_000 })
    .toBeGreaterThan(before);
  await expect(alert).toBeVisible();
  await expect(page.locator(GRID)).toHaveCount(0);

  // ── Heal ──
  //
  // Recovery is asserted, not its trigger. Both the Retry click and the
  // component's own 2500ms poll can drive it, and this spec deliberately does
  // not claim to isolate which — an assertion that tried would be a race
  // against LIVE_POLL_MS. What matters here is that a transient backend
  // failure does not leave the tab permanently stuck on an error.
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE],
    aggregate: SERVED_AGGREGATE,
    listStatus: 200,
  });
  await page.getByRole("button", { name: "Retry" }).click();
  await expect(page.locator(CLAUDE_CARD)).toBeVisible({ timeout: 20_000 });
  await expect(page.locator(`${LOAD_STATE}[data-status="error"]`)).toHaveCount(0);
});

// ───────────────────────────────────────────────────────────────────────────
// 7. Cross-tenant isolation, in the rendered DOM.
// ───────────────────────────────────────────────────────────────────────────

test("neither tenant's browser ever renders the other tenant's coding-agent card", async ({
  request,
  harness,
  browser,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE, ACME_UNKNOWN],
    aggregate: SERVED_AGGREGATE,
  });
  await seed(request, harness, TENANTS.b, {
    records: [GLOBEX_CODEX],
    aggregate: SERVED_AGGREGATE,
  });

  // Two CONTEXTS, not two tabs and not two navigations in one page.
  //
  // P5-1 already proves the API scopes by tenant, and an API-layer test
  // structurally cannot see the bug this one is for: client-side state that
  // outlives an identity — a module-scope cache, a shared localStorage key, a
  // `records` array surviving a re-mount. Separate contexts give separate
  // storage and separate JS realms, so anything that leaks between them is
  // leaking for a reason worth knowing about.
  const ctxA = await browser.newContext();
  const ctxB = await browser.newContext();
  try {
    const pageA = await ctxA.newPage();
    const pageB = await ctxB.newPage();

    await openAs(pageA, harness, TENANTS.a);
    await openAs(pageB, harness, TENANTS.b);

    // ── Presence first. ──
    //
    // The absence assertions below are worth nothing on their own: a page that
    // rendered NOTHING would satisfy every one of them. Each tenant must be
    // shown to render its own cards before it is asked not to render the
    // other's.
    await expect(pageA.locator(CLAUDE_CARD)).toBeVisible({ timeout: 20_000 });
    await expect(pageA.locator(UNKNOWN_CARD)).toBeVisible();
    await expect(pageA.locator(`${GRID} > *`)).toHaveCount(2);

    await expect(pageB.locator(GLOBEX_CARD)).toBeVisible({ timeout: 20_000 });
    await expect(pageB.locator(`${GRID} > *`)).toHaveCount(1);

    // ── Then absence. ──
    await expect(pageA.locator(GLOBEX_CARD)).toHaveCount(0);
    await expect(pageB.locator(CLAUDE_CARD)).toHaveCount(0);
    await expect(pageB.locator(UNKNOWN_CARD)).toHaveCount(0);

    // ── And absence from the whole document, not just from the grid. ──
    //
    // A card test id can only be missing if the card did not render. These
    // strings can leak through any surface — a filter dropdown's counts, a
    // stat card's rollup, a hidden detail pane — so they are checked against
    // the serialised DOM rather than against a locator.
    const domA = await pageA.content();
    expect(domA, "tenant A's DOM carries tenant B's host").not.toContain(
      GLOBEX_CODEX.event.host_id!,
    );
    expect(domA, "tenant A's DOM carries tenant B's task").not.toContain(
      GLOBEX_CODEX.event.kanban.task_id,
    );
    expect(domA).not.toContain(GLOBEX_CODEX.event.session_id.slice(0, 8));

    const domB = await pageB.content();
    expect(domB, "tenant B's DOM carries tenant A's host").not.toContain(
      ACME_CLAUDE.event.host_id!,
    );
    expect(domB, "tenant B's DOM carries tenant A's task").not.toContain(
      ACME_CLAUDE.event.kanban.task_id,
    );
    expect(domB).not.toContain(ACME_CLAUDE.event.session_id.slice(0, 8));

    // ── The harness really was asked twice, once per identity. ──
    //
    // Without this, a run in which tenant B's page never issued a request
    // would satisfy every absence assertion above and look like isolation.
    const log = await requestLog(request, harness);
    expect(log.byTenant[TENANTS.a]).toBeGreaterThan(0);
    expect(log.byTenant[TENANTS.b]).toBeGreaterThan(0);
  } finally {
    await ctxA.close();
    await ctxB.close();
  }
});

// ───────────────────────────────────────────────────────────────────────────
// 8. Fixture cleanup.
// ───────────────────────────────────────────────────────────────────────────

test("harness state does not survive a reset, so repeated runs cannot accumulate cards", async ({
  page,
  request,
  harness,
}) => {
  await seed(request, harness, TENANTS.a, {
    records: [ACME_CLAUDE, ACME_UNKNOWN],
    aggregate: SERVED_AGGREGATE,
  });
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(`${GRID} > *`)).toHaveCount(2, { timeout: 20_000 });

  // `resetHarness` asserts the store is `{}` afterwards. Re-opening proves the
  // same thing from the browser's side: the rendered consequence of the reset,
  // not just the control plane's report of it.
  await resetHarness(request, harness);
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(TAB)).toContainText("No coding agents found", { timeout: 20_000 });
  await expect(page.locator(GRID)).toHaveCount(0);

  // Seeding twice with the SAME records is idempotent — the control plane
  // REPLACES a tenant's records rather than appending. An append would be
  // invisible in a single run and would make the count assertions above
  // meaningless on the second, which is precisely the accumulation failure
  // this test exists to rule out.
  await seed(request, harness, TENANTS.a, { records: [ACME_CLAUDE], aggregate: null });
  await seed(request, harness, TENANTS.a, { records: [ACME_CLAUDE], aggregate: null });
  await openAs(page, harness, TENANTS.a);
  await expect(page.locator(`${GRID} > *`)).toHaveCount(1, { timeout: 20_000 });
});
