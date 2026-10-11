import { useEffect, useRef, useState, type CSSProperties } from 'react'
import HelpHint from '../HelpHint'
import { useMoney } from '../../money/CurrencyContext'
import type { CurrencyCode } from '../../money/currency'

// ── Types ───────────────────────────────────────────────────────────────────

export interface FleetRiskGaugeProps {
  /**
   * Annual loss expectancy, in the SOURCE currency (see money/currency.ts), or
   * `null`/`undefined` when the producer declined to price the fleet.
   *
   * Still a bare number rather than a `Money`: the gauge is handed raw figures
   * by the fleet topology and converts them for display itself, so callers are
   * not each obliged to convert before rendering. The currency this ends up
   * shown in comes from the user preference, not from this prop.
   *
   * Absence is a first-class case, not an error: the pricing routes omit their
   * money fields entirely when no declared loss frequency exists for the checks
   * they ran. When this is absent the gauge renders an explicit "not priced"
   * state carrying `unavailableReason`, rather than a number.
   */
  ale?: number | null
  /** Value at risk, 95th percentile, in the source currency, or absent. */
  var95?: number | null
  trend: 'up' | 'down' | 'stable'
  /** Previous ALE for delta display, in the source currency. */
  previousAle?: number | null
  /**
   * Why there is no figure. Shown verbatim when `ale` is absent.
   *
   * Prefer the SERVER's own `pricing.reason`. The fallback below names the
   * endpoint that owes the figure, because "Unavailable" with no cause sends a
   * reader looking for a dashboard bug instead of a missing price declaration.
   */
  unavailableReason?: string
  /**
   * Where these figures came from, shown beside them.
   *
   * Scripted demo figures are legitimate, but only if a viewer can tell they
   * are scripted at the point of display. A number on a gauge is otherwise
   * indistinguishable from a measurement.
   */
  sourceLabel?: string
  /**
   * The currency these figures are denominated in.
   *
   * Defaults to GBP because the fleet topology endpoint does not yet report a
   * currency: the ONE place that assumption still lives, named here so it is
   * visible rather than buried in a shared constant. When the topology grows a
   * currency field this default goes and the prop becomes required.
   */
  currency?: CurrencyCode
  /** Carried GBP exposure figure from the compliance evaluation, or absent. */
  carriedGbp?: number | null
  carried?: number | null
  /** Stepwise cascade indicator: true if cascade in progress or stepwise updates active */
  stepwise?: boolean
  /** Stepwise cascade status: current step index (1-based) */
  cascadeStep?: number
  /** Stepwise cascade status: total number of cascade steps */
  totalCascadeSteps?: number
  /** Currently cascading agent workload ID */
  cascadingAgent?: string
}

// ── Colour boundaries ───────────────────────────────────────────────────────

function riskColour(ale: number | null | undefined): string {
  // NaN, null and undefined all fail every < comparison and would fall through
  // to var(--error), making "unknown risk" display as maximum risk
  // (misleading). An absent or non-finite ALE is not a risk level; it is a
  // missing value, so it gets the neutral muted colour.
  if (typeof ale !== 'number' || !Number.isFinite(ale)) return 'var(--muted)'
  if (ale < 50_000) return 'var(--teal)'
  if (ale < 500_000) return 'var(--amber)'
  return 'var(--error)'
}

/**
 * The band a figure falls in, or the fact that there is no figure.
 *
 * "Not priced" rather than "Unknown": the fleet's risk is not unknown to the
 * system, it is undeclared. The distinction tells a reader whether to go
 * looking for a measurement or for a price declaration.
 */
function riskBandLabel(amount: number | null | undefined): string {
  if (typeof amount !== 'number' || !Number.isFinite(amount)) return 'Not priced'
  if (amount < 50_000) return 'Low Risk'
  if (amount < 500_000) return 'Medium Risk'
  return 'High Risk'
}

