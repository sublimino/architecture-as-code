// Every surface that renders money, checked against the user's preference.
//
// The point of testing all four together is that they must agree. A dashboard
// showing exposure in dollars on one page and pounds on the next, with neither
// labelled, is worse than either page alone — and the four had four separate
// copies of the same `'£' + n.toLocaleString('en-GB')` before this work, which
// is exactly how they would have drifted.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

const { auth, getPrefs, patchCurrency, scan, summary, frameworks } = vi.hoisted(() => {
  const token = vi.fn().mockResolvedValue('test-token')
  return {
    auth: { isAuthenticated: true, getAccessTokenSilently: token },
    getPrefs: vi.fn(),
    patchCurrency: vi.fn(),
    scan: vi.fn(),
    summary: vi.fn(),
    frameworks: vi.fn(),
  }
})

vi.mock('../auth/oidc', () => ({ useAuth0: () => auth }))
vi.mock('../api/client', () => ({
  api: {
    userPreferences: { get: getPrefs, patchCurrency },
    compliancePolicy: { scan, summary, frameworks },
  },
}))

// recharts renders SVG that jsdom cannot lay out; the pages under test only
// need their non-chart content here.
vi.mock('recharts', () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Passthrough, AreaChart: Passthrough, BarChart: Passthrough,
    Area: () => null, Bar: () => null, XAxis: () => null, YAxis: () => null,
    CartesianGrid: () => null, Tooltip: () => null, Cell: () => null,
  }
})

import { CurrencyProvider } from './CurrencyContext'
import RiskExposurePage from '../pages/RiskExposurePage'
import CompliancePolicyPage from '../pages/CompliancePolicyPage'
import AgentPosturePage from '../pages/AgentPosturePage'
import FleetRiskGauge from '../components/fleet/FleetRiskGauge'
import { resetRateTable, setRateTable, DEFAULT_RATE_TABLE } from './rates'

// Figures chosen so the converted values are unambiguous and none of them
// coincides with its own source amount.
const TOTAL_ALE = 195_500
const SUMMARY = {
  totalChecks: 20, passed: 15, failed: 5,
  totalAle: TOTAL_ALE, totalVar95: 858_000, totalTvar: 1_332_000,
  totalCarriedGbp: 98_700,
  scanTimestamp: '2026-07-27T12:00:00Z',
  frameworks: [
    { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposureGbp: 53_200 },
  ],
}

const CHECKS = [
  {
    framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-3',
    check: 'Data provenance recorded', passed: false, policyVersion: 'v2.0',
    ale: 12_400, var95: 58_000, tvar: 89_000, carriedGbp: 12_400,
    scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative',
  },
]

beforeEach(() => {
  auth.isAuthenticated = true
  resetRateTable()
  getPrefs.mockReset().mockResolvedValue({ display_currency: 'USD' })
  patchCurrency.mockReset()
  scan.mockReset().mockResolvedValue({ checks: CHECKS, summary: SUMMARY })
  summary.mockReset().mockResolvedValue(SUMMARY)
  frameworks.mockReset().mockResolvedValue(SUMMARY.frameworks)
})

/** The oracle: what Intl itself produces for a converted figure. */
function expectedUsd(sourceGbp: number): string {
  const rate = DEFAULT_RATE_TABLE.rates.USD as number
  return new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD',
    minimumFractionDigits: 0, maximumFractionDigits: 0,
  }).format(Math.round(sourceGbp * rate))
}

function expectedGbp(sourceGbp: number): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'GBP',
    minimumFractionDigits: 0, maximumFractionDigits: 0,
  }).format(sourceGbp)
}

function renderInProvider(ui: React.ReactNode) {
  return render(
    <MemoryRouter>
      <CurrencyProvider>{ui}</CurrencyProvider>
    </MemoryRouter>,
  )
}

// jsdom reports navigator.language as en-US, which resolveLocale() keys off. The
// oracle above uses the same locale, so these assertions test the conversion and
// the currency rather than the runtime's ICU spelling.

