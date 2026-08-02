/**
 * Credential issue → revoke against the LIVE API.
 *
 * The dashboard's "Manage Credentials ▾" menu called
 * POST /api/agents/{id}/credentials/revoke, which no service implemented — the
 * path existed in exactly one file in the repo, the API client. This spec is
 * the regression guard for that: it runs with demo mode OFF, so every
 * assertion below is served by the FastAPI app and Postgres, not by
 * src/api/fakeData.ts. A fixture-backed run would pass even if the endpoint
 * were deleted again, which is precisely the failure this file exists to catch.
 *
 * Agent-id shape matters. GET /api/agents merges k8s-discovered agents
 * (synthetic ids like `agent-inventory`) with agent_registry rows (UUID ids).
 * Credentials are a foreign key to the registry, so only UUID-backed agents can
 * hold one; the endpoints fail closed with a 404 for the rest rather than
 * reporting a revoke count over rows that were never stored. The spec therefore
 * selects its subject by id shape and skips — rather than fails — when the
 * live estate has no registry-backed agent, in the same SKIP-not-fail spirit as
 * `guards` in helpers.ts.
 */
import { expect } from "@playwright/test";
import { test } from "./fixtures";
import { login } from "./helpers";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Only these two states render the credential menu — see AgentHeader. */
const CREDENTIABLE_STATES = new Set(["enrolled", "active"]);

/**
 * Id of a registry-backed agent that can actually hold a credential, read from
 * the live GET /api/agents response the page issues on load. Null if none.
 *
 * Two filters, both load-bearing. The id must be a UUID, because
 * agent_credentials is a foreign key to agent_registry and the k8s-discovered
 * half of the list (agent-black-knight, agent-cardvault, …) has no registry
 * row. The lifecycle state must be enrolled or active, because AgentHeader
 * renders CredentialActionsMenu for those two states only — the live estate's
 * first UUID agent is suspended, so picking merely the first would skip on a
 * missing button and report green having asserted nothing.
 *
 * Deliberately not scraped from the DOM: agent rows on /agents are table rows
 * with an onClick that calls navigate(), not anchors, so there is no href to
 * locate by.
 */
async function firstRegistryAgentId(page: import("@playwright/test").Page): Promise<string | null> {
  const origin = new URL(page.url()).origin;
  const listed = page.waitForResponse(
    (r) => /\/api\/agents(\?|$)/.test(r.url()) && r.request().method() === "GET",
    { timeout: 20_000 },
  );
  await page.goto(`${origin}/agents`, { waitUntil: "domcontentloaded" });

  const response = await listed.catch(() => null);
  if (response === null || response.status() !== 200) return null;

  const payload = (await response.json()) as {
    agents?: Array<{ id?: unknown; lifecycle_state?: unknown }>;
  };
  if (!Array.isArray(payload.agents)) return null;

  for (const agent of payload.agents) {
    if (typeof agent.id !== "string" || !UUID.test(agent.id)) continue;
    if (typeof agent.lifecycle_state !== "string") continue;
    if (CREDENTIABLE_STATES.has(agent.lifecycle_state)) return agent.id;
  }
  return null;
}

/** Open the credential dropdown. The trigger carries a ▾ glyph, so match loosely. */
async function openCredentialMenu(page: import("@playwright/test").Page): Promise<void> {
  await page.getByRole("button", { name: /manage credentials/i }).click();
}

test.describe("agent credential lifecycle (live API)", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("issues a credential and then revokes it through the live endpoint", async ({ page }) => {
    const agentId = await firstRegistryAgentId(page);
    test.skip(agentId === null, "no enrolled/active agent_registry-backed (UUID) agent in the live estate");

    const origin = new URL(page.url()).origin;
    await page.goto(`${origin}/agents/${agentId}`, { waitUntil: "domcontentloaded" });

    // The menu only renders for enrolled/active agents (AgentDetailPage header).
    const menu = page.getByRole("button", { name: /manage credentials/i });
    test.skip(
      !(await menu.isVisible().catch(() => false)),
      "subject agent is not in a lifecycle state that permits credential actions",
    );

    // ── Issue ────────────────────────────────────────────────────────────────
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /issue credential/i }).click();

    const issueDialog = page.getByRole("dialog");
    await expect(issueDialog).toBeVisible();
    const issueResponse = page.waitForResponse(
      (r) => /\/api\/agents\/.+\/credentials$/.test(r.url()) && r.request().method() === "POST",
    );
    await issueDialog.getByRole("button", { name: /^issue credential$/i }).click();

    // Served by the live API, so a 200 here is the endpoint, not a fixture.
    expect((await issueResponse).status()).toBe(200);

    // Show-once token is rendered and never written to browser storage.
    await expect(issueDialog.getByText(/only time this token will be shown/i)).toBeVisible();
    const persisted = await page.evaluate(() =>
      Object.keys(window.localStorage).some((k) => window.localStorage.getItem(k)?.includes("demo.")),
    );
    expect(persisted, "an issued token must never be persisted in browser storage").toBe(false);

    await issueDialog.getByRole("button", { name: /saved it/i }).click();

    // ── Revoke ───────────────────────────────────────────────────────────────
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();

    const revokeDialog = page.getByRole("dialog");
    await expect(revokeDialog).toBeVisible();
    const revokeResponse = page.waitForResponse(
      (r) => r.url().includes("/credentials/revoke") && r.request().method() === "POST",
    );
    await revokeDialog.getByRole("button", { name: /revoke all credentials/i }).click();

    const revoked = await revokeResponse;
    expect(
      revoked.status(),
      "POST /api/agents/{id}/credentials/revoke must be served by the live API, not 404",
    ).toBe(200);

    const body = (await revoked.json()) as { agent_id: string; name: string; tokens_revoked: number };
    expect(body).toHaveProperty("tokens_revoked");
    // At least the credential this test just issued.
    expect(body.tokens_revoked).toBeGreaterThanOrEqual(1);

    await expect(page.getByText(/credentials revoked/i)).toBeVisible();
  });

  test("a second revoke reports nothing to revoke rather than failing", async ({ page }) => {
    const agentId = await firstRegistryAgentId(page);
    test.skip(agentId === null, "no enrolled/active agent_registry-backed (UUID) agent in the live estate");

    const origin = new URL(page.url()).origin;
    await page.goto(`${origin}/agents/${agentId}`, { waitUntil: "domcontentloaded" });

    const menu = page.getByRole("button", { name: /manage credentials/i });
    test.skip(
      !(await menu.isVisible().catch(() => false)),
      "subject agent is not in a lifecycle state that permits credential actions",
    );

    // First revoke clears whatever is outstanding; its own count is not asserted
    // because the preceding test may or may not have run against this agent.
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();
    let dialog = page.getByRole("dialog");
    await dialog.getByRole("button", { name: /revoke all credentials/i }).click();
    await expect(page.getByText(/credentials revoked/i)).toBeVisible();
    await dialog.getByRole("button", { name: /^close$/i }).click();

    // Second revoke: zero active credentials is a 200 with a zero count, not an
    // error. The dashboard renders that as "nothing to revoke".
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();
    dialog = page.getByRole("dialog");
    const second = page.waitForResponse(
      (r) => r.url().includes("/credentials/revoke") && r.request().method() === "POST",
    );
    await dialog.getByRole("button", { name: /revoke all credentials/i }).click();

    const response = await second;
    expect(response.status()).toBe(200);
    expect(((await response.json()) as { tokens_revoked: number }).tokens_revoked).toBe(0);
    await expect(page.getByText(/nothing to revoke/i)).toBeVisible();
  });
});
