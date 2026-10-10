import { execFileSync } from "node:child_process";
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";
import { newAuthedContext, supercred, watchForNavigation } from "./supercred-helpers";

test.describe.configure({ mode: "serial", timeout: 10 * 60_000 });

function isReachable(urlStr: string): boolean {
  try {
    const u = new URL(urlStr);
    const host = u.hostname;
    const port = u.port || (u.protocol === "https:" ? "443" : "80");
    execFileSync("nc", ["-z", "-w", "1", host, port], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const deployed = supercred.agentDeployed();
const reachable = isReachable(config.base);

test.describe("Fleet cascade demo: instructor window and audience window", () => {
  test.skip(
    !deployed || !reachable,
    "Fleet cascade demo requires deployed agent and reachable dashboard gateway",
  );

  test("instructor stun of cardvault triggers cascade and risk escalation in audience window, with clean topological recovery", async ({
    browser,
  }) => {
    test.setTimeout(10 * 60_000);

    const instructorCtx = await newAuthedContext(browser, { demoMode: false, superadmin: true });
    const audienceCtx = await newAuthedContext(browser, { demoMode: false, superadmin: true });

    try {
      const instructor = await instructorCtx.newPage();
      const audience = await audienceCtx.newPage();

      await Promise.all([
        login(instructor, { demoMode: false }),
        login(audience, { demoMode: false }),
      ]);

      for (const page of [instructor, audience]) {
        await expect(
          page.getByRole("heading", { name: /welcome to signal loom/i }),
          "the onboarding wizard must not be covering the app",
        ).toHaveCount(0, { timeout: 15_000 });
      }

      await Promise.all([
        instructor.goto(`/demos/fleet`, { waitUntil: "domcontentloaded" }),
        audience.goto(`/demos/fleet/audience`, { waitUntil: "domcontentloaded" }),
      ]);

      await expect(instructor.locator("[data-testid=\"fleet-demo-page\"]")).toBeVisible({
        timeout: 30_000,
      });
      await expect(audience.locator("[data-testid=\"fleet-demo-page\"]")).toBeVisible({
        timeout: 30_000,
      });

      const audienceNav = watchForNavigation(audience);

      await expect(instructor.locator("[data-testid=\"fleet-controls\"]")).toBeVisible({
        timeout: 30_000,
      });
      await expect(audience.locator("[data-testid=\"fleet-controls\"]")).toHaveCount(0);

      await expect(instructor.locator("[data-testid=\"fleet-topology\"]")).toBeVisible({
        timeout: 30_000,
      });
      await expect(audience.locator("[data-testid=\"fleet-topology\"]")).toBeVisible({
        timeout: 30_000,
      });

      // Ensure clean baseline if previous run ended in stunned state
      const cardvaultNode = instructor.locator("[data-testid=\"fleet-node-agent-cardvault\"]");
      await expect(cardvaultNode).toBeVisible({ timeout: 30_000 });
      if ((await cardvaultNode.getAttribute("data-agent-state")) === "stunned") {
        const recoverBtn = instructor.locator("[data-testid=\"fleet-recover-btn\"]");
        await expect(recoverBtn).toBeEnabled({ timeout: 15_000 });
        await recoverBtn.click();
        await expect(cardvaultNode).toHaveAttribute("data-agent-state", "active", {
          timeout: 30_000,
        });
      }

      await expect(audience.locator("[data-testid=\"fleet-risk-gauge\"]")).toBeVisible({
        timeout: 30_000,
      });
      await expect(audience.locator("[data-testid=\"fleet-risk-ale\"]")).toContainText(/(12,400|15,696)/, {
        timeout: 30_000,
      });

      await expect(audience.locator("[data-testid=\"fleet-node-agent-cardvault\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-monitor\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );

      const stunSelect = instructor.locator("[data-testid=\"fleet-stun-select\"]");
      await expect(stunSelect).toBeVisible({ timeout: 15_000 });
      await stunSelect.selectOption("agent-cardvault");

      const stunBtn = instructor.locator("[data-testid=\"fleet-stun-btn\"]");
      await expect(stunBtn).toBeEnabled({ timeout: 15_000 });
      await stunBtn.click();

      const reasonInput = instructor.locator("[data-testid=\"stun-reason-input\"]");
      await expect(reasonInput).toBeVisible({ timeout: 15_000 });
      await reasonInput.fill("Automated cascade verification test");
      const confirmBtn = instructor.getByRole("button", { name: /confirm stun/i });
      await expect(confirmBtn).toBeEnabled({ timeout: 15_000 });
      await confirmBtn.click();

      await expect(instructor.locator("[data-testid=\"fleet-stun-result\"]")).toBeVisible({
        timeout: 60_000,
      });

      await expect(audience.locator("[data-testid=\"fleet-node-agent-cardvault\"]")).toHaveAttribute(
        "data-agent-state",
        "stunned",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-txn-pipeline\"]")).toHaveAttribute(
        "data-agent-state",
        "stunned",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-llm-classifier\"]")).toHaveAttribute(
        "data-agent-state",
        "stunned",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-api-gateway\"]")).toHaveAttribute(
        "data-agent-state",
        "stunned",
        { timeout: 30_000 },
      );

      await expect(audience.locator("[data-testid=\"fleet-risk-ale\"]")).toContainText(/(847,000|1\.1M|1,072,133)/, {
        timeout: 30_000,
      });

      await expect(audience.locator("[data-testid=\"fleet-node-agent-monitor\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
      );

      const recoverBtn = instructor.locator("[data-testid=\"fleet-recover-btn\"]");
      await expect(recoverBtn).toBeEnabled({ timeout: 30_000 });
      await recoverBtn.click();

      await expect(instructor.locator("[data-testid=\"fleet-stun-result\"]")).toHaveCount(0, {
        timeout: 60_000,
      });

      await expect(audience.locator("[data-testid=\"fleet-node-agent-cardvault\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-txn-pipeline\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-llm-classifier\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );
      await expect(audience.locator("[data-testid=\"fleet-node-agent-api-gateway\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
        { timeout: 30_000 },
      );

      await expect(audience.locator("[data-testid=\"fleet-risk-ale\"]")).toContainText(/(12,400|15,696)/, {
        timeout: 30_000,
      });

      await expect(audience.locator("[data-testid=\"fleet-node-agent-monitor\"]")).toHaveAttribute(
        "data-agent-state",
        "active",
      );

      expect(
        audienceNav.count(),
        `the audience window must not navigate or reload; observed: `,
      ).toBe(0);

      expect(new URL(instructor.url()).pathname).toBe("/demos/fleet");
      expect(new URL(audience.url()).pathname).toBe("/demos/fleet/audience");
    } finally {
      await instructorCtx.close();
      await audienceCtx.close();
    }
  });

  test("the two contexts are independent and both authenticated", async ({ browser }) => {
    const a = await newAuthedContext(browser, { demoMode: false, superadmin: true });
    const b = await newAuthedContext(browser, { demoMode: false, superadmin: true });
    try {
      const pageA = await a.newPage();
      const pageB = await b.newPage();
      await Promise.all([
        login(pageA, { demoMode: false }),
        login(pageB, { demoMode: false }),
      ]);
      for (const page of [pageA, pageB]) {
        await expect(page.locator("nav a[href=\"/agents\"]")).toBeVisible({ timeout: 30_000 });
        expect(page.url()).not.toContain("/dex/");
      }
      expect(a).not.toBe(b);
    } finally {
      await a.close();
      await b.close();
    }
  });
});
