import { test, expect } from "@playwright/test";
import { login, config } from "./helpers";

/**
 * Live-data contract: no route may render on top of a failed API call.
 *
 * WHY THIS EXISTS
 *
 * On 2026-08-18 six user-visible surfaces were reporting live-data errors while
 * the entire suite was green:
 *
 *   /fleet                  Fleet API 502   (nginx, no fleet-manager endpoints)
 *   /signal-fusion          500             (IndexError in the demo runner)
 *   /signal-store           404             (route absent from a stale image)
 *   /agent-trust-topology   403 x6          (namespaces never deployed)
 *
 * Every one of them was found by a human clicking through the product. Not one
 * was found by a test, and the reason is a single line: `login()` in helpers.ts
 * defaults to `demoMode: true`, so every spec that calls it pre-seeds
 * `sl_demo_mode=true` and renders fixtures. The dashboard is DESIGNED to fall
 * back to fixtures when the live API is unavailable — which means the fallback
 * that makes a demo robust is exactly the thing that makes the suite blind. A
 * page whose backend returns 502 looks identical, to a demo-mode spec, to a
 * page whose backend is healthy.
 *
 * So this spec opts out (`demoMode: false`) and asserts the one thing no other
 * spec asserts: that the API calls a page actually makes come back 2xx.
 *
 * WHAT IT IS NOT
 *
 * It is not a rendering test and deliberately makes no claim about what the
 * page displays — the per-page specs own that. Its whole value is that it
 * catches a CLASS (the UI calls a backend that is absent, stale, misrouted or
 * forbidden) rather than four instances, and that it names the route AND the
 * endpoint AND the status so a failure is actionable without a debugger.
 *
 * ALLOWLIST DISCIPLINE
 *
 * `TOLERATED` below is the dangerous part of this file. Every entry is a hole
 * in the assertion, so each one carries the reason it is not a defect and each
 * is matched as narrowly as the case allows. Adding an entry to make a red run
 * go green — rather than because the status is genuinely correct behaviour —
 * converts this spec into decoration. That failure mode has already happened
 * elsewhere in this repo: a guard that repairs the symptom silences its own
 * alarm and the broken component ships green.
 */

/** Routes that render live data. Auth/onboarding flows are covered elsewhere. */
const ROUTES = [
  "/agents",
  "/discovery",
  "/compliance",
  "/compliance/policies",
  "/compliance/posture",
  "/compliance/risk",
  "/audit",
  "/cryptography",
  "/credential-inventory",
  "/federated-services",
  "/collusion-access",
  "/rbac-analysis",
  "/rbac-explorer",
  "/weave",
  "/signal-fusion",
  "/signal-store",
  "/agent-trust-topology",
  "/network-tests",
  "/supercred",
  "/fleet",
  "/settings",
] as const;

/** A request the dashboard makes to a backend, as opposed to an asset fetch. */
function isApiCall(url: string): boolean {
  const path = new URL(url).pathname;
  return path.startsWith("/api/") || path.startsWith("/fleet-api/");
}

interface Tolerated {
  /** Matches the request path. */
  path: RegExp;
  /** The status this endpoint is allowed to return. */
  status: number;
  /** Why this is correct behaviour and not a defect. Required. */
  because: string;
}

const TOLERATED: Tolerated[] = [
  {
    // The dashboard probes for an AFM deployment and degrades gracefully when
    // the slice is absent; `demo-signalloom-afm-up` is documented as
    // warn-do-not-fail when its source repo is missing, so a 404 here is the
    // designed answer on an estate without it, not a broken call.
    path: /^\/api\/afm\//,
    status: 404,
    because: "AFM slice is optional; its Makefile target warns rather than fails when absent",
  },
];

function isTolerated(path: string, status: number): Tolerated | undefined {
  return TOLERATED.find((t) => t.path.test(path) && t.status === status);
}

interface Failure {
  route: string;
  path: string;
  status: number;
}

