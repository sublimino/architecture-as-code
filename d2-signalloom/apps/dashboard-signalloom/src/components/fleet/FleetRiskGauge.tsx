import { useEffect, useRef, useState, type CSSProperties } from 'react'

// ── Types ───────────────────────────────────────────────────────────────────

export interface FleetRiskGaugeProps {
  /** Annual loss expectancy in GBP. */
  ale: number
  /** Value at risk, 95th percentile. */
  var95: number
  trend: 'up' | 'down' | 'stable'
  /** Previous ALE for delta display. */
  previousAle?: number
}

// ── Colour boundaries ───────────────────────────────────────────────────────

function riskColour(ale: number): string {
  if (ale < 50_000) return 'var(--teal)'
  if (ale < 500_000) return 'var(--amber)'
  return 'var(--error)'
}

// ── Formatting ──────────────────────────────────────────────────────────────

function formatGBP(value: number): string {
  if (value >= 1_000_000) {
    const m = value / 1_000_000
    return `\u00A3${m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)}M`
  }
  return `\u00A3${value.toLocaleString('en-GB')}`
}

function formatDelta(current: number, previous: number): string {
  const diff = Math.abs(current - previous)
  return formatGBP(diff)
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

// ── Component ───────────────────────────────────────────────────────────────

export default function FleetRiskGauge({ ale, var95, trend, previousAle }: FleetRiskGaugeProps) {
  const displayAle = useAnimatedNumber(ale)
  const colour = riskColour(ale)

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
        {formatGBP(displayAle)}
      </div>

      {/* Trend indicator + delta */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 14 }}>
        <span data-testid="fleet-risk-trend" style={{ color: trendColour, fontWeight: 600 }}>
          {trendIcon}
        </span>
        {previousAle !== undefined && trend !== 'stable' && (
          <span data-testid="fleet-risk-delta" style={{ color: 'var(--muted)', fontSize: 13 }}>
            {formatDelta(ale, previousAle)}
          </span>
        )}
      </div>

      {/* VaR 95 */}
      <div style={{ fontSize: 12, color: 'var(--muted)' }}>
        VaR95: {formatGBP(var95)}
      </div>

      {/* Subtitle */}
      <div style={{ fontSize: 11, color: 'var(--muted)', textAlign: 'center', marginTop: 4 }}>
        Annual Loss Expectancy (FAIR Monte Carlo)
      </div>
    </div>
  )
}
