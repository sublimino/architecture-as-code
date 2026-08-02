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
import { expect, type Page } from "@playwright/test";
import { execFileSync } from "node:child_process";

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
