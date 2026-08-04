/**
 * The two-window SuperCredential demo, proven end to end.
 *
 * This is the only test in the repo that asserts the demo's actual payoff. The
 * instructor drives a phase in one browser; the audience is looking at a
 * SECOND browser, on a different page, that nobody touches. If the second
 * window does not change on its own, the demo does not land — no matter how
 * green the component tests are, because those mock the boundary the whole
 * claim rests on.
 *
 * ─── What "no reload" means here ───────────────────────────────────────────
 *
 * Asserting only that the stun appears in window B is not enough: a test that
 * reloaded B would pass while disproving the demo. So B's navigations are
 * counted from the moment it settles on /agents, and asserted to be zero. The
 * evidence has to arrive through the page's own poll loop
 * (api/pollInterval.ts, LIVE_POLL_MS) or it does not count.
 *
 * ─── Live mode, deliberately ───────────────────────────────────────────────
 *
 * Every login here passes { demoMode: false }, the same convention
 * supercred-live-pages.spec.ts uses. Under demo mode the dashboard renders
 * bundled fixtures, and a fixture can show a stun on a cluster where nothing
 * ever ran — the single largest false-pass risk in this suite.
 *
 * ─── Locators ──────────────────────────────────────────────────────────────
 *
 * Navigation is by route href via navigateTo(). Never by accessible name: the
 * sidebar renders count badges, so the Compliance link's accessible name is
 * "Compliance 7" and an exact-name locator fails on live data while passing on
 * demo data. See supercred-helpers.ts.
 *
 * ─── Timeout ───────────────────────────────────────────────────────────────
 *
 * playwright.config.ts sets a global 30s timeout. A real demo phase runs the
 * cluster for one to three minutes — step 2 alone waits up to 300s for the
 * credential-chain Job — so this spec sets its own. The project entry raises
 * it too; this restates it at the file so a future move between projects
 * cannot silently reinstate 30s and report a working demo as a failure.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";
import { navigateTo, newAuthedContext, supercred, watchForNavigation } from "./supercred-helpers";

// Long enough for a reset plus two full phases against a live cluster.
test.describe.configure({ mode: "serial", timeout: 15 * 60_000 });

const deployed = supercred.agentDeployed();

/** The stun evidence, as the audience sees it (components/CredentialStateNotice.tsx). */
const REVOKED = '[data-testid="credential-state-revoked"]';
/** Phase 4's button on the instructor panel (components/SuperCredInstructorPanel.tsx). */
const RUN_PHASE_4 = '[data-testid="supercred-run-step-4"]';
const RUN_PHASE_2 = '[data-testid="supercred-run-step-2"]';
const RUN_STATUS = '[data-testid="supercred-run-status"]';

