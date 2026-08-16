/**
 * Adversarial tests for FleetRiskGauge — non-finite values, negative ALE, and
 * edge cases in the animated counter and risk colour mapping.
 *
 * Round 3 adversarial testing.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import FleetRiskGauge from './FleetRiskGauge'
import { CurrencyContext, type CurrencyCtx } from '../../money/CurrencyContext'
import { formatAmount, MONEY_UNAVAILABLE } from '../../money/format'

// ── Mock the auth module (CurrencyContext uses useAuth0 internally) ─────────
vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
    isAuthenticated: true,
  }),
}))

vi.mock('../../api/client', () => ({
  api: {
    userPreferences: {
      get: vi.fn().mockResolvedValue({ display_currency: 'GBP' }),
      patchCurrency: vi.fn(),
    },
  },
}))

// Provide a minimal CurrencyContext wrapper so useMoney() resolves
function renderWithCurrency(ui: React.ReactElement) {
  const ctx: CurrencyCtx = {
    currency: 'GBP',
    setCurrency: () => Promise.resolve(),
    loading: false,
    error: null,
    ensureLoaded: () => {},
  }
  return render(
    <CurrencyContext.Provider value={ctx}>
      {ui}
    </CurrencyContext.Provider>,
  )
}

// ── riskColour structural test ──────────────────────────────────────────────

describe('FleetRiskGauge — riskColour structural analysis', () => {
  const src = readFileSync(join(__dirname, 'FleetRiskGauge.tsx'), 'utf8')

  // BUG: riskColour(NaN) returns var(--error) because NaN < 50_000 is false
  // and NaN < 500_000 is false, so it falls through to the error case.
  // A NaN ALE (meaning "unknown risk") should NOT display as maximum risk.
  it('riskColour has no guard against NaN (structural)', () => {
    const match = src.match(/function riskColour\([\s\S]*?\n\}/)
    expect(match).not.toBeNull()
    const body = match![0]
    // Check if there is any NaN/isFinite guard
    const hasNaNGuard = body.includes('isNaN') || body.includes('isFinite') || body.includes('Number.isFinite')
    // This test documents the bug: NaN falls through all < comparisons to error
    expect(hasNaNGuard).toBe(true)
  })
})

// ── Rendering with adversarial values ───────────────────────────────────────

describe('FleetRiskGauge — adversarial values', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  it('renders with zero ALE without crashing', () => {
    renderWithCurrency(
      <FleetRiskGauge ale={0} var95={0} trend="stable" />,
    )
    expect(screen.getByTestId('fleet-risk-gauge')).toBeTruthy()
  })

  it('renders with very large ALE without crashing', () => {
    renderWithCurrency(
      <FleetRiskGauge ale={999_999_999_999} var95={1_500_000_000_000} trend="up" previousAle={500_000_000_000} />,
    )
    expect(screen.getByTestId('fleet-risk-gauge')).toBeTruthy()
  })

  it('renders with negative ALE (teal colour, not error)', () => {
    // Negative ALE is logically impossible but should not display as error
    renderWithCurrency(
      <FleetRiskGauge ale={-1000} var95={0} trend="down" />,
    )
    const ale = screen.getByTestId('fleet-risk-ale')
    // Negative ALE should map to teal (< 50_000) since -1000 < 50_000
    expect(ale.style.color).toBe('var(--teal)')
  })

  it('renders trend icons correctly', () => {
    const { unmount } = renderWithCurrency(
      <FleetRiskGauge ale={100_000} var95={200_000} trend="up" />,
    )
    expect(screen.getByTestId('fleet-risk-trend').textContent).toBe('▲') // ▲
    unmount()

    renderWithCurrency(
      <FleetRiskGauge ale={100_000} var95={200_000} trend="down" />,
    )
    expect(screen.getByTestId('fleet-risk-trend').textContent).toBe('▼') // ▼
  })

  it('hides delta when trend is stable', () => {
    renderWithCurrency(
      <FleetRiskGauge ale={100_000} var95={200_000} trend="stable" previousAle={90_000} />,
    )
    expect(screen.queryByTestId('fleet-risk-delta')).toBeNull()
  })

  it('shows delta when trend is not stable and previousAle is provided', () => {
    renderWithCurrency(
      <FleetRiskGauge ale={100_000} var95={200_000} trend="up" previousAle={90_000} />,
    )
    expect(screen.getByTestId('fleet-risk-delta')).toBeTruthy()
  })
})

// ── formatAmount NaN guard (indirect test) ──────────────────────────────────

describe('FleetRiskGauge — money display with NaN', () => {
  it('formatAmount(NaN, "GBP") does not produce a currency-prefixed NaN string', () => {
    const result = formatAmount(NaN, 'GBP', { locale: 'en-GB' })
    expect(result).not.toContain('NaN')
  })
})
