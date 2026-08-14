import { useEffect, useRef, useState, type CSSProperties } from 'react'
import HelpHint from '../HelpHint'
import { useMoney } from '../../money/CurrencyContext'
import type { CurrencyCode } from '../../money/currency'

// ── Types ───────────────────────────────────────────────────────────────────

export interface FleetRiskGaugeProps {
  /**
   * Annual loss expectancy, in the SOURCE currency (see money/currency.ts).
   *
   * Still a bare number: the gauge is handed raw figures by the fleet topology
   * and converts them for display itself, so callers are not each obliged to
   * convert before rendering. The currency this ends up shown in comes from the
   * user's preference, not from this prop.
   */
  ale: number
  /** Value at risk, 95th percentile, in the source currency. */
  var95: number
  trend: 'up' | 'down' | 'stable'
  /** Previous ALE for delta display, in the source currency. */
  previousAle?: number
  /**
   * The currency these figures are denominated in.
   *
   * Defaults to GBP because the fleet topology endpoint does not yet report a
   * currency — the ONE place that assumption still lives, named here so it is
   * visible rather than buried in a shared constant. When the topology grows a
   * currency field this default goes and the prop becomes required.
   */
  currency?: CurrencyCode
}

// ── Colour boundaries ───────────────────────────────────────────────────────

function riskColour(ale: number): string {
  if (ale < 50_000) return 'var(--teal)'
  if (ale < 500_000) return 'var(--amber)'
  return 'var(--error)'
}

// ── Formatting ──────────────────────────────────────────────────────────────

// The hand-rolled formatter that used to live here was
// `'\u00A3' + value.toLocaleString('en-GB')` with a bespoke "M" suffix above a
// million. Both assumptions were British-specific and neither survives a second
// currency: the symbol is not always a prefix, and the abbreviation is a CLDR
// fact (en-GB writes "\u00A32.5m", en-US writes "$2.5M", de-DE writes "Mio.").
// Intl already encodes all of it, so formatting now comes from useMoney().
//
// The one-million abbreviation THRESHOLD is preserved deliberately \u2014 it is
// COMPACT_THRESHOLD in money/format.ts \u2014 so this component's only visible
// change is its currency. A gauge that restyled every figure under a million at
// the same moment it changed currency would make a visual regression
// impossible to attribute to either change.

// ── Animated counter ────────────────────────────────────────────────────────

const ANIM_DURATION_MS = 600
const ANIM_FRAMES = 30

function useAnimatedNumber(target: number): number {
  const [display, setDisplay] = useState(target)
  const prevRef = useRef(target)
  const frameRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    // Respect prefers-reduced-motion.
    let reducedMotion = false
    try {
      reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    } catch { /* jsdom fallback */ }

    if (reducedMotion) {
      setDisplay(target)
      prevRef.current = target
      return
    }

    const from = prevRef.current
    if (from === target) return
    prevRef.current = target

    let frame = 0
    if (frameRef.current) clearInterval(frameRef.current)

    frameRef.current = setInterval(() => {
      frame++
      if (frame >= ANIM_FRAMES) {
        setDisplay(target)
        if (frameRef.current) clearInterval(frameRef.current)
        return
      }
      // Ease-out cubic.
      const t = frame / ANIM_FRAMES
      const eased = 1 - Math.pow(1 - t, 3)
      setDisplay(Math.round(from + (target - from) * eased))
    }, ANIM_DURATION_MS / ANIM_FRAMES)

    return () => {
      if (frameRef.current) clearInterval(frameRef.current)
    }
  }, [target])

  return display
}

// ── Component ───────────────────────────────────────────────────────────────

export default function FleetRiskGauge({ ale, var95, trend, previousAle, currency = 'GBP' }: FleetRiskGaugeProps) {
  const displayAle = useAnimatedNumber(ale)
  const colour = riskColour(ale)
  const { fmtMoney, asOfFor } = useMoney()
  const money = (value: number) => fmtMoney({ amount: value, currency }, { compact: true })
  const asOfNote = asOfFor(currency)

  const trendIcon = trend === 'up' ? '\u25B2' : trend === 'down' ? '\u25BC' : '\u2014'
  const trendColour = trend === 'up' ? 'var(--error)' : trend === 'down' ? 'var(--teal)' : 'var(--muted)'

  const container: CSSProperties = {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 8,
    padding: '20px 16px',
    borderRadius: 12,
    background: 'var(--surface)',
    border: '1px solid var(--border)',
  }

  return (
    <div data-testid="fleet-risk-gauge" style={container} role="status" aria-live="polite">
      {/* ALE number */}
      <div
        data-testid="fleet-risk-ale"
        style={{
          fontSize: 36,
          fontWeight: 700,
          fontVariantNumeric: 'tabular-nums',
          color: colour,
          lineHeight: 1.1,
        }}
      >
        {money(displayAle)}
      </div>

      {/* Trend indicator + delta */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 14 }}>
        <span data-testid="fleet-risk-trend" style={{ color: trendColour, fontWeight: 600 }}>
          {trendIcon}
        </span>
        {previousAle !== undefined && trend !== 'stable' && (
          <span data-testid="fleet-risk-delta" style={{ color: 'var(--muted)', fontSize: 13 }}>
            {money(Math.abs(ale - previousAle))}
          </span>
        )}
      </div>

      {/* VaR 95 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--muted)' }}>
        <span>VaR95: {money(var95)}</span>
        {/* aria-live="off" overrides the container's polite region for this
            subtree. Without it the tooltip text is announced twice: once by
            aria-describedby when the "?" takes focus, and again by the live
            region, because opening the tooltip changes the region's content. */}
        <span aria-live="off">
          <HelpHint label="What these two money figures mean" testId="fleet-risk-help">
            The big number is Annual Loss Expectancy: what this fleet is modeled to cost you in a typical year. VaR95 is the bad year, the loss that only 1 year in 20 exceeds. Both come from a FAIR simulation over the agents currently deployed, so stunning or removing an agent moves them.
          </HelpHint>
        </span>
      </div>

      {/* Subtitle. The as_of suffix appears only when a conversion actually
          happened — a converted figure with no stated date is one nobody can
          defend in a review, and that is the whole reason the rate table is
          checked in rather than fetched. */}
      <div data-testid="fleet-risk-subtitle" style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center', marginTop: 4 }}>
        Annual Loss Expectancy (FAIR Monte Carlo)
        {asOfNote !== null && ` \u00B7 ${asOfNote}`}
      </div>
    </div>
  )
}
