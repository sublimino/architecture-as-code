import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import DiscoveryPage from './DiscoveryPage'
import { api } from '../api/client'
import type { DiscoveryWorkload, DiscoveryWorkloadsResponse } from '../types/api'

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

vi.mock('../api/client', () => ({
  api: {
    discovery: {
      workloads: vi.fn(),
      autoclaimNamespace: vi.fn(),
      enroll: vi.fn(),
      dismiss: vi.fn(),
    },
    nhi: {
      discovered: vi.fn(),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'enrollment_requested' }),
      dismissAccount: vi.fn().mockResolvedValue({ account_id: 'acct-1', status: 'dismissed' }),
    },
    agents: {
      list: vi.fn().mockResolvedValue({ agents: [] }),
      claim: vi.fn(),
      autoclaimDiscovered: vi.fn(),
    },
  },
}))

function makeWorkload(overrides: Partial<DiscoveryWorkload> = {}): DiscoveryWorkload {
  return {
    id: 'workload-1',
    name: 'svc-billing-sync',
    source: 'idp',
    source_label: 'Entra ID',
    namespace: 'identity-entra',
    status: 'discovered',
    owner: 'alice@signalloom.test',
    spiffe_id: null,
    model: 'gpt-4o',
    last_seen_at: '2026-07-20T00:00:00Z',
    recommendations: {
      config: 'pass',
      content: 'recommended',
      supply_chain: 'warning',
      eu_ai_act: 'pass',
    },
    metadata: { privilege_level: 'standard' },
    ...overrides,
  }
}

const mockMultiSourceResponse: DiscoveryWorkloadsResponse = {
  workloads: [
    makeWorkload({
      id: 'idp-1',
      name: 'entra-audit-sync',
      source: 'idp',
      source_label: 'Entra ID',
      namespace: 'identity-entra',
      status: 'discovered',
      owner: 'secops@signalloom.test',
    }),
    makeWorkload({
      id: 'k8s-1',
      name: 'agent-inventory-worker',
      source: 'local_k8s',
      source_label: 'Local K8s',
      namespace: 'fe-signalloom-agents',
      status: 'in_review',
      owner: null,
      spiffe_id: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-inventory-worker',
    }),
    makeWorkload({
      id: 'afm-1',
      name: 'afm-remote-collector',
      source: 'external_k8s',
      source_label: 'AFM Cluster',
      namespace: 'staging-workloads',
      status: 'revoked',
      owner: 'compliance@signalloom.test',
    }),
    makeWorkload({
      id: 'ext-1',
      name: 'cloudrun-prompt-processor',
      source: 'external_services',
      source_label: 'Cloud Run',
      namespace: 'gcp-europe-west1',
      status: 'ignored',
      owner: 'ai-ops@signalloom.test',
    }),
    makeWorkload({
      id: 'gov-1',
      name: 'governed-security-scanner',
      source: 'local_k8s',
      source_label: 'Local K8s',
      namespace: 'fe-signalloom-agents',
      status: 'governed',
      owner: 'platform@signalloom.test',
      spiffe_id: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/governed-security-scanner',
    }),
  ],
  total: 5,
  summary: {
    total_discovered: 1,
    in_review: 1,
    ignored: 1,
    revoked: 1,
    governed: 1,
  },
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/discovery']}>
      <Routes>
        <Route path="/discovery" element={<DiscoveryPage />} />
        <Route path="/discovery/accounts/:accountId" element={<div>ACCOUNT DETAIL PAGE</div>} />
        <Route path="/onboarding" element={<div>ONBOARDING WIZARD</div>} />
      </Routes>
    </MemoryRouter>
  )
}

