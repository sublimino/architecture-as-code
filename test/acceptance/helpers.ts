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
export async function login(page: Page, opts?: { demoMode?: boolean }): Promise<void> {
  const demoMode = opts?.demoMode ?? true;
  // Pre-seed demo mode so every screen renders from fixtures (unless the
  // spec opted out via { demoMode: false })
  await page.addInitScript((demo: boolean) => {
    try {
      window.localStorage.setItem("sl_demo_mode", demo ? "true" : "false");
      // Superadmin is a visibility control that defaults off (see
      // dashboard-signalloom/src/auth/superadmin.ts). Specs that assert on the
      // superadmin-only sidebar links — RBAC Analysis, RBAC Explorer,
      // Cryptography, Federated Services, Collusion & Access — need it on.
      window.localStorage.setItem("signalloom.superadmin", "true");
    } catch {
      /* storage unavailable */
    }
  }, demoMode);

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
