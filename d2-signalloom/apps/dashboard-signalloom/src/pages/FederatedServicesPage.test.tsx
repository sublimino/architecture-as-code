import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import FederatedServicesPage from './FederatedServicesPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <FederatedServicesPage />
    </MemoryRouter>,
  )
}

describe('FederatedServicesPage', () => {
  it('renders the Federated Services heading', () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Federated Services' })).toBeInTheDocument()
  })

  it('renders the Cofide-inspired sections', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Trust Zones' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Federations' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 2, name: 'Federated Services' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Attestation Policies' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Cofide Go SDK' })).toBeInTheDocument()
  })

  it('renders concrete mock data — a federated service and the Go SDK import', () => {
    renderPage()
    expect(screen.getAllByText('payments-api').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText(/cofide-sdk-go\/cofide/)).toBeInTheDocument()
  })

  it('renders the SPIFFE Identities section with real trust domain URIs', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'SPIFFE Identities' })).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/signalloom\.demo\/ns\/fe-signalloom\/sa\/fe-signalloom/)).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/acme\.partner\.example\/ns\/kyc\/sa\/kyc-lookup/)).toBeInTheDocument()
  })

  it('renders the Federation Events section with activity log', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: 'Federation Events' })).toBeInTheDocument()
    expect(screen.getByText(/Bundle refreshed/)).toBeInTheDocument()
    expect(screen.getByText(/Awaiting signalloom-us bundle acceptance/)).toBeInTheDocument()
  })

  // This page makes the strongest claims of the three superadmin surfaces and
  // has no data path whatsoever. Read next to Credential Inventory's live view
  // it is indistinguishable from one, so the disclosure is what keeps a fixture
  // from being taken for a measurement.
  describe('says out loud that none of it was measured', () => {
    it('leads with a provenance banner rather than presenting fixtures as fact', () => {
      renderPage()
      const banner = screen.getByTestId('federated-source')
      expect(banner).toHaveTextContent(/illustrative/i)
      expect(banner).toHaveTextContent(/no trust zone, federation or SVID below was observed/i)
    })

    it('keeps the proof closed until asked, then names the file the data comes from', async () => {
      const user = userEvent.setup()
      renderPage()
      expect(screen.queryByTestId('federated-proof-console')).toBeNull()

      await user.click(screen.getByTestId('federated-disclose-proof'))
      const panel = screen.getByTestId('federated-proof-console-panel')
      expect(panel).toHaveTextContent('FederatedServicesPage.tsx')
      expect(panel).toHaveTextContent('issues no fetch')
    })

    it('names the commands that would make it real, marked as never run', async () => {
      const user = userEvent.setup()
      renderPage()
      await user.click(screen.getByTestId('federated-disclose-proof'))
      await user.click(screen.getByTestId('federated-proof-console-tab-1'))

      const panel = screen.getByTestId('federated-proof-console-panel')
      expect(panel).toHaveTextContent('spire-server bundle list')
      expect(panel).toHaveTextContent('NOT RUN')
    })
  })

  describe('shared components', () => {
    it('renders statuses through StatusBadge with a fill that actually parses', () => {
      renderPage()
      // DashKit's Pill built its background as `hex(colors.tealLoom, 0.12)`,
      // and that token is the string `var(--teal)` — so every pill on this page
      // was emitting `var(--teal)1f` and rendering with no fill at all.
      const badge = screen.getAllByText('federated', { selector: '.tag' })[0]
      expect(badge.style.background).toContain('color-mix')
      expect(badge.style.color).toBe('var(--teal)')

      const connecting = screen.getAllByText('connecting', { selector: '.tag' })[0]
      expect(connecting.style.color).toBe('var(--cyan)')
    })

    it('explains the jargon that gates federation, from inside a table header', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.hover(screen.getByTestId('federation-policy-help'))
      expect(await screen.findByRole('tooltip')).toHaveTextContent(/Federating two zones does not admit everything/i)
    })

    it('distinguishes an X.509 SVID from a replayable JWT one', async () => {
      const user = userEvent.setup()
      renderPage()

      await user.hover(screen.getByTestId('federation-svid-help'))
      expect(await screen.findByRole('tooltip')).toHaveTextContent(/replayable if it leaks/i)
    })
  })
})
