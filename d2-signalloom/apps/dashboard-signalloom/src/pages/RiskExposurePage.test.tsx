import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
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

// Mock the API client
vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      scan: vi.fn().mockResolvedValue({
        checks: [],
        summary: {
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
            { id: 'nist-800-53', name: 'NIST 800-53', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 8, failedControls: 2, totalExposureGbp: 45500 },
          ],
        },
      }),
    },
  },
}))

import RiskExposurePage from './RiskExposurePage'

function renderPage() {
  return render(
    <MemoryRouter>
      <RiskExposurePage />
    </MemoryRouter>,
  )
}

describe('RiskExposurePage', () => {
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
    const { api } = await import('../api/client')
    renderPage()

    expect((await screen.findAllByText('£195,500')).length).toBeGreaterThan(0)
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

  it('renders per-framework breakdown table', async () => {
    renderPage()
    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()
    expect(await screen.findByText('NIST 800-53')).toBeInTheDocument()
  })

  it('renders the what-if version selector', async () => {
    renderPage()
    await screen.findByText('Total ALE')
    const select = screen.getByTestId('version-select')
    expect(select).toBeInTheDocument()
  })

  it('renders the What If section heading', async () => {
    renderPage()
    expect(await screen.findByText('What If')).toBeInTheDocument()
  })
})
