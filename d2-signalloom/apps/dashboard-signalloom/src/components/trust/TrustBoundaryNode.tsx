import { memo } from 'react'
import type { NodeProps } from '@xyflow/react'

export type TrustBoundaryNodeData = {
  label: string
  caption: string
  accent: string
  width: number
  height: number
  kind: 'tenant' | 'project' | 'external'
  hot: boolean
  dim: boolean
  enterDelay: number
}

/**
 * A drawn trust boundary.
 *
 * Registered with React Flow as an ordinary node so it inherits pan, zoom and
 * the same coordinate space as everything else -- no second transform to keep
 * in sync. It is not selectable or draggable; it is scenery that happens to be
 * the most important thing on the page, since both denials in the contract
 * exist because of a wall like this one.
 */
function TrustBoundaryNodeImpl({ data }: NodeProps) {
  const { label, caption, accent, width, height, kind, hot, dim, enterDelay } =
    data as unknown as TrustBoundaryNodeData
  const isExternal = kind === 'external'

  return (
    <div
      className={`trust-boundary trust-enter ${hot ? 'trust-boundary--hot' : ''} ${dim ? 'trust-boundary--dim' : ''}`}
      style={{
        width,
        height,
        borderRadius: isExternal ? 4 : 14,
        border: `1px ${isExternal ? 'solid' : 'dashed'} ${accent}`,
        // The external band gets a hatch instead of a tint. A texture reads as
        // "somewhere else"; another flat tint would just read as another tenant.
        background: isExternal
          ? `repeating-linear-gradient(135deg, color-mix(in srgb, ${accent} 9%, transparent) 0 6px, transparent 6px 13px)`
          : `color-mix(in srgb, ${accent} 6%, transparent)`,
        boxShadow: hot ? `0 0 0 1px ${accent}, 0 10px 34px -18px ${accent}` : 'none',
        animationDelay: `${enterDelay}ms`,
        pointerEvents: 'none',
      }}
    >
      <div
        className="trust-boundary__label"
        style={{
          position: 'absolute',
          top: isExternal ? 6 : 7,
          left: 12,
          display: 'flex',
          alignItems: 'baseline',
          gap: 8,
          whiteSpace: 'nowrap',
        }}
      >
        <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: '.09em', color: accent, textTransform: 'uppercase' }}>
          {label}
        </span>
        {/* A caption wider than its own boundary spills across the neighbouring
            wall and reads as belonging to it. Below this width the label alone
            has to carry the meaning. */}
        {width > 300 && <span style={{ fontSize: 9.5, color: 'var(--dim)' }}>{caption}</span>}
      </div>
    </div>
  )
}

export const TrustBoundaryNode = memo(TrustBoundaryNodeImpl)
export default TrustBoundaryNode
