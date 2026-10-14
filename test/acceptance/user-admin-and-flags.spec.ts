// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Signal Loom — Superadmin User Administration & Tenant Feature Flag Suppression Acceptance Journey (SLFA-P4-2).
 *
 * Exercises the end-to-end administrative and feature flag lifecycle:
 *   Stage 1: Superadmin authentication & UserTable inspection with tenant filtering
 *   Stage 2: User invitation via InviteUserModal with role assignment ('editor')
 *   Stage 3: Interactive role reassignment to 'viewer' via EditUserModal with privilege change confirmation
 *   Stage 4: Tenant context switch to Kusari design partner & verification of zero-clutter sidebar suppression
 *   Stage 5: Direct route navigation gating asserting NotFoundPage fallback on suppressed surfaces
 */
import { test, expect, type Page } from '@playwright/test'
import {
  launchUserAdminFlagsHarness,
  resetHarnessState,
  inviteUserViaModal,
  editUserRoleViaModal,
  assertKusariSidebarSuppression,
  type HarnessInfo,
} from './harness/user-admin-flags-helpers'

test.describe.serial('Superadmin User Administration & Feature Flag Governance (SLFA-P4-2)', () => {
  let harness: HarnessInfo

  test.beforeAll(async () => {
    harness = await launchUserAdminFlagsHarness(__dirname)
  })

  test.afterAll(async () => {
    if (harness?.child) {
      harness.child.kill('SIGTERM')
    }
  })

  test.beforeEach(async ({ request }) => {
    await resetHarnessState(request, harness.url)
  })

  test('Stage 1..5: Complete Superadmin User Admin, Role Mutation & Kusari Feature Flag Suppression Journey', async ({
    page,
  }) => {
    // ══════════════════════════════════════════════════════════════════════════
    // Stage 1: Log in as superadmin, navigate to /admin/users, assert UserTable
    // ══════════════════════════════════════════════════════════════════════════
    await page.goto(`${harness.url}/admin/users?tenant=tenant-demo&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })

    // Assert page header and superadmin indicator
    const usersPage = page.locator('[data-testid="users-page"]')
    await expect(usersPage).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('h1')).toContainText('User Administration')

    const superadminScopePill = page.locator('[data-testid="superadmin-scope-pill"]')
    await expect(superadminScopePill).toBeVisible()
    await expect(superadminScopePill).toContainText('Global Superadmin')

    // Assert UserTable rendered with tenant filter toolbar
    const userTable = page.locator('[data-testid="admin-user-table"]')
    await expect(userTable).toBeVisible()

    const tenantFilterSelect = page.locator('[data-testid="tenant-filter-select"]')
    await expect(tenantFilterSelect).toBeVisible()

    // Assert seeded initial users are visible
    const superadminRow = page.locator('[data-testid="user-row-usr-demo-001"]')
    await expect(superadminRow).toBeVisible()
    await expect(superadminRow).toContainText('demo-user@signalloom.local')
    await expect(superadminRow.locator('[data-testid="role-badge-admin"]')).toBeVisible()
    await expect(superadminRow.locator('[data-testid="superadmin-badge"]')).toBeVisible()

    const kusariAdminRow = page.locator('[data-testid="user-row-usr-kusari-002"]')
    await expect(kusariAdminRow).toBeVisible()
    await expect(kusariAdminRow).toContainText('admin@kusari.demo')

    const acmeViewerRow = page.locator('[data-testid="user-row-usr-acme-003"]')
    await expect(acmeViewerRow).toBeVisible()
    await expect(acmeViewerRow).toContainText('operator@acme.demo')
    await expect(acmeViewerRow.locator('[data-testid="role-badge-viewer"]')).toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 2: Open InviteUserModal, fill out email and role ('editor'), submit
    // ══════════════════════════════════════════════════════════════════════════
    const targetEmail = 'operator.jane@example.com'
    const targetName = 'Jane Operator'

    await inviteUserViaModal(page, {
      email: targetEmail,
      name: targetName,
      role: 'editor',
      tenant: 'tenant-demo',
      title: 'Security Analyst',
      department: 'Detection & Response',
    })

    // Assert new user is rendered in the UserTable
    const invitedUserRow = page.locator('tr').filter({ hasText: targetEmail })
    await expect(invitedUserRow).toBeVisible({ timeout: 10_000 })
    await expect(invitedUserRow).toContainText(targetName)
    await expect(invitedUserRow.locator('[data-testid="role-badge-editor"]')).toBeVisible()
    await expect(invitedUserRow.locator('[data-testid="status-badge-invited"]')).toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 3: Edit user role to 'viewer', assert role badge updates dynamically
    // ══════════════════════════════════════════════════════════════════════════
    // Extract generated user ID from the row's edit button testid
    const editBtn = invitedUserRow.locator('[data-testid^="edit-user-btn-"]')
    await expect(editBtn).toBeVisible()
    const editBtnTestId = await editBtn.getAttribute('data-testid')
    const userId = editBtnTestId?.replace('edit-user-btn-', '') ?? ''
    expect(userId).toBeTruthy()

    await editUserRoleViaModal(page, userId, 'viewer')

    // Assert role badge dynamically updates to 'viewer' in the table row
    await expect(invitedUserRow.locator('[data-testid="role-badge-viewer"]')).toBeVisible({ timeout: 10_000 })
    await expect(invitedUserRow.locator('[data-testid="role-badge-editor"]')).not.toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 4: Switch context to Kusari tenant, assert demo links are hidden
    // ══════════════════════════════════════════════════════════════════════════
    await page.goto(`${harness.url}/admin/users?tenant=kusari&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })

    await expect(page.locator('[data-testid="harness-shell"][data-harness-tenant="kusari"]')).toBeVisible({
      timeout: 10_000,
    })

    // Assert Kusari tenant flag suppression in Sidebar navigation
    await assertKusariSidebarSuppression(page)

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 5: Attempt direct navigation to /demos/fleet, assert NotFound page
    // ══════════════════════════════════════════════════════════════════════════
    const suppressedPaths = [
      '/fleet',
      '/fleet/audience',
      '/demos/fleet',
      '/supercred',
      '/collusion-access',
      '/rbac-analysis',
      '/rbac-explorer',
    ]

    for (const path of suppressedPaths) {
      await page.goto(`${harness.url}${path}?tenant=kusari&superadmin=true`, {
        waitUntil: 'domcontentloaded',
      })

      const notFoundContainer = page.locator('[data-testid="not-found"]')
      await expect(notFoundContainer).toBeVisible({ timeout: 10_000 })
      await expect(notFoundContainer.locator('h1')).toHaveText('Page Not Found')
      await expect(notFoundContainer).toContainText(
        'The page you requested does not exist, has been moved, or is disabled for your tenant.',
      )
    }

    // Positive Control: Navigating to an enabled route (e.g. /compliance or /policies) renders successfully
    await page.goto(`${harness.url}/compliance?tenant=kusari&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })
    await expect(page.locator('[data-testid="page-compliance"]')).toBeVisible({ timeout: 10_000 })
    await expect(page.locator('[data-testid="not-found"]')).not.toBeVisible()
  })

  test('Tenant Filtering & Search Isolation across Tenants', async ({ page }) => {
    await page.goto(`${harness.url}/admin/users?tenant=tenant-demo&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })

    await expect(page.locator('[data-testid="admin-user-table"]')).toBeVisible({ timeout: 10_000 })

    // Filter to 'kusari' tenant
    const tenantFilter = page.locator('[data-testid="tenant-filter-select"]')
    await tenantFilter.selectOption('kusari')

    // Kusari admin should be visible; Acme operator should NOT be visible
    await expect(page.locator('[data-testid="user-row-usr-kusari-002"]')).toBeVisible()
    await expect(page.locator('[data-testid="user-row-usr-acme-003"]')).not.toBeVisible()

    // Clear filter
    await tenantFilter.selectOption('all')
    await expect(page.locator('[data-testid="user-row-usr-acme-003"]')).toBeVisible()

    // Search for 'operator'
    const searchInput = page.locator('[data-testid="user-search-input"]')
    await searchInput.fill('operator')
    await expect(page.locator('[data-testid="user-row-usr-acme-003"]')).toBeVisible()
    await expect(page.locator('[data-testid="user-row-usr-kusari-002"]')).not.toBeVisible()
  })

  test('Interactive Feature Flags Management & EAP Pilot Preset Application on /admin/features', async ({
    page,
  }) => {
    // ══════════════════════════════════════════════════════════════════════════
    // Stage 1: Navigate to /admin/features as superadmin for tenant 'kusari'
    // ══════════════════════════════════════════════════════════════════════════
    await page.goto(`${harness.url}/admin/features?tenant=kusari&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })

    const featuresPage = page.locator('[data-testid="features-page"]')
    await expect(featuresPage).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('h1')).toContainText('Feature Flags & Presets')

    const superadminScopePill = page.locator('[data-testid="superadmin-scope-pill"]')
    await expect(superadminScopePill).toBeVisible()
    await expect(superadminScopePill).toContainText('Global Superadmin')

    // Assert KPI metrics rendered
    await expect(page.locator('[data-testid="kpi-account-scope"]')).toContainText('kusari')
    await expect(page.locator('[data-testid="kpi-total-flags"]')).toBeVisible()

    // Assert Preset cards rendered
    const presetCard = page.locator('[data-testid="preset-card-eap_pilot"]')
    await expect(presetCard).toBeVisible()
    await expect(presetCard).toContainText('EAP Pilot')
    await expect(presetCard).toContainText('Recommended for EAP')

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 2: Apply EAP Pilot preset bundle to Kusari tenant
    // ══════════════════════════════════════════════════════════════════════════
    const applyEapBtn = page.locator('[data-testid="apply-preset-eap_pilot"]')
    await expect(applyEapBtn).toBeVisible()
    await applyEapBtn.click()

    // Assert success toast appears and no error banner is displayed
    const successToast = page.locator('[data-testid="success-toast"]')
    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Preset "EAP Pilot" applied successfully to account "kusari"')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 3: Interactive flag button toggles
    // ══════════════════════════════════════════════════════════════════════════
    const agentmaxxingToggle = page.locator('[data-testid="flag-toggle-page_agentmaxxing"]')
    await expect(agentmaxxingToggle).toBeVisible()

    // Toggle ENABLED
    await agentmaxxingToggle.click()
    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Flag "page_agentmaxxing" set to ENABLED')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()
    await expect(agentmaxxingToggle).toHaveAttribute('aria-checked', 'true')

    // Toggle DISABLED
    await agentmaxxingToggle.click()
    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Flag "page_agentmaxxing" set to DISABLED')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()
    await expect(agentmaxxingToggle).toHaveAttribute('aria-checked', 'false')

    // Filter to Config & Services category and toggle page_federated_services
    const categorySelect = page.locator('[data-testid="filter-category-select"]')
    await categorySelect.selectOption('config')
    const configCategoryCard = page.locator('[data-testid="category-group-config"]')
    await expect(configCategoryCard).toBeVisible()
    await expect(configCategoryCard).toContainText('Config & Services')

    const fedServicesToggle = page.locator('[data-testid="flag-toggle-page_federated_services"]')
    await expect(fedServicesToggle).toBeVisible()
    await fedServicesToggle.click()
    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Flag "page_federated_services"')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()

    // Reset category filter
    await categorySelect.selectOption('all')

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 4: Apply Full Demo preset bundle
    // ══════════════════════════════════════════════════════════════════════════
    const applyFullDemoBtn = page.locator('[data-testid="apply-preset-full_demo"]')
    await expect(applyFullDemoBtn).toBeVisible()
    await applyFullDemoBtn.click()

    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Preset "Full Platform Demo" applied successfully to account "kusari"')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 5: Switch account scope via selector and apply preset
    // ══════════════════════════════════════════════════════════════════════════
    const tenantSelect = page.locator('[data-testid="admin-tenant-select"]')
    await tenantSelect.selectOption('tenant-demo')
    await expect(page.locator('[data-testid="kpi-account-scope"]')).toContainText('tenant-demo')

    await applyEapBtn.click()
    await expect(successToast).toBeVisible({ timeout: 10_000 })
    await expect(successToast).toContainText('Preset "EAP Pilot" applied successfully to account "tenant-demo"')
    await expect(page.locator('[data-testid="action-error-banner"]')).not.toBeVisible()

    // ══════════════════════════════════════════════════════════════════════════
    // Stage 6: Settings editable organization name and sidebar synchronization
    // ══════════════════════════════════════════════════════════════════════════
    await page.goto(`${harness.url}/settings?tenant=kusari&superadmin=true`, {
      waitUntil: 'domcontentloaded',
    })

    // Assert Sidebar has renamed section label "Config" instead of "Design"
    const configSection = page.locator('.sl-sidebar__section-label', { hasText: 'Config' })
    await expect(configSection).toBeVisible()

    const orgInput = page.locator('[data-testid="settings-org-name-input"]')
    await expect(orgInput).toBeVisible({ timeout: 10_000 })
    await expect(orgInput).toHaveValue('Kusari Pilot Corp')

    const saveOrgBtn = page.locator('[data-testid="settings-save-org-name-btn"]')
    await expect(saveOrgBtn).toBeDisabled()

    await orgInput.fill('Kusari Global Security Corp')
    await expect(saveOrgBtn).toBeEnabled()
    await saveOrgBtn.click()

    await expect(page.locator('[data-testid="settings-org-saved-indicator"]')).toBeVisible({ timeout: 10_000 })
    await expect(page.locator('[data-testid="settings-org-saved-indicator"]')).toHaveText('Saved')

    // Sidebar workspace title updates reactively
    const workspaceTitle = page.locator('.sl-sidebar__workspace-title')
    await expect(workspaceTitle).toHaveText('Kusari Global Security Corp')
  })
})
