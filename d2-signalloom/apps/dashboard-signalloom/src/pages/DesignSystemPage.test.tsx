import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import DesignSystemPage from './DesignSystemPage'

// The page under test is deliberately provider-free: it imports presentational
// components only, so it must render with no router, no auth context and no API
// client. That is not a nicety — a gallery that needs a live cluster to render
// is a gallery nobody opens. The bare `render()` calls below are the assertion.

const LOADER_VARIANTS = ['Drive', 'Dots', 'Orbit', 'Loom'] as const
const LOADER_SIZES = ['sm', 'md'] as const

/**
 * The live-region roster for the whole page, asserted by name rather than as a
 * ceiling.
 *
 * Every `role="status"` / `role="alert"` is something a screen reader reads out
 * when its content changes, and a component gallery is the one page in the app
 * that mounts a dozen waiting-indicators at once. Left to their defaults that is
 * a wall of simultaneous "Churning" announcements at anyone who opens it.
 *
 * Three separate facts hold the roster down to this, and each is worth failing on:
 *   - the eight gallery PixelLoaders pass `announce={false}`, so they own no
 *     region at all — that is asserted per-loader in its own test below;
 *   - exactly six LoadingState specimens are rendered, because LoadingState has
 *     no `announce` opt-out and every instance is a region by construction;
 *   - CredentialStateNotice's revoked branch is a region too, which is easy to
 *     miss because nothing in its call site says so. Naming it here is the point:
 *     it was found by this assertion failing, not by reading the component.
 *
 * Listed as name/role pairs rather than counted, so a failure says which region
 * appeared or vanished instead of just that a number moved.
 */
const EXPECTED_LIVE_REGIONS: readonly [testId: string, role: string][] = [
  ['credential-state-revoked', 'status'],
  ['ds-loadingstate-block-error', 'alert'],
  ['ds-loadingstate-block-loading', 'status'],
  ['ds-loadingstate-inline-error', 'alert'],
  ['ds-loadingstate-inline-idle', 'status'],
  ['ds-loadingstate-inline-loading', 'status'],
  ['ds-loadingstate-inline-success', 'status'],
]

