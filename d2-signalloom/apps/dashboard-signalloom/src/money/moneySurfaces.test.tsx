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
import { convert } from './convert'
import { money } from './money'
import { fakeRateTable } from '../test-utils/rateTable'

// Figures chosen so the converted values are unambiguous and none of them
// coincides with its own source amount.
const TOTAL_ALE = 195_500
const SUMMARY = {
  totalChecks: 20, passed: 15, failed: 5, currency: 'GBP',
  totalAle: { amount: TOTAL_ALE, currency: 'GBP' }, totalVar95: { amount: 858_000, currency: 'GBP' }, totalTvar: { amount: 1_332_000, currency: 'GBP' },
  totalCarried: { amount: 98_700, currency: 'GBP' },
  scanTimestamp: '2026-07-27T12:00:00Z',
  frameworks: [
    { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposure: { amount: 53_200, currency: 'GBP' } },
  ],
}

const CHECKS = [
  {
    framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-3',
    check: 'Data provenance recorded', passed: false, policyVersion: 'v2.0',
    ale: { amount: 12_400, currency: 'GBP' }, var95: { amount: 58_000, currency: 'GBP' }, tvar: { amount: 89_000, currency: 'GBP' }, carried: { amount: 12_400, currency: 'GBP' },
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
  // pairs.GBP.USD, NOT rates.USD. The table's base is USD, so rates.USD is 1
  // and rates.GBP is 0.79 — using either directly is the reciprocal trap that
  // would put every figure out by a factor of 1.6. An earlier draft of this
  // very helper had it wrong.
  // Explicitly against the CANONICAL table: this helper is also called from
  // the unavailable-figure tests, where the active table has been crippled on
  // purpose and would make the oracle itself return null.
  const converted = convert(money(sourceGbp, 'GBP'), 'USD', DEFAULT_RATE_TABLE)
  return new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD',
    minimumFractionDigits: 0, maximumFractionDigits: 0,
  }).format(converted!.amount)
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
      expect(screen.getAllByText(expectedUsd(SUMMARY.totalCarried.amount)).length).toBeGreaterThan(0)
    })
    expect(await screen.findByTestId('policy-conversion-note')).toHaveTextContent(DEFAULT_RATE_TABLE.as_of)
  })
})

describe('Agent Posture renders exposure in the user currency', () => {
  it('converts the per-check figures and states the rate date', async () => {
    renderInProvider(<AgentPosturePage />)

    await waitFor(() => {
      expect(screen.getAllByText(expectedUsd(CHECKS[0].carried.amount)).length).toBeGreaterThan(0)
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

    // Both fraction bounds, as everywhere else in this suite. Capping the
    // maximum and leaving the minimum to the currency default makes the
    // expected string a property of the host's ICU rather than of this test —
    // it resolves to a minimum of 1 on Node 22 and 0 on Node 25.9, so the
    // oracle itself would render £5.1M or £5.1M here but £1.0M or £1M on the
    // day someone reaches for a round figure. See money/format.ts.
    const compact = new Intl.NumberFormat('en-US', {
      style: 'currency', currency: 'USD', notation: 'compact',
      minimumFractionDigits: 0, maximumFractionDigits: 1,
    }).format(convert(money(4_000_000, 'GBP'), 'USD', DEFAULT_RATE_TABLE)!.amount)

    await waitFor(() => {
      expect(screen.getByTestId('fleet-risk-ale').textContent).toBe(compact)
    })
  })
})

describe('an unconvertible figure renders as unavailable on every surface', () => {
  beforeEach(() => {
    // The user wants USD; the table has no USD row. There is no honest number
    // to show, so no number is shown.
    setRateTable(fakeRateTable({ 'GBP->GBP': 1 }, { as_of: '2026-08-01' }))
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
