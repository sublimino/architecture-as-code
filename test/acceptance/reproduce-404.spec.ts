import { test, expect } from './fixtures'
import { login } from './helpers'

test.describe('Initial Page Load & FeatureGate Invariant', () => {
  test('navigating to /agents under slow network must never show 404, only loading indicator', async ({ page }) => {
    // Authenticate into the dashboard
    await login(page, { demoMode: false })

    let featuresRequestStarted = false
    let featuresRequestCompleted = false
    let saw404DuringLoading = false

    // Intercept /api/v1/features and delay by 1500ms to simulate slow network / cold start
    await page.route('**/api/v1/features**', async (route) => {
      featuresRequestStarted = true
      await new Promise((resolve) => setTimeout(resolve, 1500))
      await route.continue()
      featuresRequestCompleted = true
    })

    // Poll the DOM during the navigation lifecycle
    const domCheckInterval = setInterval(async () => {
      if (featuresRequestStarted && !featuresRequestCompleted) {
        try {
          const has404 =
            (await page.locator('[data-testid="not-found"]').count()) > 0 ||
            (await page.getByText('Page Not Found').count()) > 0
          if (has404) {
            saw404DuringLoading = true
          }
        } catch {
          // ignore closed context / transient poll errors
        }
      }
    }, 50)

    try {
      // Navigate to /agents
      await page.goto(page.url().split('#')[0].replace(/\/(agents|discovery|settings).*/, '') + '/agents', {
        waitUntil: 'domcontentloaded',
      })

      // Wait for features to complete and page to settle
      await page.waitForResponse((resp) => resp.url().includes('/api/v1/features'), { timeout: 10_000 })
      await expect(page.getByRole('heading', { level: 1, name: 'Agents' })).toBeVisible({ timeout: 15_000 })
    } finally {
      clearInterval(domCheckInterval)
    }

    // Invariant: Under slow network or feature resolution, 404 should NEVER flash or pop up!
    expect(saw404DuringLoading, '404 Page Not Found flashed during initial page load!').toBe(false)
  })
})
