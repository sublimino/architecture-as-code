import { memo, useEffect, useState } from 'react'
import type { TrustEdge } from './trustTypes'
import { denialTreatment, shortVerb, visual } from './trustVisuals'
import { pointAt, splitQuadratic, tangentAt, type EdgeGeometry } from './trustGeometry'

export type TrustFlowEdgeData = {
  edge: TrustEdge
  geom: EdgeGeometry
  /** Where the wall stands, 0-1 along the curve. Only used for network blocks. */
  wallAt: number
  /**
   * Where along the curve to park the label, 0-1.
   *
   * Three identity edges converge on `planner`, so their midpoints sit within a
   * few pixels of each other and the labels overprinted into an unreadable
   * smear. Staggering the position per edge separates them without moving the lines.
   */
  labelAt: number
  /** Perpendicular nudge, px, chosen by the anti-overlap pass. */
  labelOffset: number
  selected: boolean
  hot: boolean
  dim: boolean
  onSelect: (id: string) => void
  onHover: (id: string | null) => void
}

/**
 * Calculates animation duration dynamically from telemetry throughput and latency.
 */
export function calculateFlowDuration(baseSeconds: number, throughputPps?: number, latencyMs?: number): number {
  if (!throughputPps && !latencyMs) return baseSeconds
  const speedFactor = throughputPps ? Math.max(0.2, Math.min(4.0, throughputPps / 50)) : 1.0
  const latencyFactor = latencyMs ? Math.max(0.5, Math.min(2.5, latencyMs / 10)) : 1.0
  const duration = (baseSeconds / speedFactor) * latencyFactor
  return Number(Math.max(0.4, Math.min(12.0, duration)).toFixed(2))
}

/**
 * Hook to detect prefers-reduced-motion media query.
 */
export function usePrefersReducedMotion(): boolean {
  const [prefersReduced, setPrefersReduced] = useState<boolean>(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return false
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  })

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return
    const mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)')
    const handleChange = (e: MediaQueryListEvent) => setPrefersReduced(e.matches)
    if (mediaQuery.addEventListener) {
      mediaQuery.addEventListener('change', handleChange)
      return () => mediaQuery.removeEventListener('change', handleChange)
    }
    mediaQuery.addListener(handleChange)
    return () => mediaQuery.removeListener(handleChange)
  }, [])

  return prefersReduced
}

/**
 * A trust relationship with animated SVG flow edges.
 *
 * Visual characteristics:
 *  1. Direction and confidence together: Marching-dash packets travel from source
 *     to target with velocity and stroke width determined by real-time throughput
 *     and latency telemetry.
 *  2. Mutual TLS enforcement: Attested SPIFFE mTLS is color-coded emerald green,
 *     unauthenticated connections display amber warning hues, and denied flows show red.
 *  3. Accessibility: When prefers-reduced-motion is active, animation freezes into
 *     static dotted indicators.
 *  4. Telemetry Tooltips: Hovering displays throughput (packets/sec) and latency (ms).
 */
