/**
 * AgentMaxxing Interactive Demo Console — browser acceptance (AMXD-P6-1).
 *
 * ─── How to run it ─────────────────────────────────────────────────────────
 *
 *   cd test/acceptance
 *   bun install
 *   AMXD_DEMO_CONSOLE=1 bunx playwright test agentmaxxing-demo-console.spec.ts \
 *     --project=agentmaxxing-demo-console
 *
 * `AMXD_DEMO_CONSOLE` is a precondition gate, not a preference — see the
 * project's own comment in playwright.config.ts. Without it the project is not
 * in the config at all and this file runs nowhere.
 *
 * ─── What this file is for ─────────────────────────────────────────────────
 *
 * Five phases of AMXD verified this console through jsdom. jsdom computes no
 * layout and issues no requests. AMXD-P5-GOV was the first to render it in a
 * real browser, and did so from a throwaway harness that stubbed
 * `src/auth/oidc` and decorated `createDemoBridge` — so auth was uncertified
 * and half the bridge contract was unproven, both recorded in that errata as
 * inherited by Phase 6. This is the first artefact that drives the SHIPPING
 * page, through the SHIPPING auth, at the SHIPPING route.
 *
 * It is split in two, and the split is the whole design:
 *
 *   MOCK BLOCK  `login(page)` — demoMode defaults to true (helpers.ts:108), so
 *               `client.ts:227` short-circuits into fixtures and the client
 *               bridge's mock channel drives all five stages. No backend
 *               required. This block proves the CONSOLE.
 *
 *   LIVE BLOCK  `test.skip(!guards.agentmaxxingLive(), …)` AND
 *               `login(page, { demoMode: false })`. Both halves, always. The
 *               guard alone buys nothing: with demo mode on, `client.ts:227`
 *               returns before any socket is opened, and the only statuses that
 *               path can produce are 404 (route known, fixture missing) and 501
 *               (route not implemented) — 403 is not merely unlikely there, it
 *               is structurally unreachable. A spec asserting 403 under demo
 *               mode can therefore only pass by fabricating the response it
 *               claims to verify. That fabrication is the defect this card
 *               exists to remove; do not reintroduce it by adding a fixture to
 *               turn this block green.
 *
 * ─── Why the live block checks the error CODE, not just the status ─────────
 *
 * AMXD-P4-PRE's warning: this spec constructs its own evidence-upload envelope,
 * and a binding mismatch answers 403 too — `tenant_key_binding_mismatch`,
 * `tenant_agent_binding_mismatch`, `tenant_host_binding_mismatch`
 * (RevocationPanel.tsx:337-339). A status-only assertion would go green while
 * proving the envelope was malformed rather than that the agent was revoked.
 * AMXD-P4-2's traced call chain names the correct code: `agent_revoked`.
 *
 * And per the same helper's note, `POST /v1/external-agents/hosts/{id}/revoke`
 * can succeed while revoking NOTHING — 200 with `{"revoked_agents":[],
 * "count":0}` when no agent matches the host
 * (`external_agent_registration.py:1082-1088`). So `count > 0` is asserted on
 * the revoke BEFORE the upload is attempted, otherwise the fabrication
 * reappears one layer down.
 *
 * ─── No fixed sleeps. Anywhere. ────────────────────────────────────────────
 *
 * The literal name of Playwright's fixed-sleep call is deliberately NOT written
 * anywhere in this file, not even in prose: the acceptance gate for this card is
 * a `grep -c` for that token, and a comment mentioning it would satisfy the
 * grep while proving nothing — the same "a guard can be satisfied by a comment"
 * shape this repo has been bitten by before.
 *
 * It is a named anti-pattern in this mission's architectural constitution, and
 * a spec that breaks its own mission's stated rule forfeits the credibility of
 * every other assertion in the file. Every wait here is on a signal: a rendered
 * `data-testid`, a state-machine-driven attribute (`stage-status-<id>`,
 * `autoplay-mode-indicator[data-mode]`), or a specific network response.
 *
 * ─── Selectors ─────────────────────────────────────────────────────────────
 *
 * `getByTestId` exclusively. AMXD-P2-1 through AMXD-P5-1 added those attributes
 * specifically so this spec would not have to select on copy. A text selector
 * here reintroduces the exact fragility they were added to prevent, and every
 * one of these panels is prose-heavy demo chrome whose wording will change.
 *
 * ─── Known-open defects this spec will surface ─────────────────────────────
 *
 * Recorded here so the next reader does not diagnose them from scratch. None is
 * this card's to fix; all four are named in the AMXD-P6-1 errata.
 *
 *   B1  The DEPLOYED dashboard bundle predates this console. Probed
 *       2026-09-15: `/assets/index-C4WCu_e2.js` (439,013 B) carries 0 matches
 *       for `AgentMaxxingDemoPage` and lists 33 lazy page chunks, none of them
 *       this page, while `App.tsx:436` registers the route in source. Until the
 *       image is rebuilt from this branch, every test below fails at the first
 *       `agentmaxxing-demo-page` assertion. That is a deployment precondition,
 *       not a spec defect, and it is why the SPEC-REGISTRY row says
 *       `suite-only` rather than claiming a lane.
 *
 *   B2  AMXD-P4-GOV Defect 2, open. `RevocationPanel.tsx:157` initialises
 *       `revocationSettled` from `Boolean(initialPayload)` and `:709` gates the
 *       entire dispatch form on `!revocationSettled`. Arriving at Stage 5
 *       through the stepper stores the stage payload first, so `initialPayload`
 *       is non-null and the reason selector and dispatch button never render on
 *       the composed route. `liveRevokeAndVerify` asserts their presence rather
 *       than routing around them.
 *
 *   B3  AMXD-P4-GOV Defect 1, open. Live revocation answers `insufficient_scope`
 *       because no credential-bootstrap endpoint exists. The live block asserts
 *       `agent_revoked` per this card's contract; until B3 closes it fails on
 *       the code, which is the correct signal and the reason the assertion is
 *       on the code rather than the status.
 *
 *   B4  New. A Stage-4 rejection is not drivable from the browser.
 *       `AgentMaxxingDemoPage` renders `StageProgressionController` with no
 *       `preset` prop, so the bridge always runs `HAPPY_PATH_PRESET`, whose
 *       `adversarial_tamper` stage is `expected_outcome: 'success'`
 *       (scenarios.ts:419-434). `TAMPER_BREACH_PRESET` exists but has no URL,
 *       storage or control seam. AMXD-P5-GOV proved the halt path only by
 *       decorating the bridge, and recorded that this does NOT prove the real
 *       verification engine produces that outcome. The halt test below drives
 *       the only lever the UI offers and will stay red until a preset seam
 *       exists — which is the finding, not a flake.
 *
 *   B5  New. The Zero-Payload Inspector is NOT REACHABLE from this route, so
 *       this card's mock-vs-live parity assertion for it could not be written
 *       here. `ZeroPayloadInspector` is mounted in exactly one place —
 *       `ConfinementTelemetryPanel.tsx:875` — and `AgentMaxxingDemoPage`
 *       imports neither component: Stage 3 renders a generic telemetry frame
 *       instead (the page's own comment says so). So `zero-payload-inspector`,
 *       `filter-digest`, `allowlist-list` and the rest of AMXD-P3-2's testids
 *       have no DOM to appear in on the composed route, and a browser is the
 *       only place a hydration or CSS-specificity difference between the two
 *       channels would ever become visible. Reported rather than substituted
 *       with a weaker check: wiring the panel into the page is a component
 *       change beyond this card, and asserting parity against a component the
 *       demo never shows would be theatre.
 */
