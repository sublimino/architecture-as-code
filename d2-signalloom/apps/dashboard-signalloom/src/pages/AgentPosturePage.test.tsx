import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { fakeWeaveData } from '../api/fakeWeaveData'
import { clearSignalSummaryCache } from '../hooks/useSignalSummary'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock the API client
vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      summary: vi.fn().mockResolvedValue({
        totalChecks: 20,
        passed: 15,
        failed: 5,
        currency: 'GBP',
        totalAle: { amount: 195500, currency: 'GBP' },
        totalVar95: { amount: 858000, currency: 'GBP' },
        totalTvar: { amount: 1332000, currency: 'GBP' },
        totalCarried: { amount: 98700, currency: 'GBP' },
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [
          { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposure: { amount: 53200, currency: 'GBP' } },
        ],
      }),
      scan: vi.fn().mockResolvedValue({
        checks: [
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-1', check: 'Model card published', passed: true, policyVersion: 'v2.1', ale: { amount: 8200, currency: 'GBP' }, var95: { amount: 34000, currency: 'GBP' }, tvar: { amount: 52000, currency: 'GBP' }, carried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-2', check: 'Decision explanation logged', passed: false, policyVersion: 'v2.0', ale: { amount: 12400, currency: 'GBP' }, var95: { amount: 58000, currency: 'GBP' }, tvar: { amount: 89000, currency: 'GBP' }, carried: { amount: 12400, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-1', check: 'Access policy defined', passed: true, policyVersion: 'v2.1', ale: { amount: 9800, currency: 'GBP' }, var95: { amount: 42000, currency: 'GBP' }, tvar: { amount: 65000, currency: 'GBP' }, carried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
        ],
        summary: {
          totalChecks: 3,
          passed: 2,
          failed: 1,
          currency: 'GBP',
          totalAle: { amount: 30400, currency: 'GBP' },
          totalVar95: { amount: 134000, currency: 'GBP' },
          totalTvar: { amount: 206000, currency: 'GBP' },
          totalCarried: { amount: 12400, currency: 'GBP' },
          scanTimestamp: '2026-07-27T12:00:00Z',
          frameworks: [],
        },
      }),
    },
  },
}))

const mockWeaveApi = vi.hoisted(() => ({
  getObservations: vi.fn(),
  getActors: vi.fn(),
  getCoverage: vi.fn(),
  getActor: vi.fn(),
  promoteActor: vi.fn(),
  runCorrelation: vi.fn(),
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: mockWeaveApi,
}))

import AgentPosturePage from './AgentPosturePage'

function renderPage() {
  return render(
    <MemoryRouter>
      <AgentPosturePage />
    </MemoryRouter>,
  )
}

describe('AgentPosturePage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders the Agent Posture heading', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Agent Posture' })).toBeInTheDocument()
  })

  it('renders the agent namespace', async () => {
    renderPage()
    expect(await screen.findByText(/olly-sentinel/)).toBeInTheDocument()
  })

  it('renders check pass/fail summary after loading', async () => {
    renderPage()
    expect(await screen.findByText('Checks Passed')).toBeInTheDocument()
    expect(await screen.findByText('2/3')).toBeInTheDocument()
  })

  it('renders the fresh scan response instead of a pre-scan summary', async () => {
    const { api } = await import('../api/client')
    renderPage()

    expect(await screen.findByText('2/3')).toBeInTheDocument()
    expect(api.compliancePolicy.scan).toHaveBeenCalledWith('test-token', {
      namespace: 'default', policyVersion: 'v2.0', frameworks: [],
    })
    expect(api.compliancePolicy.summary).not.toHaveBeenCalled()
  })

  it('renders control sets as expandable sections', async () => {
    renderPage()
    expect(await screen.findByText(/Transparency/)).toBeInTheDocument()
    expect(await screen.findByText(/Access Control/)).toBeInTheDocument()
  })

  it('renders framework and status filter dropdowns', async () => {
    renderPage()
    await screen.findByText('Checks Passed')
    const selects = screen.getAllByRole('combobox')
    expect(selects.length).toBeGreaterThanOrEqual(2)
  })

  it('renders total exposure stat card', async () => {
    renderPage()
    expect(await screen.findByText('Total Exposure')).toBeInTheDocument()
  })
})

describe('AgentPosturePage — Signal Evidence Section', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
  })

  it('renders the Signal Evidence section when signal data is available', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByTestId('signal-evidence-section')).toBeInTheDocument()
  })

  it('renders layer coverage indicators with tooltips', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')
    expect(screen.getByText('Layer Coverage')).toBeInTheDocument()

    // Check that layer labels are rendered
    expect(screen.getByText('Network/Egress')).toBeInTheDocument()
    expect(screen.getByText('Identity/Auth')).toBeInTheDocument()
    expect(screen.getByText('Application/SaaS')).toBeInTheDocument()
    expect(screen.getByText('Endpoint/Host')).toBeInTheDocument()
    expect(screen.getByText('Behavioural')).toBeInTheDocument()
  })

  it('shows layer tooltips with correct descriptions', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')

    const networkLayer = screen.getByText('Network/Egress').closest('[title]')
    expect(networkLayer).toHaveAttribute('title', expect.stringContaining('Outbound traffic analysis'))

    const identityLayer = screen.getByText('Identity/Auth').closest('[title]')
    expect(identityLayer).toHaveAttribute('title', expect.stringContaining('Identity and access audit'))
  })

  it('shows the View Weave button', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')
    const btn = screen.getByRole('button', { name: /view weave/i })
    expect(btn).toBeInTheDocument()
  })

  it('shows graceful empty state when no observations exist', async () => {
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
    renderPage()

    await screen.findByText('Agent Posture')
    // The section renders but says no observations yet
    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByText('No signal observations recorded yet.')).toBeInTheDocument()
  })

  it('shows graceful message when signal API errors', async () => {
    mockWeaveApi.getObservations.mockRejectedValue(new Error('Service down'))
    mockWeaveApi.getActors.mockRejectedValue(new Error('Service down'))
    renderPage()

    await screen.findByText('Agent Posture')
    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByText(/signal-ingest may be offline/)).toBeInTheDocument()
  })
})
