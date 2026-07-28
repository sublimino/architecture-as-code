import { expect, test } from "./fixtures";

const DASHBOARD_URL = process.env.DASHBOARD_URL ?? "https://127.0.0.1:18443";
const API_URL = process.env.SIGNALLOOM_API_URL ?? DASHBOARD_URL;
const DEX_URL = process.env.SIGNALLOOM_DEX_URL ?? "http://127.0.0.1:15556";

test.setTimeout(Number(process.env.SIGNALLOOM_TEST_TIMEOUT ?? 30_000));

const pages = [
  ["Dashboard root", null, "Agents"],
  ["Agents", "Agents", "Governed"],
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
        await page.getByRole("link", { name: nav }).click();
      }
      await expect(page.getByText(title, { exact: false }).first()).toBeVisible();
    });
  }

});

test.describe("SignalLoom TEST-1 Dex and API contracts", () => {
  test("Dex login token maps demo user to local tenant", async ({ page, request }) => {
    let callback = "";
    await page.route("http://localhost:5173/callback**", async (route) => {
      callback = route.request().url();
      await route.fulfill({ contentType: "text/html", body: "callback captured" });
    });
    const auth = new URL("/dex/auth", DEX_URL);
    auth.searchParams.set("client_id", "signalloom-dashboard");
    auth.searchParams.set("redirect_uri", "http://localhost:5173/callback");
    auth.searchParams.set("response_type", "code");
    auth.searchParams.set(
      "scope",
      "openid profile email groups audience:server:client_id:signalloom-api",
    );
    await page.goto(auth.toString());
    await page.locator('input[name="login"]').fill("demo-user@signalloom.local");
    await page.locator('input[name="password"]').fill("password");
    await page.getByRole("button", { name: /login/i }).click();
    await expect(page.getByText("callback captured")).toBeVisible();

    const code = new URL(callback).searchParams.get("code");
    expect(code).toBeTruthy();
    const token = await request.post(`${DEX_URL}/dex/token`, {
      form: {
        grant_type: "authorization_code",
        code: code ?? "",
        redirect_uri: "http://localhost:5173/callback",
        client_id: "signalloom-dashboard",
        client_secret: "signalloom-dashboard-local-only",
      },
    });
    expect(token.ok()).toBe(true);
    const idToken = (await token.json()).id_token as string;
    const api = await request.get(`${API_URL}/api/agents`, {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    expect(api.status()).toBe(200);
    expect(await api.json()).toMatchObject({ tenant_id: "tenant-demo" });
  });

  test("dashboard logout redirects to Dex authentication", async ({ request }) => {
    const response = await request.get(`${DASHBOARD_URL}/logout`, {
      maxRedirects: 0,
    });
    expect([302, 303]).toContain(response.status());
    expect(response.headers().location).toContain("/dex/");
  });

});
