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
  /**
   * The `error.code` from the response envelope that is tolerated, when status
   * alone is too coarse to be honest.
   *
   * This exists because status alone WAS too coarse, and tolerating on it would
   * have been the exact failure this file's header warns about. `/api/rbac/*`
   * answers with 503 for four distinct causes (rbac_correlation.py
   * `_afm_failure`): `afm_not_deployed` means the optional AFM slice was never
   * deployed and the message names the remedy, while `afm_unreachable` and
   * `afm_bad_response` mean AFM IS deployed and is broken or breaking its
   * contract. Same status, opposite meanings. An entry matching only
   * `/api/rbac/` + 503 would tolerate the designed absence AND silently swallow
   * a real outage forever — decoration, on the one signal a security-posture
   * tool most needs to scream about.
   *
   * When set, the observed code must match exactly. An unreadable body yields
   * no code and is therefore NOT tolerated: fail closed, because "we could not
   * tell" is not "it is fine".
   */
  code?: string;
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
  {
    // The same optional slice, reached through the correlation API rather than
    // probed directly. rbac_correlation.py deliberately fails CLOSED — its
    // header argues that a posture tool reporting "no escalations" because its
    // upstream was unreachable is a worse failure than a visible 503 — so an
    // absent AFM surfaces here as 503 rather than as empty data. That is
    // correct behaviour, and the dashboard already renders it as "not
    // deployed" with the remedy (rbacCorrelationApi.ts BACKEND_ABSENT_CODES),
    // not as an error.
    //
    // PINNED TO THE CODE, and that is the whole point. This endpoint answers
    // 503 for four causes: `afm_not_deployed` (the slice was never deployed —
    // this one), plus `afm_unreachable` and `afm_bad_response`, which both mean
    // AFM IS deployed and is broken or breaking its contract. Matching on
    // path+status alone would tolerate the designed absence AND silently
    // swallow a real outage forever, on precisely the signal a security-posture
    // tool most needs to raise.
    path: /^\/api\/rbac\//,
    status: 503,
    code: "afm_not_deployed",
    because:
      "AFM slice is optional and CI never runs demo-signalloom-afm-up; " +
      "rbac_correlation.py fails closed with afm_not_deployed and names the remedy. " +
      "afm_unreachable and afm_bad_response stay untolerated — those mean AFM is deployed and broken",
  },
];

/**
 * Pure matcher, taking its entry list as an argument rather than closing over
 * TOLERATED, so the tolerance RULES can be tested without asserting against
 * whatever the live list happens to contain today. A test that had to use the
 * real list would change meaning every time an entry was added.
 */
export function matchTolerated(
  entries: readonly Tolerated[],
  path: string,
  status: number,
  code?: string,
): Tolerated | undefined {
  return entries.find((t) => {
    if (!t.path.test(path) || t.status !== status) return false;
    // No code pinned: status is a sufficient discriminator for this entry.
    if (t.code === undefined) return true;
    // Code pinned: it must match exactly. `code === undefined` here means the
    // body could not be read, which fails closed by falling through to false.
    return t.code === code;
  });
}

function isTolerated(path: string, status: number, code?: string): Tolerated | undefined {
  return matchTolerated(TOLERATED, path, status, code);
}

/**
 * The `error.code` from this repo's standard error envelope,
 * `{"error":{"code","message"}}` (api_compat.py `_error_response`).
 *
 * Defensive throughout: a body that is missing, not JSON, not that shape, or
 * no longer buffered yields `undefined` rather than throwing. Undefined is the
 * fail-closed value — a code-pinned TOLERATED entry will not match it — so an
 * unreadable body reports the failure instead of hiding it.
 */
async function errorCode(response: {
  json: () => Promise<unknown>;
}): Promise<string | undefined> {
  try {
    const body = (await response.json()) as { error?: { code?: unknown } } | null;
    const code = body?.error?.code;
    return typeof code === "string" ? code : undefined;
  } catch {
    return undefined;
  }
}

interface Failure {
  route: string;
  path: string;
  status: number;
  /** Carried into the report: "503" alone does not say which 503 this was. */
  code?: string;
}

/**
 * Wait until this route's API traffic has actually happened and then stopped.
 *
 * `waitForLoadState("networkidle")` is the obvious choice here and it is WRONG,
 * measurably so. This spec used it for exactly one run: on a cold first run it
 * caught the /fleet 502 and the /signal-fusion 500, and on the warm re-run it
 * completed all 21 routes in 16 seconds and reported everything clean. Nothing
 * had been fixed in between. networkidle resolves as soon as there are no
 * in-flight requests, and immediately after `domcontentloaded` there are none
 * YET — the SPA has not booted, so the condition is satisfied by the gap
 * BEFORE the work rather than the quiet after it. The spec was racing the app
 * and scoring the race as a pass.
 *
 * That is the same defect this whole spec exists to catch, turned inward: a
 * component reporting a confident answer it has not earned. So instead of
 * asking the browser whether it is idle, we watch the thing we actually care
 * about — this route's own API calls — and require BOTH that at least one
 * arrived and that a quiet window followed it.
 */