describe('DiscoveryPage Super Datatable', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.nhi.scans as ReturnType<typeof vi.fn>).mockResolvedValue({ scans: [] })
    ;(api.discovery.workloads as ReturnType<typeof vi.fn>).mockResolvedValue(mockMultiSourceResponse)
    ;(api.discovery.autoclaimNamespace as ReturnType<typeof vi.fn>).mockResolvedValue({
      total_claimed: 2,
      claimed: [
        { namespace: 'fe-signalloom-agents', spiffe_id: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-inventory-worker', status: 'granted' },
        { namespace: 'fe-signalloom-agents', spiffe_id: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/governed-security-scanner', status: 'granted' },
      ],
    })
    ;(api.discovery.enroll as ReturnType<typeof vi.fn>).mockResolvedValue({ status: 'in_review' })
    ;(api.discovery.dismiss as ReturnType<typeof vi.fn>).mockResolvedValue({ status: 'ignored' })
  })

  it('renders all four connector sources and all discovery states in Super Datatable', async () => {
    renderPage()

    expect(await screen.findByText('Shadow AI & Multi-Source Discovery')).toBeInTheDocument()
    expect(screen.getByText('entra-audit-sync')).toBeInTheDocument()
    expect(screen.getByText('agent-inventory-worker')).toBeInTheDocument()
    expect(screen.getByText('afm-remote-collector')).toBeInTheDocument()
    expect(screen.getByText('cloudrun-prompt-processor')).toBeInTheDocument()
    expect(screen.getByText('governed-security-scanner')).toBeInTheDocument()

    // Assert sources visible
    expect(screen.getByText('Entra ID')).toBeInTheDocument()
    expect(screen.getByText('Cloud Run')).toBeInTheDocument()
    expect(screen.getAllByText('Local K8s').length).toBeGreaterThan(0)
    expect(screen.getByText('AFM Cluster')).toBeInTheDocument()
  })

  it('renders control recommendations badges and policy requirement hints', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    // Find control badges
    const cfgBadges = screen.getAllByTestId('control-rec-badge-config')
    expect(cfgBadges.length).toBeGreaterThan(0)

    const euBadges = screen.getAllByTestId('control-rec-badge-eu_ai_act')
    expect(euBadges.length).toBeGreaterThan(0)

    // Click on CFG badge to reveal requirement tooltip
    await userEvent.click(cfgBadges[0])
    expect(screen.getByText(/credential confinement policies/i)).toBeInTheDocument()
  })

  it('filters workloads by connector source facet', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    // Click IDP source facet
    const idpFacetBtn = screen.getByTestId('discovery-source-facet-idp')
    await userEvent.click(idpFacetBtn)

    expect(screen.getByText('entra-audit-sync')).toBeInTheDocument()
    expect(screen.queryByText('afm-remote-collector')).not.toBeInTheDocument()
    expect(screen.queryByText('cloudrun-prompt-processor')).not.toBeInTheDocument()
  })

  it('filters workloads by discovery lifecycle state facet', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    // Click 'Revoked' state facet
    const revokedFacetBtn = screen.getByTestId('discovery-state-facet-revoked')
    await userEvent.click(revokedFacetBtn)

    expect(screen.getByText('afm-remote-collector')).toBeInTheDocument()
    expect(screen.queryByText('entra-audit-sync')).not.toBeInTheDocument()
    expect(screen.queryByText('cloudrun-prompt-processor')).not.toBeInTheDocument()
  })

  it('filters workloads by namespace dropdown select', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    const nsSelect = screen.getByTestId('discovery-namespace-select')
    await userEvent.selectOptions(nsSelect, 'gcp-europe-west1')

    expect(screen.getByText('cloudrun-prompt-processor')).toBeInTheDocument()
    expect(screen.queryByText('entra-audit-sync')).not.toBeInTheDocument()
  })

  it('searches workloads by name or owner query', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    const searchInput = screen.getByTestId('discovery-search-input')
    await userEvent.type(searchInput, 'prompt-processor')

    expect(screen.getByText('cloudrun-prompt-processor')).toBeInTheDocument()
    expect(screen.queryByText('entra-audit-sync')).not.toBeInTheDocument()
  })

  it('clears active filters via ToolbarClear button', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    // Apply search filter
    const searchInput = screen.getByTestId('discovery-search-input')
    await userEvent.type(searchInput, 'remote-collector')
    expect(screen.queryByText('entra-audit-sync')).not.toBeInTheDocument()

    // Click Clear filters
    const clearBtn = screen.getByTestId('discovery-clear-filters')
    await userEvent.click(clearBtn)

    expect(screen.getByText('entra-audit-sync')).toBeInTheDocument()
    expect(screen.getByText('afm-remote-collector')).toBeInTheDocument()
  })

  it('opens Auto-Claim Namespace modal and triggers bulk onboarding', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    // Click Auto-Claim Namespace toolbar button
    const autoClaimBtn = screen.getByTestId('autoclaim-namespace-btn')
    await userEvent.click(autoClaimBtn)

    // Modal dialog is displayed
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByText('Auto-Claim Discovered Namespace')).toBeInTheDocument()

    // Select target namespace and confirm
    const modalSelect = screen.getByTestId('autoclaim-modal-namespace-select')
    await userEvent.selectOptions(modalSelect, 'fe-signalloom-agents')

    const confirmBtn = screen.getByTestId('autoclaim-modal-confirm-btn')
    await userEvent.click(confirmBtn)

    await waitFor(() => {
      expect(api.discovery.autoclaimNamespace).toHaveBeenCalledWith('test-token', 'fe-signalloom-agents')
    })

    // Feedback notification toast appears
    expect(await screen.findByText(/Successfully auto-claimed 2 workload\(s\)/i)).toBeInTheDocument()
  })

  it('handles inline Claim / Enroll row action and transitions status', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    const enrollBtn = screen.getByTestId('enroll-workload-btn-idp-1')
    await userEvent.click(enrollBtn)

    await waitFor(() => {
      expect(api.discovery.enroll).toHaveBeenCalledWith('test-token', 'idp-1')
    })

    expect(await screen.findByText(/enrolled into governance review/i)).toBeInTheDocument()
  })

  it('handles inline Ignore / Dismiss row action and transitions status', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    const dismissBtn = screen.getByTestId('dismiss-workload-btn-idp-1')
    await userEvent.click(dismissBtn)

    await waitFor(() => {
      expect(api.discovery.dismiss).toHaveBeenCalledWith('test-token', 'idp-1')
    })

    expect(await screen.findByText(/dismissed/i)).toBeInTheDocument()
  })

  it('navigates to /onboarding when Connect Directory button is clicked', async () => {
    renderPage()

    await screen.findByText('entra-audit-sync')

    const ctaBtn = screen.getByRole('button', { name: /Connect Directory \/ Clusters/i })
    await userEvent.click(ctaBtn)

    expect(await screen.findByText('ONBOARDING WIZARD')).toBeInTheDocument()
  })
})