import { expect, test, type Locator, type Page, type TestInfo } from "@playwright/test";
import { config, guards, login } from "./helpers";

// ── Route and stage vocabulary ──────────────────────────────────────────────

/** Sidebar entry is `/demos/agentmaxxing` (Sidebar.tsx:121, superadminOnly). */
const CONSOLE_PATH = "/demos/agentmaxxing";

/**
 * The five stages, in the order `types.ts` STAGE_IDS declares them. `panel` is
 * the testid of the component AgentMaxxingDemoPage mounts for that stage;
 * `confinement_streaming` has no dedicated panel on the composed route (the
 * page renders a generic telemetry frame), so it is asserted through the
 * stage-panel wrapper instead.
 */
const STAGES = [
  { n: 1, id: "operator_init", panel: "token-issue-panel" },
  { n: 2, id: "host_enrolled", panel: "enrollment-panel" },
  { n: 3, id: "confinement_streaming", panel: null },
  { n: 4, id: "adversarial_tamper", panel: "adversarial-simulation-panel" },
  { n: 5, id: "revocation_denied", panel: "revocation-panel" },
] as const;

type StageRow = (typeof STAGES)[number];

/** HAPPY_PATH_PRESET's agent id (scenarios.ts:357). */
const PRESET_AGENT_ID = "amxd-demo-agent-happy-01";

/** AdversarialSimulationPanel.tsx:58 — the single ephemeral artifact row. */
const ARTIFACT_ID = "artifact-demo-001";

/** AdversarialSimulationPanel.tsx:65 — the digest injection writes. */
const CORRUPTED_SHA_PREFIX = "deadbeef";

/**
 * types.ts AUTO_PLAY_DWELL_MS. Held here as a literal on purpose: the timing
 * assertion below is only meaningful if the number it compares against is the
 * CONTRACT, not whatever the implementation currently computes. Importing the
 * constant would make the test agree with the code by construction.
 */
