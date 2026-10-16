import { expect, test, type ConsoleMessage } from "@playwright/test";
import { config, login } from "./helpers";

/**
 * Proves the live connector flow against a REAL Anthropic Claude connector in
 * the deployed cluster — the thing "are there tests for this?" was actually
 * asking about.
 *
 * WHY THIS EXISTS
 *
 * `connectorsClient.remoteAgents.test.ts` and its siblings stub the provider
 * HTTP call, so they prove the frontend parses a response correctly. None of
 * them prove the credentials stored for this tenant's Anthropic Claude
 * connector still work from the deployed pod, that the remote-agents sync
 * loop is actually running, or that the SSE stream the dashboard depends on
 * for live updates is reachable through the Gateway. A unit test cannot prove
 * any of that — only a real HTTP round trip from a real browser against the
 * real cluster can.
 *
 * SCOPE
 *
 * This is read-only. It never types, logs or screenshots a credential — the
 * "Test Connection" click exercises the STORED-connector route
 * (`ConnectorConfigureModal.handleTest` with every field left blank, which
 * sends `credentials: {}` and lets the server use what it already holds; see
 * `src/components/ConnectorConfigureModal.tsx:106-113`). It never clicks
 * "Claim" on a discovered agent — there is no unclaim route, and claiming
 * would mutate the principal's tenant permanently.
 *
 * OPT-IN
 *
 * Gated on `LIVE_PROVIDER=1`, the same pattern `docs` and
 * `agentmaxxing-demo-console` use in playwright.config.ts: this spec's
 * precondition (a tenant with a configured, connected, successfully-synced
 * Anthropic Claude connector) is not something `make acceptance-test` can
 * provide on its own, so an unconditional project would redden the default
 * lane for a reason unrelated to any assertion here.
 *
 * RUN
 *
 *   LIVE_PROVIDER=1 DASHBOARD_URL=https://ftna-signalloom.taild4da3.ts.net \
 *     bunx playwright test --project=live-provider
 */

// Allow-listed console noise. Every entry needs a reason; "it just isn't an
// error" is not one. See live-data.spec.ts's ALLOWLIST for the same
// discipline on network responses.
const CONSOLE_ALLOWLIST: RegExp[] = [
  // helpers.ts `login()` documents the mechanism: the dashboard mounts its
  // providers before the OIDC token has resolved, so the first one or more
  // calls to /api/v1/features take an unauthenticated 401 before the retry
  // succeeds once the token lands. The user never sees it — the flags arrive
  // and the page renders. If a browser-logged resource failure for that one
  // path surfaces here, it is this known pre-auth race, not a defect.
  /\/api\/v1\/features.*401/,
];

function isAllowlisted(message: string): boolean {
  return CONSOLE_ALLOWLIST.some((re) => re.test(message));
}

// A browser-logged "Failed to load resource" console message carries the
// status in `m.text()` but the URL only in `m.location().url` — the two never
// share one string. Join them before matching so the allowlist regex (which
// needs both) actually has something to match against.
function consoleEntryText(m: ConsoleMessage): string {
  const loc = m.location();
  return `${loc?.url ?? ""} ${m.text()}`;
}

