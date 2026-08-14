// The renderer against payloads that are NOT GBP.
//
// The shipped demo reports in GBP, so every other test in this suite exercises
// one denomination. That is exactly the gap the money-model side warned about:
// `riskctl --json` reports in each ORG's currency (`doc.Currency`), so the
// first time this renderer meets a second denomination must not be in front of
// a customer. risk/org/ludlow-health.yaml is a US provider whose amounts are
// all GBP — one org file away from proving the point.
//
// These build documents the fixture never produces: a EUR-reported estate, a
// JPY one with no minor unit, and a deliberately mixed one that must refuse to
// total rather than add two different kinds of number.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

const { auth, getPrefs, patchCurrency, scan, summary, frameworks } = vi.hoisted(() => ({
  auth: { isAuthenticated: true, getAccessTokenSilently: vi.fn().mockResolvedValue('t') },
  getPrefs: vi.fn(),
  patchCurrency: vi.fn(),
  scan: vi.fn(),
  summary: vi.fn(),
  frameworks: vi.fn(),
}))

vi.mock('../auth/oidc', () => ({ useAuth0: () => auth }))
vi.mock('../api/client', () => ({
  api: {
    userPreferences: { get: getPrefs, patchCurrency },
    compliancePolicy: { scan, summary, frameworks },
  },
}))
vi.mock('recharts', () => {
  const P = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: P, AreaChart: P, BarChart: P,
    Area: () => null, Bar: () => null, XAxis: () => null, YAxis: () => null,
    CartesianGrid: () => null, Tooltip: () => null, Cell: () => null,
  }
})

import { CurrencyProvider } from './CurrencyContext'
import RiskExposurePage from '../pages/RiskExposurePage'
import AgentPosturePage from '../pages/AgentPosturePage'
import { convert } from './convert'
import { money, sumMoney } from './money'
import { resetRateTable, DEFAULT_RATE_TABLE } from './rates'
import type { CurrencyCode } from './currency'
import type { PostureSummary, ComplianceCheck } from '../types/compliance'

/** A scan document reported in `currency`, with figures denominated to match. */
function documentIn(currency: CurrencyCode): PostureSummary {
  const m = (n: number) => money(n, currency)
  return {
    totalChecks: 10, passed: 7, failed: 3,
    currency,
    totalAle: m(195_500), totalVar95: m(858_000), totalTvar: m(1_332_000),
    totalCarried: m(98_700),
    scanTimestamp: '2026-07-27T12:00:00Z',
    frameworks: [{
      id: 'eu-ai-act', name: 'EU AI Act', versions: ['v2.0'],
      totalControls: 10, passedControls: 7, failedControls: 3,
      totalExposure: m(53_200),
    }],
  }
}

function checksIn(currency: CurrencyCode): ComplianceCheck[] {
  const m = (n: number) => money(n, currency)
  return [{
    framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-3',
    check: 'Data provenance recorded', passed: false, policyVersion: 'v2.0',
    ale: m(12_400), var95: m(58_000), tvar: m(89_000), carried: m(12_400),
    scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative',
  }]
}

function serve(currency: CurrencyCode) {
  const doc = documentIn(currency)
  scan.mockResolvedValue({ checks: checksIn(currency), summary: doc })
  summary.mockResolvedValue(doc)
  frameworks.mockResolvedValue(doc.frameworks)
  return doc
}

beforeEach(() => {
  auth.isAuthenticated = true
  resetRateTable()
  getPrefs.mockReset().mockResolvedValue({ display_currency: 'USD' })
  patchCurrency.mockReset()
  scan.mockReset(); summary.mockReset(); frameworks.mockReset()
})

const inProvider = (ui: React.ReactNode) =>
  render(<MemoryRouter><CurrencyProvider>{ui}</CurrencyProvider></MemoryRouter>)

