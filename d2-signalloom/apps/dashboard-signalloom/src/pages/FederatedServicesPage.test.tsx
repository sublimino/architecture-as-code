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

    // The measured half of the live response: trust domains and SPIFFE IDs
    // observed on real workloads. Everything else is refused by name. This is
    // the shape fe-signalloom's federation_state actually emits.
    const panel = <T,>(items: T[], extra: Record<string, unknown> = {}) => ({
      available: true as const,
      items,
      evidence_state: 'observed' as const,
      assurance: 'observed',
      freshness: 'fresh' as const,
      observed_at: '2026-10-12T00:00:00Z',
      evidence_source: 'trust-topology collector',
      reason: 'SPIFFE IDs observed on in-cluster workloads',
      unmeasured_fields: [],
      ...extra,
    })
    const refused = (reason: string) => ({
      available: false as const,
      items: [],
      evidence_state: 'unavailable' as const,
      assurance: 'unavailable',
      freshness: 'unavailable' as const,
      observed_at: '2026-10-12T00:00:00Z',
      evidence_source: null,
      reason,
      unmeasured_fields: [],
    })

    const LIVE_STATE = () => ({
      generated_at: '2026-10-12T00:00:00Z',
      tenant: 'tenant-a',
      collectors: { kubernetes: { status: 'ok', observed_at: '2026-10-12T00:00:00Z', reason: '' } },
      zones: panel(
        [{ name: 'osramp.local', domain: 'osramp.local', identities: 1, clusters: null, servers: null, status: null }],
        {
          unmeasured_fields: [
            { field: 'clusters', reason: 'no source enumerates clusters per trust domain' },
            { field: 'servers', reason: 'counting SPIRE servers needs a read this service cannot perform' },
            { field: 'status', reason: 'zone status is bundle-exchange state and nothing collects it' },
          ],
        },
      ),
      identities: panel(
        [{ uri: 'spiffe://osramp.local/ns/tenant-a/sa/alpha', workload: 'alpha', ns: 'tenant-a', sa: 'alpha', svid: null, expiry: null }],
        {
          unmeasured_fields: [
            { field: 'svid', reason: 'the SVID type lives in the SVID, which this service never handles' },
            { field: 'expiry', reason: 'SVID expiry is carried inside the SVID' },
          ],
        },
      ),
      federations: refused('a federation is a ClusterFederatedTrustDomain object and nothing reads one'),
      services: refused('the Cofide Connect xDS fabric this panel describes is not deployed'),
      policies: refused('attestation policies are ClusterSPIFFEID resources and no collector reads them'),
      events: refused('no federation event stream is collected, published or stored'),
      counts: {
        trust_zones: 1,
        spiffe_identities: 1,
        federations: null,
        federated_services: null,
        attestation_policies: null,
        attestation_success_rate: null,
        active_alerts: null,
      },
      unmeasured_fields: [
        { field: 'attestation_success_rate', reason: 'no attestation outcome stream is collected' },
        { field: 'active_alerts', reason: 'there is no federation alert source' },
      ],
    })

    const renderLive = async (state: unknown = LIVE_STATE()) => {
      const spy = vi
        .spyOn(api.federation, 'summary')
        .mockResolvedValue(state as Awaited<ReturnType<typeof api.federation.summary>>)
      render(
        <MemoryRouter>
          <FederatedServicesPage />
        </MemoryRouter>,
      )
      await waitFor(() => {
        expect(spy).toHaveBeenCalledTimes(1)
      })
      return spy
    }

    it('renders measured zones and SPIFFE identities from the live API', async () => {
      await renderLive()

      const sourceBanner = screen.getByTestId('federated-source')
      expect(sourceBanner).toHaveTextContent('Live Mode')
      expect(sourceBanner).toHaveTextContent(/Connected to live SPIFFE trust bundle federation/i)

      await waitFor(() => {
        expect(screen.getAllByText('osramp.local').length).toBeGreaterThan(0)
        expect(screen.getByText('spiffe://osramp.local/ns/tenant-a/sa/alpha')).toBeInTheDocument()
      })

      expect(screen.queryByText(/illustrative/i)).toBeNull()
    })

    it('refuses the four panels with no source instead of rendering rows', async () => {
      await renderLive()

      for (const name of ['federations', 'services', 'policies', 'events']) {
        const refusal = await screen.findByTestId(`fed-${name}-unavailable`)
        expect(refusal).toHaveTextContent('Not measured.')
        expect(refusal.textContent?.length ?? 0).toBeGreaterThan(40)
      }
      // A refused panel renders no table at all, so no row and no empty-state
      // that could read as "we looked and there is nothing".
      expect(screen.queryByTestId('fed-federations-toolbar')).toBeNull()
      expect(screen.queryByTestId('fed-federations-empty')).toBeNull()
    })

    it('shows per-field refusals rather than a plausible value', async () => {
      await renderLive()

      const zoneRefusals = await screen.findByTestId('fed-zones-refusals')
      for (const field of ['clusters', 'servers', 'status']) {
        expect(zoneRefusals).toHaveTextContent(field)
      }
      const idRefusals = screen.getByTestId('fed-identities-refusals')
      expect(idRefusals).toHaveTextContent('svid')
      expect(idRefusals).toHaveTextContent('expiry')

      // Refused cells say so in the table body; they are not blank, not zero,
      // and not a badge that reads as a healthy state.
      expect(screen.getAllByTestId('fed-unmeasured-cell').length).toBeGreaterThanOrEqual(4)
      // No zone row carries a status badge: the only 'active' text on the page
      // is the filter chip label, never a claim about a trust zone.
      const zoneRow = screen.getAllByText('osramp.local')[0].closest('tr') as HTMLElement
      expect(zoneRow).not.toBeNull()
      expect(within(zoneRow).queryByText('active')).toBeNull()
      expect(within(zoneRow).queryByText('federated')).toBeNull()
      expect(within(zoneRow).getAllByTestId('fed-unmeasured-cell').length).toBe(3)
    })

    it('reports counts it has and refuses the two it never could', async () => {
      await renderLive()

      expect(screen.getAllByText('Trust zones').length).toBeGreaterThan(0)
      expect(screen.getAllByText('SPIFFE identities').length).toBeGreaterThan(0)
      // Federations / services / policies have no source, so their cards say so
      // rather than showing 0, which would read as "federated nothing" instead
      // of "we do not know".
      expect(screen.getAllByText('not measured').length).toBeGreaterThanOrEqual(3)
      expect(screen.queryByText('99.8')).toBeNull()
      expect(screen.queryByText('99.8%')).toBeNull()
    })

    it('never renders a demo fixture value in live mode', async () => {
      // The mutation this pins: forcing the demo gate false must not change what
      // live mode renders, and no fixture may leak into the live path. The gate
      // symbol is invoked on this path (isDemoMode() in useFederatedServices),
      // so a fixture reaching the screen here would be a live-mode fabrication.
      await renderLive()

      for (const zone of TRUST_ZONES) {
        expect(screen.queryByText(zone.domain)).toBeNull()
      }
      for (const policy of POLICIES) {
        expect(screen.queryByText(policy.name)).toBeNull()
      }
      for (const service of FEDERATED_SERVICES) {
        expect(screen.queryByText(service.service)).toBeNull()
      }
      for (const federation of FEDERATIONS) {
        expect(screen.queryByText(federation.policy)).toBeNull()
      }
    })

    it('treats a panel missing from the response as unavailable, not as empty', async () => {
      const partial: Record<string, unknown> = LIVE_STATE()
      delete partial.identities
      await renderLive(partial)

      const refusal = await screen.findByTestId('fed-identities-unavailable')
      expect(refusal).toHaveTextContent(/carried no identities panel/i)
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

      // A failed live read shows the failure. It does not quietly show fixtures.
      for (const zone of TRUST_ZONES) {
        expect(screen.queryByText(zone.domain)).toBeNull()
      }
      expect(screen.queryByText(/illustrative/i)).toBeNull()
    })
  })
})