describe('DesignSystemPage', () => {
  it('renders with no router, auth or API providers', () => {
    expect(() => render(<DesignSystemPage />)).not.toThrow()
    expect(screen.getByRole('heading', { level: 1, name: /Design System/i })).toBeInTheDocument()
  })

  // ── Loaders ───────────────────────────────────────────────────────────────

  it('shows every PixelLoader variant by name, including Loom', () => {
    render(<DesignSystemPage />)
    for (const variant of LOADER_VARIANTS) {
      expect(screen.getByTestId(`ds-loader-caption-${variant}`)).toHaveTextContent(variant)
    }
  })

  it('shows every variant at both sizes', () => {
    render(<DesignSystemPage />)
    for (const variant of LOADER_VARIANTS) {
      for (const size of LOADER_SIZES) {
        expect(screen.getByTestId(`ds-loader-${variant}-${size}`)).toHaveAttribute('data-size', size)
      }
    }
  })

  it('gives the gallery loaders no live region of their own', () => {
    render(<DesignSystemPage />)
    for (const variant of LOADER_VARIANTS) {
      for (const size of LOADER_SIZES) {
        const loader = screen.getByTestId(`ds-loader-${variant}-${size}`)
        expect(loader).not.toHaveAttribute('role')
        expect(loader).not.toHaveAttribute('aria-live')
      }
    }
  })

  it('holds the whole page to its declared live-region roster', () => {
    render(<DesignSystemPage />)
    const actual = [...document.querySelectorAll('[role="status"], [role="alert"]')]
      .map((el) => [el.getAttribute('data-testid') ?? '(no testid)', el.getAttribute('role') ?? ''])
      .sort((a, b) => a[0].localeCompare(b[0]))

    expect(actual).toEqual(EXPECTED_LIVE_REGIONS.map(([id, role]) => [id, role]))
  })

  // ── LoadingState ──────────────────────────────────────────────────────────

  it('shows LoadingState in each phase across both variants', () => {
    render(<DesignSystemPage />)
    expect(screen.getByTestId('ds-loadingstate-inline-idle')).toHaveAttribute('data-status', 'idle')
    expect(screen.getByTestId('ds-loadingstate-inline-loading')).toHaveAttribute('data-status', 'loading')
    expect(screen.getByTestId('ds-loadingstate-inline-success')).toHaveAttribute('data-status', 'success')
    expect(screen.getByTestId('ds-loadingstate-inline-error')).toHaveAttribute('data-status', 'error')
    expect(screen.getByTestId('ds-loadingstate-block-loading')).toHaveAttribute('data-status', 'loading')
    expect(screen.getByTestId('ds-loadingstate-block-error')).toHaveAttribute('data-status', 'error')
  })

  // ── ErrorState ────────────────────────────────────────────────────────────

  it('shows both ErrorState branches — retryable and 401', () => {
    render(<DesignSystemPage />)
    const retryable = screen.getByTestId('ds-errorstate-retry')
    expect(within(retryable).getByTestId('error-retry')).toHaveTextContent('Retry')
    expect(within(retryable).getByText('Failed to load')).toBeInTheDocument()

    const authFailure = screen.getByTestId('ds-errorstate-auth')
    expect(within(authFailure).getByTestId('error-login')).toHaveTextContent('Log in')
    expect(within(authFailure).getByText('Your session has expired')).toBeInTheDocument()
    // isAuthError is what drives the branch, so the 401 specimen must carry a
    // message that actually trips it — otherwise this renders the Retry state
    // and silently documents the wrong thing.
    expect(within(authFailure).queryByTestId('error-retry')).not.toBeInTheDocument()
  })

  // ── Component sections ────────────────────────────────────────────────────

  const SECTIONS = [
    'tokens',
    'pixel-loader',
    'loading-state',
    'error-state',
    'empty-state',
    'status-badge',
    'help-hint',
    'data-table',
    'donut-chart',
    'proof-console',
    'credential-state-notice',
    'dash-kit',
    'not-shown',
  ] as const

  it('renders every documented section with a heading and a when-to-use note', () => {
    render(<DesignSystemPage />)
    for (const id of SECTIONS) {
      const section = screen.getByTestId(`ds-section-${id}`)
      // By testid, not by role: a specimen can bring its own h2 (DashKit's
      // Section does), so `getByRole('heading')` inside a group is ambiguous.
      const heading = within(section).getByTestId(`ds-heading-${id}`)
      expect(heading.tagName).toBe('H2')
      expect(heading.textContent?.trim()).not.toBe('')
      expect(within(section).getByTestId(`ds-when-${id}`).textContent?.trim()).not.toBe('')
    }
  })

  it('renders a swatch for every theme-switched colour token', () => {
    render(<DesignSystemPage />)
    const swatches = within(screen.getByTestId('ds-section-tokens')).getAllByTestId(/^ds-token-/)
    // themes.ts CSS_VAR_NAMES is the declared set; the page must not hand-pick.
    expect(swatches.length).toBeGreaterThanOrEqual(16)
    expect(screen.getByTestId('ds-token---cyan')).toBeInTheDocument()
  })

  it('renders live specimens, not just headings', () => {
    render(<DesignSystemPage />)
    expect(screen.getByText('enterprise_admin'.replace(/_/g, ' '))).toBeInTheDocument()
    expect(screen.getByTestId('ds-datatable-pagination')).toBeInTheDocument()
    expect(screen.getByTestId('ds-proof-console')).toBeInTheDocument()
    expect(screen.getByTestId('credential-state-revoked')).toBeInTheDocument()
    expect(screen.getByText(/No agents match this filter/i)).toBeInTheDocument()
  })

  // ── Coverage ledger ───────────────────────────────────────────────────────

  it('lists the components it could not show, each with a reason', () => {
    render(<DesignSystemPage />)
    const ledger = screen.getByTestId('ds-section-not-shown')
    const rows = within(ledger).getAllByTestId(/^ds-skipped-/)
    expect(rows.length).toBeGreaterThanOrEqual(8)
    for (const row of rows) {
      // A name with no reason beside it is the failure mode this page exists to
      // avoid — an omission that looks like an oversight.
      expect(row.textContent?.trim().length ?? 0).toBeGreaterThan(20)
    }
    expect(within(ledger).getByTestId('ds-skipped-Sidebar')).toBeInTheDocument()
  })
})
