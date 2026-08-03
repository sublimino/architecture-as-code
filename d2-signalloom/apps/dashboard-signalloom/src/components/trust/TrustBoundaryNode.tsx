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
          ? `repeating-linear-gradient(135deg, color-mix(in srgb, ${accent} 5%, transparent) 0 5px, transparent 5px 18px)`
          : `color-mix(in srgb, ${accent} 6%, transparent)`,
        boxShadow: hot ? `0 0 0 1px ${accent}, 0 10px 34px -18px ${accent}` : 'none',
        animationDelay: `${enterDelay}ms`,
        pointerEvents: 'none',
      }}
    >
      {/* Label and caption stack, both clipped to the boundary they belong to.
       *
       * Previously they sat on one nowrap line: "NORTHSTAR INVESTIGATIONS
       * BOUNDARY" is ~214px of text in a 222px box, so it overran its own
       * dashed edge AND the parent tenant's, ending in open canvas. The caption
       * was then gated on `width > 300`, which meant the 768px Acme tenant
       * explained itself while the 258px Northstar tenant said nothing at all
       * -- one of the two walls the page exists to show, silent.
       *
       * Colour: the label is --text, not the tenant accent. The accents are
       * 3.8-4.2:1 against the canvas at 10px in some themes; the accent still
       * codes the tenant via the dot and the border, where contrast rules for
       * text do not apply. */}
      <div
        className="trust-boundary__label"
        style={{
          position: 'absolute',
          top: isExternal ? 5 : 6,
          left: 12,
          right: 10,
          display: 'flex',
          flexDirection: 'column',
          gap: 1,
        }}
      >
        <span style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }}>
          <span aria-hidden="true" style={{ width: 6, height: 6, borderRadius: 2, background: accent, flex: 'none' }} />
          <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: '.09em', color: 'var(--text)', textTransform: 'uppercase', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {label}
          </span>
        </span>
        <span style={{ fontSize: 9.5, color: 'var(--muted)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {caption}
        </span>
      </div>
    </div>
  )
}

export const TrustBoundaryNode = memo(TrustBoundaryNodeImpl)
export default TrustBoundaryNode
