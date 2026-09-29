import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock recharts to avoid SVG rendering issues in jsdom
vi.mock('recharts', () => ({
  ResponsiveContainer: ({ children }: { children: React.ReactNode }) => <div data-testid="responsive-container">{children}</div>,
  AreaChart: ({ children }: { children: React.ReactNode }) => <div data-testid="area-chart">{children}</div>,
  Area: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
}))

// Mock the API client and fairApi
vi.mock('../api/fairApi', () => ({
  fairApi: {
    fetchFrameworkVersions: vi.fn().mockResolvedValue([
      { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.1', status: 'active', isDefault: true },
      { frameworkId: 'eu-ai-act', name: 'EU AI Act', version: 'v2.0', status: 'retired', isDefault: false },
      { frameworkId: 'nist-800-53', name: 'NIST 800-53', version: 'v2.1', status: 'active', isDefault: true },
      { frameworkId: 'iso-42001', name: 'ISO 42001', version: 'v1.0-draft', status: 'draft', isDefault: false },
    ]),
    calculateLossExceedance: vi.fn().mockImplementation((ale: number, tvar: number) => {
      if (!ale && !tvar) return []
      return [
        { probability: 100, loss: ale, label: '100%' },
        { probability: 50, loss: Math.round((ale + tvar) / 2), label: '50%' },
        { probability: 0, loss: tvar, label: '0%' },
      ]
    }),
    currentSource: () => 'riskctl',
  },
  FAIR_API_PREFIX: '/v1/risk',
  FAIR_VERSIONS_PREFIX: '/v1/fair/versions',
}))

vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      scan: vi.fn().mockResolvedValue({
        checks: [],
        summary: {
          totalChecks: 20,
          passed: 15,
          failed: 5,
          currency: 'GBP',
          totalAle: { amount: 200000, currency: 'GBP' },
          totalVar95: { amount: 800000, currency: 'GBP' },
          totalTvar: { amount: 1200000, currency: 'GBP' },
          totalCarried: { amount: 100000, currency: 'GBP' },
          scanTimestamp: '2026-07-27T12:00:00Z',
          frameworks: [
            { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v2.1', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposure: { amount: 60000, currency: 'GBP' } },
            { id: 'nist-800-53', name: 'NIST 800-53', versions: ['v2.1'], totalControls: 10, passedControls: 8, failedControls: 2, totalExposure: { amount: 40000, currency: 'GBP' } },
          ],
        },
      }),
    },
    compliance: {
      posture: vi.fn().mockResolvedValue({
        agents: [
          { id: 'agent-1', agent_id: 'agent-1', name: 'Sentinel Alpha', agent_name: 'Sentinel Alpha', lifecycle_state: 'Governed', namespace: 'fe-signalloom-agents' },
          { id: 'agent-2', agent_id: 'agent-2', name: 'Sentinel Beta', agent_name: 'Sentinel Beta', lifecycle_state: 'Governed', namespace: 'fe-signalloom-agents' },
          { id: 'agent-3', agent_id: 'agent-3', name: 'Sentinel Gamma', agent_name: 'Sentinel Gamma', lifecycle_state: 'Governed', namespace: 'default' },
          { id: 'agent-4', agent_id: 'agent-4', name: 'Shadow Worker', agent_name: 'Shadow Worker', lifecycle_state: 'Discovered', namespace: 'default' },
        ] as any,
      }),
    },
    agents: {
      list: vi.fn().mockResolvedValue({
        agents: [
          { id: 'agent-1', name: 'Sentinel Alpha', lifecycle_state: 'Governed', namespace: 'fe-signalloom-agents' },
          { id: 'agent-2', name: 'Sentinel Beta', lifecycle_state: 'Governed', namespace: 'fe-signalloom-agents' },
          { id: 'agent-3', name: 'Sentinel Gamma', lifecycle_state: 'Governed', namespace: 'default' },
          { id: 'agent-4', name: 'Shadow Worker', lifecycle_state: 'Discovered', namespace: 'default' },
        ],
        total: 4,
      } as any),
    },
  },
}))

import RiskExposurePage from './RiskExposurePage'
import { api } from '../api/client'
import { fairApi } from '../api/fairApi'

function renderPage() {
  return render(
    <MemoryRouter>
      <RiskExposurePage />
    </MemoryRouter>,
  )
}

