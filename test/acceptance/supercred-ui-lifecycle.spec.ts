/**
 * The complete SuperCred lifecycle, driven exclusively from the instructor UI.
 *
 * It first resets any rehearsal state, verifies every audience-facing stage,
 * resets the completed demo, then reruns all phases. This makes reset a proven
 * transition rather than a cleanup command that happens to return success.
 */
import { test, expect } from "./fixtures";
import { login } from "./helpers";
import { navigateTo, newAuthedContext } from "./supercred-helpers";

test.describe.configure({ mode: "serial", timeout: 30 * 60_000 });

const RUN_STATUS = '[data-testid="supercred-run-status"]';
const RUN_STEP = (step: string) => `[data-testid="supercred-run-step-${step}"]`;
const RESET = '[data-testid="supercred-reset"]';
const RESET_CONFIRM = '[data-testid="supercred-reset-confirm"]';

async function runStep(instructor: import("@playwright/test").Page, step: string): Promise<void> {
  await instructor.locator(RUN_STEP(step)).click();
  const status = instructor.locator(RUN_STATUS)
  await expect(status).toContainText(new RegExp(`Step\\s+${step}\\s+\\(step\\)\\s+—\\s+(?:running|succeeded)`), { timeout: 30_000 });
  await expect(status).toContainText(new RegExp(`Step\\s+${step}\\s+\\(step\\)\\s+—\\s+succeeded`), { timeout: 10 * 60_000 });
}

async function reset(instructor: import("@playwright/test").Page): Promise<void> {
  await expect(instructor.locator(RESET)).toBeVisible({ timeout: 30_000 });
  await instructor.locator(RESET).click();
  await instructor.locator(RESET_CONFIRM).click();
  const status = instructor.locator(RUN_STATUS)
  await expect(status).toContainText(/Step\s+5\s+\(reset\)\s+—\s+(?:running|succeeded)/, { timeout: 30_000 });
  await expect(status).toContainText(/Step\s+5\s+\(reset\)\s+—\s+succeeded/, { timeout: 10 * 60_000 });
}

test("complete lifecycle, reset, and rerun project correct live state", async ({ browser }) => {
  const instructorContext = await newAuthedContext(browser, { demoMode: false, superadmin: true });
  const audienceContext = await newAuthedContext(browser, { demoMode: false, superadmin: false });
  try {
    const instructor = await instructorContext.newPage();
    const audience = await audienceContext.newPage();
    await Promise.all([login(instructor, { demoMode: false }), login(audience, { demoMode: false })]);
    await Promise.all([navigateTo(instructor, "/supercred"), navigateTo(audience, "/agents")]);

    // A clean starting point must be achievable through the UI.
    await reset(instructor);
    await expect(instructor.getByTestId('supercred-clean-state')).toContainText(/clean state verified.*teardown completed/i);
    for (const step of ['1', '2', '3', '4', '5']) {
      await expect(instructor.getByTestId(`supercred-phase-status-${step}`)).toHaveText('not run');
    }
    await navigateTo(audience, "/agents");
    await expect(audience.getByText(/cardvault agent/i)).toHaveCount(0, { timeout: 60_000 });

    await runStep(instructor, "1");
    await navigateTo(audience, "/agents");
    await expect(audience.getByText(/cardvault agent/i).first()).toBeVisible({ timeout: 60_000 });
    await expect(audience.getByText(/enrolled/i).first()).toBeVisible();

    await runStep(instructor, "2");
    await expect(audience.getByText(/active/i).first()).toBeVisible({ timeout: 60_000 });
    await navigateTo(audience, "/credential-inventory");
    await expect(audience.getByTestId("credential-inventory-source")).toContainText(/live/i);
    await expect(audience.getByText(/cardvault/i).first()).toBeVisible();

    await runStep(instructor, "3");
    await navigateTo(audience, "/compliance");
    await expect(audience.getByText(/cardvault agent/i).first()).toBeVisible({ timeout: 60_000 });
    await expect(audience.getByText(/securitycontext/i).first()).toBeVisible();

    await runStep(instructor, "4");
    await expect(instructor.locator('[data-testid="supercred-run-control-error"]')).toHaveCount(0);
    await navigateTo(audience, "/agents");
    await expect(audience.locator('[data-testid="credential-state-revoked"]').first()).toContainText(/credentials revoked/i, { timeout: 120_000 });
    await navigateTo(audience, "/audit");
    // The runner durably records the privileged phase invocation before it
    // mutates the cluster. The agent page above proves the resulting state;
    // this row proves the control's own audit contract without inventing an
    // `agent.stunned` event that the runner did not itself observe.
    const auditRows = audience.locator('table tbody');
    await expect(auditRows.getByRole('button', { name: 'demo.phase_run' }).first()).toBeVisible({ timeout: 60_000 });

    await runStep(instructor, "5");
    await navigateTo(audience, "/agents");
    await expect(audience.getByText(/cardvault agent/i)).toHaveCount(0, { timeout: 60_000 });
    await navigateTo(audience, "/compliance");
    await expect(audience.getByText(/cardvault agent/i)).toHaveCount(0, { timeout: 60_000 });
    await navigateTo(audience, "/credential-inventory");
    await expect(audience.getByText(/cardvault/i)).toHaveCount(0, { timeout: 60_000 });
    await navigateTo(audience, "/audit");
    // Audit events are append-only: teardown removes the runtime resource but
    // must not erase the recorded privileged invocation.
    await expect(auditRows.getByRole('button', { name: 'demo.phase_run' }).first()).toBeVisible({ timeout: 60_000 });

    // Reset after a completed lifecycle, then prove the UI can start again.
    await reset(instructor);
    for (const step of ["1", "2", "3", "4", "5"]) await runStep(instructor, step);
  } finally {
    // A completed phase-5 teardown can race Playwright's own fixture cleanup;
    // closing an already-closed context is not a product failure.
    await instructorContext.close().catch(() => undefined);
    await audienceContext.close().catch(() => undefined);
  }
});
