import { test, expect } from './fixtures'
import { login } from './helpers'

// What the page drew between navigation start and the end of the test,
// recorded in the page itself by a MutationObserver installed before any
// script of the app runs. Polling from the test process missed whatever
// appeared and vanished between two polls, and could only start once the
// intercepted request had been seen.
type Seen = { notFound: boolean; loader: boolean }
// This directory compiles with lib ESNext only (no DOM, see tsconfig.json), so
// the in-page code names the few browser globals it touches structurally.
type PageGlobals = {
  document: {
    querySelector(selector: string): unknown
    body: { textContent: string | null } | null
  }
  MutationObserver: new (callback: () => void) => {
    observe(target: unknown, options: Record<string, boolean>): void
  }
  __reproduce404Seen?: Seen
}

test.describe('Initial Page Load & FeatureGate Invariant', () => {
  test('navigating to /agents under slow network must never show 404, only loading indicator', async ({ page }) => {
    // Authenticate into the dashboard
    await login(page, { demoMode: false })

    await page.addInitScript(() => {
      const g = globalThis as unknown as PageGlobals
      const seen: Seen = { notFound: false, loader: false }
      g.__reproduce404Seen = seen
      const check = () => {
        if (
          g.document.querySelector('[data-testid="not-found"]') ||
          g.document.body?.textContent?.includes('Page Not Found')
        ) {
          seen.notFound = true
        }
        if (g.document.querySelector('[data-testid="route-loading"]')) {
          seen.loader = true
        }
      }
      new g.MutationObserver(check).observe(g.document, { childList: true, subtree: true, characterData: true })
    })

    // Hold every /api/v1/features request until the loader has been asserted
    // on screen, rather than delaying it by a guessed amount: the flags are
    // provably unresolved for as long as the assertions below take.
    let release!: () => void
    const released = new Promise<void>((resolve) => {
      release = resolve
    })
    let held = 0
    await page.route('**/api/v1/features**', async (route) => {
      held += 1
      await released
      await route.continue()
    })

    // Completion is the response actually arriving, not route.continue()
    // returning. Armed before navigation so the response cannot be missed.
    const featuresResponse = page.waitForResponse(
      (resp) => new URL(resp.url()).pathname === '/api/v1/features',
      { timeout: 15_000 },
    )

    await page.goto((page.url().split('#')[0] ?? '').replace(/\/(agents|discovery|settings).*/, '') + '/agents', {
      waitUntil: 'domcontentloaded',
    })

    // While the flags are held: the loader is on screen and no 404 is.
    await expect.poll(() => held, { message: 'the dashboard never requested /api/v1/features' }).toBeGreaterThan(0)
    await expect(page.getByTestId('route-loading')).toBeVisible()
    await expect(page.getByTestId('not-found')).toHaveCount(0)

    release()
    const response = await featuresResponse
    expect(response.ok(), `/api/v1/features answered ${response.status()}`).toBe(true)
    await expect(page.getByRole('heading', { level: 1, name: 'Agents' })).toBeVisible({ timeout: 15_000 })

    const seen = await page.evaluate(() => (globalThis as unknown as PageGlobals).__reproduce404Seen)
    expect(seen, 'the in-page observer was not installed').toBeDefined()
    expect(seen!.loader, 'no loading indicator was drawn while the flags resolved').toBe(true)
    // Invariant: under slow feature resolution, 404 must never flash.
    expect(seen!.notFound, '404 Page Not Found was drawn during initial page load').toBe(false)
  })
})
