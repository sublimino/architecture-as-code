import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import FederatedServicesPage from './FederatedServicesPage'
import * as demoModeModule from '../api/demoMode'
import { api } from '../api/client'
import {
  TRUST_ZONES,
  FEDERATIONS,
  FEDERATED_SERVICES,
  POLICIES,
} from '../api/fakeData'

describe('FederatedServicesPage', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    if (typeof localStorage !== 'undefined' && localStorage.clear) {
      localStorage.clear()
    }
  })

  describe('Demo Mode', () => {
    beforeEach(() => {
      vi.spyOn(demoModeModule, 'isDemoMode').mockReturnValue(true)
    })

    it('renders the Federated Services page title and overview copy', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      expect(screen.getByRole('heading', { level: 1, name: 'Federated Services' })).toBeInTheDocument()
      expect(screen.getByText(/Secretless, cross-trust-zone connectivity/i)).toBeInTheDocument()
    })

    it('renders the Demo Mode environment indicator badge and no illustrative copy', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      const sourceBanner = screen.getByTestId('federated-source')
      expect(sourceBanner).toBeInTheDocument()
      expect(sourceBanner).toHaveTextContent('Demo Mode')
      expect(sourceBanner).toHaveTextContent(/Operating against local cryptographic federated identity fixtures/i)

      // Strict Anti-Criterion check: zero occurrences of "illustrative" in DOM
      expect(screen.queryByText(/illustrative/i)).toBeNull()
    })

    it('renders all four StatCards with computed fixture counts', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      expect(screen.getAllByText('Trust zones').length).toBeGreaterThan(0)
      expect(screen.getAllByText('Federations').length).toBeGreaterThan(0)
      expect(screen.getAllByText('Federated services').length).toBeGreaterThan(0)
      expect(screen.getAllByText('Attestation policies').length).toBeGreaterThan(0)

      const activeCount = FEDERATED_SERVICES.filter((s) => s.status === 'active').length
      expect(screen.getByText(`${activeCount}/${FEDERATED_SERVICES.length}`)).toBeInTheDocument()
      expect(screen.getAllByText(String(TRUST_ZONES.length)).length).toBeGreaterThan(0)
    })

    it('renders all six sections and data tables', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      expect(screen.getByRole('heading', { level: 2, name: 'Trust Zones' })).toBeInTheDocument()
      expect(screen.getByRole('heading', { level: 2, name: 'Federations' })).toBeInTheDocument()
      expect(screen.getByRole('heading', { level: 2, name: 'Federated Services' })).toBeInTheDocument()
      expect(screen.getByRole('heading', { level: 2, name: 'Attestation Policies' })).toBeInTheDocument()
      expect(screen.getByRole('heading', { level: 2, name: 'SPIFFE Identities' })).toBeInTheDocument()
      expect(screen.getByRole('heading', { level: 2, name: 'Federation Events' })).toBeInTheDocument()

      // Table data presence
      expect(screen.getAllByText('signalloom-eu').length).toBeGreaterThan(0)
      expect(screen.getByText('eu.signalloom.svc.cluster.local')).toBeInTheDocument()
      expect(screen.getAllByText('payments-api').length).toBeGreaterThan(0)
      expect(screen.getAllByText('ap-payments').length).toBeGreaterThan(0)
      expect(screen.getByText('spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom')).toBeInTheDocument()
    })

    it('supports interactive search and filter bar on Trust Zones table', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      const zonesSection = screen.getByRole('heading', { level: 2, name: 'Trust Zones' }).closest('section')!
      const searchInput = screen.getByTestId('fed-zones-search')
      expect(searchInput).toBeInTheDocument()

      fireEvent.change(searchInput, { target: { value: 'acme' } })
      expect(within(zonesSection).getByText('partner-acme')).toBeInTheDocument()
      expect(within(zonesSection).queryByText('signalloom-eu')).toBeNull()

      fireEvent.change(searchInput, { target: { value: 'nonexistent-zone' } })
      expect(within(zonesSection).getByText('Nothing matches those filters')).toBeInTheDocument()

      fireEvent.change(searchInput, { target: { value: '' } })
      expect(within(zonesSection).getByText('signalloom-eu')).toBeInTheDocument()
    })

    it('toggles proof console disclosure without errors', () => {
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      const proofBtn = screen.getByTestId('federated-disclose-proof')
      expect(proofBtn).toHaveTextContent(/How do we know\?/i)

      fireEvent.click(proofBtn)
      expect(screen.getByTestId('federated-proof-console')).toBeInTheDocument()
      expect(screen.getByText(/Federation Attestation/i)).toBeInTheDocument()
      expect(proofBtn).toHaveTextContent('Hide proof')

      fireEvent.click(proofBtn)
      expect(screen.queryByTestId('federated-proof-console')).toBeNull()
      expect(proofBtn).toHaveTextContent(/How do we know\?/i)
    })
  })

  describe('Live Mode', () => {
    beforeEach(() => {
      vi.spyOn(demoModeModule, 'isDemoMode').mockReturnValue(false)
    })

    it('fetches live data via api.federation.summary and displays Live Mode banner', async () => {
      const mockLiveSummary = {
        zones: [
          { name: 'live-zone-alpha', domain: 'alpha.signalloom.live', clusters: 4, servers: 2, status: 'active' },
        ],
        federations: [
          { left: 'live-zone-alpha', right: 'live-zone-beta', mode: 'bidirectional', policy: 'ap-live-policy', status: 'federated' },
        ],
        services: [
          { service: 'live-order-service', home: 'live-zone-alpha', consumer: 'live-zone-beta', endpoint: 'orders.live:8443', transport: 'Cofide Go SDK', status: 'active' },
        ],
        policies: [
          { name: 'ap-live-policy', selector: 'k8s:ns:orders', zones: 'alpha, beta' },
        ],
        identities: [
          { uri: 'spiffe://live.domain/ns/orders/sa/order-svc', workload: 'service', ns: 'orders', sa: 'order-svc', svid: 'X.509', expiry: '2027-01-01T00:00:00Z' },
        ],
        events: [
          { ts: '2026-09-29T10:00:00Z', zone: 'live-zone-alpha', event: 'Live Bundle Sync', detail: 'Trust bundle synced', severity: 'info' },
        ],
      }

      const summarySpy = vi.spyOn(api.federation, 'summary').mockResolvedValue(mockLiveSummary)

      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      await waitFor(() => {
        expect(summarySpy).toHaveBeenCalledTimes(1)
      })

      const sourceBanner = screen.getByTestId('federated-source')
      expect(sourceBanner).toHaveTextContent('Live Mode')
      expect(sourceBanner).toHaveTextContent(/Connected to live SPIFFE trust bundle federation/i)

      await waitFor(() => {
        expect(screen.getAllByText('live-zone-alpha').length).toBeGreaterThan(0)
        expect(screen.getByText('alpha.signalloom.live')).toBeInTheDocument()
        expect(screen.getByText('live-order-service')).toBeInTheDocument()
        expect(screen.getAllByText('ap-live-policy').length).toBeGreaterThan(0)
        expect(screen.getByText('spiffe://live.domain/ns/orders/sa/order-svc')).toBeInTheDocument()
      })

      // Strict Anti-Criterion check: zero occurrences of "illustrative" in Live Mode
      expect(screen.queryByText(/illustrative/i)).toBeNull()
    })

    it('renders error boundary alert when live fetch fails', async () => {
      vi.spyOn(api.federation, 'summary').mockRejectedValue(new Error('Network error: Gateway timeout'))

      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )

      await waitFor(() => {
        const errorElement = screen.getByTestId('federated-error')
        expect(errorElement).toBeInTheDocument()
        expect(errorElement).toHaveTextContent('Network error: Gateway timeout')
      })

      expect(screen.queryByText(/illustrative/i)).toBeNull()
    })
  })
})
