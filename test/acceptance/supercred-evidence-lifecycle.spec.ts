/**
 * The Credential Lifecycle card, driven from the instructor controls.
 *
 * supercred-ui-lifecycle.spec.ts already runs every phase from the instructor
 * UI and checks the audience pages — Agents, Credential Inventory, Compliance.
 * It never touches a single `evidence-*` testid, so the one card on the page
 * that claims to report OBSERVED cluster state had no end-to-end coverage at
 * all. That gap is how the panel shipped calling
 * `/demo-api/evidence` with no Authorization header: the endpoint
 * sits behind `authenticated_tenant`, returned 401, and the card fell back to
 * "No evidence has been collected yet." — which reads exactly like "there is no
 * credential chain" rather than "we were not allowed to look".
 *
 * Two properties are under test here, and they are different:
 *
 *   1. The request is AUTHENTICATED. Asserted on the wire, not inferred from
 *      the rendering, because a 401 and an genuinely-empty chain look the same
 *      on screen — which is the entire defect.
 *   2. The lifecycle re-probes after the instructor runs phase 2. Step 1 has
 *      already deployed the services and seeded credentials, so phase 2 need
 *      not change an already-observed row; the test proves a fresh,
 *      authenticated observation rather than inventing progress.
 */
import { test, expect, type Page, type Request } from "@playwright/test";
import { login } from "./helpers";
import { navigateTo, newAuthedContext } from "./supercred-helpers";

test.describe.configure({ mode: "serial", timeout: 30 * 60_000 });

const EVIDENCE_URL = /\/demo-api\/evidence/;
const RUN_STATUS = '[data-testid="supercred-run-status"]';
const RUN_STEP = (step: string) => `[data-testid="supercred-run-step-${step}"]`;
const RESET = '[data-testid="supercred-reset"]';
const RESET_CONFIRM = '[data-testid="supercred-reset-confirm"]';

async function runStep(page: Page, step: string): Promise<void> {
  await page.locator(RUN_STEP(step)).click();
  const status = page.locator(RUN_STATUS);
  await expect(status).toContainText(new RegExp(`Step\\s+${step}\\s+\\(step\\)\\s+—\\s+(?:running|succeeded)`), { timeout: 30_000 });
  await expect(status).toContainText(new RegExp(`Step\\s+${step}\\s+\\(step\\)\\s+—\\s+succeeded`), { timeout: 10 * 60_000 });
}

async function reset(page: Page): Promise<void> {
  await expect(page.locator(RESET)).toBeVisible({ timeout: 30_000 });
  await page.locator(RESET).click();
  await page.locator(RESET_CONFIRM).click();
  const status = page.locator(RUN_STATUS);
  await expect(status).toContainText(/Step\s+5\s+\(reset\)\s+—\s+succeeded/, { timeout: 10 * 60_000 });
}

/**
 * The panel only mounts once an activeAgent exists (SuperCredPage.tsx), which
 * needs the agent list loaded. The button carries no testid, so it is located
 * by its accessible name.
 */
async function mountLifecycle(page: Page): Promise<void> {
  await page.getByRole("button", { name: /refresh agents/i }).click();
  await expect(page.getByTestId("credential-evidence-panel")).toBeVisible({ timeout: 60_000 });
}

/** State labels as the card renders them, keyed by step number. */
async function rowStates(page: Page): Promise<Record<number, string>> {
  const rows = page.locator('[data-testid^="evidence-step-"]');
  const out: Record<number, string> = {};
  for (let i = 0; i < (await rows.count()); i += 1) {
    const id = await rows.nth(i).getAttribute("data-testid");
    const n = Number(id?.replace("evidence-step-", ""));
    out[n] = ((await page.getByTestId(`evidence-state-${n}`).textContent()) ?? "").trim();
  }
  return out;
}

test("the credential lifecycle is authenticated and tracks the instructor controls", async ({ browser }) => {
  const ctx = await newAuthedContext(browser, { demoMode: false, superadmin: true });
  try {
    const page = await ctx.newPage();

    // Record every evidence request on the wire. An assertion on the rendering
    // alone cannot tell an authenticated empty chain from a rejected session.
    const evidenceRequests: Request[] = [];
    page.on("request", (r) => {
      if (EVIDENCE_URL.test(r.url())) evidenceRequests.push(r);
    });
    const unauthorised: number[] = [];
    page.on("response", async (r) => {
      if (EVIDENCE_URL.test(r.url()) && r.status() === 401) unauthorised.push(r.status());
    });

    await login(page, { demoMode: false });
    await navigateTo(page, "/supercred");

    await reset(page);
    await runStep(page, "1");
    await mountLifecycle(page);

    // ── Property 1: the request carries a bearer token ────────────────────
    expect(evidenceRequests.length, "the panel must actually call the evidence endpoint").toBeGreaterThan(0);
    for (const req of evidenceRequests) {
      expect(
        req.headers()["authorization"] ?? "",
        "every evidence request must be authenticated — an unauthenticated one renders as an empty chain",
      ).toMatch(/^Bearer .+/);
    }
    expect(unauthorised, "no evidence request may come back 401").toHaveLength(0);

    // ...and the card must not be reporting the empty state it shows on 401.
    await expect(page.getByTestId("evidence-headline")).not.toHaveText(/No evidence has been collected yet/i);
    await expect(page.getByTestId("evidence-error")).toHaveCount(0);
    await expect(page.getByTestId("evidence-step-1")).toBeVisible({ timeout: 60_000 });
    const afterDeploy = await rowStates(page);
    expect(Object.keys(afterDeploy).length, "the chain has six steps").toBe(6);

    // Deployment must produce at least the agent observation.
    expect(afterDeploy[1]).toMatch(/observed/);

    // ── Property 2: phase 2 causes a fresh observation ────────────────────
    const beforePhaseTwo = evidenceRequests.length;
    await runStep(page, "2");
    await page.getByTestId("evidence-refresh").click();
    await expect.poll(() => evidenceRequests.length, { timeout: 120_000 }).toBeGreaterThan(beforePhaseTwo);
    await expect(page.getByTestId("evidence-step-1")).toBeVisible({ timeout: 60_000 });

    const afterChain = await rowStates(page);
    expect(page.getByTestId("evidence-error")).toHaveCount(0);
    expect(Object.keys(afterChain).length, "the refresh keeps six evidence steps").toBe(6);
    expect(afterChain[1]).toMatch(/observed/);

    // Re-check must re-probe, not replay: a second click issues another
    // authenticated request.
    const before = evidenceRequests.length;
    await page.getByTestId("evidence-refresh").click();
    await expect.poll(() => evidenceRequests.length, { timeout: 120_000 }).toBeGreaterThan(before);
    const latest = evidenceRequests.at(-1)
    expect(latest, "Re-check must issue a fresh request").toBeDefined()
    expect(latest?.headers()["authorization"] ?? "").toMatch(/^Bearer .+/);

    // ── Anti-assertions: no fabricated progress ───────────────────────────
    const body = (await page.getByTestId("credential-evidence-panel").innerText()).toLowerCase();
    expect(body, 'the card must never render "completed" — it has no such state').not.toContain("completed");
  } finally {
    await ctx.close();
  }
});