async function settle(
  count: () => number,
  { firstCallTimeout = 15_000, quietMs = 1_500, maxMs = 25_000 } = {},
): Promise<void> {
  const started = Date.now();

  // Phase 1: wait for the first call. A route that never issues one is a real
  // finding, not a reason to hang, so this resolves rather than throws — the
  // per-route silent assertion below is what reports it, with a better message.
  while (count() === 0 && Date.now() - started < firstCallTimeout) {
    await new Promise((r) => setTimeout(r, 100));
  }
  if (count() === 0) return;

  // Phase 2: quiesce. Pages fan out in waves (auth, then data, then panels),
  // so "no new call for quietMs" is the end of the fan-out, bounded by maxMs
  // for pages that long-poll and would otherwise never go quiet.
  let last = count();
  let lastChange = Date.now();
  while (Date.now() - started < maxMs) {
    await new Promise((r) => setTimeout(r, 100));
    const now = count();
    if (now !== last) {
      last = now;
      lastChange = Date.now();
    } else if (Date.now() - lastChange >= quietMs) {
      return;
    }
  }
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

    // Classification is async now, because deciding whether a 503 is the
    // designed absence of an optional slice or a real outage requires the
    // error code, and reading a body is a promise. Each classification is
    // parked here and awaited before the assertions, rather than left to run
    // detached — an un-awaited handler would let the test assert on `failures`
    // while entries were still being appended, and the race would resolve in
    // favour of "clean" exactly as often as the machine was fast.
    const classified: Array<Promise<void>> = [];

    page.on("response", (response) => {
      const url = response.url();
      if (!isApiCall(url)) return;
      const path = new URL(url).pathname;
      const status = response.status();
      seen.push({ route: currentRoute, path, status });
      if (status < 400) return;
      // Captured now: currentRoute advances while the body is in flight.
      const route = currentRoute;
      classified.push(
        (async () => {
          const code = await errorCode(response);
          if (isTolerated(path, status, code)) return;
          failures.push({ route, path, status, code });
        })(),
      );
    });

    // demoMode:false is the entire point — see the header. With the default
    // (true) this spec would pass against all four of the defects it was
    // written for, because fixtures answer before the network is ever touched.
    await login(page, { demoMode: false });

    for (const route of ROUTES) {
      currentRoute = route;
      await page.goto(`${config.base}${route}`, { waitUntil: "domcontentloaded" });
      await settle(() => seen.filter((s) => s.route === route).length);
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

    // Every parked classification must finish before `failures` is read, or
    // the assertion races the thing it is asserting on.
    await Promise.all(classified);

    const report = failures
      .map((f) => `  ${f.route}  ->  ${f.path}  ${f.status}${f.code ? ` (${f.code})` : ""}`)
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

    // The dashboard authenticates with `Authorization: Bearer <access_token>`,
    // NOT with a cookie. The first version of this test used
    // `fetch(p, { credentials: "same-origin" })` on the theory that a fetch
    // issued from the page context inherits the browser's session — and it
    // returned 401 on every endpoint, which is exactly the uninformative
    // answer that would let a genuinely-broken endpoint hide behind an
    // authentication failure.
    //
    // oidc-client-ts stores the user under an `oidc.user:<issuer>:<client>`
    // key, and THIS app puts that store in localStorage on purpose —
    // `userStore: new WebStorageStateStore({ store: window.localStorage })`
    // (auth/oidc.tsx:36), so evidence links opened in new tabs share the
    // session. Looking only in sessionStorage found nothing and produced a
    // false "no token" failure. Both stores are searched here so a future
    // change to that decision degrades to a slower lookup, not a wrong answer.
    const token = await page.evaluate(() => {
      for (const store of [window.localStorage, window.sessionStorage]) {
        for (let i = 0; i < store.length; i++) {
          const key = store.key(i);
          if (!key?.startsWith("oidc.user:")) continue;
          try {
            const v = JSON.parse(store.getItem(key) ?? "{}");
            if (v?.access_token) return v.access_token as string;
          } catch {
            /* not the entry we want */
          }
        }
      }
      return null;
    });

    expect(
      token,
      "no OIDC access token found in local or session storage — the probes " +
        "below would all return 401 and prove nothing about the endpoints " +
        "themselves, so this fails here rather than reporting a false result",
    ).toBeTruthy();

    const results: string[] = [];
    for (const { path, was } of ENDPOINTS) {
      const probe = await page.evaluate(
        async ([p, t]) => {
          const r = await fetch(p!, { headers: { Authorization: `Bearer ${t}` } });
          return { status: r.status, contentType: r.headers.get("content-type") ?? "" };
        },
        [path, token] as const,
      );
      results.push(`${path} -> ${probe.status} ${probe.contentType}  (was: ${was})`);
      expect(
        probe.status,
        `${path} returned ${probe.status} (was: ${was})`,
      ).toBeLessThan(400);
      // A 200 is not proof of live data. The SPA catch-all answers unmatched
      // paths with index.html and 200 OK — that is precisely how /fleet-api/
      // failures used to present before nginx got an explicit location block,
      // and fleetApi.ts still carries a comment about it. An API path that
      // returns HTML has not been served by an API.
      expect(
        probe.contentType,
        `${path} returned ${probe.status} but with content-type ` +
          `"${probe.contentType}" — an API path answered with HTML is the SPA ` +
          `catch-all, not the backend`,
      ).toContain("application/json");
    }
    console.log(results.join("\n"));
  });
});