describe('RiskExposurePage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders the Risk Exposure heading', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Risk Exposure' })).toBeInTheDocument()
  })

  it('renders big stat cards with GBP values', async () => {
    renderPage()
    expect(await screen.findByText('Total ALE')).toBeInTheDocument()
    expect(await screen.findByText(/Total VaR/)).toBeInTheDocument()
    expect(await screen.findByText('Total TVaR')).toBeInTheDocument()
    expect(await screen.findByText('Carried Risk')).toBeInTheDocument()
  })

  it('renders risk values from the latest policy scan response', async () => {
    renderPage()
    expect((await screen.findAllByText('£200,000')).length).toBeGreaterThan(0)
    expect(api.compliancePolicy.scan).toHaveBeenCalledWith('test-token', {
      namespace: 'default', policyVersion: 'v2.0', frameworks: [],
    })
  })

  it('renders calibration source tags', async () => {
    renderPage()
    const tags = await screen.findAllByText('industry-indicative')
    expect(tags.length).toBeGreaterThanOrEqual(4)
  })

  it('renders the loss exceedance area chart', async () => {
    renderPage()
    await screen.findByText('Total ALE')
    expect(screen.getByTestId('area-chart')).toBeInTheDocument()
  })

  it('renders per-framework breakdown table with status badges', async () => {
    renderPage()
    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()
    expect(await screen.findByText('NIST 800-53')).toBeInTheDocument()
    // Status badges rendered next to framework identifiers
    const activeBadges = await screen.findAllByTestId('status-badge-active')
    expect(activeBadges.length).toBeGreaterThanOrEqual(2)
  })

  it('fetches dynamic versions from API and populates version selector', async () => {
    renderPage()
    await screen.findByText('Total ALE')
    expect(fairApi.fetchFrameworkVersions).toHaveBeenCalled()

    const select = screen.getByTestId('version-select') as HTMLSelectElement
    expect(select).toBeInTheDocument()
    // Options derived from API mock (v2.1, v2.0, v1.0-draft)
    await waitFor(() => {
      const options = Array.from(select.options).map((o) => o.value)
      expect(options).toContain('v2.1')
      expect(options).toContain('v2.0')
    })
  })

  it('allows changing policy version to trigger recalculation', async () => {
    renderPage()
    await screen.findByText('Total ALE')
    const select = screen.getByTestId('version-select')

    fireEvent.change(select, { target: { value: 'v2.1' } })
    await waitFor(() => {
      expect(api.compliancePolicy.scan).toHaveBeenCalledWith('test-token', {
        namespace: 'default', policyVersion: 'v2.1', frameworks: [],
      })
    })
  })

  it('allows changing namespace from namespace selector', async () => {
    renderPage()
    await screen.findByText('Total ALE')
    const nsSelect = screen.getByTestId('namespace-select')

    fireEvent.change(nsSelect, { target: { value: 'fe-signalloom-agents' } })
    await waitFor(() => {
      expect(api.compliancePolicy.scan).toHaveBeenCalledWith('test-token', {
        namespace: 'fe-signalloom-agents', policyVersion: 'v2.0', frameworks: [],
      })
    })
  })

  it('renders population segmented filter buttons and adjusts risk metrics on selection', async () => {
    renderPage()
    // Initial All Agents tab
    expect(await screen.findByTestId('population-filter')).toBeInTheDocument()
    const allBtn = screen.getByTestId('filter-all')
    const governedBtn = screen.getByTestId('filter-governed')
    const discoveredBtn = screen.getByTestId('filter-discovered')

    expect(allBtn).toBeInTheDocument()
    expect(governedBtn).toBeInTheDocument()
    expect(discoveredBtn).toBeInTheDocument()

    // Switch to Governed population (3 out of 4 agents = 75%)
    fireEvent.click(governedBtn)
    await waitFor(() => {
      // 75% of £200,000 = £150,000
      expect(screen.getAllByText('£150,000').length).toBeGreaterThan(0)
    })

    // Switch to Discovered population (1 out of 4 agents = 25%)
    fireEvent.click(discoveredBtn)
    await waitFor(() => {
      // 25% of £200,000 = £50,000
      expect(screen.getAllByText('£50,000').length).toBeGreaterThan(0)
    })
  })

  it('handles empty agent population gracefully without crash or NaN', async () => {
    vi.mocked(api.agents.list).mockResolvedValueOnce({
      agents: [
        { id: 'agent-1', name: 'Sentinel Alpha', lifecycle_state: 'Governed', namespace: 'fe-signalloom-agents' } as any,
      ],
      total: 1,
    } as any)
    vi.mocked(api.compliance.posture).mockResolvedValueOnce({
      agents: [
        { agent_id: 'agent-1', agent_name: 'Sentinel Alpha', posture_score: 1.0, results: [] },
      ],
    })

    renderPage()
    await screen.findByText('Total ALE')

    // Click Discovered (which has 0 agents)
    const discoveredBtn = screen.getByTestId('filter-discovered')
    fireEvent.click(discoveredBtn)

    await waitFor(() => {
      expect(screen.getAllByText('£0').length).toBeGreaterThan(0)
    })
  })

  it('renders correctly when API returns raw wire format with carried and exposure fields', async () => {
    vi.mocked(api.compliancePolicy.scan).mockResolvedValueOnce({
      checks: [],
      summary: {
        totalChecks: 10,
        passed: 10,
        failed: 0,
        currency: 'GBP',
        totalAle: 20000 as any,
        totalVar95: 50000 as any,
        totalTvar: 80000 as any,
        carried: { amount: 0, currency: 'GBP' },
        totalCarriedGbp: 0,
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [
          {
            id: 'wire-fw',
            name: 'Wire Framework',
            versions: ['v1.0'],
            totalControls: 10,
            passedControls: 10,
            failedControls: 0,
            exposure: { amount: 0, currency: 'GBP' },
            totalExposureGbp: 0,
          } as any,
        ],
      } as any,
    })

    renderPage()
    expect(await screen.findByText('Wire Framework')).toBeInTheDocument()
    expect(await screen.findByText('Carried Risk')).toBeInTheDocument()
  })
})
