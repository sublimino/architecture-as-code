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

  it('formats millions correctly', () => {
    render(<FleetRiskGauge ale={2500000} var95={4000000} trend="up" />)
    const aleEl = screen.getByTestId('fleet-risk-ale')
    expect(aleEl.textContent).toContain('2.5M')
  })
})
