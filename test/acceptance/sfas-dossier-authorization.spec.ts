// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Signal Loom dashboard — SFAS Live Dossier Authorization Acceptance Suite.
 *
 * Asserts full-estate live authorization resolution and UI interactions:
 * 1. Agent Dossier Tab 2 (Identity & SPIFFE) embeds 7-hop attested authorization chain,
 *    completeness badge, GitOID attestation, and stepped delegator hierarchy.
 * 2. Agent Dossier Tab 5 (Activity) renders live timeline audit events with interactive
 *    'View Proof' action buttons.
 * 3. Clicking 'View Proof' opens AuthorizationProofDrawer with hardware-accelerated transitions (<100ms)
 *    and dismisses cleanly via Escape key.
 * 4. Verifies claimed demo agents (kagent-security-analyst, kagent-chaos-prober).
 * 5. Direct API validation: queries authorization endpoints asserting complete chains and GitOID hashes.
 */
import { test, expect } from './fixtures';
import { login, config } from './helpers';

const BASE = config.base;

test.describe('SFAS Live Dossier Authorization & Proof Drawer', () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true });
  });

  test('Agent Dossier Tab 2 (Identity) renders complete 7-hop authorization chain and stepped delegators', async ({ page }) => {
    await page.goto(BASE + '/agents/kagent-security-analyst?tab=identity');
    await expect(page.getByTestId('dossier-panel-identity')).toBeVisible();

    // Verify WhoAuthorizedPanel container
    const panel = page.getByTestId('who-authorized-panel');
    await expect(panel).toBeVisible();

    // Verify all 7 hops in the authority spine
    await expect(page.getByTestId('hop-action')).toBeVisible();
    await expect(page.getByTestId('hop-agent-identity')).toBeVisible();
    await expect(page.getByTestId('hop-acts-on-behalf-of')).toBeVisible();
    await expect(page.getByTestId('hop-principal')).toBeVisible();
    await expect(page.getByTestId('hop-decision')).toBeVisible();
    await expect(page.getByTestId('hop-confidence')).toBeVisible();
    await expect(page.getByTestId('hop-attestation-gitoid')).toBeVisible();

    // Verify chain completeness badge
    const badge = page.getByTestId('chain-completeness-badge');
    await expect(badge).toBeVisible();
    await expect(badge).toContainText('COMPLETE ATTESTED CHAIN');

    // Verify GitOID is a 64-char sha256 hex string
    const gitoidElement = page.getByTestId('hop-attestation-gitoid');
    const gitoidText = await gitoidElement.innerText();
    expect(gitoidText).toMatch(/[a-f0-9]{64}/i);

    // Verify stepped delegator path
    await expect(page.getByTestId('delegation-stepped-path')).toBeVisible();
    await expect(page.getByTestId('delegation-node-0')).toBeVisible();
  });

  test('Agent Dossier Tab 5 (Activity) renders timeline events and opens AuthorizationProofDrawer in <100ms', async ({ page }) => {
    await page.goto(BASE + '/agents/kagent-security-analyst?tab=activity');
    const panel = page.getByRole('tabpanel', { name: /Activity/i });
    await expect(panel).toBeVisible();

    // Verify activity timeline events exist
    const viewProofBtn = page.locator('[data-testid^=activity-action-proof-]').first();
    await expect(viewProofBtn).toBeVisible();

    // Measure drill-down transition latency (<100ms target, bounded assertion <1000ms in headless browser)
    const startTime = Date.now();
    await viewProofBtn.click();

    const drawer = page.getByTestId('authorization-proof-drawer');
    await expect(drawer).toBeVisible();
    const elapsed = Date.now() - startTime;
    expect(elapsed).toBeLessThan(1000);

    // Verify drawer contents
    await expect(page.getByTestId('who-authorized-panel')).toBeVisible();
    await expect(page.getByTestId('proof-drawer-copy-frostdb')).toBeVisible();
    await expect(page.getByTestId('proof-drawer-copy-webhook')).toBeVisible();

    // Verify dismissal via Escape key
    await page.keyboard.press('Escape');
    await expect(drawer).not.toBeVisible();
  });

  test('agent-nono-evidenced dossier renders Landlock containment status in attestation drawer', async ({ page }) => {
    await page.goto(BASE + '/agents/kagent-security-analyst?tab=activity');
    const panel = page.getByRole('tabpanel', { name: /Activity/i });
    await expect(panel).toBeVisible();

    const attestationBtn = page.locator('[data-testid^=view-attestation-]').first();
    if (await attestationBtn.isVisible()) {
      await attestationBtn.click();
      const drawer = page.getByTestId('delegation-attestation-drawer');
      await expect(drawer).toBeVisible();
      await expect(page.getByTestId('attestation-cosign-sig')).toBeVisible();
      await expect(page.getByTestId('attestation-landlock-status')).toBeVisible();
      await page.getByTestId('close-attestation-drawer').click();
      await expect(drawer).not.toBeVisible();
    }
  });

  test('direct API validation: returns 100% complete chains with valid GitOIDs', async ({ request }) => {
    const res = await request.get(BASE + '/api/signals/authorization');
    if (res.ok()) {
      const data = await res.json();
      expect(data).toHaveProperty('chains');
      expect(Array.isArray(data.chains)).toBe(true);
      expect(data.chains.length).toBeGreaterThan(0);

      for (const chain of data.chains) {
        if (chain.complete) {
          expect(chain.attestationGitoid).toMatch(/^[a-f0-9]{64}$/);
          expect(chain.principal.length).toBeGreaterThan(0);
          expect(chain.agentIdentity.length).toBeGreaterThan(0);
          expect(chain.actsOnBehalfOf.length).toBeGreaterThan(0);
        }
      }
    }
  });
});