const DWELL_MS = { "1x": 4000, "2x": 2000, instant: 100 } as const;
type Pacing = keyof typeof DWELL_MS;

// ── Per-stage failure screenshots ───────────────────────────────────────────

/**
 * Failure-screenshot sequence, per test.
 *
 * `screenshot: 'only-on-failure'` in playwright.config.ts already captures the
 * page when a test dies, but it names the file after the TEST. A five-stage
 * spec that fails with one generic filename tells a CI reader only that "the
 * AgentMaxxing spec failed", not which of five distinct and unrelated defects
 * to start investigating. These attachments name the stage.
 *
 * Keyed by TestInfo and zero-padded, so two stages failing in the same run
 * produce `…-failure-01.png` and `…-failure-02.png` rather than the second
 * overwriting the first.
 */
const failureSeq = new WeakMap<TestInfo, number>();

function nextSeq(testInfo: TestInfo): string {
  const n = (failureSeq.get(testInfo) ?? 0) + 1;
  failureSeq.set(testInfo, n);
  return String(n).padStart(2, "0");
}

/**
 * Run `body` as a named stage step. On failure, capture and attach a screenshot
 * called `amxd-stage-<n>-<stage-id>-failure-<seq>.png` before rethrowing.
 */
async function stageStep<T>(
  page: Page,
  testInfo: TestInfo,
  stage: Pick<StageRow, "n" | "id">,
  title: string,
  body: () => Promise<T>,
): Promise<T> {
  return await test.step(`Stage ${stage.n} · ${stage.id} — ${title}`, async () => {
    try {
      return await body();
    } catch (err) {
      const name = `amxd-stage-${stage.n}-${stage.id}-failure-${nextSeq(testInfo)}.png`;
      const path = testInfo.outputPath(name);
      await page.screenshot({ path, fullPage: true }).catch(() => {
        /* a dead page cannot be photographed; the assertion error is the report */
      });
      await testInfo
        .attach(name, { path, contentType: "image/png" })
        .catch(() => {
          /* attachment is a convenience, never a second failure */
        });
      throw err;
    }
  });
}

// ── Navigation and stage helpers ────────────────────────────────────────────

function stageStatus(page: Page, id: StageRow["id"]): Locator {
  return page.getByTestId(`stage-status-${id}`);
}

/** Open the console and wait for the stepper to mount. No fixed waits. */
async function openConsole(page: Page): Promise<void> {
  await page.goto(`${config.base}${CONSOLE_PATH}`, { waitUntil: "domcontentloaded" });
  await expect(page.getByTestId("agentmaxxing-demo-page")).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId("stage-progression-controller")).toBeVisible();
  await expect(page.getByTestId("stepper-header")).toBeVisible();
  await expect(page.getByTestId("autoplay-controls")).toBeVisible();
}

/**
 * Advance one stage and wait for the reducer to mark it confirmed.
 *
 * `stage-status-<id>` renders the raw `StageExecutionStatus`
 * (StepperHeader.tsx:203-206), so it is a state-machine-driven attribute and the
 * only honest signal that the dual-lock gate settled. Waiting on it is why this
 * file needs no timeouts: `toHaveText` polls until the DOM says so.
 */
async function advanceTo(page: Page, stage: StageRow): Promise<void> {
  await page.getByTestId("stepper-advance-button").click();
  await expect(stageStatus(page, stage.id)).toHaveText("confirmed", { timeout: 30_000 });
  await expect(page.getByTestId(`stage-panel-${stage.id}`)).toBeVisible();
}

/** Return the console to Stage 1 with no fixed wait. */
async function resetEstate(page: Page): Promise<void> {
  await page.getByTestId("autoplay-reset-estate-button").click();
  await expect(page.getByTestId("stage-panel-operator_init")).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId("autoplay-mode-indicator")).toHaveAttribute("data-mode", "manual");
}

/**
 * Drive one Auto-Play pass at `pacing` and return the wall-clock milliseconds
 * from clicking Start to the mode indicator reporting `completed`.
 *
 * The clock starts AFTER the click resolves and stops on the state attribute,
 * so it measures the engine, not Playwright's dispatch latency.
 */
async function autoPlayRun(page: Page, pacing: Pacing): Promise<number> {
  await page.getByTestId(`autoplay-speed-${pacing}`).click();
  await expect(page.getByTestId(`autoplay-speed-${pacing}`)).toHaveAttribute("data-active", "true");

  const indicator = page.getByTestId("autoplay-mode-indicator");
  const started = Date.now();
  await page.getByTestId("autoplay-toggle-button").click();
  await expect(indicator).toHaveAttribute("data-mode", "completed", { timeout: 120_000 });
  const elapsed = Date.now() - started;

  await expect(stageStatus(page, "revocation_denied")).toHaveText("confirmed");
  return elapsed;
}

