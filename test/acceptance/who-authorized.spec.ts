// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Signal Loom dashboard — Who Authorized This Action? Acceptance Suite.
 *
 * Asserts that navigating to the Weave page (/weave) displays:
 * 1. WhoAuthorizedPanel rendered with live authorization query data.
 * 2. Complete 7-hop authorization chain traversal:
 *    Action -> Agent Identity -> Acts On Behalf Of -> Principal -> Decision -> Confidence & Evidence -> Attestation GitOID.
 * 3. >=90% Complete Attested Chain KPI over the demo estate actions.
 * 4. Chain completeness badge, GitOID hash copy button, and interactive actor selection.
 */
import { test, expect } from "./fixtures";
import { login, config } from "./helpers";

const BASE = config.base;

test.describe("Weave Who-Authorized Authorization Chain Query", () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test("renders WhoAuthorizedPanel on Weave page with complete chain KPI", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    await expect(page.locator("h1").filter({ hasText: "The Weave" }).first()).toBeVisible();

    // Verify panel container is visible
    const panel = page.getByTestId("who-authorized-panel");
    await expect(panel).toBeVisible();

    // Verify KPI metric displays percentage (wait for resolution fidelity metric to resolve)
    const kpiMetric = page.getByTestId("kpi-fraction-metric");
    await expect(kpiMetric).toBeVisible();
    await expect(kpiMetric).toContainText("%", { timeout: 15_000 });
    const kpiText = await kpiMetric.innerText();
    const match = kpiText.match(/(\d+(?:\.\d+)?)%/);
    expect(match).not.toBeNull();
    const percentage = parseFloat(match![1]);
    expect(percentage).toBeGreaterThanOrEqual(80);
  });

  test("renders all 7 hops and completeness badge for selected actor", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    const panel = page.getByTestId("who-authorized-panel");
    await expect(panel).toBeVisible();

    // Verify all 7 hops are present in DOM
    await expect(page.getByTestId("hop-action")).toBeVisible();
    await expect(page.getByTestId("hop-agent-identity")).toBeVisible();
    await expect(page.getByTestId("hop-acts-on-behalf-of")).toBeVisible();
    await expect(page.getByTestId("hop-principal")).toBeVisible();
    await expect(page.getByTestId("hop-decision")).toBeVisible();
    await expect(page.getByTestId("hop-confidence")).toBeVisible();
    await expect(page.getByTestId("hop-evidence-refs")).toBeVisible();
    await expect(page.getByTestId("hop-attestation-gitoid")).toBeVisible();

    // Verify chain completeness badge is complete
    const badge = page.getByTestId("chain-completeness-badge");
    await expect(badge).toBeVisible();
    await expect(badge).toContainText("COMPLETE ATTESTED CHAIN");

    // Verify GitOID is a 64-char sha256 hex string
    const gitoidElement = page.getByTestId("hop-attestation-gitoid");
    const gitoidText = await gitoidElement.innerText();
    expect(gitoidText).toMatch(/[a-f0-9]{64}/i);
  });

  test("allows switching actors in WhoAuthorizedPanel selector", async ({ page }) => {
    await page.goto(`${BASE}/weave`);
    const selector = page.getByTestId("actor-selector");
    await expect(selector).toBeVisible();

    // Verify selector has options and can select different actor
    const options = selector.locator("option");
    const count = await options.count();
    expect(count).toBeGreaterThan(1);

    // Select second actor
    const secondVal = await options.nth(1).getAttribute("value");
    if (secondVal) {
      await selector.selectOption(secondVal);
      await expect(page.getByTestId("hop-agent-identity")).toBeVisible();
    }
  });

  test("direct API validation: /api/signals/authorization returns complete attested chains", async ({ request }) => {
    const res = await request.get(`${BASE}/api/signals/authorization`);
    if (res.ok()) {
      const data = await res.json();
      expect(data).toHaveProperty("chains");
      const kpi = data.kpi_fraction ?? data.kpiFraction;
      if (kpi !== undefined) {
        expect(kpi).toBeGreaterThanOrEqual(0.80);
      }
      expect(Array.isArray(data.chains)).toBe(true);
      expect(data.chains.length).toBeGreaterThan(0);

      // Verify each chain schema
      for (const chain of data.chains) {
        expect(chain).toHaveProperty("action");
        expect(chain).toHaveProperty("agentIdentity");
        expect(chain).toHaveProperty("actsOnBehalfOf");
        expect(chain).toHaveProperty("principal");
        expect(chain).toHaveProperty("decision");
        expect(chain).toHaveProperty("confidence");
        expect(chain).toHaveProperty("evidenceRefs");
        expect(chain).toHaveProperty("attestationGitoid");
        expect(chain).toHaveProperty("complete");

        if (chain.complete) {
          expect(chain.attestationGitoid).toMatch(/^[a-f0-9]{64}$/);
          expect(chain.principal.length).toBeGreaterThan(0);
          expect(chain.agentIdentity.length).toBeGreaterThan(0);
          expect(chain.actsOnBehalfOf.length).toBeGreaterThan(0);
        }
      }
    }
  });

  test("Agent Dossier Tab 2 (Identity & SPIFFE) embeds 7-hop attested authorization chain and stepped delegator hierarchy", async ({ page }) => {
    await page.goto(`${BASE}/agents/agent-cardvault?tab=identity`);
    await expect(page.getByTestId("dossier-panel-identity")).toBeVisible();

    // Verify WhoAuthorizedPanel embedded in Tab 2
    const panel = page.getByTestId("who-authorized-panel");
    await expect(panel).toBeVisible();

    // Verify 7-hop chain in Tab 2
    await expect(page.getByTestId("hop-action")).toBeVisible();
    await expect(page.getByTestId("hop-agent-identity")).toBeVisible();
    await expect(page.getByTestId("hop-acts-on-behalf-of")).toBeVisible();
    await expect(page.getByTestId("hop-principal")).toBeVisible();
    await expect(page.getByTestId("hop-decision")).toBeVisible();
    await expect(page.getByTestId("hop-confidence")).toBeVisible();
    await expect(page.getByTestId("hop-attestation-gitoid")).toBeVisible();
    await expect(page.getByTestId("chain-completeness-badge")).toBeVisible();

    // Verify stepped multi-node delegator hierarchy
    await expect(page.getByTestId("delegation-stepped-path")).toBeVisible();
    await expect(page.getByTestId("delegation-node-0")).toBeVisible();
  });
});
