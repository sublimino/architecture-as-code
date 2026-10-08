// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Acceptance test helper library for User Administration & Feature Flag suppression journeys.
 */
import { spawn, type ChildProcessByStdio } from 'node:child_process'
import { join } from 'node:path'
import type { Readable } from 'node:stream'
import { expect, type Page, type APIRequestContext } from '@playwright/test'

export interface HarnessInfo {
  url: string
  child: ChildProcessByStdio<null, Readable, Readable>
}

export interface InviteUserOptions {
  email: string
  name?: string
  role: 'admin' | 'editor' | 'viewer'
  tenant?: string
  title?: string
  department?: string
}

/**
 * Launch isolated user administration and feature flags harness on an ephemeral port.
 */
export async function launchUserAdminFlagsHarness(rootDir: string): Promise<HarnessInfo> {
  const script = join(rootDir, 'harness', 'user-admin-flags-server.ts')
  const child = spawn('bun', [script, '--port', '0'], {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, TMPDIR: '/tmp/buntmp', BUN_TMPDIR: '/tmp/buntmp' },
  })

  const stderr: string[] = []
  child.stderr.on('data', (b: Buffer) => stderr.push(b.toString()))

  const url = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`user-admin-flags harness timed out after 60s. stderr:\n${stderr.join('')}`)),
      60_000,
    )
    let out = ''
    child.stdout.on('data', (b: Buffer) => {
      out += b.toString()
      const match = out.match(/^USER_ADMIN_FLAGS_HARNESS_READY (\S+)/m)
      if (match?.[1]) {
        clearTimeout(timer)
        resolve(match[1])
      }
    })
    child.on('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`user-admin-flags harness exited with code ${code}. stderr:\n${stderr.join('')}`))
    })
  })

  return { url, child }
}

/**
 * Reset harness state between tests.
 */
export async function resetHarnessState(request: APIRequestContext, harnessUrl: string): Promise<void> {
  const res = await request.post(`${harnessUrl}/harness/reset`)
  expect(res.ok(), 'Harness reset failed').toBeTruthy()
}

/**
 * Perform complete user invitation via InviteUserModal.
 */
export async function inviteUserViaModal(page: Page, options: InviteUserOptions): Promise<void> {
  const inviteBtn = page.locator('[data-testid="invite-user-btn"]')
  await expect(inviteBtn).toBeVisible({ timeout: 10_000 })
  await inviteBtn.click()

  const modal = page.locator('[data-testid="invite-user-modal"]')
  await expect(modal).toBeVisible({ timeout: 5_000 })

  const emailInput = page.locator('[data-testid="invite-email-input"]')
  await expect(emailInput).toBeVisible()
  await emailInput.fill(options.email)

  if (options.name) {
    await page.locator('[data-testid="invite-name-input"]').fill(options.name)
  }

  await page.locator('[data-testid="invite-role-select"]').selectOption(options.role)

  if (options.tenant) {
    const tenantSelect = page.locator('[data-testid="invite-tenant-select"]')
    const tenantInput = page.locator('[data-testid="invite-tenant-input"]')
    if (await tenantSelect.isVisible().catch(() => false)) {
      await tenantSelect.selectOption(options.tenant)
    } else if (await tenantInput.isVisible().catch(() => false)) {
      await tenantInput.fill(options.tenant)
    }
  }

  if (options.title) {
    await page.locator('[data-testid="invite-title-input"]').fill(options.title)
  }

  if (options.department) {
    await page.locator('[data-testid="invite-department-input"]').fill(options.department)
  }

  const submitBtn = page.locator('[data-testid="invite-submit-btn"]')
  await expect(submitBtn).toBeEnabled()
  await submitBtn.click()

  await expect(modal).not.toBeVisible({ timeout: 10_000 })
}

/**
 * Edit existing user role via EditUserModal.
 */
export async function editUserRoleViaModal(
  page: Page,
  userId: string,
  newRole: 'admin' | 'editor' | 'viewer',
): Promise<void> {
  const editBtn = page.locator(`[data-testid="edit-user-btn-${userId}"]`)
  await expect(editBtn).toBeVisible({ timeout: 10_000 })
  await editBtn.click()

  const modal = page.locator('[data-testid="edit-user-modal"]')
  await expect(modal).toBeVisible({ timeout: 5_000 })

  const roleSelect = page.locator('[data-testid="edit-role-select"]')
  await expect(roleSelect).toBeVisible()
  await roleSelect.selectOption(newRole)

  // Acknowledge privilege modification callout if prompted
  const callout = page.locator('[data-testid="edit-confirmation-callout"]')
  if (await callout.isVisible().catch(() => false)) {
    const confirmCheck = page.locator('[data-testid="edit-confirm-checkbox"]')
    await expect(confirmCheck).toBeVisible()
    await confirmCheck.check()
  }

  const submitBtn = page.locator('[data-testid="edit-submit-btn"]')
  await expect(submitBtn).toBeEnabled()
  await submitBtn.click()

  await expect(modal).not.toBeVisible({ timeout: 10_000 })
}

/**
 * Assert Kusari design partner feature flag suppression across Sidebar links.
 */
export async function assertKusariSidebarSuppression(page: Page): Promise<void> {
  const nav = page.locator('#sl-sidebar-nav')
  await expect(nav).toBeVisible({ timeout: 10_000 })

  // 1. Assert core governance & compliance surfaces ARE visible
  await expect(nav.locator('a[href="/policies"]')).toBeVisible()
  await expect(nav.locator('a[href="/compliance"]')).toBeVisible()
  await expect(nav.locator('a[href="/audit"]')).toBeVisible()
  await expect(nav.locator('a[href="/settings"]')).toBeVisible()

  // 2. Assert suppressed demo & advanced surfaces are HIDDEN (not rendered)
  await expect(nav.locator('a[href="/fleet"]')).not.toBeVisible()
  await expect(nav.locator('a[href="/fleet/audience"]')).not.toBeVisible()
  await expect(nav.locator('a[href="/supercred"]')).not.toBeVisible()
  await expect(nav.locator('a[href="/rbac-analysis"]')).not.toBeVisible()
  await expect(nav.locator('a[href="/rbac-explorer"]')).not.toBeVisible()
  await expect(nav.locator('a[href="/collusion-access"]')).not.toBeVisible()
}