test.describe("SuperCredential demo — instructor window and audience window", () => {
  test.skip(
    !deployed,
    "SuperCred agent not deployed — run: make demo-signalloom-supercred-1 && make demo-signalloom-supercred-2",
  );

  test("phase 4 driven in the instructor window stuns the agent in the audience window, with no reload", async ({
    browser,
  }) => {
    test.setTimeout(15 * 60_000);

    // ── Two contexts, one storage state ──────────────────────────────────
    // Separate cookie jars and separate render loops: this must not be two
    // tabs sharing one page's state, or "the other window updated" would be
    // trivially true.
    const instructorCtx = await newAuthedContext(browser, { demoMode: false, superadmin: true });
    const audienceCtx = await newAuthedContext(browser, { demoMode: false, superadmin: false });

    try {
      const instructor = await instructorCtx.newPage();
      const audience = await audienceCtx.newPage();

      // ── Both windows up, concurrently ──────────────────────────────────
      // Concurrently and not sequentially because that is the demo: the
      // audience window is already open and already polling before the
      // instructor touches anything.
      await Promise.all([
        login(instructor, { demoMode: false }),
        login(audience, { demoMode: false }),
      ]);
      // Fail fast, and by name, if the first-run wizard is covering the app.
      // It renders OVER a fully working sidebar, so login() passes and the
      // next click hangs for the whole test timeout while reporting a locator
      // problem. newAuthedContext seeds the app's own skip key; this asserts
      // the seed worked rather than discovering it fifteen minutes later.
      for (const page of [instructor, audience]) {
        await expect(
          page.getByRole("heading", { name: /welcome to signal loom/i }),
          "the onboarding wizard must not be covering the app — check the sl_onboarding_skipped seed in newAuthedContext",
        ).toHaveCount(0, { timeout: 15_000 });
      }

      await Promise.all([
        navigateTo(instructor, "/supercred"),
        navigateTo(audience, "/agents"),
      ]);

      await expect(instructor.locator(RUN_PHASE_4)).toBeVisible({ timeout: 30_000 });
      await expect(audience.getByText(/cardvault/i).first()).toBeVisible({ timeout: 60_000 });

      // ── Precondition: the agent must not already be stunned ────────────
      // A rehearsal an hour earlier is the normal case (ISA: "instructor
      // error is expected"). Starting from an already-revoked agent would
      // make the assertion below vacuous, so re-establish the credential
      // chain from the instructor window — through the UI, because that is
      // the path under test — and wait for the audience window to agree.
      if (await audience.locator(REVOKED).first().isVisible().catch(() => false)) {
        await instructor.locator(RUN_PHASE_2).click();
        await expect(instructor.locator(RUN_STATUS)).toContainText(/succeeded/, {
          timeout: 10 * 60_000,
        });
        await expect(audience.locator(REVOKED)).toHaveCount(0, { timeout: 120_000 });
      }
      await expect(audience.locator(REVOKED)).toHaveCount(0, { timeout: 60_000 });

      // ── Phase 3 is deliberately NOT driven here ──────────────────────────
      // The compliance scan is a demo step, not a precondition for the stun.
      // A superadmin must be able to revoke an agent's credentials whether
      // or not it has been scanned — a misbehaving-but-compliant workload is
      // still stunnable. The script's own guard (`preflight_agent_stunnable`)
      // now accepts `active` OR `non-compliant`, so jumping straight from the
      // credential chain (phase 2) to the stun (phase 4) is the harder and
      // more useful test.

      // ── From here on, nothing may navigate the audience window ─────────
      const audienceNav = watchForNavigation(audience);

      // ── Anti: no auth token in any URL ─────────────────────────────────
      // A token in a query string or path segment is logged by every proxy it
      // passes, lands in browser history, and leaks through Referer. The
      // client puts it in an Authorization header (api/demoRunner.ts) — this
      // watches every request BOTH windows make while the demo runs and
      // proves it stays there. Live, not by reading the source.
      const urlsWithSecrets: string[] = [];
      const auditUrl = (url: string) => {
        const parsed = new URL(url);
        const jwtLike = /\beyJ[A-Za-z0-9_-]{8,}\./;
        const named = /(^|[?&/])(token|access_token|id_token|bearer|authorization|jwt)([=/]|$)/i;
        if (jwtLike.test(url) || named.test(parsed.search) || named.test(parsed.pathname)) {
          urlsWithSecrets.push(url);
        }
      };
      instructor.on("request", (r) => auditUrl(r.url()));
      audience.on("request", (r) => auditUrl(r.url()));

      // ── Drive phase 4 in the instructor window only ─────────────────────
      await instructor.locator(RUN_PHASE_4).click();
      await expect(instructor.locator(RUN_STATUS)).toContainText(/succeeded/, {
        timeout: 10 * 60_000,
      });

      // ── The payoff: the untouched window changes on its own ────────────
      const revoked = audience.locator(REVOKED).first();
      await expect(
        revoked,
        "the audience window must show the stun without anyone touching it",
      ).toBeVisible({ timeout: 120_000 });

      // Names WHY, not just a status word — an audience reading "suspended"
      // has not been told anything (ISC-53).
      await expect(revoked).toContainText(/credentials revoked/i);

      // ── And it got there without a reload ──────────────────────────────
      expect(
        audienceNav.count(),
        `the audience window must not navigate or reload — observed: ${audienceNav.describe()}`,
      ).toBe(0);

      expect(
        urlsWithSecrets,
        "no auth token may appear in a URL query parameter or path segment",
      ).toEqual([]);

      // The instructor window is still on /supercred and the audience window
      // is still on /agents: two windows, two pages, one cluster.
      expect(new URL(instructor.url()).pathname).toBe("/supercred");
      expect(new URL(audience.url()).pathname).toBe("/agents");
    } finally {
      await instructorCtx.close();
      await audienceCtx.close();
    }
  });

  test("the two contexts are independent and both authenticated", async ({ browser }) => {
    // Guards the harness itself. If newAuthedContext ever stopped carrying the
    // sessionStorage OIDC token, the test above would fail as a timeout on a
    // locator, twenty minutes in, with Dex's login form on screen. This fails
    // in seconds and names the cause.
    const a = await newAuthedContext(browser, { demoMode: false });
    const b = await newAuthedContext(browser, { demoMode: false });
    try {
      const pageA = await a.newPage();
      const pageB = await b.newPage();
      await Promise.all([
        pageA.goto(config.base, { waitUntil: "domcontentloaded" }),
        pageB.goto(config.base, { waitUntil: "domcontentloaded" }),
      ]);
      for (const page of [pageA, pageB]) {
        // Located by href, never by label.
        await expect(page.locator('nav a[href="/agents"]')).toBeVisible({ timeout: 30_000 });
        expect(page.url()).not.toContain("/dex/");
      }
      expect(a).not.toBe(b);
    } finally {
      await a.close();
      await b.close();
    }
  });
});
