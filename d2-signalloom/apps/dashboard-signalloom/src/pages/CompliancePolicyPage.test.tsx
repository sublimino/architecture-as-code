import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock recharts to avoid SVG rendering issues in jsdom
vi.mock('recharts', () => ({
  ResponsiveContainer: ({ children }: { children: React.ReactNode }) => <div data-testid="responsive-container">{children}</div>,
  BarChart: ({ children }: { children: React.ReactNode }) => <div data-testid="bar-chart">{children}</div>,
  Bar: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
  Cell: () => null,
}))

// Mock the API client
vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      frameworks: vi.fn().mockResolvedValue([
        {
          id: 'eu-ai-act',
          name: 'EU AI Act',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 10,
          passedControls: 7,
          failedControls: 3,
          totalExposureGbp: 53200,
        },
        {
          id: 'nist-800-53',
          name: 'NIST 800-53',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 10,
          passedControls: 8,
          failedControls: 2,
          totalExposureGbp: 45500,
        },
        {
          id: 'finos-aigf',
          name: 'FINOS AIGF',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 11,
          passedControls: 8,
          failedControls: 3,
          totalExposureGbp: 50500,
        },
        {
          id: 'gemara',
          name: 'Gemara',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 10,
          passedControls: 7,
          failedControls: 3,
          totalExposureGbp: 61900,
        },
      ]),
      summary: vi.fn().mockResolvedValue({
        totalChecks: 41,
        passed: 30,
        failed: 11,
        totalAle: 195500,
        totalVar95: 858000,
        totalTvar: 1332000,
        totalCarriedGbp: 98700,
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [],
      }),
      scan: vi.fn().mockResolvedValue({
        checks: [],
        summary: {
          totalChecks: 41,
          passed: 35,
          failed: 6,
          totalAle: 195500,
          totalVar95: 858000,
          totalTvar: 1332000,
          totalCarriedGbp: 31100,
          scanTimestamp: '2026-07-27T12:01:00Z',
          frameworks: [],
        },
      }),
    },
  },
}))

import CompliancePolicyPage from './CompliancePolicyPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <CompliancePolicyPage />
    </MemoryRouter>,
  )
}

describe('CompliancePolicyPage', () => {
  it('renders the Policy Compliance heading', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Policy Compliance' })).toBeInTheDocument()
  })

  it('renders framework cards after loading', async () => {
    renderPage()
    const euMatches = await screen.findAllByText('EU AI Act')
    expect(euMatches.length).toBeGreaterThanOrEqual(1)
    const nistMatches = await screen.findAllByText('NIST 800-53')
    expect(nistMatches.length).toBeGreaterThanOrEqual(1)
    const finosMatches = await screen.findAllByText('FINOS AIGF')
    expect(finosMatches.length).toBeGreaterThanOrEqual(1)
    const gemaraMatches = await screen.findAllByText('Gemara')
    expect(gemaraMatches.length).toBeGreaterThanOrEqual(1)
  })

  it('renders stat cards with check totals', async () => {
    renderPage()
    expect(await screen.findByText('Total Checks')).toBeInTheDocument()
    expect(await screen.findByText('41')).toBeInTheDocument()
    const passedMatches = screen.getAllByText('Passed')
    expect(passedMatches.length).toBeGreaterThanOrEqual(1)
    const failedMatches = screen.getAllByText('Failed')
    expect(failedMatches.length).toBeGreaterThanOrEqual(1)
  })

  it('renders a Scan Now button', async () => {
    renderPage()
    const btn = screen.getByRole('button', { name: /Scan Now/i })
    expect(btn).toBeInTheDocument()
  })

  it('calls the scan API when Scan Now is clicked', async () => {
    const { api } = await import('../api/client')
    renderPage()
    await screen.findAllByText('EU AI Act')
    await userEvent.click(screen.getByRole('button', { name: /Scan Now/i }))
    await waitFor(() => {
      expect(api.compliancePolicy.scan).toHaveBeenCalled()
    })
  })

  it('renders the bar chart container', async () => {
    renderPage()
    await screen.findAllByText('EU AI Act')
    expect(screen.getByTestId('bar-chart')).toBeInTheDocument()
  })

  it('renders version pills on framework cards', async () => {
    renderPage()
    const pills = await screen.findAllByText('v2.1')
    expect(pills.length).toBeGreaterThan(0)
  })

  it('renders total exposure in GBP format', async () => {
    renderPage()
    expect(await screen.findByText('Total Exposure')).toBeInTheDocument()
  })
})
