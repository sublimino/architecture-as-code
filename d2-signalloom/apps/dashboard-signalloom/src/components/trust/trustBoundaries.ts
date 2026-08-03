// Derives the drawable trust boundaries from the topology contract.
//
// The pre-redesign diagram drew nodes and arrows but never drew a boundary at
// all -- containment was implied by parentId and by where things happened to be
// positioned. That made the two most important facts on the page invisible:
// the cross-tenant wall and the cross-project wall. Both denials in the
// contract exist *because* of a boundary, and neither boundary was on screen.
//
// So boundaries are first-class here: real regions, computed from the same
// contract data, that the denial edges visibly terminate against.

import type { TrustNode } from './trustTypes'
import { accentFor } from './trustVisuals'

/** Node box, matching the hand-tuned x/y layout the contract data carries. */
export const NODE_W = 190
export const NODE_H = 56

export type BoundaryKind = 'tenant' | 'project'

export type Boundary = {
  id: string
  kind: BoundaryKind
  label: string
  /** Sub-label: what crossing this boundary actually costs you. */
  caption: string
  tenant: string
  accent: string
  x: number
  y: number
  width: number
  height: number
  /** Ids of the visible nodes enclosed. Hover highlighting reads this. */
  memberIds: string[]
  /** Nesting depth: tenants wrap projects, so tenants paint first. */
  depth: number
}

const PAD = { tenant: 34, project: 16 }
// Two lines now (label + caption), so the boxes need more clear space on top.
const LABEL_HEADROOM = 32

/**
 * External nodes are deliberately excluded from every boundary. A workload in
 * AWS Lambda is not inside the Acme Payments trust boundary -- that is the
 * entire point of it being marked lower-assurance. Letting the project box
 * stretch down to enclose it would draw the opposite claim, and the enrolment
 * edge would no longer be seen crossing anything.
 */
function inClusterDescendants(root: TrustNode, all: TrustNode[]): TrustNode[] {
  const byParent = new Map<string, TrustNode[]>()
  all.forEach(node => {
    if (!node.parentId) return
    byParent.set(node.parentId, [...(byParent.get(node.parentId) ?? []), node])
  })
  const out: TrustNode[] = []
  const walk = (node: TrustNode) => {
    if (node.location === 'external') return
    out.push(node)
    ;(byParent.get(node.id) ?? []).forEach(walk)
  }
  walk(root)
  return out
}

function boxOf(nodes: TrustNode[], pad: number, headroom: number) {
  const left = Math.min(...nodes.map(n => n.x - NODE_W / 2)) - pad
  const right = Math.max(...nodes.map(n => n.x + NODE_W / 2)) + pad
  const top = Math.min(...nodes.map(n => n.y - NODE_H / 2)) - pad - headroom
  const bottom = Math.max(...nodes.map(n => n.y + NODE_H / 2)) + pad
  return { x: left, y: top, width: right - left, height: bottom - top }
}

/**
 * @param visibleNodes the filtered node set currently on screen. Boundaries are
 *   computed over what is actually visible, so filtering to one tenant collapses
 *   the wall rather than leaving an empty box implying hidden members.
 */
export function deriveBoundaries(visibleNodes: TrustNode[]): Boundary[] {
  const visibleIds = new Set(visibleNodes.map(n => n.id))
  const out: Boundary[] = []

  for (const node of visibleNodes) {
    if (node.kind !== 'tenant' && node.kind !== 'project') continue

    const members = inClusterDescendants(node, visibleNodes).filter(n => visibleIds.has(n.id))
    // A boundary around a single node is noise, not information -- it says
    // nothing the node's own border does not already say.
    if (members.length < 2) continue

    const kind: BoundaryKind = node.kind
    const box = boxOf(members, PAD[kind], LABEL_HEADROOM)
    out.push({
      id: `boundary-${node.id}`,
      kind,
      // "Acme tenant boundary", not "Acme tenant". The region and the node
      // inside it are different objects and must not read as the same label --
      // one is a wall, the other is the thing that owns it.
      label: `${node.label} boundary`,
      caption: kind === 'tenant'
        ? 'cross-tenant traffic is network-blocked'
        : 'cross-project calls need a project claim',
      tenant: node.tenant,
      accent: accentFor(node.tenant),
      ...box,
      memberIds: members.map(n => n.id),
      depth: kind === 'tenant' ? 0 : 1,
    })
  }

  // Tenants first so projects paint on top of them.
  return out.sort((a, b) => a.depth - b.depth)
}

export type ExternalBand = { y: number; height: number; count: number } | null

/**
 * The in-cluster / external divide -- the most consequential boundary here,
 * because everything below it is modeled rather than proved. Returned separately
 * from the nested boundaries because it is a half-plane, not a box.
 */
export function deriveExternalBand(visibleNodes: TrustNode[]): ExternalBand {
  const external = visibleNodes.filter(n => n.location === 'external')
  if (external.length === 0) return null
  const inCluster = visibleNodes.filter(n => n.location !== 'external')
  const topOfExternal = Math.min(...external.map(n => n.y - NODE_H / 2))
  const bottomOfCluster = inCluster.length
    ? Math.max(...inCluster.map(n => n.y + NODE_H / 2))
    : topOfExternal - 40
  const y = (topOfExternal + bottomOfCluster) / 2 - 10
  // Height comes from the members, never from the canvas.
  //
  // This used to be `canvasHeight - y`, mixing a CSS pixel constant into a
  // graph coordinate -- two different spaces, and not even the same scale once
  // fitView applies a zoom. It happened to enclose the external row by about
  // 12px; moving that row down by any amount would have left the workloads
  // hanging outside the band labelled "Outside the cluster", which is a region
  // asserting containment it did not have.
  const bottom = Math.max(...external.map(n => n.y + NODE_H / 2)) + PAD.tenant
  return { y, height: bottom - y, count: external.length }
}