/**
 * True when a risk summary carries an ALE a reader can be shown.
 *
 * The one place the question is answered, so a page and this gauge cannot
 * disagree about whether a figure exists. `0` IS priced: a measured zero is a
 * figure. Absent and non-finite are not.
 *
 * It lives here rather than in api/fleetApi.ts because both fleet page suites
 * wholesale-mock that module with no `importOriginal`, so any helper added
 * there is missing at runtime under test.
 */
export function isPriced(risk: { ale?: number | null } | null | undefined): boolean {
  return typeof risk?.ale === 'number' && Number.isFinite(risk.ale)
}

/**
 * Shown when there is no figure and the producer gave no reason.
 *
 * Names the endpoint that owes the figure. /fleet-api/v1/fleet/topology is the
 * only source this gauge has; when its `aggregateRisk` carries no `ale` there
 * is nothing else to fall back to, and saying so is the whole fix.
 */
export const UNPRICED_NO_SERVER_REASON =
  'No priced figure from /fleet-api/v1/fleet/topology (aggregateRisk carries no ale), ' +
  'and the response stated no reason.'

// ── Animated counter ────────────────────────────────────────────────────────

const ANIM_DURATION_MS = 600
const ANIM_FRAMES = 30
const STEPWISE_DURATION_MS = 180
const STEPWISE_FRAMES = 12

