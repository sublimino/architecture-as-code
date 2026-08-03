import { memo } from 'react'
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
   * smear ("SPIRE issues SOpenBao exchanges SuperCredential"). Staggering the
   * position per edge separates them without moving the lines.
   */
  labelAt: number
  selected: boolean
  hot: boolean
  dim: boolean
  onSelect: (id: string) => void
  onHover: (id: string | null) => void
}

/**
 * A trust relationship.
 *
 * The three things this draws that the previous straight-line version could
 * not:
 *
 *  1. Direction and confidence together. Packets march source -> target at a
 *     speed set by how good the evidence is, so a modeled edge visibly drifts
 *     where a fixture-tested one moves with intent. See trustVisuals.ts.
 *  2. A network block that stops at the wall. The packet gets as far as the
 *     boundary and dies there; the rest of the path is drawn as a ghost,
 *     because that traffic never happened.
 *  3. An authorization rejection that does *not* stop at a wall. The call
 *     arrives, is understood, and is refused -- so the token travels the whole
 *     way and comes back. The page draws a hard distinction between these two
 *     denials in text; now the motion draws it too.
 */
function TrustFlowEdgeImpl({ edge, geom, wallAt, labelAt, selected, hot, dim, onSelect, onHover }: TrustFlowEdgeData) {
  const v = visual[edge.evidence]
  const denied = edge.decision === 'denied'
  const treatment = denialTreatment(edge.decision, edge.denialKind)
  const stroke = denied ? 'var(--error)' : v.color

  const classes = [
    'trust-edge',
    hot && 'trust-edge--hot',
    dim && 'trust-edge--dim',
  ].filter(Boolean).join(' ')

  const label = pointAt(geom.start, geom.control, geom.end, labelAt)
  const wall = pointAt(geom.start, geom.control, geom.end, wallAt)
  const wallTangent = tangentAt(geom.start, geom.control, geom.end, wallAt)
  const wallAngle = (Math.atan2(wallTangent.y, wallTangent.x) * 180) / Math.PI
  const blocked = splitQuadratic(geom.start, geom.control, geom.end, wallAt)

  return (
    <g
      className={classes}
      onClick={() => onSelect(edge.id)}
      onMouseEnter={() => onHover(edge.id)}
      onMouseLeave={() => onHover(null)}
      style={{ cursor: 'pointer' }}
    >
      {/* Generous invisible hit area. A 2px line is not a click target. */}
      <path className="trust-edge__hit" d={geom.d} />

      {treatment === 'wall' ? (
        // Split at the wall: the near half is traffic that happened, the far
        // half is traffic that did not. One path at one opacity cannot say that.
        <>
          <path
            className="trust-edge__line"
            d={blocked.before}
            stroke={stroke}
            strokeWidth={selected ? 3.4 : 2.4}
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
          strokeWidth={selected ? 3.4 : 2.2}
          strokeOpacity={v.restOpacity}
          strokeDasharray={v.dash === 'none' ? undefined : v.dash}
          markerEnd={denied ? undefined : `url(#trust-arrow-${edge.evidence})`}
        />
      )}

      {/* Marching packets. pathLength=100 normalises the dash pattern so the
          cadence is identical on a short edge and a long one -- speed then
          means evidence, not distance. */}
      {!denied && (
        <path
          className="trust-edge__flow"
          d={geom.d}
          pathLength={100}
          stroke={stroke}
          strokeWidth={selected || hot ? 4 : 3}
          strokeDasharray="4 21"
          style={{
            animationDuration: `${v.flowSeconds}s`,
            animationTimingFunction: v.timing,
            filter: `drop-shadow(0 0 4px ${stroke})`,
          }}
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
        fill={denied ? 'var(--error)' : 'var(--text)'}
        fontSize={10}
        opacity={dim ? 0.2 : 1}
      >
        <title>{edge.verb}</title>
        {shortVerb(edge.verb)}
      </text>
    </g>
  )
}

export const TrustFlowEdge = memo(TrustFlowEdgeImpl)
export default TrustFlowEdge
