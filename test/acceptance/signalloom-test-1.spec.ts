import { expect, test } from "./fixtures";

// CI/local-kind default: Gateway port-forwarded to :30754 via host-resolver-rules (resolves
// to 127.0.0.1 anywhere). Matches Dex issuer + redirect URI + auth.setup.ts.
const DASHBOARD_URL =
  process.env.DASHBOARD_URL ?? "https://dashboard.osramp.acme.local:30754";
const API_URL = process.env.SIGNALLOOM_API_URL ?? DASHBOARD_URL;
const DEX_URL = process.env.SIGNALLOOM_DEX_URL ?? "http://127.0.0.1:15556";
const DEX_DEMO_PASSWORD = process.env.DEX_DEMO_PASSWORD ?? "demo-user";

test.setTimeout(Number(process.env.SIGNALLOOM_TEST_TIMEOUT ?? 30_000));

const pages = [
  ["Dashboard root", null, "Agents"],
  // "Governed" was a tab label on AgentsPage; GovernedTab is now rendered
  // unconditionally with no visible tab UI, so the literal text never
  // appears — "Register Agent" is the stable content marker smoke.spec.ts
  // already relies on for this page.
  ["Agents", "Agents", "Register Agent"],
  ["Compliance", "Compliance", "Compliance"],
  ["Audit Trail", "Audit Trail", "Audit Trail"],
  ["Cryptography", "Cryptography", "Cryptography"],
  ["Federated Services", "Federated Services", "Federated Services"],
  ["Collusion & Access", "Collusion & Access", "Collusion"],
  ["Settings", "Settings", "Settings"],
] as const;

test.describe("SignalLoom TEST-1 dashboard matrix", () => {
  for (const [journey, nav, title] of pages) {
    test(`${journey} opens through the integrated dashboard`, async ({ page }) => {
      await page.goto(DASHBOARD_URL);
      await expect(page.getByText("Agents", { exact: false }).first()).toBeVisible({ timeout: 10_000 });
      if (nav !== null) {
        // exact:true — the sidebar now also has a "Policy Compliance" link
        // (docs/policy-as-versioned-code), whose accessible name contains
        // "Compliance" as a substring and made the default non-exact match
        // ambiguous (strict-mode violation) for nav === "Compliance".
        await page.getByRole("link", { name: nav, exact: true }).click();
      }
      await expect(page.getByText(title, { exact: false }).first()).toBeVisible();
    });
  }

});

test.describe("SignalLoom TEST-1 Dex and API contracts", () => {
  test("Dex login token maps demo user to local tenant", async ({ page, request }) => {
    // The auth.setup project already authenticated via Dex. This test verifies
    // the resulting token (stored in localStorage by react-oidc-context) is
    // accepted by the API and returns agent data for the demo tenant.
    await page.goto(DASHBOARD_URL);
    await page.waitForURL(/\/agents/, { timeout: 15_000 });

    const idToken = await page.evaluate(() => {
      for (const [key, value] of Object.entries(localStorage)) {
        if (key.startsWith("oidc.user:")) {
          try { return JSON.parse(value).id_token; } catch { /* skip */ }
        }
      }
      return null;
    });
    expect(idToken).toBeTruthy();

    // Verify the token is accepted by the API (200, not 401).
    const api = await request.get(`${API_URL}/api/agents`, {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    expect(api.status()).toBe(200);
  });

  test("dashboard sign out clears the session and redirects to Dex", async ({ page }) => {
    await page.goto(DASHBOARD_URL);
    await page.locator('button[title="Sign out"]').click();
    await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  });

});