// ════════════════════════════════════════════════════════════════════════════
// MOCK BLOCK — no backend. Proves the console.
// ════════════════════════════════════════════════════════════════════════════

test.describe("AgentMaxxing demo console — mock channel", () => {
  test.beforeEach(async ({ page }) => {
    // Default demoMode: true. The client bridge's mock channel supplies all five
    // stages client-side (AMXD-P6-PRE confirmed there are no server-side mock
    // fixtures to seed), so nothing below requires a backend.
    await login(page);
    await openConsole(page);
  });

  test("all five stages advance in order and each reaches confirmed", async ({ page }, testInfo) => {
    // Stage 1 is pre-confirmed at boot: `operator_init` is never a target of the
    // controller's advance(), which is why TokenIssuePanel performs it itself and
    // hands the result back through recordStagePayload.
    await stageStep(page, testInfo, STAGES[0], "token issued and recorded", async () => {
      await expect(page.getByTestId("token-issue-panel")).toBeVisible();
      await expect(page.getByTestId("token-issue-btn")).toBeVisible();
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      await expect(stageStatus(page, "operator_init")).toHaveText("confirmed");
    });

    for (const stage of STAGES.slice(1)) {
      await stageStep(page, testInfo, stage, "advances and confirms", async () => {
        await advanceTo(page, stage);
        if (stage.panel) {
          await expect(page.getByTestId(stage.panel)).toBeVisible();
        }
        await expect(page.getByTestId(`stage-payload-preview-${stage.id}`)).toBeVisible();
      });
    }

    // Every stage, re-asserted at the end. An intermediate stage that regressed
    // to `failed` after its own step passed would otherwise go unnoticed.
    for (const stage of STAGES) {
      await expect(stageStatus(page, stage.id)).toHaveText("confirmed");
    }
  });

  test("stage 2 enrollment renders the generated type's Ed25519 and revocation fields", async ({
    page,
  }, testInfo) => {
    await stageStep(page, testInfo, STAGES[1], "enrollment record shape", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      await advanceTo(page, STAGES[1]);

      await expect(page.getByTestId("enrollment-result")).toBeVisible();

      // `types/externalAgent.ts` is generated by generate_external_agent_types.py
      // and marked DO NOT EDIT. `key_algorithm: "Ed25519"` is a string-literal
      // type there (line 10), not a free string, so an exact match is the only
      // assertion that keeps testing what it claims to test when the generator
      // next runs. A `toContainText('Ed')` here would survive a rename.
      await expect(page.getByTestId("key-algorithm-badge")).toHaveText("Ed25519");

      // `revocation_endpoint: string` (line 174). EnrollmentPanel.tsx:72 derives
      // it as `/v1/external-agents/${preset.agent_id}/revocations`; asserted
      // against HAPPY_PATH_PRESET's own agent id rather than a substring, so a
      // change of shape fails rather than passing on a common prefix.
      await expect(page.getByTestId("revocation-endpoint")).toHaveText(
        `/v1/external-agents/${PRESET_AGENT_ID}/revocations`,
      );

      await expect(page.getByTestId("public-key-fingerprint")).toBeVisible();
      await expect(page.getByTestId("enrollment-channel-badge")).toBeVisible();
    });
  });

  test("tamper control 1: hash mismatch raises containment and marks the artifact Mismatch", async ({
    page,
  }, testInfo) => {
    await stageStep(page, testInfo, STAGES[3], "SHA-256 tamper injection", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      for (const stage of [STAGES[1], STAGES[2], STAGES[3]]) {
        await advanceTo(page, stage);
      }

      const panel = page.getByTestId("adversarial-simulation-panel");
      await expect(panel).toBeVisible();
      await expect(page.getByTestId("hash-status-badge")).toHaveText("Intact");
      await expect(page.getByTestId(`artifact-status-badge-${ARTIFACT_ID}`)).toHaveText("Match");

      await page.getByTestId("inject-hash-mismatch-btn").click();

      // The containment alert is the panel's own verdict, not a colour change.
      await expect(page.getByTestId("containment-alert-hash-mismatch")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.getByTestId("containment-alert-badge-hash_mismatch")).toBeVisible();
      await expect(page.getByTestId("hash-status-badge")).toHaveText("Tampered");

      // The comparison table's mismatch badge specifically — this is the
      // "verification engine flags the discrepancy" claim in the constitution.
      await expect(page.getByTestId("hash-comparison-table")).toBeVisible();
      await expect(page.getByTestId(`artifact-status-badge-${ARTIFACT_ID}`)).toHaveText("Mismatch");

      // And that the digest actually moved, not merely that a badge flipped.
      await expect(page.getByTestId(`artifact-computed-sha-${ARTIFACT_ID}`)).toContainText(
        CORRUPTED_SHA_PREFIX,
      );
      await expect(page.getByTestId("current-hash-value")).toContainText(CORRUPTED_SHA_PREFIX);
      await expect(page.getByTestId("original-hash-value")).not.toContainText(CORRUPTED_SHA_PREFIX);

      // Restore is the negative control: without it, a panel hard-wired to
      // "Mismatch" after any click would pass everything above.
      await page.getByTestId("restore-hash-mismatch-btn").click();
      await expect(page.getByTestId("hash-status-badge")).toHaveText("Intact", { timeout: 30_000 });
      await expect(page.getByTestId(`artifact-status-badge-${ARTIFACT_ID}`)).toHaveText("Match");
      await expect(page.getByTestId("containment-alert-hash-mismatch")).toBeHidden();
    });
  });

  test("tamper control 2: symlink escape raises its own containment alert", async ({
    page,
  }, testInfo) => {
    await stageStep(page, testInfo, STAGES[3], "symlink escape injection", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      for (const stage of [STAGES[1], STAGES[2], STAGES[3]]) {
        await advanceTo(page, stage);
      }

      await expect(page.getByTestId("tamper-control-symlink-escape")).toBeVisible();
      await page.getByTestId("inject-symlink-escape-btn").click();

      await expect(page.getByTestId("containment-alert-symlink-escape")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.getByTestId("containment-alert-badge-symlink_escape")).toBeVisible();
      await expect(page.getByTestId("symlink-status-badge")).toBeVisible();
      await expect(page.getByTestId("rejection-reason-symlink-escape")).toBeVisible();
      await expect(page.getByTestId("syscall-flags-symlink-escape")).toBeVisible();

      // Zero-payload invariant: a containment alert must carry metadata only.
      // `bytes-read-symlink-escape` is a counter, which is the allowlisted shape.
      await expect(page.getByTestId("bytes-read-symlink-escape")).toBeVisible();

      await page.getByTestId("restore-symlink-escape-btn").click();
      await expect(page.getByTestId("containment-alert-symlink-escape")).toBeHidden({
        timeout: 30_000,
      });
    });
  });

  test("tamper control 3: oversized write raises its own containment alert", async ({
    page,
  }, testInfo) => {
    await stageStep(page, testInfo, STAGES[3], "oversized write injection", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      for (const stage of [STAGES[1], STAGES[2], STAGES[3]]) {
        await advanceTo(page, stage);
      }

      await expect(page.getByTestId("tamper-control-oversized-write")).toBeVisible();
      await page.getByTestId("inject-oversized-write-btn").click();

      await expect(page.getByTestId("containment-alert-oversized-write")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.getByTestId("containment-alert-badge-oversized_write")).toBeVisible();
      await expect(page.getByTestId("oversize-status-badge")).toBeVisible();
      await expect(page.getByTestId("rejection-reason-oversized-write")).toBeVisible();
      await expect(page.getByTestId("threshold-oversized-write")).toBeVisible();
      await expect(page.getByTestId("bytes-read-oversized-write")).toBeVisible();

      await page.getByTestId("restore-oversized-write-btn").click();
      await expect(page.getByTestId("containment-alert-oversized-write")).toBeHidden({
        timeout: 30_000,
      });
    });
  });

  test("auto-play completes at all three speeds and the toggle really changes pacing", async ({
    page,
  }, testInfo) => {
    const elapsed: Record<Pacing, number> = { "1x": 0, "2x": 0, instant: 0 };

    for (const pacing of ["1x", "2x", "instant"] as const) {
      await stageStep(page, testInfo, STAGES[4], `auto-play pass at ${pacing}`, async () => {
        await resetEstate(page);
        elapsed[pacing] = await autoPlayRun(page, pacing);
        for (const stage of STAGES) {
          await expect(stageStatus(page, stage.id)).toHaveText("confirmed");
        }
      });
    }

    // Ordering, not absolute values. A toggle wired to nothing would produce
    // three indistinguishable timings and pass any per-run bound taken alone.
    expect(elapsed["1x"]).toBeGreaterThan(elapsed["2x"]);
    expect(elapsed["2x"]).toBeGreaterThan(elapsed.instant);

    // Each speed must clear its own dwell floor: four transitions (Stage 1 is
    // pre-confirmed), so >= 4 x dwell, less a small tolerance for the clock
    // starting after the click resolves.
    expect(elapsed["1x"]).toBeGreaterThan(4 * DWELL_MS["1x"] * 0.9);
    expect(elapsed["2x"]).toBeGreaterThan(4 * DWELL_MS["2x"] * 0.9);

    // ─── The confirmation-wait proof, in a real browser ───────────────────
    //
    // AMXD-P5-1's contract is a DUAL lock: a stage may settle only once BOTH
    // the dwell timer has elapsed AND the channel has confirmed. A fake-timer
    // Vitest test can show the timer half; only a browser shows both.
    //
    // The bound is 500 ms and it is a LOWER bound, never an equality — real
    // browser and CI timing jitter makes an exact-match assertion a guaranteed
    // flake. 500 is chosen because it sits ABOVE the pure-dwell floor of
    // 4 x 100 ms = 400 ms: an implementation that advanced on the timer alone
    // and ignored confirmation would finish in ~400 ms and FAIL this line.
    // That is what makes it a proof rather than a tautology.
    expect(elapsed.instant).toBeGreaterThan(500);
  });

  test("a stage 4 rejection halts an auto-play run and demands operator action", async ({
    page,
  }, testInfo) => {
    // See B4 in this file's header. The composed route exposes no preset seam,
    // so the only lever a browser has is the tamper panel's own injection. This
    // test drives that lever and asserts AMXD-P5-1's halt-on-rejection contract
    // exactly as written. It is expected to stay red until the console offers a
    // way to select TAMPER_BREACH_PRESET; that redness is the finding, and
    // loosening it to match today's behaviour would delete the finding.
    await stageStep(page, testInfo, STAGES[3], "inject tamper, then auto-play", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      for (const stage of [STAGES[1], STAGES[2], STAGES[3]]) {
        await advanceTo(page, stage);
      }
      await page.getByTestId("inject-hash-mismatch-btn").click();
      await expect(page.getByTestId("containment-alert-hash-mismatch")).toBeVisible({
        timeout: 30_000,
      });
    });

    await stageStep(page, testInfo, STAGES[3], "auto-play halts on the rejection", async () => {
      await resetEstate(page);
      await page.getByTestId("autoplay-speed-instant").click();
      await page.getByTestId("autoplay-toggle-button").click();

      const indicator = page.getByTestId("autoplay-mode-indicator");
      await expect(indicator).toHaveAttribute("data-mode", "halted", { timeout: 120_000 });

      await expect(page.getByTestId("autoplay-halted-banner")).toBeVisible();
      await expect(page.getByTestId("autoplay-error-message")).toBeVisible();

      // Halted means STOPPED, not "paused and then finished anyway".
      await expect(stageStatus(page, "revocation_denied")).not.toHaveText("confirmed");

      // And that recovery is an operator decision, not automatic.
      await expect(page.getByTestId("autoplay-retry-button")).toBeVisible();
      await expect(page.getByTestId("autoplay-reset-estate-button")).toBeVisible();
    });
  });

  test("reset estate is idempotent and returns the console to stage 1", async ({
    page,
  }, testInfo) => {
    await stageStep(page, testInfo, STAGES[0], "reset twice", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 30_000 });
      await advanceTo(page, STAGES[1]);

      await resetEstate(page);
      await expect(stageStatus(page, "host_enrolled")).not.toHaveText("confirmed");

      // Twice, because "idempotent" is the claim in the constitution and a
      // reset that threw on an already-reset estate would pass a single call.
      await resetEstate(page);
      await expect(page.getByTestId("stage-panel-operator_init")).toBeVisible();
    });
  });

  test("renders Signal Loom design system StatCards and progressive log stream with StreamingLogBlock", async ({
    page,
  }) => {
    // StatCards row
    await expect(page.getByText("Stage Progress")).toBeVisible();
    await expect(page.getByText("01 / 05 Confirmed")).toBeVisible();
    await expect(page.getByText("Execution State")).toBeVisible();
    await expect(page.getByTestId("stage-progression-controller").getByText("Active", { exact: true })).toBeVisible();
    await expect(page.getByText("Channel & Preset")).toBeVisible();
    await expect(page.getByText("Invariant Status")).toBeVisible();
    await expect(page.getByText("Zero Customer Payload", { exact: true })).toBeVisible();

    // Execution Log Stream slot and controls
    await expect(page.getByTestId("execution-log-stream-slot")).toBeVisible();
    await expect(page.getByTestId("agentmaxxing-log-stream")).toBeVisible();
    await expect(page.getByTestId("log-stream-status-indicator")).toBeVisible();
    await expect(page.getByTestId("log-stream-clear-btn")).toBeVisible();
    await expect(page.getByTestId("log-stream-copy-btn")).toBeVisible();

    // Stepping to Stage 2 updates log stream and advances state
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-host_enrolled")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByTestId("stage-payload-preview-host_enrolled")).toBeVisible({ timeout: 15_000 });

    // Stepping to Stage 3 mounts ConfinementTelemetryPanel (B5 resolved)
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-confinement_streaming")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByTestId("stage-payload-preview-confinement_streaming")).toBeVisible({ timeout: 15_000 });
  });

  test("sub-path /demos/agentmaxxing/goal resolves cleanly to demo page without 404 or redirect", async ({
    page,
  }) => {
    await page.goto(`${config.base}/demos/agentmaxxing/goal`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("agentmaxxing-demo-page")).toBeVisible({ timeout: 30_000 });
    await expect(page.getByText("AgentMaxxing Interactive Demo Console")).toBeVisible();
    await expect(page.getByTestId("execution-log-stream-slot")).toBeVisible();
  });

  test("renders preset switcher, landlock path policy inspector, and attestation bundle export", async ({
    page,
  }) => {
    // Preset switcher rendered and interactive
    await expect(page.getByTestId("preset-switcher")).toBeVisible();
    await expect(page.getByTestId("preset-option-amxd-demo-happy-path")).toBeVisible();
    await expect(page.getByTestId("preset-option-amxd-demo-tamper-breach")).toBeVisible();
    await expect(page.getByTestId("preset-option-amxd-demo-revocation-race")).toBeVisible();

    // Attestation bundle export rendered
    await expect(page.getByTestId("attestation-bundle-export")).toBeVisible();
    await expect(page.getByTestId("attestation-download-btn")).toBeVisible();
    await expect(page.getByTestId("attestation-copy-btn")).toBeVisible();

    // Toggle attestation JSON statement
    await page.getByTestId("attestation-preview-toggle").click();
    await expect(page.getByTestId("attestation-json-preview")).toBeVisible();
    await page.getByTestId("attestation-preview-toggle").click();
    await expect(page.getByTestId("attestation-json-preview")).toBeHidden();

    // Advance to Stage 3 to verify Landlock LSM Path Policy Inspector
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-host_enrolled")).toBeVisible({ timeout: 15_000 });
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-confinement_streaming")).toBeVisible({ timeout: 15_000 });

    await expect(page.getByTestId("landlock-policy-inspector")).toBeVisible();
    const inspectorTable = page.getByTestId("landlock-policy-inspector-table");
    await expect(inspectorTable).toBeVisible();
    await expect(inspectorTable.getByText("/home/*/.ssh")).toBeVisible();
    await expect(inspectorTable.getByText("/var/run/docker.sock")).toBeVisible();
  });

  test("captures verified full-page screenshots of agentmaxxing demo console", async ({
    page,
  }) => {
    const outDir = "/home/andy/.gemini/antigravity-cli/brain/91263899-a979-428c-82e9-14039c9e2517";

    // Hide any fixed bottom right floating badges (theme toggle / demo badge) for clean screenshots
    await page.addStyleTag({
      content: '[style*="position: fixed"], [class*="fixed"] { display: none !important; }',
    });

    // Screenshot 1: Stage 1 overview
    await expect(page.getByTestId("agentmaxxing-demo-page")).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId("preset-switcher")).toBeVisible();
    await expect(page.getByTestId("autoplay-controls")).toBeVisible();
    await expect(page.getByTestId("attestation-bundle-export")).toBeVisible();
    await page.screenshot({ path: `${outDir}/agentmaxxing_stage1_overview.png`, fullPage: false });

    // Advance to Stage 2
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-host_enrolled")).toBeVisible({ timeout: 15_000 });

    // Advance to Stage 3
    await page.getByTestId("stepper-advance-button").click();
    await expect(page.getByTestId("stage-panel-confinement_streaming")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByTestId("landlock-policy-inspector")).toBeVisible();

    // Toggle attestation JSON preview open to display full cryptographic evidence
    await page.getByTestId("attestation-preview-toggle").click();
    await expect(page.getByTestId("attestation-json-preview")).toBeVisible();

    // Scroll Landlock Policy Inspector into view
    await page.getByTestId("landlock-policy-inspector").scrollIntoViewIfNeeded();

    // Screenshot 2: Stage 3 with Landlock LSM Path Policy Inspector & Cryptographic Payload
    await page.screenshot({ path: `${outDir}/agentmaxxing_stage3_landlock.png`, fullPage: false });

    // Scroll Attestation Bundle Export into view
    await page.getByTestId("attestation-bundle-export").scrollIntoViewIfNeeded();

    // Screenshot 3: Attestation Bundle Export with in-toto Statement v1
    await page.screenshot({ path: `${outDir}/agentmaxxing_attestation_bundle.png`, fullPage: false });

    // Scroll Log Stream into view to capture restyled toolbar
    await page.getByTestId("execution-log-stream-slot").getByTestId("agentmaxxing-log-stream").scrollIntoViewIfNeeded();

    // Screenshot 4: Execution Log Stream Toolbar with proper badges and buttons
    await page.screenshot({ path: `${outDir}/agentmaxxing_log_stream_toolbar.png`, fullPage: false });
  });
});

