import { memo } from 'react'
import { Handle, Position, type NodeProps } from '@xyflow/react'
import type { TrustNode } from './trustTypes'
import { rankOf, visual } from './trustVisuals'

export type TrustFlowNodeData = {
  node: TrustNode
  selected: boolean
  /** On the highlighted trust path: this node, or something one hop from it. */
  hot: boolean
  /** Something else is highlighted and this is not part of it. */
  dim: boolean
}

/**
 * A topology node.
 *
 * Rendered as real DOM rather than SVG so it inherits the product's theme
 * tokens, wraps and ellipsises like the rest of the UI, and -- the part that
 * matters most -- stays reachable to assistive technology and to
 * testing-library queries. The SVG-only version this replaces was invisible to
 * both, which is why the page needed a parallel button list to be usable at all.
 */
function TrustFlowNodeImpl({ data }: NodeProps) {
  const { node, selected, hot, dim } = data as unknown as TrustFlowNodeData
  const v = visual[node.evidence]
  const isExternal = node.location === 'external'
  const accent = isExternal ? 'var(--amber)' : v.color
  const glow = isExternal ? 'var(--amber-glow)' : v.tint

  const classes = [
    'trust-node',
    'trust-enter',
    isExternal && 'trust-node--external',
    node.kind === 'platform' && 'trust-node--root',
    selected && 'trust-node--selected',
    hot && 'trust-node--hot',
    dim && 'trust-node--dim',
  ].filter(Boolean).join(' ')

  return (
    <div
      className={classes}
      style={{
        borderColor: accent,
        borderStyle: node.evidence === 'observed' ? 'solid' : 'dashed',
        background: `linear-gradient(180deg, ${v.tint}, transparent 78%), var(--surface2)`,
        // Depth cues carry the node's own evidence colour, so a lit-up path is
        // colour-coded by how much it can be trusted rather than by one house
        // accent. Composed here rather than in CSS because a :hover rule cannot
        // see per-node data without a custom property, and this app's theme
        // guard (cssVarUsage.test.ts) does not allow undeclared ones.
        boxShadow: [
          selected && `0 0 0 3px color-mix(in srgb, ${accent} 38%, transparent)`,
          (hot || selected) && `0 8px 22px -8px ${glow}`,
          'inset 0 1px 0 color-mix(in srgb, var(--text) 6%, transparent)',
        ].filter(Boolean).join(', '),
        // Staggered by trust rank: platform settles first, then tenants and
        // issuers, then projects, then the agents.
        animationDelay: `${(rankOf[node.kind] ?? 3) * 70}ms`,
      }}
    >
      {/* Hidden connection points. Edges are floating -- they compute their own
          attachment on the node's border -- but React Flow still requires a
          handle to exist for an edge to bind to. */}
      <Handle type="target" position={Position.Top} style={{ opacity: 0, pointerEvents: 'none' }} />
      <Handle type="source" position={Position.Bottom} style={{ opacity: 0, pointerEvents: 'none' }} />

      <div className="trust-node__label" title={node.label}>{node.label}</div>
      <div className="trust-node__meta">
        {isExternal ? 'EXTERNAL · LOWER ASSURANCE' : node.evidence.toUpperCase()}
      </div>
    </div>
  )
}

export const TrustFlowNode = memo(TrustFlowNodeImpl)
export default TrustFlowNode
