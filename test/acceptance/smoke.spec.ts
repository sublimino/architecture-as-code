/**
 * Signal Loom dashboard — initial-pages smoke suite.
 *
 * Authenticates once per test through local Dex, then drives the left-hand
 * sidebar to each initial page and asserts it renders (heading + representative
 * content) with no uncaught page errors. Uses the diagnostics-capturing `test`
 * fixture so any console/network failure is attached to the report.
 *
 * Preconditions: the local stack is up and the Envoy Gateway is port-forwarded,
 * which scripts/acceptance-test.sh does for every invocation. The dashboard is
 * reached at https://dashboard.osramp.acme.local:30754 (see config.base in
 * helpers.ts); playwright.config.ts resolves that hostname to 127.0.0.1.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

type PageCase = {
  nav: string;
  heading: string;
  content?: string[];
};

const PAGES: PageCase[] = [
  { nav: "Agents", heading: "Agents" },
  { nav: "Compliance", heading: "Compliance", content: ["Agent Posture"] },
  { nav: "Audit Trail", heading: "Audit Trail" },
  { nav: "Cryptography", heading: "Cryptography", content: ["Cluster Root of Trust", "SPIFFE / SPIRE Bootstrap", "Cipher Discovery (PQC)"] },
  { nav: "Federated Services", heading: "Federated Services", content: ["Trust Zones", "payments-api", "Cofide Go SDK"] },
  // "Collusion Pairs" is deliberately NOT in this content list: the page's
  // demo-mode Run selector has options labelled e.g. "Prod GitOps Cluster
  // (EU) · 2026-07-28 09:12 · 2 collusion pairs" (CollusionAccessPage.tsx's
  // demoOptions()), and getByText() is case-insensitive-substring by
  // default, so it matches that hidden <option> before the real "Collusion
  // Pairs" <h2> further down the page and times out waiting for it to
  // become visible. The dedicated "uses the radial cluster graph background"
  // test below asserts the Collusion Pairs heading via role scoping instead.
  { nav: "Collusion & Access", heading: "Collusion & Access", content: ["Remediation Priorities"] },
  // "KubeSec-AFM" is deliberately NOT asserted as content here, for the same
  // reason "Collusion Pairs" is not: the generic getByText matcher finds it in
  // the wrong place. It is worse than that case, though, because the wrong
  // place is the FAILURE state.
  //
  // The string renders unconditionally in the page's description paragraph
  // (RbacAnalysisPage.tsx:225) and AGAIN inside the "KubeSec-AFM platform is
  // not reachable" error banner (:424). So the assertion was satisfied twice
  // over in precisely the condition it existed to catch: with no AFM deployed,
  // /afm/ answering 502 and the page showing nothing but an error, this test
  // passed. It could not fail. It was green on all four lanes while every one
  // of them served a 502.
  //
  // The dedicated "RBAC Analysis renders live AFM data" test below asserts the
  // healthy state instead, by test id and on elements that exist ONLY when the
  // backend answered.
  { nav: "RBAC Analysis", heading: "RBAC Analysis" },
  { nav: "RBAC Explorer", heading: "RBAC Explorer", content: ["KubeSec-AFM RBAC analysis"] },
  { nav: "Agent Trust Topology", heading: "Agent Trust Topology", content: ["Trust relationship plane"] },
  { nav: "Settings", heading: "Settings" },
];

test("unauthenticated visit is redirected to the Dex login", async ({ page }) => {
  await page.goto(`${BASE}/cryptography`, { waitUntil: "domcontentloaded" });
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");
  // The protected page must NOT have leaked before authentication.
  await expect(page.getByRole("heading", { level: 1, name: "Cryptography" })).toHaveCount(0);
});

test.describe("authenticated dashboard", () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test("dashboard shows the full sidebar navigation", async ({ page }) => {
    for (const p of PAGES) {
      await expect(page.getByRole("link", { name: p.nav, exact: true })).toBeVisible();
    }
  });

  for (const p of PAGES) {
    test(`nav → ${p.nav} renders its page`, async ({ page }) => {
      const pageErrors: string[] = [];
      page.on("pageerror", (e) => {
        // Cross-origin iframe asset errors (e.g. Next.js /_next/) bubble as
        // "Unexpected token '<'" — not a Signal Loom page error.
        if (e.message.includes("Unexpected token '<'")) return;
        pageErrors.push(e.message);
      });

      await page.getByRole("link", { name: p.nav, exact: true }).click();

      await expect(page.getByRole("heading", { level: 1, name: p.heading })).toBeVisible({ timeout: 20_000 });

      for (const c of p.content ?? []) {
        await expect(page.getByText(c, { exact: false }).first()).toBeVisible({ timeout: 15_000 });
      }

      expect(pageErrors, `uncaught page errors on ${p.nav}: ${pageErrors.join("; ")}`).toEqual([]);
    });
  }

  test("Collusion & Access has no page-specific background", async ({ page }) => {
    await page.getByRole("link", { name: "Collusion & Access", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Collusion & Access" })).toBeVisible({ timeout: 20_000 });
    // Role-scoped (not getByText) so this can't match the Run selector's
    // hidden demo option that also contains the substring "collusion pairs".
    await expect(page.getByRole("heading", { level: 2, name: "Collusion Pairs" })).toBeVisible({ timeout: 15_000 });
    // This page used to carry a radial cluster-graph backdrop that no other
    // page had, which made it look like a different product. Uniformity is the
    // requirement now, so the absence is the thing worth asserting: a
    // reintroduced backdrop should fail here rather than be noticed by eye.
    await expect(page.getByTestId("ktp-graph-bg")).toHaveCount(0);
  });

  test("RBAC Analysis renders live AFM data, not its unreachable banner", async ({ page }) => {
    await page.getByRole("link", { name: "RBAC Analysis", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "RBAC Analysis" })).toBeVisible({ timeout: 20_000 });

    // Deliberately NOT behind guards.afmDeployed(). afm-integration,
    // afm-frontend, rbac-analysis and rbac-explorer all skip themselves when
    // the slice is absent, which is right for suites that assert on AFM's own
    // behaviour — but it leaves nobody asserting that the slice is SUPPOSED to
    // be there. AFM is part of the estate now (Makefile: demo-signalloom-afm-up
    // is fail-closed), so its absence is a failure, and this is the test that
    // says so.

    // The banner the page shows when /afm/health did not answer. Asserted
    // first, by test id, because it is the exact state that used to satisfy the
    // old string assertion instead of failing it.
    await expect(
      page.locator('[data-testid="afm-unreachable"]'),
      'the RBAC Analysis page is showing "KubeSec-AFM platform is not reachable" — the AFM slice is not deployed, or /afm/ is 502ing',
    ).toHaveCount(0);

    // The iframe is rendered only when status.reachable is true
    // (RbacAnalysisPage.tsx:454), so its presence is a live statement about
    // /afm/health rather than about what got bundled into the SPA.
    await expect(page.locator('[data-testid="afm-iframe"]')).toBeVisible({ timeout: 20_000 });

    // ── and AFM must actually HOLD something ────────────────────────────────
    //
    // Reachability alone is not the bar. A freshly deployed AFM answers
    // /afm/health with 200 while holding zero clusters — the import CronJob is
    // on */30 and does not run on creation — and the page then renders
    // "0 clusters" beside a green dot and an empty embedded dashboard. Every
    // check above passes in that state. It is a worse failure than the 502
    // because nothing downstream reports anything wrong.
    const clusterCount = page.locator('[data-testid="cluster-count"]');
    await expect(clusterCount).toBeVisible({ timeout: 20_000 });
    await expect(
      clusterCount,
      "AFM is reachable but holds no clusters — the cluster-import Job never completed, so the dashboard is empty",
    ).not.toHaveText(/^\s*0 clusters\s*$/);
  });

  test("DemoToggle widget is visible on every page", async ({ page }) => {
    const toggle = page.getByTestId("demo-toggle");
    await expect(toggle).toBeVisible({ timeout: 10_000 });
    // Initial state matches either label.
    await expect(toggle).toHaveText(/LIVE API|DEMO DATA/);
  });

  test("Agent Trust Topology exposes denied authorization evidence", async ({ page }) => {
    await page.getByRole("link", { name: "Agent Trust Topology", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Agent Trust Topology" })).toBeVisible({ timeout: 20_000 });
    await page.getByRole("button", { name: "Authorization plane", exact: true }).click();
    await page.getByRole("button", { name: /cross-project application denial/i }).click();
    await expect(page.getByText("Modeled application authorization rejection")).toBeVisible();
    await expect(page.getByText("Trust contract model", { exact: true })).toBeVisible();
  });

  test("Help & Support modal opens and closes", async ({ page }) => {
    // Open via sidebar button.
    await page.getByRole("button", { name: /help & support/i }).click();
    const heading = page.getByRole("heading", { name: "Help & Support" });
    await expect(heading).toBeVisible({ timeout: 10_000 });
    // FAQ content renders.
    await expect(page.getByText("Getting started")).toBeVisible();
    // Close with the × button.
    await page.getByRole("button", { name: "×" }).click();
    await expect(heading).not.toBeVisible({ timeout: 5_000 });
  });

  test("unknown route redirects to Agents", async ({ page }) => {
    await page.goto(`${BASE}/nonexistent-route-12345`, { waitUntil: "domcontentloaded" });
    // The SPA catch-all <Navigate to="/agents" /> fires.
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    expect(page.url()).toContain("/agents");
  });

  test("Agents page renders past loading (API round-trip)", async ({ page }) => {
    await page.getByRole("link", { name: "Agents", exact: true }).click();
    await expect(page.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible({ timeout: 20_000 });
    // The heading only renders after the API responds — the loading state
    // returns a <div>Loading…</div> with no h1. Additionally, the Governed
    // tab's "Register Agent" button is always present once the data loads.
    await expect(page.getByRole("button", { name: /Register Agent/i })).toBeVisible({ timeout: 15_000 });
  });

  /**
   * THE SINGLE-SCROLL-CONTEXT INVARIANT.
   *
   * The shell is `height: 100vh; overflow: hidden` with `<main>` as the one
   * scroll container, so the document itself must never scroll. When it does,
   * the browser's own scrollbar drags the whole UI — sidebar, page, sticky
   * rail and all — off the top of the screen, which is what a reader sees as
   * "there are two scrollbars and the on-this-page index has vanished".
   *
   * The mechanism this guards is specific and easy to reintroduce, because
   * nothing has to be positioned on purpose for it to happen: `overflow: auto`
   * makes `<main>` a clip, but only `position` makes it a containing block. An
   * absolutely-positioned descendant with no positioned ancestor resolves
   * against the initial containing block, which is OUTSIDE that clip, so its
   * box lands in document coordinates and extends the document's scroll area.
   * The two that triggered it were visually-hidden live regions — the
   * `position: absolute; width: 1px` recipe is the whole cause — and they sit
   * on other pages too, harmless only because those pages are short enough
   * that the span's static position still falls inside the viewport.
   *
   * Which is why this asserts on the SHORT routes as well as the long ones.
   * On /agents the defect is invisible to the eye and still measurable here.
   *
   * jsdom implements no layout: every height it reports is 0, so this
   * invariant cannot be expressed as a unit test at any level of effort. A
   * real browser is the only instrument that can see it.
   */
  const SCROLL_CONTEXT_ROUTES: { route: string; heading: string }[] = [
    // Two ordinary pages as the control: whatever fixes the design-system
    // pages must leave these exactly as they are.
    { route: "/agents", heading: "Agents" },
    { route: "/compliance", heading: "Compliance" },
    // Both PageTocLayout pages. /design-system/headers was measurably clean
    // while /design-system was not, so testing only the broken one would have
    // let a fix that merely moved the problem pass.
    { route: "/design-system", heading: "Design System & Component Library" },
    { route: "/design-system/headers", heading: "Design System — Headers" },
  ];

  for (const { route, heading } of SCROLL_CONTEXT_ROUTES) {
    test(`${route} has exactly one scroll context`, async ({ page }) => {
      await page.goto(`${BASE}${route}`, { waitUntil: "domcontentloaded" });
      await expect(page.getByRole("heading", { level: 1, name: heading })).toBeVisible({ timeout: 20_000 });

      // SAMPLED OVER A WINDOW, not measured once, and that is not belt-and-
      // braces — a single reading taken when the <h1> appears reports this page
      // as CLEAN while it is broken. Measured on the unfixed build: docScroll
      // was 720 at 0ms and at 250ms, and 9413 at 500ms. The two elements that
      // escape are visually-hidden live regions inside specimens that mount a
      // beat after the page does, so they simply do not exist yet at the
      // moment the heading becomes visible.
      //
      // Sampling also makes the assertion the right shape. A document that
      // scrolls for two seconds and then stops is still the defect — the
      // scrollbar appears, the layout jolts — so the invariant is "never", and
      // the worst sample is what has to satisfy it.
      const m = await page.evaluate(async () => {
        const doc = document.documentElement;
        const main = document.querySelector("main") as HTMLElement;
        const sample = () => {
          // Reported so a failure says WHICH element escaped rather than only
          // that the number is wrong: this is the diagnosis that saves the
          // next person the bisect.
          const escapers = Array.from(document.querySelectorAll("main *"))
            .filter((el) => {
              if (getComputedStyle(el).position !== "absolute") return false;
              const op = (el as HTMLElement).offsetParent;
              return op === null || op === document.body || op === document.documentElement;
            })
            .map((el) => `${el.tagName.toLowerCase()}.${el.className || "-"}@y${Math.round(el.getBoundingClientRect().top)}`);
          return { docScroll: doc.scrollHeight, mainScroll: main.scrollHeight, escapers };
        };

        let worst = sample();
        let maxMainScroll = worst.mainScroll;
        for (let i = 0; i < 30; i++) {
          await new Promise((r) => setTimeout(r, 100));
          const s = sample();
          maxMainScroll = Math.max(maxMainScroll, s.mainScroll);
          if (s.docScroll > worst.docScroll) worst = s;
        }
        return {
          docClient: doc.clientHeight,
          mainClient: main.clientHeight,
          maxDocScroll: worst.docScroll,
          maxMainScroll,
          escapers: worst.escapers,
        };
      });

      expect(
        m.maxDocScroll,
        `${route}: the document must never scroll — it reached ${m.maxDocScroll}px in a ${m.docClient}px viewport. ` +
          `Absolutely-positioned descendants of <main> with no positioned ancestor: ` +
          `${m.escapers.length ? m.escapers.join(", ") : "none found"}`,
      ).toBeLessThanOrEqual(m.docClient);

      // Without this the test passes vacuously on a page that failed to render
      // its content: a blank <main> also produces a non-scrolling document.
      expect(m.maxMainScroll, `${route}: <main> rendered no scrollable content`).toBeGreaterThan(m.mainClient);
    });
  }

  test("the design-system rail stays put while the content scrolls", async ({ page }) => {
    // Explicitly wider than RAIL_MIN_VIEWPORT (1280) rather than relying on the
    // 1280 default: at exactly the breakpoint a classic (non-overlay) scrollbar
    // takes the viewport to 1275 and `display: none` wins, and whether a given
    // machine paints overlay scrollbars is not something this test should be
    // betting on.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(`${BASE}/design-system`, { waitUntil: "domcontentloaded" });
    await expect(page.getByTestId("page-toc")).toBeVisible({ timeout: 20_000 });

    const railTop = async () => (await page.getByTestId("page-toc").boundingBox())!.y;
    // Index rather than id: "a later entry became current" is the behaviour,
    // and naming a specific section would tie this to the page's contents.
    const activeIndex = () =>
      page.evaluate(() =>
        Array.from(document.querySelectorAll(".ds-toc-link")).findIndex(
          (a) => a.getAttribute("aria-current") === "location",
        ),
      );

    // The route wrapper carries `.fade-in`, whose keyframes translate it, so
    // for the first few hundred milliseconds every y in this test is offset by
    // a couple of pixels — measured at 30.57 against an expected 28. Waiting on
    // the element's OWN animations (getAnimations() does not recurse) settles
    // that deterministically; a wider tolerance would have hidden it instead,
    // and this page is full of infinite specimen animations that a
    // document-wide wait would block on forever.
    await page.evaluate(async () => {
      const el = document.querySelector("main > div.fade-in") as HTMLElement;
      await Promise.all(el.getAnimations().map((a) => a.finished.catch(() => undefined)));
    });

    // Unscrolled: the rail sits at the content's 28px top padding — below its
    // own 20px sticky clamp, so the assertion after the scroll is proof it
    // moved up and held rather than having started there by luck.
    expect(await railTop()).toBeCloseTo(28, 0);
    expect(await activeIndex()).toBe(0);

    await page.evaluate(() => {
      (document.querySelector("main") as HTMLElement).scrollTop = 6000;
    });
    // The scrollspy is an IntersectionObserver, so it settles a frame or two
    // after the scroll rather than synchronously with it.
    await page.waitForTimeout(1000);

    // THE BUG, stated as a measurement: with a second scroll context the rail
    // travelled with the document and left the screen entirely. Sticking means
    // clamping to its own `top: 20px` against <main>'s padding box, which
    // starts at viewport y=0.
    expect(
      await railTop(),
      "the rail scrolled away with the content instead of sticking to top: 20px",
    ).toBeCloseTo(20, 0);
    await expect(page.getByTestId("page-toc")).toBeInViewport();

    // Scrolling must not have introduced the document scroll either: a sticky
    // element that mispositions can grow the page it sits in.
    const docScrolls = await page.evaluate(
      () => document.documentElement.scrollHeight > document.documentElement.clientHeight,
    );
    expect(docScrolls, "scrolling the content grew the document").toBe(false);

    // And the highlight still tracks — a rail that sticks but stops following
    // the reader is only half the feature.
    expect(await activeIndex(), "the active-section highlight did not advance").toBeGreaterThan(0);
  });
});