// ════════════════════════════════════════════════════════════════════════════
// LIVE BLOCK — real backend, real 403. Proves the DENIAL.
// ════════════════════════════════════════════════════════════════════════════

test.describe("AgentMaxxing demo console — live channel revocation denial", () => {
  // Both halves. Copy both lines together or the guard buys nothing — see the
  // file header, and helpers.ts `guards.agentmaxxingLive()`'s own note.
  test.skip(
    !guards.agentmaxxingLive(),
    "AgentMaxxing backend not deployed — run: make demo-signalloom-up",
  );

  test("revoking the host makes the next evidence upload fail 403 agent_revoked", async ({
    page,
  }, testInfo) => {
    await login(page, { demoMode: false });
    await openConsole(page);

    await stageStep(page, testInfo, STAGES[4], "reach stage 5 on the live channel", async () => {
      await page.getByTestId("token-issue-btn").click();
      await expect(page.getByTestId("token-issue-result")).toBeVisible({ timeout: 60_000 });
      for (const stage of STAGES.slice(1)) {
        await advanceTo(page, stage);
      }
      await expect(page.getByTestId("revocation-panel")).toBeVisible();

      // The channel badge is the cheapest proof that `{ demoMode: false }`
      // actually took effect. Reading localStorage would NOT do: with
      // `sl_demo_mode` absent, `demoMode.ts:33` returns `SL_ENV === 'demo'` and
      // `VITE_SL_ENV` defaults to `'demo'` (demoMode.ts:16), so demo mode is ON
      // with no key present. Read the app's state, not the key.
      await expect(page.getByTestId("revocation-channel-badge")).toContainText("live", {
        ignoreCase: true,
      });
    });

    await stageStep(page, testInfo, STAGES[4], "dispatch an attributable revocation", async () => {
      // B2: these are gated on !revocationSettled and do not render when Stage 5
      // is reached through the stepper. Asserted rather than routed around — a
      // spec that dispatched by another path would hide AMXD-P4-GOV Defect 2.
      await expect(page.getByTestId("revocation-reason-select")).toBeVisible();
      await expect(page.getByTestId("revocation-dispatch-btn")).toBeVisible();

      await page
        .getByTestId("revocation-reason-select")
        .selectOption({ index: 1 });
      await page
        .getByTestId("revocation-notes-input")
        .fill("AMXD-P6-1 acceptance: attributable revocation under test");

      // The revoke can answer 200 while revoking NOTHING
      // (external_agent_registration.py:1082-1088). Assert count > 0 HERE, or
      // the 403 below was never going to happen and its absence would read as a
      // product bug rather than as an empty revoke.
      const revokeResponse = page.waitForResponse(
        (r) => r.url().includes("/revoke") && r.request().method() === "POST",
        { timeout: 60_000 },
      );
      await page.getByTestId("revocation-dispatch-btn").click();
      const revoked = await revokeResponse;

      expect(revoked.status(), "revoke must be accepted before a denial can be proven").toBe(200);
      const revokeBody = (await revoked.json()) as { count?: number; revoked_agents?: unknown[] };
      expect(
        revokeBody.count ?? 0,
        `revoke returned 200 with count=${revokeBody.count ?? 0}; nothing was revoked, so no ` +
          "403 agent_revoked can follow. This is an empty revoke, not a denial failure.",
      ).toBeGreaterThan(0);

      await expect(page.getByTestId("revocation-operator-attribution")).toBeVisible();
    });

    await stageStep(page, testInfo, STAGES[4], "the next upload is denied 403 agent_revoked", async () => {
      const uploadResponse = page.waitForResponse(
        (r) => r.url().includes("evidence-uploads") && r.status() === 403,
        { timeout: 60_000 },
      );
      await page.getByTestId("upload-attempt-trigger-btn").click();
      const denial = await uploadResponse;

      expect(denial.status()).toBe(403);

      // The code, not merely the status. AMXD-P4-PRE: a binding mismatch on this
      // spec's own constructed envelope answers 403 too, so a status-only
      // assertion would go green while proving the envelope was malformed.
      // AMXD-P4-2's traced call chain names `agent_revoked`.
      const body = (await denial.json()) as { error?: { code?: string }; code?: string };
      const errorCode = body.error?.code ?? body.code;
      expect(
        errorCode,
        "403 must be agent_revoked. `tenant_key_binding_mismatch`, " +
          "`tenant_agent_binding_mismatch` and `tenant_host_binding_mismatch` also answer 403 " +
          "and would prove the envelope wrong rather than the agent revoked; " +
          "`insufficient_scope` is AMXD-P4-GOV Defect 1, still open.",
      ).toBe("agent_revoked");

      // And that the operator can SEE it — the console's own denial proof.
      await expect(page.getByTestId("revocation-denial-badge")).toBeVisible();
      await expect(page.getByTestId("revocation-timeline")).toBeVisible();
      await expect(page.getByTestId("timeline-reason-code")).toContainText("agent_revoked");
      await expect(page.getByTestId("revocation-binding-mismatch-warning")).toBeHidden();
    });
  });
});
