import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import FleetRiskGauge from './FleetRiskGauge'

// matchMedia stub is provided by test-setup.ts, but we override matches
// per-test when we need reduced motion.

describe('FleetRiskGauge', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders the ALE number formatted as GBP', () => {
    render(<FleetRiskGauge ale={847000} var95={1200000} trend="up" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    // Formatted as currency — the exact locale formatting may vary but should
    // contain the value. With 847000, formatGBP produces "\u00A3847,000".
    expect(aleEl.textContent).toContain('847')
  })

  it('renders VaR95 value', () => {
    render(<FleetRiskGauge ale={100000} var95={500000} trend="stable" />)
    expect(screen.getByText(/VaR95/)).toBeInTheDocument()
    expect(screen.getByText(/500/)).toBeInTheDocument()
  })

  it('renders the FAIR Monte Carlo subtitle', () => {
    render(<FleetRiskGauge ale={0} var95={0} trend="stable" />)
    expect(screen.getByText(/Annual Loss Expectancy.*FAIR Monte Carlo/)).toBeInTheDocument()
  })

  it('shows green colour when ALE < 50K', () => {
    render(<FleetRiskGauge ale={30000} var95={40000} trend="stable" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    expect(aleEl.style.color).toBe('var(--teal)')
  })

  it('shows amber colour when ALE >= 50K and < 500K', () => {
    render(<FleetRiskGauge ale={200000} var95={400000} trend="up" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    expect(aleEl.style.color).toBe('var(--amber)')
  })

  it('shows red colour when ALE >= 500K', () => {
    render(<FleetRiskGauge ale={750000} var95={1000000} trend="up" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    expect(aleEl.style.color).toBe('var(--error)')
  })

  it('shows upward trend indicator with red colour', () => {
    render(<FleetRiskGauge ale={100000} var95={200000} trend="up" />)
    const trendEl = screen.getByTestId('fleet-risk-trend')
    expect(trendEl.textContent).toBe('\u25B2')
    expect(trendEl.style.color).toBe('var(--error)')
  })

  it('shows downward trend indicator with green colour', () => {
    render(<FleetRiskGauge ale={100000} var95={200000} trend="down" />)
    const trendEl = screen.getByTestId('fleet-risk-trend')
    expect(trendEl.textContent).toBe('\u25BC')
    expect(trendEl.style.color).toBe('var(--teal)')
  })

  it('shows stable trend indicator', () => {
    render(<FleetRiskGauge ale={100000} var95={200000} trend="stable" />)
    const trendEl = screen.getByTestId('fleet-risk-trend')
    expect(trendEl.textContent).toBe('\u2014')
    expect(trendEl.style.color).toBe('var(--muted)')
  })

  it('shows delta when previousAle is provided and trend is not stable', () => {
    render(<FleetRiskGauge ale={200000} var95={300000} trend="up" previousAle={150000} />)
    const deltaEl = screen.getByTestId('fleet-risk-delta')
    // Delta is |200000 - 150000| = 50000 -> "\u00A350,000"
    expect(deltaEl.textContent).toContain('50')
  })

  it('does not show delta when trend is stable', () => {
    render(<FleetRiskGauge ale={200000} var95={300000} trend="stable" previousAle={200000} />)
    expect(screen.queryByTestId('fleet-risk-delta')).not.toBeInTheDocument()
  })

  it('animates the number transition', () => {
    const { rerender } = render(<FleetRiskGauge ale={100000} var95={200000} trend="stable" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    const initialText = aleEl.textContent

    // Change the ALE.
    rerender(<FleetRiskGauge ale={500000} var95={200000} trend="up" />)

    // Advance through some animation frames (20ms per frame with 30 frames).
    act(() => { vi.advanceTimersByTime(100) })

    // Part-way through: the value must have MOVED off the old one but not yet
    // arrived at the new one. Without these two the test passed even if the
    // component snapped straight to the final number, which is precisely the
    // behaviour it is named for.
    const midText = aleEl.textContent
    expect(midText).not.toBe(initialText)

    // After full animation.
    act(() => { vi.advanceTimersByTime(600) })
    const finalText = aleEl.textContent

    expect(midText).not.toBe(finalText)
    // The final value should reflect the new ALE.
    expect(finalText).toContain('500')
  })

  it('has role=status for accessibility', () => {
    render(<FleetRiskGauge ale={0} var95={0} trend="stable" />)
    const gauge = screen.getByTestId('fleet-risk-gauge')
    expect(gauge).toHaveAttribute('role', 'status')
  })

  // This assertion used to read `toContain('2.5M')`, with a capital M, and it
  // passed for a reason that had nothing to do with the component: jsdom
  // reports navigator.language as en-US, and compact notation is uppercase in
  // American English but LOWERCASE in British English — en-GB renders £2.5m,
  // and de-DE renders "2,5 Mio.". The suite was therefore asserting one
  // locale's spelling while the product's users are British, and would have
  // gone red on an ICU update or the day the test environment reported a
  // different locale, with nothing wrong in the component.
  //
  // Fixed the way the money tests already assert: against Intl's own output,
  // and against the PROPERTY that matters — the figure is abbreviated rather
  // than grouped in full — instead of against a spelling.
  it('abbreviates millions rather than grouping them in full', () => {
    render(<FleetRiskGauge ale={2500000} var95={4000000} trend="up" />)
    const shown = screen.getByTestId('fleet-risk-ale').textContent ?? ''

    const locale = navigator.language || 'en-GB'
    const options: Intl.NumberFormatOptions = { style: 'currency', currency: 'GBP' }
    const abbreviated = new Intl.NumberFormat(locale, {
      ...options, notation: 'compact', maximumFractionDigits: 1,
    }).format(2500000)
    const grouped = new Intl.NumberFormat(locale, {
      ...options, minimumFractionDigits: 0, maximumFractionDigits: 0,
    }).format(2500000)

    expect(shown).toBe(abbreviated)
    expect(shown).not.toBe(grouped)
    expect(shown.length).toBeLessThan(grouped.length)
    // The magnitude is still legible whichever locale is in force.
    expect(shown).toMatch(/2[.,]5/)
  })

  it('groups figures below a million in full, keeping the existing threshold', () => {
    render(<FleetRiskGauge ale={847000} var95={900000} trend="up" />)
    const shown = screen.getByTestId('fleet-risk-ale').textContent ?? ''

    const locale = navigator.language || 'en-GB'
    expect(shown).toBe(
      new Intl.NumberFormat(locale, {
        style: 'currency', currency: 'GBP',
        minimumFractionDigits: 0, maximumFractionDigits: 0,
      }).format(847000),
    )
  })
})

// "ALE" and "VaR95" are the two numbers a bank executive is asked to act on and
// the two pieces of jargon nothing on the page defines. Fake timers are in
// force for the whole file, so these drive the hint with fireEvent rather than
// userEvent, which waits on real timers.
describe('FleetRiskGauge explains its own jargon', () => {
  it('defines ALE and VaR95 in plain English behind a keyboard-reachable "?"', () => {
    render(<FleetRiskGauge ale={847000} var95={1200000} trend="up" />)

    const hint = screen.getByTestId('fleet-risk-help')
    expect(hint).toHaveAccessibleName('What these two money figures mean')
    act(() => { hint.focus() })
    expect(document.activeElement).toBe(hint)

    const tooltip = screen.getByRole('tooltip')
    expect(tooltip).toHaveTextContent('Annual Loss Expectancy')
    // VaR95 is the one an executive is most likely to misread as a cap rather
    // than a percentile, so the hint must express it as a frequency.
    expect(tooltip.textContent).toMatch(/1 year in 20/i)
    expect(hint.getAttribute('aria-describedby')).toBe(tooltip.id)
  })

  it('mutes the surrounding live region so the tooltip is not announced twice', () => {
    render(<FleetRiskGauge ale={100000} var95={500000} trend="stable" />)

    // The gauge card is aria-live="polite" so a changing figure is announced.
    // Opening a tooltip inside it also changes the region, which would read the
    // whole explanation out a second time on top of aria-describedby.
    const muted = screen.getByTestId('fleet-risk-help').closest('[aria-live]')
    expect(muted?.getAttribute('aria-live')).toBe('off')
  })
})
