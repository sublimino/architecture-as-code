/**
 * Shared test helpers for the Signal Loom acceptance test suite.
 *
 * Centralises the Dex login flow, environment config, AFM precondition checks,
 * and polling utilities so every spec file uses one battle-tested implementation
 * instead of copy-pasted variants.
 *
 * Usage:
 *   import { login, config, afm, polling } from "./helpers";
 */
import { expect, type Page, type APIRequestContext } from "@playwright/test";
import { execFileSync } from "node:child_process";

// ── Deployment guards ───────────────────────────────────────────────────────

/**
 * Existence guards for D2 slices, mirroring the SKIP semantics of
 * `scripts/acceptance-test.sh:start_port_forward` and the BATS gate in
 * `d2-osramp-apps/test/_helper.bats`.
 *
 * A slice that was never deployed is a SKIP, not a failure, so the suite stays
 * runnable against any subset of the estate. Guards name DECLARATIVE objects
 * only (Namespace, Service, Deployment) because Flux keeps those reconciled
 * whether or not the workload behind them is healthy — guarding a runtime Pod
 * would skip exactly when a pod has crashed, which is the breakage these tests
 * exist to catch. A deployed-but-unhealthy slice still runs its assertions and
 * still fails.
 */
export const guards = {
  /** True when the named cluster object exists. Never throws. */
  exists(kind: string, name: string, namespace?: string): boolean {
    // execFile with an argument array — never shell interpolation.
    const args = ["--request-timeout=10s", "get", kind, name];
    if (namespace) args.push("--namespace", namespace);
    try {
      execFileSync("kubectl", args, { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  },

  /** k8s-afm slice — `make demo-k8s-afm-up`. */
  afmDeployed(): boolean {
    return guards.exists("service", "afm-platform", "fe-k8s-afm");
  },

  /** olly-replica slice — `make demo-olly-up`. */
  ollyDeployed(): boolean {
    return guards.exists("service", "customer-portal", "olly-replica");
  },

  /** osramp-apps backend (Archivista) — `make demo-osramp-up`. */
  archivistaDeployed(): boolean {
    return guards.exists("service", "osramp-archivista", "backend");
  },

  /** kube-prometheus-stack Grafana — part of the observability profile. */
  grafanaDeployed(): boolean {
    return guards.exists("service", "kube-prometheus-stack-grafana", "monitoring");
  },

  /**
   * AgentMaxxing backend — the FastAPI app that serves external-agent
   * enrollment, evidence upload, and host revocation.
   *
   * @consumedBy AMXD-P4-2 — the revoke-then-upload dispatch test.
   * @consumedBy AMXD-P6-1 — the live-mode spec block in the demo-console spec.
   *
   * ─── Why this guard exists ──────────────────────────────────────────────
   *
   * `login()` below defaults to `demoMode: true` (see its `opts?.demoMode ??
   * true`). In demo mode `dashboard-signalloom/src/api/client.ts:227`
   * short-circuits `req()` into `resolveFake()` BEFORE any network call is
   * attempted, so no assertion downstream of that call can ever observe a real
   * HTTP response. Worse, a 403 is not merely unlikely under demo mode — it is
   * structurally unreachable: when a route has no fixture, `client.ts:233-239`
   * throws `demoModeError` with status **404** (route known, fixture missing)
   * or **501** (route not implemented), and those are the only two statuses
   * that path can produce. A spec that asserts `403` while demo mode is on can
   * therefore only pass by fabricating the very response it claims to verify.
   *
   * One caveat on that "never 403": `client.ts:227`'s real condition is
   * `isDemoMode() && !requiresLiveAgentDetail(method, path)`. That exception is
   * GET-only (`client.ts:66`), so it cannot rescue a POST revoke — but it does
   * mean "structurally unreachable" is a statement about this flow, not a
   * universal law of the client.
   *
   * So a live-403 spec needs BOTH halves, and the guard is only one of them:
   *
   *   test.skip(!guards.agentmaxxingLive(),
   *     'AgentMaxxing backend not deployed — run: make demo-signalloom-up');
   *   await login(page, { demoMode: false });
   *
   * Copy both lines. `guards.agentmaxxingLive()` without `{ demoMode: false }`
   * still short-circuits into fixtures at `client.ts:227` and the guard will
   * have bought you nothing. Note that `loginExpectingDex()` below hardcodes
   * `sl_demo_mode = "true"` with no opt-out — it is not a substitute for
   * `login(page, { demoMode: false })` in a live spec.
   *
   * ─── Two more prerequisites the guard does NOT cover ────────────────────
   *
   * 1. `POST /v1/external-agents/hosts/{host_id}/revoke` can succeed and revoke
   *    NOTHING. `revoke_external_host_handler` selects agents by `host_id` and
   *    returns HTTP 200 with `{"status":"revoked","revoked_agents":[],
   *    "count":0}` when none match (`external_agent_registration.py:1082-1088`).
   *    A spec that reads 200 and moves on will then assert a 403 that was never
   *    going to happen. **Assert `count > 0` on the revoke before asserting on
   *    the upload** — otherwise the fabrication this guard removes reappears one
   *    layer down.
   * 2. There is no client call site yet: `rg 'external-agents'
   *    apps/dashboard-signalloom/src` is empty. P4-2 builds the request as well
   *    as the assertion.
   *
   * ─── Why a red P4-2 will say 404, and why nginx is NOT the culprit ──────
   *
   * [DATED — describes the tree as of AMXD-P1-5; re-check once AMXD-P1-4 lands.]
   *
   * The intuitive story is "nginx has no `location /v1/`, so the request 404s at
   * the proxy". That is wrong, and acting on it keeps you red:
   *
   *   - `nginx.conf:102` ALREADY proxies `location /api/` to
   *     `fe-signalloom-api.fe-signalloom.svc.cluster.local:8000`.
   *   - `client.ts:241` rewrites any path not starting with `/api` to
   *     `/api${path}`, so `req('/v1/external-agents/…')` leaves the browser as
   *     `/api/v1/external-agents/…` and matches that proxy.
   *   - It therefore REACHES FastAPI — and 404s there, because the revoke and
   *     upload routes are mounted only on `v1_router` (prefix
   *     `/v1/external-agents`, lines 1231 and 1241-1242), never on `router`
   *     (prefix `/api/v1/external-agents`, the `for r in (router, compat_router)`
   *     loop at 1219-1226).
   *
   * So the expected first failure is a router-prefix/mount-coverage mismatch on
   * the wire, not an absent proxy. A genuinely unproxied POST would hit the SPA
   * catch-all (`nginx.conf:325`, `try_files … /index.html`) and nginx answers
   * **405 Method Not Allowed**, not 404. Do not use "did the request cross the
   * wire" to tell these apart — in the likely case it did.
   *
   * And do NOT check `localStorage.sl_demo_mode === 'true'` to decide whether
   * demo mode is off: with the key absent, `demoMode.ts:33` returns
   * `SL_ENV === 'demo'`, and `VITE_SL_ENV` defaults to `'demo'`
   * (`demoMode.ts:16`). Demo mode is ON with no key present. Read the app's
   * state, not the key.
   *
   * Whatever the cause, adding a demo fixture to turn the red green re-creates
   * exactly the defect this guard was written to remove.
   *
   * ─── Which object, and why this one ─────────────────────────────────────
   *
   * `service/fe-signalloom-api` in namespace `fe-signalloom`
   * (`d2-signalloom/apps/fe-signalloom/base/api-service.yaml`). That Service
   * fronts the FastAPI app which registers
   * `POST /v1/external-agents/hosts/{host_id}/revoke`
   * (`src/external_agent_registration.py:1231`) and raises
   * `APIError(status_code=403, code="host_revoked", …)` on the subsequent
   * upload at **lines 1189-1193**, inside
   * `upload_external_agent_evidence_handler` (def at 1166), gated on
   * `await is_external_agent_revoked(...)` at 1186. Note the two other
   * identical `403 host_revoked` raises at lines 1120 and 1142 are in
   * `enroll_external_agent_handler` (def at 1093) — the ENROLLMENT path, not
   * the upload path. Grepping the message string lands on the wrong half of the
   * flow; the revoke-then-upload 403 is 1189-1193.
   *
   * It deliberately does NOT probe the route, the nginx proxy, or a Pod. Per
   * the block at the top of this section, a guard separates "never provisioned"
   * from "provisioned and broken"; a missing route on a deployed backend is the
   * second kind, and a guard that went false for it would SKIP precisely when
   * the route regressed — the crashed-Pod anti-pattern in a new costume. A
   * deployed-but-broken AgentMaxxing backend still runs its assertions and
   * still fails.
   *
   * Two honest limits on what a `true` means here. This is an EXISTENCE check,
   * not a liveness check: `kubectl get service` exits 0 for a Service whose
   * selector matches no ready Pod, so a backend that is entirely down still
   * satisfies this guard. And `fe-signalloom-api` fronts the whole Signal Loom
   * API, so its presence says the estate slice is up — not that the AgentMaxxing
   * routers are mounted in the running image. Both are deliberate: each is a
   * "provisioned and broken" condition the spec must fail on, not skip.
   *
   * Never throws: it inherits `guards.exists`'s try/catch, so a missing object,
   * an unreachable API server, and a `kubectl` absent from PATH all return
   * false rather than converting a legitimate SKIP into a hard failure. It does
   * BLOCK, though — `--request-timeout=10s` bounds the API round-trip but not
   * kubeconfig resolution or the TCP dial, same as every sibling guard.
   */
  agentmaxxingLive(): boolean {
    return guards.exists("service", "fe-signalloom-api", "fe-signalloom");
  },
} as const;

// ── Configuration ───────────────────────────────────────────────────────────

export const config = {
  /**
   * Signal Loom dashboard base URL.
   *
   * The dashboard is served through the Envoy Gateway, which requires the SNI
   * hostname *.osramp.acme.local (playwright.config.ts resolves it to 127.0.0.1
   * via --host-resolver-rules). DASHBOARD_URL is exported by
   * scripts/acceptance-test.sh once it has established the gateway forward.
   *
   * The previous `http://localhost:5173` default predates that migration and no
   * longer resolves, which failed every spec that reached the dashboard or the
   * AFM proxy beneath it. SIGNALLOOM_UI_URL still wins for local vite work.
   */
  base:
    process.env.SIGNALLOOM_UI_URL ??
    process.env.DASHBOARD_URL ??
    "https://dashboard.osramp.acme.local:30754",
  /** Dex demo user email. */
  user: process.env.SIGNALLOOM_USER ?? "demo-user@signalloom.local",
  /** Dex demo user password. */
  pass: process.env.SIGNALLOOM_PASS ?? "demo-user",
} as const;

// ── Dex Login ───────────────────────────────────────────────────────────────

/**
 * Authenticate through the local Dex login and wait for the dashboard sidebar.
 *
 * Handles both fresh sessions (Dex login form) and already-authenticated
 * sessions (AutoSignIn skip). By default sets `sl_demo_mode=true` in
 * localStorage so the dashboard renders demo fixtures when the live API is
 * unavailable — pass `{ demoMode: false }` for specs that assert on real
 * cluster data (e.g. rbac-explorer.spec.ts expects the actual "local"
 * cluster and real namespaces, which only exist behind the live API; demo
 * mode serves a single fake "Demo Cluster" fixture instead). Toggling this
 * via the DemoToggle UI control after login doesn't work here — its
 * click-then-reload flow re-triggers this same addInitScript, which always
 * re-forces demo mode back on before the app boots.
 *
 * Waits for the sidebar "Agents" link as proof of successful auth + SPA render.
 */
export async function login(page: Page, opts?: { demoMode?: boolean; skipOnboarding?: boolean }): Promise<void> {
  const demoMode = opts?.demoMode ?? true;
  const skipOnboarding = opts?.skipOnboarding ?? true;
  // Pre-seed demo mode so every screen renders from fixtures (unless the
  // spec opted out via { demoMode: false })
  await page.addInitScript(
    ({ demo, skip }: { demo: boolean; skip: boolean }) => {
      try {
        window.localStorage.setItem("sl_demo_mode", demo ? "true" : "false");
        // Superadmin is a visibility control that defaults off (see
        // dashboard-signalloom/src/auth/superadmin.ts). Specs that assert on the
        // superadmin-only sidebar links — RBAC Analysis, RBAC Explorer,
        // Cryptography, Federated Services, Collusion & Access — need it on.
        window.localStorage.setItem("signalloom.superadmin", "true");
        if (skip) {
          window.localStorage.setItem(
            "sl_onboarding_skipped",
            JSON.stringify({ skippedAt: Date.now() }),
          );
        }
      } catch {
        /* storage unavailable */
      }
    },
    { demo: demoMode, skip: skipOnboarding },
  );

  await page.goto(config.base, { waitUntil: "domcontentloaded" });

  const loginInput = page.locator('input[name="login"]');
  const needsLogin = await loginInput
    .waitFor({ state: "visible", timeout: 15_000 })
    .then(() => true)
    .catch(() => false);

  if (needsLogin) {
    await loginInput.fill(config.user);
    await page.locator('input[name="password"]').fill(config.pass);
    await Promise.all([
      page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
      page.getByRole("button", { name: /login|sign in|submit/i }).click(),
    ]);

    // After Dex redirects back, react-oidc-context exchanges the auth code
    // for tokens (POST /dex/token). During this exchange isLoading=true and
    // the App renders <Spinner /> — no Sidebar exists yet. waitForURL
    // resolves as soon as the browser URL leaves /dex/, but the token
    // exchange can take several seconds on a cold Dex. Wait for the network
    // round-trip to settle before timing the Sidebar assertion.
    await page.waitForLoadState("networkidle", { timeout: 20_000 });
  }

  // Sidebar mounted = app rendered post-auth
  await expect(
    page.getByRole("link", { name: "Agents", exact: true }),
  ).toBeVisible({ timeout: 15_000 });
}

/**
 * Login variant that always expects the Dex form (for login-specific tests
 * that need to verify the login flow itself, not skip it).
 */
export async function loginExpectingDex(page: Page): Promise<void> {
  // Same pre-seeding as login() — superadmin-only sidebar links (RBAC Analysis,
  // RBAC Explorer, etc.) are invisible without this, and demo mode ensures
  // fixture-backed rendering when the live API is unavailable.
  await page.addInitScript(() => {
    try {
      window.localStorage.setItem("sl_demo_mode", "true");
      window.localStorage.setItem("signalloom.superadmin", "true");
      window.localStorage.setItem(
        "sl_onboarding_skipped",
        JSON.stringify({ skippedAt: Date.now() }),
      );
    } catch {
      /* storage unavailable */
    }
  });

  await page.goto(config.base, { waitUntil: "domcontentloaded" });
  const loginInput = page.locator('input[name="login"]');
  await expect(loginInput).toBeVisible({ timeout: 15_000 });
  expect(page.url()).toContain("/dex/auth");
  await loginInput.fill(config.user);
  await page.locator('input[name="password"]').fill(config.pass);
  await Promise.all([
    page.waitForURL((u) => !u.toString().includes("/dex/"), { timeout: 20_000 }),
    page.getByRole("button", { name: /login|sign in|submit/i }).click(),
  ]);
  await page.waitForURL(/\/(agents|compliance|audit|settings)?$|\/agents/, {
    timeout: 20_000,
  });
  await expect(
    page.getByText(/agents|compliance|audit trail|settings/i).first(),
  ).toBeVisible({ timeout: 15_000 });
}

// ── AFM Preconditions ───────────────────────────────────────────────────────

export const afm = {
  /**
   * Assert AFM is reachable and has seeded clusters. Call in `beforeAll` to
   * fail fast before running UI tests that depend on AFM data.
   */
  async assertHealthy(request: APIRequestContext): Promise<void> {
    const health = await request.get(`${config.base}/afm/health`).catch(() => null);
    expect(
      health?.ok(),
      "AFM must be reachable at /afm/health — run: make demo-k8s-afm-up",
    ).toBeTruthy();

    const clusters = await request.get(`${config.base}/afm/clusters`).catch(() => null);
    expect(clusters?.ok(), "AFM /clusters endpoint must respond").toBeTruthy();
    const data = await clusters!.json();
    expect(
      data.length,
      "AFM must have ≥1 seeded cluster — run: scripts/rbac-to-afm.py",
    ).toBeGreaterThanOrEqual(1);
  },
};

// ── Polling Utilities ───────────────────────────────────────────────────────

export const polling = {
  /**
   * Wait for RBAC Explorer data to load — one of three outcomes:
   *   - "data"  → `data-testid="rbac-stats"` is visible (success)
   *   - "error" → `data-testid="rbac-error"` is visible (React crash caught)
   *   - "empty" → "No RBAC data" text visible, or nothing showed up in time
   *     (fetch returned null)
   *
   * Uses a single locator built from `.or()` so Playwright's own auto-wait
   * drives this event-driven, rather than a hand-rolled poll loop on a fixed
   * `waitForTimeout` interval — whichever of the three appears first resolves
   * the wait immediately instead of waiting out the next 500ms tick. Fails
   * fast on crash instead of waiting the full timeout.
   */
  async waitForRbacData(
    page: Page,
    timeoutMs = 30_000,
  ): Promise<"data" | "error" | "empty"> {
    const stats = page.locator('[data-testid="rbac-stats"]');
    const error = page.locator('[data-testid="rbac-error"]');
    const empty = page.getByText("No RBAC data");

    await stats.or(error).or(empty).first().waitFor({ state: "visible", timeout: timeoutMs }).catch(() => {
      /* none appeared within timeoutMs — fall through to the empty default below */
    });

    if (await stats.isVisible().catch(() => false)) return "data";
    if (await error.isVisible().catch(() => false)) return "error";
    return "empty";
  },

  /**
   * Wait for a select element's options to populate. Uses Playwright's
   * `expect().toPass()` for auto-retry instead of fixed waits.
   */
  async waitForOptions(
    page: Page,
    testId: string,
    minCount: number,
    timeoutMs = 10_000,
  ): Promise<string[]> {
    const selector = page.locator(`[data-testid="${testId}"]`);
    await expect(async () => {
      const options = await selector.locator("option").allTextContents();
      expect(options.length).toBeGreaterThanOrEqual(minCount);
    }).toPass({ timeout: timeoutMs });
    return selector.locator("option").allTextContents();
  },
};
