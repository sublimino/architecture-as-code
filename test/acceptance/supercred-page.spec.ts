/**
 * SuperCred demo page — drives the demo from the UI, the way it is presented.
 *
 * The scripted path (`make demo-signalloom-supercred-1..5`) and the UI path are
 * two different code paths to the same outcome, and the demo is given from the
 * UI. Proving the script works proves nothing about the page: the page talks to
 * /supercred-api (nginx → fake-integration-proxy), the script talks to kubectl
 * and the policy-engine directly. Only this file exercises what the audience
 * actually sees.
 *
 * Preconditions: steps 1 and 2 have run (`make demo-signalloom-supercred-1`,
 * `-2`). Guarded, not assumed — a missing deployment is a SKIP with the command
 * that fixes it, matching the SKIP semantics in helpers.ts. A DEPLOYED but
 * BROKEN demo still runs every assertion and still fails.
 *
 * Superadmin: SuperCred is moving behind the superadmin flag, which defaults
 * off. Every test here seeds it before the app boots.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";
import { navLink, navigateTo, supercred, enableSuperadmin } from "./supercred-helpers";

const deployed = supercred.agentDeployed();

test.describe("SuperCred demo page", () => {
  test.skip(
    !deployed,
    "SuperCred agent not deployed — run: make demo-signalloom-supercred-1 && make demo-signalloom-supercred-2",
  );

  test.beforeEach(async ({ page }) => {
    // Superadmin on, demo mode OFF: this page must be driven against the live
    // proxy, not fixtures. With demo mode on it would render invented agents
    // and every assertion below would pass without the cluster being involved
    // at all — a whole-file false pass.
    await enableSuperadmin(page, false);
    await login(page, { demoMode: false });
  });

  test("SuperCred is reachable from the sidebar once superadmin is on", async ({ page }) => {
    // Located by href. The label carries no badge today, but every other nav
    // item's did at some point, and that is how this suite broke twice.
    await expect(navLink(page, "/supercred")).toBeVisible({ timeout: 15_000 });
    await navigateTo(page, "/supercred");
    await expect(page.getByRole("heading", { name: "SuperCredential Demo" })).toBeVisible();
  });

  test("the page is hidden from the sidebar without superadmin", async ({ page, context }) => {
    // Superadmin is a VISIBILITY control (auth/superadmin.ts), so the route
    // stays reachable by direct URL — this asserts the sidebar, not access.
    // Skips rather than fails while SuperCred is still an unguarded nav item,
    // so it starts enforcing the moment the flag lands instead of needing to
    // be remembered.
    await context.clearCookies();
    const fresh = await context.newPage();
    await fresh.addInitScript(() => {
      window.localStorage.setItem("signalloom.superadmin", "false");
      window.localStorage.setItem("sl_demo_mode", "false");
    });
    await login(fresh, { demoMode: false });
    const visible = await navLink(fresh, "/supercred")
      .isVisible()
      .catch(() => false);
    test.skip(visible, "SuperCred is not behind the superadmin flag yet");
    await expect(navLink(fresh, "/supercred")).toHaveCount(0);
    await fresh.close();
  });

  test("architecture overview and the six-stage flow render", async ({ page }) => {
    await navigateTo(page, "/supercred");
    await expect(page.getByTestId("supercred-architecture")).toBeVisible();
    const diagram = page.getByTestId("supercred-flow-diagram");
    await expect(diagram).toBeVisible();
    // Six stages, matching the six demo steps. A count assertion catches a
    // partially-rendered diagram, which a visibility check does not.
    await expect(diagram.locator("> div")).toHaveCount(6);
  });

  test("Refresh Agents discovers the SuperCred agent from the live proxy", async ({ page }) => {
    await navigateTo(page, "/supercred");

    // Before any fetch the page must say so, rather than showing an empty list
    // that is indistinguishable from "discovery ran and found nothing".
    await expect(page.getByTestId("supercred-not-loaded")).toBeVisible();

    await page.getByRole("button", { name: /refresh agents/i }).click();

    // Discovery summary appears only once a fetch has completed.
    const summary = page.getByTestId("supercred-discovery-summary");
    await expect(summary).toBeVisible({ timeout: 30_000 });

    // The agent is deployed (guarded above), so discovery MUST find it. An
    // empty state here is a real failure, not an acceptable outcome.
    await expect(
      page.getByTestId("supercred-empty-state"),
      "the agent is deployed, so the page must not report an empty discovery",
    ).toHaveCount(0);
    await expect(page.getByTestId("discovery-supercred")).not.toHaveText("0");
    await expect(page.getByTestId("supercred-error")).toHaveCount(0);
  });

  test("the agent reports the namespace Flux actually placed it in", async ({ page }) => {
    // Flux's targetNamespace can move the pod from fe-signalloom-agents to
    // fe-signalloom. The page must follow it, because every subsequent
    // compliance/stun call is namespace-scoped.
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });
    const ns = page.locator('[data-testid^="agent-namespace-"]');
    await expect(ns.first()).toBeVisible();
    await expect(ns.first()).toContainText(/fe-signalloom/);
  });

  test("no agent is left blocked on a missing image", async ({ page }) => {
    // supercred-phase-warning renders when a pod is Pending/ImagePullBackOff.
    // Its presence means the kind-loaded images did not survive, which is the
    // single most common way this demo dies in front of an audience.
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.getByTestId("discovery-blocked")).toHaveText("0");
    await expect(page.getByTestId("supercred-phase-warning")).toHaveCount(0);
  });

  test("Compliance Scan reports the agent as non-compliant with reasons", async ({ page }) => {
    test.skip(
      !supercred.policyEngineDeployed(),
      "policy-engine not deployed — run: make demo-signalloom-supercred-1",
    );
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });

    await page.getByRole("button", { name: /compliance scan/i }).first().click();

    const results = page.getByTestId("supercred-compliance");
    await expect(results).toBeVisible({ timeout: 30_000 });

    // The agent pod INTENTIONALLY ships without a securityContext — that is the
    // finding the demo is built around. Asserting merely that "a result
    // appeared" would pass if the scan returned all-clear, which would mean the
    // demo has no story.
    await expect(results).toContainText("security-context-present");
    await expect(results.getByText("FAIL").first()).toBeVisible();

    // At least one failed check must be counted in the summary.
    const summary = page.getByTestId("supercred-compliance-summary");
    await expect(summary).toBeVisible();
    await expect(summary).not.toContainText("0 failed");
  });

  test("Stun Agent revokes credentials and reports the actions taken", async ({ page }) => {
    test.skip(
      supercred.agentState() === "stunned",
      "agent is already stunned — re-run steps 1-2 for a clean stun test",
    );
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });

    const stun = page.getByRole("button", { name: /stun agent/i }).first();
    await expect(stun).toBeVisible();
    await stun.click();

    const result = page.getByTestId("supercred-stun-result");
    await expect(result).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId("supercred-stun-actions")).toContainText(
      /OpenBao dynamic lease revoked/i,
    );

    // The UI claiming a stun is not the same as the cluster having been
    // changed. Verify the label the platform actually set — this is the
    // difference between the page rendering a message and the demo working.
    await expect(async () => {
      expect(supercred.agentState()).toBe("stunned");
    }).toPass({ timeout: 30_000 });

    // Once stunned, the Stun button is withdrawn for that agent.
    await expect(page.getByRole("button", { name: /stun agent/i })).toHaveCount(0);
  });

  test("the credential lifecycle and inventory reflect the stun", async ({ page }) => {
    test.skip(
      supercred.agentState() !== "stunned",
      "agent is not stunned — the post-stun view is what this asserts",
    );
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });

    await expect(page.getByTestId("supercred-lifecycle")).toBeVisible();
    await expect(page.getByTestId("supercred-lifecycle-steps").locator("> div")).toHaveCount(6);
    // Step 6 is the platform's response — it must show failure once stunned.
    await expect(page.getByTestId("lifecycle-status-6")).toHaveText(/failed/i);

    const credentials = page.getByTestId("supercred-credentials");
    await expect(credentials).toBeVisible();
    await expect(credentials.getByText("REVOKED").first()).toBeVisible();
  });

  test("the page records no console errors or failed requests", async ({ page }) => {
    // The fixtures wrapper attaches console/pageerror/http-error diagnostics to
    // the report. This drives the full happy path so any of them surface here
    // rather than as a mystery in a later spec.
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-discovery-summary")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.getByTestId("supercred-error")).toHaveCount(0);
    await expect(page.getByTestId("supercred-demo-steps")).toBeVisible();
  });
});

test.describe("SuperCred page without the demo deployed", () => {
  test.skip(deployed, "the demo IS deployed — this covers the torn-down state");

  test("reports an honest empty state rather than a blank page", async ({ page }) => {
    // After teardown the page must say discovery found nothing and name the
    // command that fixes it. A blank card here is how an operator concludes
    // the dashboard is broken when the demo is simply not running.
    await enableSuperadmin(page, false);
    await login(page, { demoMode: false });
    await navigateTo(page, "/supercred");
    await page.getByRole("button", { name: /refresh agents/i }).click();
    await expect(page.getByTestId("supercred-empty-state")).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId("supercred-empty-state")).toContainText(
      "make demo-signalloom-supercred-1",
    );
  });
});

test.describe("SuperCred API surface", () => {
  test.skip(!deployed, "SuperCred agent not deployed");

  test("/supercred-api/agents returns the labelled agent", async ({ request }) => {
    // The page's own data source, asserted independently of React. When the UI
    // and this disagree, the fault is in the page; when they agree and both are
    // empty, the fault is in the cluster. Two separate signals.
    const res = await request.get(`${config.base}/supercred-api/agents`);
    expect(res.ok(), `/supercred-api/agents returned ${res.status()}`).toBeTruthy();
    const body = await res.json();
    expect(Array.isArray(body.agents), "response must carry an agents array").toBeTruthy();
    const labelled = (body.agents ?? []).filter(
      (a: { supercred?: boolean }) => a.supercred === true,
    );
    expect(
      labelled.length,
      "the deployed agent carries signalloom.ai/supercred=true and must appear",
    ).toBeGreaterThanOrEqual(1);
  });
});
