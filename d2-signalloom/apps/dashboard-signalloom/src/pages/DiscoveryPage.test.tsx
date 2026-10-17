import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom'
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

function LocationDisplay() {
  const location = useLocation()
  return <div data-testid="location-display">{location.search}</div>
}

function renderPage(initialEntry = '/discovery') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route
          path="/discovery"
          element={
            <>
              <DiscoveryPage />
              <LocationDisplay />
            </>
          }
        />
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

  it('clicking Attention Required header button selects and filters attention-required workloads', async () => {
    renderPage()
    await screen.findByText('entra-audit-sync')

    const attentionHeaderBtn = screen.getByTestId('attention-required-header-btn')
    await userEvent.click(attentionHeaderBtn)

    // agent-inventory-worker (unowned/in_review), afm-remote-collector (revoked), entra-audit-sync (discovered) remain
    expect(screen.getByText('agent-inventory-worker')).toBeInTheDocument()
    expect(screen.getByText('afm-remote-collector')).toBeInTheDocument()
    // governed-security-scanner (governed, owned) is filtered out
    expect(screen.queryByText('governed-security-scanner')).not.toBeInTheDocument()
  })

  it('clicking unowned alert button filters specifically to unowned workloads', async () => {
    renderPage()
    await screen.findByText('entra-audit-sync')

    const unownedAlertBtn = screen.getByTestId('attention-alert-unowned')
    await userEvent.click(unownedAlertBtn)

    // agent-inventory-worker is unowned
    expect(screen.getByText('agent-inventory-worker')).toBeInTheDocument()
    // entra-audit-sync has owner secops@signalloom.test so it must be filtered out
    expect(screen.queryByText('entra-audit-sync')).not.toBeInTheDocument()
    expect(screen.queryByText('governed-security-scanner')).not.toBeInTheDocument()
  })

  it('clicking workload name opens DiscoveredWorkloadDrawer in-context without navigating away', async () => {
    renderPage()
    await screen.findByText('entra-audit-sync')

    // Workload name button
    const workloadBtn = screen.getByTestId('discovery-workload-name-idp-1')
    await userEvent.click(workloadBtn)

    // Drawer should open and be visible
    const drawer = await screen.findByTestId('discovered-workload-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByTestId('drawer-workload-name')).toHaveTextContent('entra-audit-sync')
    expect(screen.getByTestId('drawer-workload-source')).toHaveTextContent('Entra ID')
    expect(screen.getByTestId('drawer-workload-id')).toHaveTextContent('idp-1')

    // Does NOT navigate to the old account detail page
    expect(screen.queryByText('ACCOUNT DETAIL PAGE')).not.toBeInTheDocument()

    // 4 pillars should be present in the drawer
    expect(screen.getByTestId('drawer-control-recommendations')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-rec-config')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-rec-content')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-rec-supply_chain')).toBeInTheDocument()
    expect(screen.getByTestId('drawer-rec-eu_ai_act')).toBeInTheDocument()
  })

  it('opens DiscoveredWorkloadDrawer directly when deep-linked with ?workload= query parameter', async () => {
    renderPage('/discovery?workload=k8s-1')
    await screen.findByTestId('discovery-workload-name-k8s-1')

    // Drawer should be open for k8s-1
    const drawer = await screen.findByTestId('discovered-workload-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByTestId('drawer-workload-name')).toHaveTextContent('agent-inventory-worker')
    expect(screen.getByTestId('drawer-workload-source')).toHaveTextContent('Local K8s')
    expect(screen.getByTestId('drawer-workload-spiffe-id')).toHaveTextContent('spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-inventory-worker')
  })

  it('closes DiscoveredWorkloadDrawer when close button is clicked', async () => {
    renderPage('/discovery?workload=idp-1')
    await screen.findByTestId('discovery-workload-name-idp-1')

    expect(screen.getByTestId('discovered-workload-drawer')).toBeInTheDocument()

    const closeBtn = screen.getByTestId('drawer-close-btn')
    await userEvent.click(closeBtn)

    expect(screen.queryByTestId('discovered-workload-drawer')).not.toBeInTheDocument()
  })

  it('triggers enrollment from inside DiscoveredWorkloadDrawer', async () => {
    renderPage('/discovery?workload=idp-1')
    await screen.findByTestId('discovery-workload-name-idp-1')

    const drawerEnrollBtn = screen.getByTestId('drawer-enroll-btn')
    await userEvent.click(drawerEnrollBtn)

    await waitFor(() => {
      expect(api.discovery.enroll).toHaveBeenCalledWith('test-token', 'idp-1')
    })
  })

  it('opens DiscoveredWorkloadDrawer when deep-linked by workload name or suffix ID', async () => {
    renderPage('/discovery?workload=agent-inventory-worker')
    await screen.findByTestId('discovery-workload-name-k8s-1')

    const drawer = await screen.findByTestId('discovered-workload-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByTestId('drawer-workload-name')).toHaveTextContent('agent-inventory-worker')
    expect(screen.getByTestId('drawer-workload-id')).toHaveTextContent('k8s-1')
  })

  it('filters workloads using the GitOps filter button in DataTableToolbar', async () => {
    renderPage('/discovery')
    await screen.findByTestId('discovery-workload-name-idp-1')

    const gitopsBtn = screen.getByTestId('discovery-gitops-filter-btn')
    expect(gitopsBtn).toBeInTheDocument()
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'false')

    await userEvent.click(gitopsBtn)
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'true')

    await userEvent.click(gitopsBtn)
    expect(gitopsBtn).toHaveAttribute('aria-pressed', 'false')
  })

  it('navigating with ?agent=agent_01FoEhnKF9QsC5DGmuELhm7G opens the drawer automatically and closing it cleans up the query param', async () => {
    const claudeWorkload = makeWorkload({
      id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'claude-remote-agent',
      source: 'external_services',
      source_label: 'Anthropic Claude',
      namespace: 'claude-env',
      status: 'discovered',
      owner: 'andrew@controlplane.com',
      metadata: { provider_id: 'claude' },
    })

    ;(api.discovery.workloads as ReturnType<typeof vi.fn>).mockResolvedValue({
      workloads: [claudeWorkload, ...mockMultiSourceResponse.workloads],
      total: 6,
      summary: mockMultiSourceResponse.summary,
    })

    renderPage('/discovery?agent=agent_01FoEhnKF9QsC5DGmuELhm7G')
    await screen.findByTestId('discovery-workload-name-agent_01FoEhnKF9QsC5DGmuELhm7G')

    const drawer = await screen.findByTestId('discovered-workload-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByTestId('drawer-workload-name')).toHaveTextContent('claude-remote-agent')
    expect(screen.getByTestId('drawer-workload-id')).toHaveTextContent('agent_01FoEhnKF9QsC5DGmuELhm7G')
    expect(screen.getByTestId('location-display')).toHaveTextContent('agent=agent_01FoEhnKF9QsC5DGmuELhm7G')

    // Close the drawer and verify it cleans up the query param
    const closeBtn = screen.getByTestId('drawer-close-btn')
    await userEvent.click(closeBtn)

    await waitFor(() => {
      expect(screen.queryByTestId('discovered-workload-drawer')).not.toBeInTheDocument()
    })
    expect(screen.getByTestId('location-display')).not.toHaveTextContent('agent=')
  })
})

// ── Design-system audit A3: the Governed badge's background must come from
// a token (var(--teal-bg)), not the raw rgba(20, 184, 166, 0.15) literal —
// rule 1, colour comes only from tokens. ───────────────────────────────────

describe('Discovery page (design-system A3: Governed badge)', () => {
  it('renders the Governed badge with a tokenised background, not a raw rgba literal', async () => {
    renderPage('/discovery')
    const row = await screen.findByTestId('discovery-row-gov-1')
    const badge = within(row).getByText('Governed')
    expect(badge.getAttribute('style') ?? '').not.toMatch(/rgba\(/)
    expect(badge.getAttribute('style')).toContain('var(--teal-bg)')
  })
})

