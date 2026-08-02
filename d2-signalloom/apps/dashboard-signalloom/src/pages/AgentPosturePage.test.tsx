import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

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
        totalAle: 195500,
        totalVar95: 858000,
        totalTvar: 1332000,
        totalCarriedGbp: 98700,
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [
          { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposureGbp: 53200 },
        ],
      }),
      scan: vi.fn().mockResolvedValue({
        checks: [
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-1', check: 'Model card published', passed: true, policyVersion: 'v2.1', ale: 8200, var95: 34000, tvar: 52000, carriedGbp: 0, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-2', check: 'Decision explanation logged', passed: false, policyVersion: 'v2.0', ale: 12400, var95: 58000, tvar: 89000, carriedGbp: 12400, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-1', check: 'Access policy defined', passed: true, policyVersion: 'v2.1', ale: 9800, var95: 42000, tvar: 65000, carriedGbp: 0, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
        ],
        summary: {
          totalChecks: 3,
          passed: 2,
          failed: 1,
          totalAle: 30400,
          totalVar95: 134000,
          totalTvar: 206000,
          totalCarriedGbp: 12400,
          scanTimestamp: '2026-07-27T12:00:00Z',
          frameworks: [],
        },
      }),
    },
  },
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
