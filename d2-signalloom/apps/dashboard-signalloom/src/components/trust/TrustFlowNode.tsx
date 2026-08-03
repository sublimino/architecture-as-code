import { memo } from 'react'
import { type NodeProps } from '@xyflow/react'
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
 * tokens, wraps like the rest of the UI, and is queryable by testing-library.
 *
 * It is NOT the accessible surface: the canvas is aria-hidden and the button
 * list under it is the equivalent. Announcing both meant hearing every node
 * twice, and React Flow's own focus handling put fifteen dead tab stops in
 * front of the list that works. There are no <Handle>s here either -- edges are
 * drawn in a portal, so nothing binds to them.
 */
function TrustFlowNodeImpl({ data }: NodeProps) {
  const { node, selected, hot, dim } = data as unknown as TrustFlowNodeData
  const v = visual[node.evidence]
  const isExternal = node.location === 'external'
  const accent = isExternal ? 'var(--amber)' : v.color
  const glow = isExternal ? 'color-mix(in srgb, var(--amber) 44%, transparent)' : v.tint

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
        // Not a bare 'dashed': dotted-vs-dashed is the only evidence cue that
        // survives a theme where every accent is the same red. See trustVisuals.
        borderStyle: v.borderStyle,
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
      <div className="trust-node__label" title={node.label}>{node.label}</div>
      <div className="trust-node__meta">
        {isExternal ? 'EXTERNAL · LOWER ASSURANCE' : node.evidence.toUpperCase()}
      </div>
    </div>
  )
}

export const TrustFlowNode = memo(TrustFlowNodeImpl)
export default TrustFlowNode