test.describe("live data", () => {
  // NOT serial, and that is deliberate — it was serial for one run and the
  // consequence was immediate: the sweep failed, and Playwright reported
  // "1 did not run" for the endpoint test below. In a serial group a failure
  // skips the remainder, so the two tests that name the four already-paid-for
  // endpoints never executed on precisely the run where they were most useful.
  //
  // The usual reason to serialise here — these projects drive one shared demo
  // cluster — does not apply: both tests only navigate and read. Neither
  // mutates the estate, and each does its own login(), so they share no state.
  test.describe.configure({ mode: "parallel" });

  test("no route renders on top of a failed API call", async ({ page }) => {
    test.setTimeout(4 * 60_000);

    const failures: Failure[] = [];
    const seen: Array<{ route: string; path: string; status: number }> = [];
    let currentRoute = "(pre-login)";

    page.on("response", (response) => {
      const url = response.url();
      if (!isApiCall(url)) return;
      const path = new URL(url).pathname;
      const status = response.status();
      seen.push({ route: currentRoute, path, status });
      if (status < 400) return;
      if (isTolerated(path, status)) return;
      failures.push({ route: currentRoute, path, status });
    });

    // demoMode:false is the entire point — see the header. With the default
    // (true) this spec would pass against all four of the defects it was
    // written for, because fixtures answer before the network is ever touched.
    await login(page, { demoMode: false });

    for (const route of ROUTES) {
      currentRoute = route;
      await page.goto(`${config.base}${route}`, { waitUntil: "domcontentloaded" });
      // Pages fan out several calls after first paint; networkidle is the
      // observable end of that fan-out. A page with a long-poll never settles,
      // so failing to settle is not itself an assertion — we just move on with
      // whatever arrived, and the responses already captured still count.
      await page
        .waitForLoadState("networkidle", { timeout: 15_000 })
        .catch(() => undefined);
    }

    // A spec that observed NOTHING would report zero failures and read as a
    // pass. That is the shape of every silent-skip defect in this repo, so the
    // absence of traffic is itself a failure.
    expect(
      seen.length,
      "no API traffic was observed at all — the spec proved nothing. " +
        "Check that demoMode:false took effect and that the dashboard is reachable.",
    ).toBeGreaterThan(0);

    // ...and the same argument applies PER ROUTE, which is not a refinement but
    // a defect this spec had on its first run. /signal-store was reported by a
    // human as failing with a 404, the sweep visited it, and the sweep saw zero
    // requests from it — because the page threw before it ever reached the
    // network. Counting only failed responses therefore scored a broken page as
    // clean. Every route listed above is data-driven by construction, so a route
    // that issues no API call at all has failed earlier and quieter than one
    // that issues a call and gets a 500.
    const silent = ROUTES.filter((r) => !seen.some((s) => s.route === r));
    expect(
      silent,
      `route(s) made no API call at all — they failed before reaching the ` +
        `network, which is quieter than a 5xx and just as broken:\n` +
        silent.map((r) => `  ${r}`).join("\n"),
    ).toEqual([]);

    const report = failures
      .map((f) => `  ${f.route}  ->  ${f.path}  ${f.status}`)
      .join("\n");

    expect(
      failures,
      failures.length
        ? `${failures.length} API call(s) failed across ${ROUTES.length} routes ` +
          `(${seen.length} calls observed):\n${report}`
        : "",
    ).toEqual([]);
  });

  test("the four reported endpoints answer", async ({ page }) => {
    // Named explicitly, in addition to the sweep above, so a regression on any
    // one of them fails with that endpoint's name rather than inside a list.
    // The sweep catches the class; this catches the four we already paid for.
    const ENDPOINTS = [
      { path: "/fleet-api/v1/fleet/topology", was: "502 nginx, no fleet-manager endpoints" },
      { path: "/api/signals/store/stats", was: "404, route absent from a stale image" },
      { path: "/api/demo/signalfusion/status", was: "500, IndexError in the demo runner" },
      { path: "/api/signals/coverage", was: "collector reachability for agent-trust" },
    ] as const;

    await login(page, { demoMode: false });

    const results: string[] = [];
    for (const { path, was } of ENDPOINTS) {
      // Issued from the page context so it carries the session the browser
      // holds. Probing these with a bare fetch from the test process would
      // send no credentials and turn every one of them into an uninformative
      // 401 — which is the "confident answer it has not earned" trap.
      const status = await page.evaluate(async (p) => {
        const r = await fetch(p, { credentials: "same-origin" });
        return r.status;
      }, path);
      results.push(`${path} -> ${status}  (was: ${was})`);
      expect(status, `${path} returned ${status} (was: ${was})`).toBeLessThan(400);
    }
    console.log(results.join("\n"));
  });
});
