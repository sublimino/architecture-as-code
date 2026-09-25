import { expect, test } from './fixtures'
import { config, login } from './helpers'

// Test JWT payloads for Tenant A (tenant-alpha) and Tenant B (tenant-beta)
function createTenantToken(tenantId: string, sub: string = `user-${tenantId}`): string {
  const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url')
  const payload = Buffer.from(
    JSON.stringify({
      sub,
      tenant_id: tenantId,
      iss: 'https://dex.signalloom.local',
      aud: 'signalloom-dashboard',
      exp: Math.floor(Date.now() / 1000) + 3600,
    })
  ).toString('base64url')
  return `${header}.${payload}.`
}

test.describe('Tenant Warning Notifications & Audit Linking (EAPR-P3-5 / D13)', () => {
  const TENANT_A = 'tenant-alpha'
  const TENANT_B = 'tenant-beta'

  const warningTenantA = {
    id: 'audit-warn-alpha-901',
    event_type: 'containment_action',
    agent_id: 'agent-alpha-worker',
    agent_name: 'Alpha Worker Agent',
    timestamp: new Date().toISOString(),
    details: { reason: 'Policy violation containment trigger' },
  }

  const warningTenantB = {
    id: 'audit-warn-beta-902',
    event_type: 'policy_violation',
    agent_id: 'agent-beta-worker',
    agent_name: 'Beta Worker Agent',
    timestamp: new Date().toISOString(),
    details: { reason: 'Unauthorized egress attempt' },
  }

  test('Tenant A receives scoped warning notifications and deep-links to audit event ID', async ({ page }) => {
    const tokenA = createTenantToken(TENANT_A)

    // Intercept audit API and route according to authenticated token / tenant
    await page.route('**/api/audit*', async (route) => {
      const authHeader = route.request().headers()['authorization'] || ''
      if (authHeader.includes(tokenA) || authHeader.includes(TENANT_A)) {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            items: [warningTenantA],
            total: 1,
            page: 1,
            limit: 50,
          }),
        })
      } else {
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            items: [],
            total: 0,
            page: 1,
            limit: 50,
          }),
        })
      }
    })

    // Seed session with Tenant A token
    await page.addInitScript(({ token, tenant }: { token: string; tenant: string }) => {
      try {
        window.sessionStorage.setItem('signalloom_token', token)
        window.sessionStorage.setItem('signalloom_tenant', tenant)
        window.localStorage.setItem('sl_demo_mode', 'false')
      } catch {
        /* storage unavailable */
      }
    }, { token: tokenA, tenant: TENANT_A })

    await page.goto(config.base, { waitUntil: 'domcontentloaded' })

    // Wait for the notification bell to be visible
    const bell = page.locator('[data-testid="tenant-warnings-bell"]')
    await expect(bell).toBeVisible({ timeout: 15_000 })

    // Verify unread badge count shows 1
    const countBadge = page.locator('[data-testid="tenant-warnings-count"]')
    await expect(countBadge).toBeVisible({ timeout: 10_000 })
    await expect(countBadge).toHaveText('1')

    // Open notification panel
    await bell.click()

    const panel = page.locator('[data-testid="tenant-warnings-panel"]')
    await expect(panel).toBeVisible()

    // Verify warning row contains agent name, event type, and audit link
    const warningRow = page.locator(`[data-testid="tenant-warning-row-${warningTenantA.id}"]`)
    await expect(warningRow).toBeVisible()
    await expect(warningRow).toContainText('CONTAINMENT ACTION')
    await expect(warningRow).toContainText('Alpha Worker Agent')

    const auditLink = page.locator(`[data-testid="tenant-warning-link-${warningTenantA.id}"]`)
    await expect(auditLink).toBeVisible()
    await expect(auditLink).toHaveAttribute(
      'href',
      `/agents/${encodeURIComponent(warningTenantA.agent_id)}?tab=activity&audit=${encodeURIComponent(warningTenantA.id)}`
    )

    // Click link to navigate to agent detail page with audit search param
    await auditLink.click()

    await expect(page).toHaveURL(new RegExp(`/agents/${warningTenantA.agent_id}`))
  })

  test('Tenant B does not see Tenant A warnings, and positive control proves Tenant B warnings render', async ({ page }) => {
    const tokenB = createTenantToken(TENANT_B)
    let tenantBWarningActive = false

    // Intercept audit API ensuring cross-tenant isolation
    await page.route('**/api/audit*', async (route) => {
      const authHeader = route.request().headers()['authorization'] || ''

      // If requested by Tenant B
      if (authHeader.includes(tokenB) || authHeader.includes(TENANT_B)) {
        const items = tenantBWarningActive ? [warningTenantB] : []
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            items,
            total: items.length,
            page: 1,
            limit: 50,
          }),
        })
      } else {
        // Any request without Tenant B auth gets empty or Tenant A data
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            items: [warningTenantA],
            total: 1,
            page: 1,
            limit: 50,
          }),
        })
      }
    })

    // Seed session as Tenant B
    await page.addInitScript(({ token, tenant }: { token: string; tenant: string }) => {
      try {
        window.sessionStorage.setItem('signalloom_token', token)
        window.sessionStorage.setItem('signalloom_tenant', tenant)
        window.localStorage.setItem('sl_demo_mode', 'false')
      } catch {
        /* storage unavailable */
      }
    }, { token: tokenB, tenant: TENANT_B })

    await page.goto(config.base, { waitUntil: 'domcontentloaded' })

    const bell = page.locator('[data-testid="tenant-warnings-bell"]')
    await expect(bell).toBeVisible({ timeout: 15_000 })

    // Negative Assertion: Tenant B has 0 unread warnings; badge must not be visible
    const countBadge = page.locator('[data-testid="tenant-warnings-count"]')
    await expect(countBadge).not.toBeVisible()

    // Open panel: must show empty state and MUST NOT show Tenant A warning
    await bell.click()
    const emptyNotice = page.locator('[data-testid="tenant-warnings-empty"]')
    await expect(emptyNotice).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-warning-row-${warningTenantA.id}"]`)).not.toBeVisible()

    // Close panel
    await bell.click()

    // Positive Control: Now raise a warning for Tenant B
    tenantBWarningActive = true

    // Trigger notification poll or reload
    await page.reload({ waitUntil: 'domcontentloaded' })
    await expect(bell).toBeVisible({ timeout: 15_000 })

    // Verify Tenant B now sees its own warning badge
    await expect(countBadge).toBeVisible({ timeout: 10_000 })
    await expect(countBadge).toHaveText('1')

    await bell.click()
    const tenantBRow = page.locator(`[data-testid="tenant-warning-row-${warningTenantB.id}"]`)
    await expect(tenantBRow).toBeVisible()
    await expect(tenantBRow).toContainText('POLICY VIOLATION')
    await expect(tenantBRow).toContainText('Beta Worker Agent')
  })
})
