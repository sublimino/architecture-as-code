/**
 * Helpers for the SuperCred end-to-end acceptance specs.
 *
 * Kept in its own module rather than bolted onto helpers.ts so the e2e track
 * does not collide with the six feature branches concurrently editing that
 * file. Everything here is additive.
 *
 * ─── The locator rule ──────────────────────────────────────────────────────
 *
 * NEVER locate sidebar navigation by its accessible name. `getByRole('link',
 * { name })` is SUBSTRING matching, and `{ exact: true }` is worse, not better:
 * the sidebar anchors render count badges, so the accessible name of the
 * Compliance link is "Compliance 7", not "Compliance". An exact match therefore
 * fails the moment a badge appears or its number changes — which is to say, it
 * fails on live data and passes on demo data. This has broken the suite twice.
 *
 * The route href is the stable identity of a nav item. It does not change when
 * a badge appears, when a count changes, or when the label is reworded. Use
 * navLink() and nothing else.
 */
import { expect, type Browser, type BrowserContext, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

/** Sidebar link for a route, located by href. Never by label. */
export function navLink(page: Page, route: string) {
  return page.locator(`nav a[href="${route}"]`);
}

/** Navigate via the sidebar and wait for the URL to settle on the route. */
export async function navigateTo(page: Page, route: string): Promise<void> {
  const link = navLink(page, route);
  await expect(link, `sidebar link for ${route} must be present`).toBeVisible({
    timeout: 15_000,
  });
  await link.click();
  await page.waitForURL((u) => new URL(u).pathname === route, { timeout: 15_000 });
}

// ── Cluster preconditions ──────────────────────────────────────────────────

/**
 * The SuperCred agent pod, wherever Flux put it. agents-cardvault.yaml declares
 * fe-signalloom-agents, but the Kustomization's targetNamespace can relocate
 * it to fe-signalloom — so a guard that checks only the declared namespace
 * reports "not deployed" for a running demo and silently skips the whole suite.
 */
const AGENT_NAMESPACES = ["fe-signalloom-agents", "fe-signalloom"];

function kubectlOk(args: string[]): boolean {
  try {
    execFileSync("kubectl", ["--request-timeout=10s", ...args], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export const supercred = {
  /** True when step 1 has deployed the agent pod. */
  agentDeployed(): boolean {
    return AGENT_NAMESPACES.some((ns) =>
      kubectlOk(["get", "pod", "agent-cardvault", "-n", ns]),
    );
  },

  /** True when the policy-engine backing the compliance scan is available. */
  policyEngineDeployed(): boolean {
    return kubectlOk(["get", "deployment", "policy-engine", "-n", "inf-signalloom"]);
  },

  /** The `signalloom.ai/state` label the demo steps drive. */
  agentState(): string | null {
    for (const ns of AGENT_NAMESPACES) {
      try {
        const out = execFileSync(
          "kubectl",
          [
            "--request-timeout=10s",
            "-n",
            ns,
            "get",
            "pod",
            "agent-cardvault",
            "-o",
            "jsonpath={.metadata.labels.signalloom\\.ai/state}",
          ],
          { encoding: "utf8" },
        );
        return out.trim() || null;
      } catch {
        /* try the next namespace */
      }
    }
    return null;
  },
};

// ── Multi-window contexts ──────────────────────────────────────────────────

/** Where auth.setup.ts leaves cookies + localStorage. */
const AUTH_STATE_FILE = "test-results/.auth-state.json";
/** Where auth.setup.ts dumps sessionStorage. Mirrors fixtures.ts. */
const AUTH_SESSION_FILE = "test-results/.auth-session.json";

/**
 * A second (or third) authenticated browser context.
 *
 * The two-window demo needs two genuinely independent contexts — separate
 * cookie jars, separate storage, separate render loops — because the whole
 * claim under test is that ONE browser changing the cluster is visible in
 * ANOTHER browser that nobody touched. The `context` fixture in fixtures.ts
 * only ever hands out the one Playwright made for the test, so contexts made
 * here have to reproduce what that fixture does:
 *
 *   * `storageState` restores cookies and localStorage (Playwright's own
 *     mechanism, configured per-project in playwright.config.ts);
 *   * the OIDC token lives in sessionStorage, which storageState does NOT
 *     cover (dashboard-signalloom/src/auth/oidc.tsx keeps it per-tab on
 *     purpose so a shared demo link cannot hand over a session), so it is
 *     restored by an init script — before any page script, because the app
 *     reads its token during boot and would otherwise bounce to Dex.
 *
 * Both files are written by the `setup` project. When they are absent the
 * context is still usable; login() will drive the Dex form instead.
 */
export async function newAuthedContext(
  browser: Browser,
  opts?: { demoMode?: boolean; superadmin?: boolean },
): Promise<BrowserContext> {
  const demoMode = opts?.demoMode ?? false;
  const superadmin = opts?.superadmin ?? true;

  const context = await browser.newContext({
    ...(existsSync(AUTH_STATE_FILE) ? { storageState: AUTH_STATE_FILE } : {}),
    ignoreHTTPSErrors: true,
  });

  if (existsSync(AUTH_SESSION_FILE)) {
    await context.addInitScript((json: string) => {
      try {
        for (const [key, value] of Object.entries(JSON.parse(json) as Record<string, string>)) {
          window.sessionStorage.setItem(key, value);
        }
      } catch {
        /* a malformed dump must not mask the real assertion failure */
      }
    }, readFileSync(AUTH_SESSION_FILE, "utf8"));
  }

  await context.addInitScript(
    ({ demo, admin }: { demo: boolean; admin: boolean }) => {
      try {
        window.localStorage.setItem("sl_demo_mode", demo ? "true" : "false");
        window.localStorage.setItem("signalloom.superadmin", admin ? "true" : "false");
      } catch {
        /* storage unavailable */
      }
    },
    { demo: demoMode, admin: superadmin },
  );

  return context;
}

/**
 * Count every full document load and every main-frame navigation on a page.
 *
 * This is the instrument for "the audience window updated WITHOUT a reload".
 * Asserting only that the stun became visible cannot distinguish live polling
 * from a reload the test itself issued — and a reload would make the
 * assertion pass while disproving the thing being demonstrated. So the count
 * is taken and asserted to be zero.
 *
 * Both signals are watched: `load` catches a full document reload, and
 * `framenavigated` on the main frame additionally catches SPA history
 * navigation, which would mean the page remounted rather than re-rendered.
 */
export function watchForNavigation(page: Page): { count: () => number; describe: () => string } {
  const events: string[] = [];
  page.on("load", () => events.push(`load ${page.url()}`));
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) events.push(`framenavigated ${frame.url()}`);
  });
  return {
    count: () => events.length,
    describe: () => (events.length === 0 ? "no navigation" : events.join("; ")),
  };
}

/**
 * Enable superadmin BEFORE the app boots.
 *
 * SuperCred is moving behind the superadmin flag, which defaults OFF (see
 * dashboard-signalloom/src/auth/superadmin.ts). Toggling it through the UI
 * after login does not work: the toggle reloads, which re-runs the init script,
 * which re-applies whatever it was seeded with. It has to be set as an init
 * script so it is in localStorage before the first render.
 *
 * `login()` in helpers.ts already seeds this, so this is for specs that drive
 * their own navigation — and it documents the requirement explicitly rather
 * than relying on a side effect of the shared login helper.
 */
export async function enableSuperadmin(page: Page, demoMode = false): Promise<void> {
  await page.addInitScript((demo: boolean) => {
    try {
      window.localStorage.setItem("signalloom.superadmin", "true");
      window.localStorage.setItem("sl_demo_mode", demo ? "true" : "false");
    } catch {
      /* storage unavailable */
    }
  }, demoMode);
}