describe('Risk Exposure renders every figure in the user currency', () => {
  it('converts the headline figures and states the rate date', async () => {
    renderInProvider(<RiskExposurePage />)

    await waitFor(() => {
      expect(screen.getAllByText(expectedUsd(TOTAL_ALE)).length).toBeGreaterThan(0)
    })
    // Grouping is Intl's, not a hand-rolled comma: 195500 * 1.2658 = 247,464.
    expect(expectedUsd(TOTAL_ALE)).toContain(',')

    const note = await screen.findByTestId('risk-conversion-note')
    expect(note).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
    expect(note).toHaveTextContent('GBP')
  })

  it('shows no figure still denominated in the source currency', async () => {
    renderInProvider(<RiskExposurePage />)
    await waitFor(() => expect(screen.getAllByText(expectedUsd(TOTAL_ALE)).length).toBeGreaterThan(0))
    // The precise regression: the source number surviving on screen because one
    // call site was missed in a four-copy formatter.
    expect(screen.queryByText(expectedGbp(TOTAL_ALE))).not.toBeInTheDocument()
  })
})

describe('Policy Compliance renders exposure in the user currency', () => {
  it('converts total exposure and states the rate date', async () => {
    renderInProvider(<CompliancePolicyPage />)

    await waitFor(() => {
      expect(screen.getAllByText(expectedUsd(SUMMARY.totalCarriedGbp)).length).toBeGreaterThan(0)
    })
    expect(await screen.findByTestId('policy-conversion-note')).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
  })
})

describe('Agent Posture renders exposure in the user currency', () => {
  it('converts the per-check figures and states the rate date', async () => {
    renderInProvider(<AgentPosturePage />)

    await waitFor(() => {
      expect(screen.getAllByText(expectedUsd(CHECKS[0].carriedGbp)).length).toBeGreaterThan(0)
    })
    expect(await screen.findByTestId('posture-conversion-note')).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
  })
})

describe('Fleet risk gauge renders in the user currency', () => {
  it('converts the ALE and appends the rate date to its subtitle', async () => {
    renderInProvider(<FleetRiskGauge ale={200_000} var95={400_000} trend="up" />)

    await waitFor(() => {
      expect(screen.getByTestId('fleet-risk-ale').textContent).toBe(expectedUsd(200_000))
    })
    expect(screen.getByTestId('fleet-risk-subtitle')).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
  })

  it('keeps the one-million abbreviation threshold it already had', async () => {
    renderInProvider(<FleetRiskGauge ale={4_000_000} var95={5_000_000} trend="up" />)

    const compact = new Intl.NumberFormat('en-US', {
      style: 'currency', currency: 'USD', notation: 'compact', maximumFractionDigits: 1,
    }).format(Math.round(4_000_000 * (DEFAULT_RATE_TABLE.rates.USD as number)))

    await waitFor(() => {
      expect(screen.getByTestId('fleet-risk-ale').textContent).toBe(compact)
    })
  })
})

describe('an unconvertible figure renders as unavailable on every surface', () => {
  beforeEach(() => {
    // The user wants USD; the table has no USD row. There is no honest number
    // to show, so no number is shown.
    setRateTable({ as_of: '2026-08-01', base: 'GBP', rates: { GBP: 1 } })
  })

  it('Risk Exposure shows the word Unavailable, not the source number', async () => {
    renderInProvider(<RiskExposurePage />)
    await waitFor(() => expect(screen.getAllByText('Unavailable').length).toBeGreaterThan(0))
    expect(screen.queryByText(expectedUsd(TOTAL_ALE))).not.toBeInTheDocument()
    expect(screen.queryByText(expectedGbp(TOTAL_ALE))).not.toBeInTheDocument()
  })

  it('the fleet gauge shows the word Unavailable in place of the ALE', async () => {
    renderInProvider(<FleetRiskGauge ale={200_000} var95={400_000} trend="up" />)
    await waitFor(() => {
      expect(screen.getByTestId('fleet-risk-ale').textContent).toBe('Unavailable')
    })
    // What the user sees, named explicitly: the word "Unavailable" where the
    // money was, with no currency symbol anywhere near it and no digits that
    // could be mistaken for a converted figure.
    expect(screen.getByTestId('fleet-risk-ale').textContent).not.toMatch(/[$£€]/)
    expect(screen.getByTestId('fleet-risk-ale').textContent).not.toMatch(/\d/)
  })

  it('discloses no rate date, because no conversion happened', async () => {
    renderInProvider(<RiskExposurePage />)
    await waitFor(() => expect(screen.getAllByText('Unavailable').length).toBeGreaterThan(0))
    expect(screen.queryByTestId('risk-conversion-note')).not.toBeInTheDocument()
  })
})
