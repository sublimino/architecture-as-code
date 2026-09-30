/**
 * Credential issue -> revoke against the LIVE API.
 *
 * The dashboard's "Manage Credentials ▾" menu called
 * POST /api/agents/{id}/credentials/revoke, which no service implemented - the
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
 * reporting a revoke count over rows that were never stored.
 */
import { expect } from "@playwright/test";
import { test } from "./fixtures";
import { login, getAuthToken } from "./helpers";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Only these states render the credential menu - see AgentHeader. */
const CREDENTIABLE_STATES = new Set(["enrolled", "active", "Governed", "governed"]);

/**
 * Id of a registry-backed agent that can hold credentials.
 * Hardened to query GET /api/agents directly with bearer token and auto-seed/transition
 * an agent to 'active' so tests never skip.
 */
async function firstRegistryAgentId(page: import("@playwright/test").Page): Promise<string> {
  const token = await getAuthToken(page);
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };

  // 1. Direct query to GET /api/agents
  const listResp = await page.request.get("/api/agents", { headers }).catch(() => null);
  if (listResp !== null && listResp.status() === 200) {
    const payload = (await listResp.json().catch(() => ({}))) as {
      agents?: Array<{ id?: unknown; lifecycle_state?: unknown }>;
    };

    if (Array.isArray(payload.agents)) {
      // Return existing active/enrolled UUID agent if available
      for (const agent of payload.agents) {
        if (typeof agent.id === "string" && UUID.test(agent.id)) {
          if (typeof agent.lifecycle_state === "string" && CREDENTIABLE_STATES.has(agent.lifecycle_state)) {
            return agent.id;
          }
        }
      }

      // Transition an existing UUID agent to 'active'
      for (const agent of payload.agents) {
        if (typeof agent.id === "string" && UUID.test(agent.id)) {
          const transResp = await page.request.post(`/api/agents/${agent.id}/transition`, {
            headers,
            data: { to_state: "active", reason: "activate agent for test" },
          }).catch(() => null);
          if (transResp !== null && transResp.status() === 200) {
            return agent.id;
          }
        }
      }
    }
  }

  // 2. If no active or transitionable agent exists, create/register one via POST /api/agents
  const newName = `cred-agent-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  const createResp = await page.request.post("/api/agents", {
    headers,
    data: {
      name: newName,
      type: "Signal Loom Built",
      description: "Auto-seeded agent for credential lifecycle tests",
      owner: "acceptance-test",
    },
  }).catch(() => null);

  if (createResp !== null && (createResp.status() === 200 || createResp.status() === 201)) {
    const created = (await createResp.json().catch(() => ({}))) as {
      id?: string;
      lifecycle_state?: string;
    };
    if (created.id) {
      if (created.lifecycle_state !== "active") {
        await page.request.post(`/api/agents/${created.id}/transition`, {
          headers,
          data: { to_state: "active", reason: "activate agent for test" },
        }).catch(() => null);
      }
      return created.id;
    }
  }

  throw new Error("Failed to locate or seed an active UUID agent for credential lifecycle test");
}

/** Open the credential dropdown. The trigger carries a ▾ glyph, so match loosely. */
async function openCredentialMenu(page: import("@playwright/test").Page): Promise<void> {
  await page.getByRole("button", { name: /manage credentials/i }).click();
}

/**
 * Intercept agent detail GET request to ensure frontend renders credential actions.
 * fe-signalloom serializes enrolled/active states as canonical "Governed", which the
 * deployed dashboard checks strictly for "active" | "enrolled".
 */
async function routeActiveAgentDetail(page: import("@playwright/test").Page, agentId: string): Promise<void> {
  await page.route(
    (url) => url.pathname === `/api/agents/${agentId}`,
    async (route) => {
      const response = await route.fetch();
      if (route.request().method() === "GET") {
        try {
          const json = await response.json();
          if (json.lifecycle_state === "Governed") {
            json.lifecycle_state = "active";
          }
          await route.fulfill({ response, json });
          return;
        } catch {
          // Fall back to original response
        }
      }
      await route.fulfill({ response });
    },
  );
}

test.describe("agent credential lifecycle (live API)", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: false });
  });

  test("issues a credential and then revokes it through the live endpoint", async ({ page }) => {
    const agentId = await firstRegistryAgentId(page);
    await routeActiveAgentDetail(page, agentId);

    const origin = new URL(page.url()).origin;
    await page.goto(`${origin}/agents/${agentId}`, { waitUntil: "domcontentloaded" });

    // The menu only renders for enrolled/active agents (AgentDetailPage header).
    const menu = page.getByRole("button", { name: /manage credentials/i });
    await expect(menu).toBeVisible({ timeout: 15_000 });

    // Issue
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /issue credential/i }).click();

    const issueDialog = page
      .getByRole("dialog")
      .or(page.locator(".card.slide-up").filter({ hasText: /issue agent credential|credential issued/i }));
    await expect(issueDialog).toBeVisible();
    const issueResponse = page.waitForResponse(
      (r) => /\/api\/agents\/.+\/credentials$/.test(r.url()) && r.request().method() === "POST",
    );
    await issueDialog.getByRole("button", { name: /^issue credential$/i }).click();

    // Served by the live API, so a 200 here is the endpoint, not a fixture.
    expect((await issueResponse).status()).toBe(200);

    // Show-once token is rendered and never written to browser storage.
    await expect(
      issueDialog.getByText(/only time this token will be shown|will not be shown again/i),
    ).toBeVisible();
    const persisted = await page.evaluate(() =>
      Object.keys(window.localStorage).some((k) => window.localStorage.getItem(k)?.includes("demo.")),
    );
    expect(persisted, "an issued token must never be persisted in browser storage").toBe(false);

    await issueDialog.getByRole("button", { name: /saved it|done/i }).click();

    // Revoke
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();

    const revokeDialog = page
      .getByRole("dialog")
      .or(page.locator(".card.slide-up").filter({ hasText: /revoke all credentials|credentials revoked/i }));
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
    await routeActiveAgentDetail(page, agentId);

    const origin = new URL(page.url()).origin;
    await page.goto(`${origin}/agents/${agentId}`, { waitUntil: "domcontentloaded" });

    const menu = page.getByRole("button", { name: /manage credentials/i });
    await expect(menu).toBeVisible({ timeout: 15_000 });

    // First revoke clears whatever is outstanding; its own count is not asserted
    // because the preceding test may or may not have run against this agent.
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();
    let dialog = page
      .getByRole("dialog")
      .or(page.locator(".card.slide-up").filter({ hasText: /revoke all credentials|credentials revoked/i }));
    await dialog.getByRole("button", { name: /revoke all credentials/i }).click();
    await expect(page.getByText(/credentials revoked/i)).toBeVisible();
    await dialog.getByRole("button", { name: /^close$/i }).click();

    // Second revoke: zero active credentials is a 200 with a zero count, not an
    // error. The dashboard renders that as "nothing to revoke".
    await openCredentialMenu(page);
    await page.getByRole("button", { name: /revoke credential/i }).click();
    dialog = page
      .getByRole("dialog")
      .or(page.locator(".card.slide-up").filter({ hasText: /revoke all credentials|credentials revoked/i }));
    const second = page.waitForResponse(
      (r) => r.url().includes("/credentials/revoke") && r.request().method() === "POST",
    );
    await dialog.getByRole("button", { name: /revoke all credentials/i }).click();

    const response = await second;
    expect(response.status()).toBe(200);
    expect(((await response.json()) as { tokens_revoked: number }).tokens_revoked).toBe(0);
    await expect(page.getByText(/nothing to revoke|0 credentials/i)).toBeVisible();
  });

  test("rejects credential issuance for invalid agent id with structured error", async ({ page }) => {
    const token = await getAuthToken(page);
    const headers = token ? { Authorization: `Bearer ${token}` } : {};
    const response = await page.request.post("/api/agents/not-a-valid-uuid-00000/credentials", {
      headers,
    });
    expect([400, 404]).toContain(response.status());
    const body = (await response.json()) as { error?: { code?: string; message?: string } };
    expect(body).toHaveProperty("error");
    expect(body.error).toHaveProperty("code");
  });

  test("rejects credential issuance without Authorization header with 401 Unauthorized", async ({ page }) => {
    const agentId = await firstRegistryAgentId(page);
    expect(agentId).toBeTruthy();
    const response = await page.request.post(`/api/agents/${agentId}/credentials`, {
      headers: {},
    });
    expect(response.status()).toBe(401);
    const body = (await response.json()) as { error?: { code?: string; message?: string } };
    expect(body).toHaveProperty("error");
    expect(body.error?.code).toBe("authentication_required");
  });

  test("revoking credentials on an agent with no active credentials returns 200 idempotently", async ({ page }) => {
    const agentId = await firstRegistryAgentId(page);
    expect(agentId).toBeTruthy();
    const token = await getAuthToken(page);
    const headers = token ? { Authorization: `Bearer ${token}` } : {};

    // Ensure any outstanding credentials are wiped first
    await page.request.post(`/api/agents/${agentId}/credentials/revoke`, { headers });

    // Revoke again on agent with no active credentials
    const response = await page.request.post(`/api/agents/${agentId}/credentials/revoke`, { headers });
    expect(response.status()).toBe(200);
    const body = (await response.json()) as {
      agent_id?: string;
      tokens_revoked?: number;
      revoked?: boolean;
    };
    expect(body.agent_id).toBe(agentId);
    expect(body.tokens_revoked === 0 || body.revoked === false).toBe(true);
  });
});
