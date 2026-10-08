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
   * user preference, not from this prop.
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
   * currency: the ONE place that assumption still lives, named here so it is
   * visible rather than buried in a shared constant. When the topology grows a
   * currency field this default goes and the prop becomes required.
   */
  currency?: CurrencyCode
  /** Carried GBP exposure figure from the compliance evaluation. */
  carriedGbp?: number
  carried?: number
}

// ── Colour boundaries ───────────────────────────────────────────────────────

function riskColour(ale: number): string {
  // NaN fails every < comparison and would fall through to var(--error),
  // making "unknown risk" display as maximum risk (misleading). A non-finite
  // ALE is not a risk level; it is a missing value, so it gets the neutral
  // muted colour.
  if (!Number.isFinite(ale)) return 'var(--muted)'
  if (ale < 50_000) return 'var(--teal)'
  if (ale < 500_000) return 'var(--amber)'
  return 'var(--error)'
}

function riskBandLabel(amount: number): string {
  if (!Number.isFinite(amount)) return 'Unknown'
  if (amount < 50_000) return 'Low Risk'
  if (amount < 500_000) return 'Medium Risk'
  return 'High Risk'
}

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

// ── Radial Gauge Math ───────────────────────────────────────────────────────

/**
 * Calculates needle end point on a semi-circular arc (180 deg to 0 deg).
 * Center: (100, 95), Radius: 70, Needle length: 55.
 */
function getNeedleCoords(val: number): { x: number; y: number } {
  const cx = 100
  const cy = 95
  const needleLength = 55

  if (!Number.isFinite(val) || val <= 0) {
    return { x: cx - needleLength, y: cy }
  }

  let angleDeg = 180
  if (val < 50_000) {
    angleDeg = 180 - (val / 50_000) * 60
  } else if (val < 500_000) {
    angleDeg = 120 - ((val - 50_000) / 450_000) * 60
  } else {
    const fraction = Math.min(1, (val - 500_000) / 500_000)
    angleDeg = 60 - fraction * 60
  }

  const rad = (angleDeg * Math.PI) / 180
  return {
    x: Math.round((cx - needleLength * Math.cos(rad)) * 100) / 100,
    y: Math.round((cy - needleLength * Math.sin(rad)) * 100) / 100,
  }
}

// ── Component ───────────────────────────────────────────────────────────────

export default function FleetRiskGauge({
  ale,
  var95,
  trend,
  previousAle,
  currency = 'GBP',
  carriedGbp,
  carried,
}: FleetRiskGaugeProps) {
  const displayAle = useAnimatedNumber(ale)
  const carriedValue = carriedGbp ?? carried ?? ale
  const displayCarried = useAnimatedNumber(carriedValue)

  const colour = riskColour(ale)
  const carriedColour = riskColour(carriedValue)
  const { fmtMoney, asOfFor } = useMoney()
  const money = (value: number) => fmtMoney({ amount: value, currency }, { compact: true })
  const asOfNote = asOfFor(currency)

  const trendIcon = trend === 'up' ? '\u25B2' : trend === 'down' ? '\u25BC' : '-'
  const trendColour = trend === 'up' ? 'var(--error)' : trend === 'down' ? 'var(--teal)' : 'var(--muted)'

  const needleCoords = getNeedleCoords(displayAle)

  const container: CSSProperties = {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: 8,
    padding: '20px 16px',
    borderRadius: 12,
    background: 'var(--surface)',
    border: '1px solid var(--border)',
    position: 'relative',
  }

  return (
    <div data-testid="fleet-risk-gauge" style={container} role="status" aria-live="polite">
      {/* Top row: Section title and Risk Band badge */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', width: '100%' }}>
        <span style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--muted)' }}>
          Fleet Risk Gauge
        </span>
        <span
          data-testid="fleet-risk-band"
          style={{
            fontSize: 10,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            padding: '2px 7px',
            borderRadius: 4,
            color: colour,
            border: `1px solid ${colour}`,
            background: 'color-mix(in srgb, currentColor 8%, transparent)',
          }}
        >
          {riskBandLabel(ale)}
        </span>
      </div>

      {/* SVG Radial Gauge */}
      <svg
        data-testid="fleet-radial-gauge"
        viewBox="0 0 200 115"
        width="200"
        height="115"
        aria-hidden="true"
        style={{ overflow: 'visible' }}
      >
        {/* Low risk band: green (var(--teal)) */}
        <path
          d="M 30 95 A 70 70 0 0 1 65 34.38"
          fill="none"
          stroke="var(--teal)"
          strokeWidth="9"
          strokeLinecap="round"
          data-testid="fleet-gauge-band-low"
        />
        {/* Medium risk band: amber (var(--amber)) */}
        <path
          d="M 65 34.38 A 70 70 0 0 1 135 34.38"
          fill="none"
          stroke="var(--amber)"
          strokeWidth="9"
          data-testid="fleet-gauge-band-medium"
        />
        {/* High risk band: red (var(--error)) */}
        <path
          d="M 135 34.38 A 70 70 0 0 1 170 95"
          fill="none"
          stroke="var(--error)"
          strokeWidth="9"
          strokeLinecap="round"
          data-testid="fleet-gauge-band-high"
        />

        {/* Dynamic Needle */}
        <line
          x1="100"
          y1="95"
          x2={needleCoords.x}
          y2={needleCoords.y}
          stroke={colour}
          strokeWidth="3.5"
          strokeLinecap="round"
          data-testid="fleet-gauge-needle"
        />
        <circle cx="100" cy="95" r="5" fill={colour} />

        {/* Band range labels */}
        <text x="24" y="110" fontSize="9" fontWeight="600" fill="var(--teal)">
          Low
        </text>
        <text x="100" y="24" fontSize="9" fontWeight="600" fill="var(--amber)" textAnchor="middle">
          Medium
        </text>
        <text x="176" y="110" fontSize="9" fontWeight="600" fill="var(--error)" textAnchor="end">
          High
        </text>
      </svg>

      {/* ALE number (Digital Counter) */}
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

      {/* Carried GBP Exposure */}
      <div
        data-testid="fleet-risk-carried"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          fontSize: 13,
          fontWeight: 600,
          color: 'var(--text)',
        }}
      >
        <span style={{ color: 'var(--muted)', fontWeight: 500 }}>Carried GBP:</span>
        <span style={{ color: carriedColour, fontVariantNumeric: 'tabular-nums' }}>
          {money(displayCarried)}
        </span>
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
        <span aria-live="off">
          <HelpHint label="What these two money figures mean" testId="fleet-risk-help">
            The big number is Annual Loss Expectancy: what this fleet is modeled to cost you in a typical year. VaR95 is the bad year, the loss that only 1 year in 20 exceeds. Both come from a FAIR simulation over the agents currently deployed, so stunning or removing an agent moves them.
          </HelpHint>
        </span>
      </div>

      {/* Subtitle */}
      <div data-testid="fleet-risk-subtitle" style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center', marginTop: 4 }}>
        Annual Loss Expectancy (FAIR Monte Carlo)
        {asOfNote !== null && ` \u00B7 ${asOfNote}`}
      </div>
    </div>
  )
}
