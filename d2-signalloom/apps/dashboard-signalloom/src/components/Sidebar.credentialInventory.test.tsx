/**
 * Nav wiring for the Credential Inventory page.
 *
 * Lives in its own file rather than in Sidebar.test.tsx because that suite's
 * module-level useAuth0 mock is a non-superadmin user, and the superadmin block
 * only renders for an eligible one.
 *
 * Links are located by href, never by accessible name — nav anchors render count
 * badges, so their names shift (see commit 1066e66).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import Sidebar from './Sidebar'
import { AppContext } from '../App'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    // Matches isSuperadminEligible()'s demo-user allow-list.
    user: { name: 'demo-user', email: 'demo-user@signalloom.local' },
    logout: vi.fn(),
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  }),
}))

vi.mock('../api/client', () => ({
  api: {
    settings: vi.fn().mockResolvedValue({
      tenant_id: 'tenant-1', org_name: 'Acme', plan_tier: 'growth', agent_count: 3,
      billing_tier: null, api_key_status: 'active', selected_frameworks: [],
      consent_required: false, cookie_preferences: null,
      preferred_scan_cadence_hours: 24, alert_email: null, alert_threshold: 1,
    }),
    nhi: {
      discovered: vi.fn().mockResolvedValue({
        accounts: [], total: 0,
        summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 },
      }),
    },
  },
}))

const NAV_HREF = '/credential-inventory'

function renderSidebar(superadmin: boolean) {
  return render(
    <MemoryRouter>
      <AppContext.Provider value={{
        failingControls: 0, setFailingControls: () => undefined,
        helpOpen: false, setHelpOpen: () => undefined,
        apiKeyReveal: null, setApiKeyReveal: () => undefined,
        cookieSettingsOpen: false, setCookieSettingsOpen: () => undefined,
        connectedProviderCount: 0, totalProviderCount: 0,
        needsOnboarding: null, refreshOnboardingState: () => Promise.resolve(),
        superadmin, setSuperadmin: () => undefined,
      }}>
        <Sidebar />
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('Credential Inventory nav entry', () => {
  it('appears in the superadmin block when superadmin is on', async () => {
    renderSidebar(true)
    await waitFor(() => {
      expect(document.querySelector(`nav a[href="${NAV_HREF}"]`)).not.toBeNull()
    })
  })

  it('is hidden when superadmin is off — it is an admin surface', async () => {
    renderSidebar(false)
    // Wait for the nav to settle before asserting an absence.
    await waitFor(() => expect(document.querySelector('nav a[href="/agents"]')).not.toBeNull())
    expect(document.querySelector(`nav a[href="${NAV_HREF}"]`)).toBeNull()
  })

  it('sits alongside the other trust-fabric admin surfaces', async () => {
    renderSidebar(true)
    await waitFor(() => {
      expect(document.querySelector(`nav a[href="${NAV_HREF}"]`)).not.toBeNull()
    })
    expect(document.querySelector('nav a[href="/cryptography"]')).not.toBeNull()
  })

  it('does not consume a numbered keyboard shortcut', async () => {
    renderSidebar(true)
    const link = await waitFor(() => {
      const el = document.querySelector(`nav a[href="${NAV_HREF}"]`)
      expect(el).not.toBeNull()
      return el as HTMLElement
    })
    // Shortcut badges are rendered on hover for the first nine primary items
    // only; a superadmin entry must never claim one.
    expect(link.textContent).toBe('Credential Inventory')
    expect(screen.getAllByRole('link').findIndex((a) => a.getAttribute('href') === NAV_HREF))
      .toBeGreaterThan(8)
  })
})
