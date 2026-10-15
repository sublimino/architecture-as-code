import { test, expect } from './fixtures'
import { login } from './helpers'

test.describe('Admin Features Page Auth Guard & 401 Prevention', () => {
  test('navigating to /admin/features fires authenticated requests with zero 401s', async ({ page }) => {
    // 1. Authenticate into the dashboard
    await login(page, { demoMode: false })

    const unauthorizedRequests: string[] = []

    // 2. Track all network responses to admin features endpoints
    page.on('response', (response) => {
      const url = response.url()
      if (url.includes('/api/v1/admin/features')) {
        if (response.status() === 401) {
          unauthorizedRequests.push(`401 Unauthorized: ${url}`)
        }
      }
    })

    // 3. Navigate to /admin/features
    const baseUrl = page.url().split('#')[0].replace(/\/(agents|discovery|settings|admin).*/, '')
    await page.goto(`${baseUrl}/admin/features`, {
      waitUntil: 'domcontentloaded',
    })

    // 4. Assert page elements render properly
    const heading = page.getByRole('heading', { level: 1, name: 'Feature Flags & Presets' })
    await expect(heading).toBeVisible({ timeout: 15_000 })

    const presetBundlesCard = page.locator('[data-testid="preset-bundles-card"]')
    await expect(presetBundlesCard).toBeVisible({ timeout: 15_000 })

    // 5. Invariant: Zero 401 responses occurred on initial load or background queries!
    expect(
      unauthorizedRequests,
      `Expected zero 401 responses on /admin/features, but encountered: ${unauthorizedRequests.join(', ')}`,
    ).toEqual([])
  })
})