const shown = (m: { amount: number; currency: CurrencyCode }) =>
  new Intl.NumberFormat('en-US', {
    style: 'currency', currency: m.currency,
    minimumFractionDigits: 0, maximumFractionDigits: 0,
  }).format(m.amount)

describe('a document reported in a currency other than GBP', () => {
  it('converts EUR-reported figures into the user currency', async () => {
    const doc = serve('EUR')
    inProvider(<RiskExposurePage />)

    const expected = shown(convert(doc.totalAle, 'USD', DEFAULT_RATE_TABLE)!)
    await waitFor(() => expect(screen.getAllByText(expected).length).toBeGreaterThan(0))
  })

  it('uses the DOCUMENT currency for the rate, not a hardcoded source', async () => {
    // The regression this whole change exists for. EUR->USD is 1.087 and
    // GBP->USD is 1.266, so a renderer still assuming GBP would show a figure
    // 16% too high — plausible, and wrong in the direction that flatters.
    const doc = serve('EUR')
    inProvider(<RiskExposurePage />)

    const correct = shown(convert(doc.totalAle, 'USD', DEFAULT_RATE_TABLE)!)
    const ifItAssumedGbp = shown(convert(money(doc.totalAle.amount, 'GBP'), 'USD', DEFAULT_RATE_TABLE)!)
    expect(correct).not.toBe(ifItAssumedGbp)

    await waitFor(() => expect(screen.getAllByText(correct).length).toBeGreaterThan(0))
    expect(screen.queryByText(ifItAssumedGbp)).not.toBeInTheDocument()
  })

  it('names the document currency in the provenance line, not GBP', async () => {
    serve('EUR')
    inProvider(<RiskExposurePage />)
    const note = await screen.findByTestId('risk-conversion-note')
    expect(note).toHaveTextContent('EUR')
    expect(note).not.toHaveTextContent('GBP')
  })

  it('renders a JPY-reported document without inventing minor units', async () => {
    // JPY has no subunit. A figure shown as ¥196,203.00 states a quantity of
    // money that cannot exist.
    const doc = serve('JPY')
    inProvider(<RiskExposurePage />)

    const expected = shown(convert(doc.totalAle, 'USD', DEFAULT_RATE_TABLE)!)
    await waitFor(() => expect(screen.getAllByText(expected).length).toBeGreaterThan(0))
  })

  it('shows a document unconverted when the user has chosen its own currency', async () => {
    getPrefs.mockResolvedValue({ display_currency: 'EUR' })
    const doc = serve('EUR')
    inProvider(<RiskExposurePage />)

    await waitFor(() => expect(screen.getAllByText(shown(doc.totalAle)).length).toBeGreaterThan(0))
    // Nothing was converted, so there is nothing to disclose.
    expect(screen.queryByTestId('risk-conversion-note')).not.toBeInTheDocument()
  })
})

describe('a mixed-currency document refuses to total', () => {
  it('sumMoney returns null rather than adding two kinds of number', () => {
    expect(sumMoney([money(100, 'GBP'), money(100, 'USD')], 'GBP')).toBeNull()
  })

  it('treats an empty list as zero in the document currency', () => {
    expect(sumMoney([], 'EUR')).toEqual({ amount: 0, currency: 'EUR' })
  })

  it('renders the Agent Posture total as unavailable rather than a wrong number', async () => {
    const doc = documentIn('GBP')
    const mixed = [...checksIn('GBP'), ...checksIn('USD')]
    scan.mockResolvedValue({ checks: mixed, summary: doc })
    summary.mockResolvedValue(doc)
    frameworks.mockResolvedValue(doc.frameworks)

    inProvider(<AgentPosturePage />)

    // What the user sees: the word Unavailable where the total exposure figure
    // would be. Better than a number that is the sum of pounds and dollars,
    // which would look entirely normal on a slide.
    await waitFor(() => expect(screen.getAllByText('Unavailable').length).toBeGreaterThan(0))
  })
})
