// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { test, expect } from './fixtures'
import { login, config } from './helpers'

const BASE = config.base

test.describe('Signal Loom OpenBao & SPIRE Identity Audit Streamer', () => {
  test.beforeEach(async ({ page }) => {
    await login(page, { demoMode: true })
  })

  test('renders IdentityAuditPanel on Weave page with active leases and out-of-role filtering', async ({ page }) => {
    // Navigate to Weave dashboard
    await page.goto(`${BASE}/weave`)

    // 1. Verify IdentityAuditPanel presence
    const panel = page.getByTestId('identity-audit-panel')
    await expect(panel).toBeVisible()
    await expect(page.getByTestId('active-leases-count')).toContainText('Active Leases:')

    // 2. Verify audit table rows are visible
    const firstRow = page.getByTestId('audit-row-bao-audit-1')
    await expect(firstRow).toBeVisible()

    // 3. Test out-of-role filter toggle
    const outOfRoleFilter = page.getByTestId('filter-out_of_role')
    await outOfRoleFilter.click()

    // Only out-of-role row should remain visible
    await expect(page.getByTestId('audit-row-bao-audit-2')).toBeVisible()
    await expect(page.getByTestId('status-out-of-role-bao-audit-2')).toBeVisible()
    await expect(page.getByTestId('audit-row-bao-audit-1')).not.toBeVisible()

    // 4. Return to All Signals filter
    const allFilter = page.getByTestId('filter-all')
    await allFilter.click()
    await expect(page.getByTestId('audit-row-bao-audit-1')).toBeVisible()
  })
})