function TrustFlowEdgeImpl({ edge, geom, wallAt, labelAt, labelOffset, selected, hot, dim, onSelect, onHover }: TrustFlowEdgeData) {
  const v = visual[edge.evidence]
  const denied = edge.decision === 'denied'
  const treatment = denialTreatment(edge.decision, edge.denialKind)
  const prefersReduced = usePrefersReducedMotion()

  // Color coding: denied is error, mTLS enforced is teal/green, unauthenticated is amber, otherwise evidence color
  const stroke = denied
    ? 'var(--error)'
    : edge.mtlsEnforced === true
      ? 'var(--teal)'
      : edge.mtlsEnforced === false
        ? 'var(--amber)'
        : v.color

  const classes = [
    'trust-edge',
    hot && 'trust-edge--hot',
    dim && 'trust-edge--dim',
    prefersReduced && 'trust-edge--reduced-motion',
  ].filter(Boolean).join(' ')

  const labelPoint = pointAt(geom.start, geom.control, geom.end, labelAt)
  const labelTangent = tangentAt(geom.start, geom.control, geom.end, labelAt)
  const label = { x: labelPoint.x - labelTangent.y * labelOffset, y: labelPoint.y + labelTangent.x * labelOffset }
  const wall = pointAt(geom.start, geom.control, geom.end, wallAt)
  const wallTangent = tangentAt(geom.start, geom.control, geom.end, wallAt)
  const wallAngle = (Math.atan2(wallTangent.y, wallTangent.x) * 180) / Math.PI
  const blocked = splitQuadratic(geom.start, geom.control, geom.end, wallAt)

  // Dynamic animation velocity & stroke width from throughput/latency
  const flowDuration = calculateFlowDuration(v.flowSeconds, edge.throughputPps, edge.latencyMs)
  const baseStrokeWidth = edge.throughputPps
    ? edge.throughputPps > 200 ? 4.5 : edge.throughputPps > 50 ? 3.4 : 2.4
    : denied ? 5 : selected ? 3.4 : 2.2
  const activeFlowWidth = selected || hot ? Math.max(4, baseStrokeWidth + 1) : Math.max(3, baseStrokeWidth)

  const tooltipText = `${edge.verb}${
    edge.throughputPps != null ? ` (${edge.throughputPps} pkt/s, ${edge.latencyMs ?? 0} ms)` : ''
  }${edge.mtlsEnforced != null ? ` [mTLS: ${edge.mtlsEnforced ? 'Attested' : 'Unauthenticated'}]` : ''}`

  return (
    <g
      className={classes}
      data-testid={`trust-flow-edge-${edge.id}`}
      data-edge-id={edge.id}
      data-mtls={edge.mtlsEnforced ? 'true' : 'false'}
      onClick={() => onSelect(edge.id)}
      onMouseEnter={() => onHover(edge.id)}
      onMouseLeave={() => onHover(null)}
      style={{ cursor: 'pointer' }}
    >
      {/* Generous invisible hit area. A 2px line is not a click target. */}
      <path className="trust-edge__hit" d={geom.d} />

      {treatment === 'wall' ? (
        // Split at the wall: the near half is traffic that happened, the far half is traffic that did not.
        <>
          <path
            className="trust-edge__line"
            d={blocked.before}
            stroke={stroke}
            strokeWidth={5}
            strokeOpacity={v.restOpacity}
            strokeDasharray={v.dash === 'none' ? undefined : v.dash}
          />
          <path
            className="trust-edge__line"
            d={blocked.after}
            stroke={stroke}
            strokeWidth={1.4}
            strokeOpacity={0.22}
            strokeDasharray="2 6"
          />
        </>
      ) : (
        <path
          className="trust-edge__line"
          d={geom.d}
          stroke={stroke}
          strokeWidth={baseStrokeWidth}
          strokeOpacity={v.restOpacity}
          strokeDasharray={v.dash === 'none' ? undefined : v.dash}
          markerEnd={denied ? undefined : `url(#trust-arrow-${edge.evidence})`}
        />
      )}

      {/* Denied edges get a hollow centre */}
      {denied && (
        <path
          className="trust-edge__line"
          d={treatment === 'wall' ? blocked.before : geom.d}
          stroke="var(--surface)"
          strokeWidth={1.8}
          strokeDasharray={v.dash === 'none' ? undefined : v.dash}
          fill="none"
        />
      )}

      {/* Marching packets or static dotted indicator if prefers-reduced-motion */}
      {!denied && (
        <path
          className={`trust-edge__flow ${prefersReduced ? 'trust-edge__flow--static' : ''}`}
          d={geom.d}
          pathLength={100}
          stroke={stroke}
          strokeWidth={activeFlowWidth}
          strokeDasharray={prefersReduced ? '2 6' : '4 21'}
          style={
            prefersReduced
              ? { animation: 'none', animationDuration: '0s' }
              : {
                  animationDuration: `${flowDuration}s`,
                  animationTimingFunction: v.timing,
                }
          }
        />
      )}

      {treatment === 'wall' && (
        <g transform={`translate(${wall.x} ${wall.y}) rotate(${wallAngle})`}>
          <rect className="trust-wall__pulse" x={-1} y={-16} width={2} height={32} fill="var(--error)" rx={1} />
          <rect x={-2.5} y={-11} width={5} height={22} fill="var(--error)" rx={2.5} />
        </g>
      )}

      {treatment === 'rebound' && (
        <circle
          className="trust-rebound__token"
          r={4}
          fill="var(--error)"
          style={{ offsetPath: `path('${geom.d}')` }}
        />
      )}

      <text
        className="trust-edge__label"
        x={label.x}
        y={label.y - 9}
        textAnchor="middle"
        fill={denied ? 'color-mix(in srgb, var(--error) 60%, var(--text))' : 'var(--text)'}
        fontSize={10}
        opacity={dim ? 0.2 : 1}
      >
        <title>{tooltipText}</title>
        {shortVerb(edge.verb)}
      </text>

      {/* Telemetry badge on hover */}
      {(hot || selected) && edge.throughputPps != null && (
        <g transform={`translate(${label.x} ${label.y + 7})`}>
          <rect
            x={-36}
            y={-7}
            width={72}
            height={14}
            rx={3}
            fill="var(--surface2)"
            stroke="var(--border)"
            strokeWidth={1}
            opacity={0.9}
          />
          <text
            textAnchor="middle"
            y={3}
            fontSize={8}
            fill="var(--muted)"
            fontWeight={600}
          >
            {edge.throughputPps} pps · {edge.latencyMs ?? 0}ms
          </text>
        </g>
      )}
    </g>
  )
}

export const TrustFlowEdge = memo(TrustFlowEdgeImpl)
export default TrustFlowEdge