test.describe("Live Anthropic Claude connector", () => {
  test("stored credentials verify, remote agents sync, the event stream is live, and Discovery reflects the source", async ({
    page,
  }) => {
    const consoleErrors: string[] = [];
    page.on("console", (m: ConsoleMessage) => {
      const entry = consoleEntryText(m);
      if (m.type() === "error" && !isAllowlisted(entry)) {
        consoleErrors.push(`console: ${entry}`);
      }
    });
    page.on("pageerror", (e) => {
      if (!isAllowlisted(e.message)) consoleErrors.push(`pageerror: ${e.message}`);
    });

    // No fixtures: every assertion below must observe the real backend.
    await login(page, { demoMode: false });

    // ── 1. Settings › Connectors: Anthropic Claude is connected, and its
    //      stored-connector Test returns a verified result with no key typed.
    await page.goto(`${config.base}/settings?tab=connectors`);
    await expect(page.getByTestId("settings-tabpanel-connectors")).toBeVisible({ timeout: 15_000 });

    // `syncStatusText` in Settings.tsx is "Synced" or "Not yet scanned" only
    // when `connector.status === 'connected'` — "Not configured" and
    // "Disconnected" are the only other values this pill ever renders. This
    // is the one unique-by-provider testid on the row, so it proves
    // "connected" without having to scope an ancestor on inline styles.
    await expect(page.getByTestId("sync-status-claude")).toHaveText(/Synced|Not yet scanned/, {
      timeout: 15_000,
    });

    await page.getByTestId("configure-connector-claude").click();

    // No credentials typed: the modal must be offering to keep the server's
    // stored set, not asking for a fresh one.
    await expect(page.getByTestId("connector-stored-credentials-note")).toBeVisible();

    await page.getByTestId("btn-modal-test-connection").click();
    await expect(page.getByTestId("test-connection-success")).toBeVisible({ timeout: 30_000 });

    await page.getByRole("button", { name: "Close" }).click();

    // ── 2 & 3. Navigate to the Claude remote-environment console. This is the
    //      page that subscribes to remote agents (GET .../remote-agents) and
    //      opens the shared SSE connection (GET /api/connectors/stream) — see
    //      useConnectorStream.ts. Capture both responses off that one
    //      navigation rather than guessing when they fire.
    const [remoteAgentsResponse, streamResponse] = await Promise.all([
      page.waitForResponse(
        (r) =>
          /\/api\/connectors\/claude\/remote-agents(\?|$)/.test(r.url()) &&
          r.request().method() === "GET",
      ),
      page.waitForResponse((r) => /\/api\/connectors\/stream(\?|$)/.test(r.url())),
      page.getByTestId("view-environment-claude").click(),
    ]);

    expect(remoteAgentsResponse.ok(), `GET .../remote-agents returned ${remoteAgentsResponse.status()}`).toBeTruthy();
    const snapshot = await remoteAgentsResponse.json();
    expect(
      Array.isArray(snapshot.agents) ? snapshot.agents.length : 0,
      `expected >=1 remote agent, got: ${JSON.stringify(snapshot.agents)}`,
    ).toBeGreaterThanOrEqual(1);
    expect(snapshot.sync_state?.last_success_at, "sync_state.last_success_at must be set").toBeTruthy();
    expect(snapshot.sync_state?.last_error, "sync_state.last_error must be null").toBeNull();

    expect(streamResponse.status(), "GET /api/connectors/stream must respond 200").toBe(200);
    expect(
      streamResponse.headers()["content-type"] ?? "",
      "the connector stream must be served as text/event-stream",
    ).toContain("text/event-stream");

    // The rendered panel must agree with the wire response: no sync error
    // surfaced, and the sync-state line never falls back to the raw
    // "Sync mode: <mode>" phrase (that fallback only fires for a mode this
    // backend should never report for a healthy live/poll connector).
    await expect(page.getByTestId("remote-agents-panel")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByTestId("remote-sync-error")).not.toBeVisible();
    const syncStateText = await page.getByTestId("remote-sync-state").innerText();
    expect(syncStateText, `remote-sync-state read: ${syncStateText}`).not.toContain("Sync mode:");

    // ── 4. Discovery: at least one row sourced from Anthropic Claude, with
    //      either an unclaimed "Claim" control or an already-"Claimed →" link
    //      — never clicked, since there is no unclaim route and clicking
    //      Claim would mutate the principal's tenant permanently. The source
    //      card's sync badge must read "Polling every …" or "Live", never the
    //      raw "Sync mode:" fallback.
    await page.goto(`${config.base}/discovery`);
    await expect(page.getByTestId("discovery-sources")).toBeVisible({ timeout: 15_000 });

    const claudeSourceSync = page.getByTestId("discovery-source-claude-sync");
    await expect(claudeSourceSync).toBeVisible({ timeout: 15_000 });
    const sourceSyncText = await claudeSourceSync.innerText();
    expect(sourceSyncText, `discovery-source-claude-sync read: ${sourceSyncText}`).toMatch(/^(Polling every |Live$)/);
    expect(sourceSyncText).not.toContain("Sync mode:");

    const claudeRow = page
      .locator('tr[data-testid^="discovery-row-"]')
      .filter({ hasText: "Anthropic Claude" })
      .first();
    await expect(claudeRow, "expected at least one Discovery row sourced from Anthropic Claude").toBeVisible({
      timeout: 15_000,
    });
    const claimOrClaimed = claudeRow
      .locator('[data-testid^="claim-remote-btn-"]')
      .or(claudeRow.locator('[data-testid^="remote-claimed-link-"]'));
    await expect(
      claimOrClaimed.first(),
      "expected the Anthropic Claude row to carry a Claim button or a Claimed -> link",
    ).toBeVisible({ timeout: 15_000 });

    // ── 5. No unexpected console errors anywhere in the flow above.
    expect(consoleErrors, `unexpected console errors: ${consoleErrors.join(" | ")}`).toEqual([]);
  });
});