function useAnimatedNumber(target: number, isStepwise = false): number {
  const [display, setDisplay] = useState(target)
  const displayRef = useRef(target)
  const frameRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    // Respect prefers-reduced-motion.
    let reducedMotion = false
    try {
      reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    } catch { /* jsdom fallback */ }

    if (reducedMotion) {
      setDisplay(target)
      displayRef.current = target
      return
    }

    const from = displayRef.current
    if (from === target) return

    let frame = 0
    if (frameRef.current) clearInterval(frameRef.current)

    const duration = isStepwise ? STEPWISE_DURATION_MS : ANIM_DURATION_MS
    const totalFrames = isStepwise ? STEPWISE_FRAMES : ANIM_FRAMES

    frameRef.current = setInterval(() => {
      frame++
      if (frame >= totalFrames) {
        setDisplay(target)
        displayRef.current = target
        if (frameRef.current) clearInterval(frameRef.current)
        return
      }
      // Ease-out cubic.
      const t = frame / totalFrames
      const eased = 1 - Math.pow(1 - t, 3)
      const nextVal = Math.round(from + (target - from) * eased)
      setDisplay(nextVal)
      displayRef.current = nextVal
    }, duration / totalFrames)

    return () => {
      if (frameRef.current) clearInterval(frameRef.current)
    }
  }, [target, isStepwise])

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
  unavailableReason,
  sourceLabel,
  stepwise = false,
  cascadeStep,
  totalCascadeSteps,
  cascadingAgent,
}: FleetRiskGaugeProps) {
  // `priced` is the discriminator for the whole component. Absent and zero are
  // two different claims and only one of them is a figure.
  const priced = isPriced({ ale })
  const isStepwiseActive = stepwise || cascadeStep !== undefined
  // Hooks run unconditionally. 0 is the animation INPUT when unpriced, never
  // the rendered value: every read of displayAle below is behind `priced`.
  const displayAle = useAnimatedNumber(priced ? (ale as number) : 0, isStepwiseActive)
  // `?? ale` only when carried is itself absent AND ale is a figure: falling
  // back to ale is a stated approximation, falling back to 0 would be an
  // invented one.
  const carriedValue = carriedGbp ?? carried ?? (priced ? (ale as number) : null)
  const carriedPriced = typeof carriedValue === 'number' && Number.isFinite(carriedValue)
  const displayCarried = useAnimatedNumber(carriedPriced ? (carriedValue as number) : 0, isStepwiseActive)

  const colour = riskColour(ale)
  const carriedColour = riskColour(carriedValue)
  const { fmtMoney, asOfFor } = useMoney()
  // `null` in, MONEY_UNAVAILABLE out. money/format.ts is null-safe by
  // construction, so absence survives all the way to the glyph.
  const money = (value: number | null | undefined) =>
    typeof value === 'number' && Number.isFinite(value)
      ? fmtMoney({ amount: value, currency }, { compact: true })
      : fmtMoney(null)
  const asOfNote = asOfFor(currency)

  const trendIcon = trend === 'up' ? '\u25B2' : trend === 'down' ? '\u25BC' : '-'
  const trendColour = trend === 'up' ? 'var(--error)' : trend === 'down' ? 'var(--teal)' : 'var(--muted)'

  // NaN parks the needle at the low end (val <= 0 branch), which is a reading.
  // Unpriced gets no needle at all, below.
  const needleCoords = getNeedleCoords(priced ? displayAle : Number.NaN)

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

      {/* Stepwise cascade progression indicator */}
      {isStepwiseActive && cascadeStep !== undefined && totalCascadeSteps !== undefined && (
        <div
          data-testid="fleet-risk-stepwise"
          style={{
            fontSize: 10,
            fontWeight: 600,
            color: 'var(--amber)',
            background: 'color-mix(in srgb, var(--amber) 10%, transparent)',
            border: '1px solid color-mix(in srgb, var(--amber) 30%, transparent)',
            padding: '2px 8px',
            borderRadius: 4,
            display: 'flex',
            alignItems: 'center',
            gap: 5,
            width: '100%',
            justifyContent: 'center',
          }}
        >
          <span
            style={{
              width: 6,
              height: 6,
              borderRadius: '50%',
              background: 'var(--amber)',
              display: 'inline-block',
            }}
          />
          <span>
            Cascade Step {cascadeStep} of {totalCascadeSteps}
            {cascadingAgent ? `: ${cascadingAgent}` : ''}
          </span>
        </div>
      )}

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

        {/* Dynamic Needle. Absent when there is no figure: a needle resting on
            "Low" is a reading, and the one thing this gauge must not do is
            report an unpriced fleet as a low-risk one. */}
        {priced && (
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
        )}
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
        {priced ? money(displayAle) : money(null)}
      </div>

      {/* Why there is no figure. Rendered only in the unpriced state, and
          carrying the producer's own reason when it gave one. */}
      {!priced && (
        <div
          data-testid="fleet-risk-unpriced-reason"
          style={{
            fontSize: 11,
            lineHeight: 1.4,
            color: 'var(--muted)',
            textAlign: 'center',
            border: '1px solid var(--border)',
            borderRadius: 6,
            padding: '6px 8px',
          }}
        >
          {unavailableReason ?? UNPRICED_NO_SERVER_REASON}
        </div>
      )}

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
          {carriedPriced ? money(displayCarried) : money(null)}
        </span>
      </div>

      {/* Trend indicator + delta */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 14 }}>
        <span data-testid="fleet-risk-trend" style={{ color: trendColour, fontWeight: 600 }}>
          {trendIcon}
        </span>
        {/* A delta needs BOTH endpoints. `Math.abs(undefined - x)` is NaN, and
            a NaN delta used to reach Intl as currency-prefixed garbage. */}
        {priced && typeof previousAle === 'number' && Number.isFinite(previousAle) && trend !== 'stable' && (
          <span data-testid="fleet-risk-delta" style={{ color: 'var(--muted)', fontSize: 13 }}>
            {money(Math.abs((ale as number) - previousAle))}
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

      {/* Provenance. Scripted demo figures are a legitimate product feature;
          presenting them without saying so is not. */}
      {sourceLabel !== undefined && (
        <div
          data-testid="fleet-risk-source"
          style={{
            fontSize: 10,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            color: 'var(--amber)',
            border: '1px solid var(--amber)',
            borderRadius: 4,
            padding: '2px 7px',
          }}
        >
          {sourceLabel}
        </div>
      )}
    </div>
  )
}