// ─── The tolerance rules themselves ─────────────────────────────────────────
//
// TOLERATED is the dangerous part of this file, so the rules governing it are
// tested rather than trusted. These need no browser and no cluster; they run in
// the same project so they cannot become a spec nothing invokes — the defect
// that kept live-data.spec.ts itself from running until 3d70cc2.
test.describe("tolerance rules", () => {
  const ENTRIES: Tolerated[] = [
    { path: /^\/api\/thing\//, status: 404, because: "status alone is honest here" },
    { path: /^\/api\/coded\//, status: 503, code: "designed_absence", because: "only this code" },
  ];

  test("a code-pinned entry tolerates ONLY that code", () => {
    // The whole point. Same path, same status, opposite meanings — an entry
    // that pinned no code would return truthy for all three of these.
    expect(matchTolerated(ENTRIES, "/api/coded/x", 503, "designed_absence")).toBeTruthy();
    expect(matchTolerated(ENTRIES, "/api/coded/x", 503, "real_outage")).toBeUndefined();
    expect(matchTolerated(ENTRIES, "/api/coded/x", 503, "contract_break")).toBeUndefined();
  });

  test("a code-pinned entry does NOT tolerate an unreadable body", () => {
    // "We could not tell" is not "it is fine". An unreadable body yields no
    // code, and the entry must fail closed rather than wave it through — the
    // alternative makes every malformed 503 tolerated for free.
    expect(matchTolerated(ENTRIES, "/api/coded/x", 503)).toBeUndefined();
  });

  test("an entry with no code still matches on path and status alone", () => {
    // The pre-existing shape has to keep working, or adding the code axis
    // silently narrows entries that were correct as they were.
    expect(matchTolerated(ENTRIES, "/api/thing/y", 404)).toBeTruthy();
    expect(matchTolerated(ENTRIES, "/api/thing/y", 404, "anything")).toBeTruthy();
    expect(matchTolerated(ENTRIES, "/api/thing/y", 500)).toBeUndefined();
    expect(matchTolerated(ENTRIES, "/api/other/y", 404)).toBeUndefined();
  });

  test("every live TOLERATED entry states a because", () => {
    // A hole in the assertion with no stated reason is indistinguishable from
    // one added to turn a red run green.
    for (const t of TOLERATED) {
      expect(t.because.trim().length, `${t.path} ${t.status} has no reason`).toBeGreaterThan(10);
    }
  });

  test("the AFM 503 is tolerated ONLY as a designed absence", () => {
    // The entry this test guards is a hole in the assertion, so the hole is
    // pinned shut from both sides.
    //
    // /api/rbac/* answers 503 for four causes and only ONE of them is correct
    // behaviour. Proven in the backend's own suite, which runs as CI stage 2:
    // test_list_clusters_reports_afm_not_deployed_when_its_name_does_not_resolve
    // asserts code `afm_not_deployed` for a gaierror (an undeployed slice),
    // while test_refused_connection_is_not_reported_as_not_deployed asserts
    // `afm_unreachable` for a refused connection — same endpoint, same status,
    // different code, different fix.
    //
    // So tolerating on path+status would wave through a deployed-and-broken
    // AFM forever. These four assertions are what stops that.
    expect(isTolerated("/api/rbac/clusters", 503, "afm_not_deployed")).toBeTruthy();
    expect(isTolerated("/api/rbac/clusters", 503, "afm_unreachable")).toBeUndefined();
    expect(isTolerated("/api/rbac/clusters", 503, "afm_bad_response")).toBeUndefined();
    // Body unreadable: not tolerated, because "could not tell" is not "fine".
    expect(isTolerated("/api/rbac/clusters", 503)).toBeUndefined();
  });
});
