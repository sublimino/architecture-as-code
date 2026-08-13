// Fleet topology geometry.
//
// ── What an edge means ──────────────────────────────────────────────────────
//
// fleet-manager emits one edge per declared dependency, and its `from` is the
// agent that HOLDS the dependency:
//
//     Edge{From: a.ID, To: dep}      // apps/fleet-manager/main.go
//
// so `{from: "agent-monitor", to: "agent-cardvault"}` reads "monitor depends
// on cardvault". The diagram draws that relation in the direction failure
// travels, which is the opposite of the way it is written: the dependency sits
// ABOVE, the agent that needs it sits BELOW, and the arrow points down. Stun
// the top card and everything reachable downward from it goes with it, which
// is exactly what fleet-manager's CascadeTargets computes by walking the same
// edges in reverse. The picture and the cascade are then the same statement.
//
// One exception, and it is drawn as one: CascadeTargets skips agents of type
// `observability`, so a link INTO the SRE monitor is a dependency that does
// not cascade. Those are rendered as watch links, not cascade links.
//
// ── Why the geometry lives here and not in the component ────────────────────
//
// jsdom reports every rect as zero, so a rendered React Flow canvas can only
// tell you a path element exists, never where it went. Keeping the layout and
// the routing as pure functions is the only way the interesting claims -- no
// line crosses a card, no two links leave a card from the same point, every
// link ends on a border -- can actually be asserted.

// ── Metrics ─────────────────────────────────────────────────────────────────

export const NODE_W = 200
export const NODE_H = 80
/** Clear space between two cards on the same layer. */
export const H_GAP = 56
/** Clear space between layers. Every horizontal edge run lives in this band. */
export const V_GAP = 96

/** Distance from the card block to the first bypass channel, then between them. */
const CHANNEL_GAP = 34
/** How far a bypassing edge drops into the gutter before turning sideways. */
const GUTTER_DROP = 28
/** Extra drop per bypassing edge, so two of them never share a horizontal run. */
const GUTTER_STEP = 14
/** Corner radius on a routed elbow. */
const CORNER_R = 12
/** Barycentre sweeps. Two down/up pairs settles this fleet and any like it. */
const ORDER_SWEEPS = 4

// ── Types ───────────────────────────────────────────────────────────────────

export interface FleetEdge {
  /** The agent that holds the dependency. Drawn BELOW. */
  from: string
  /** The agent it depends on. Drawn ABOVE. */
  to: string
}

/** Everything the geometry needs from an agent. */
export interface FleetNodeLike {
  id: string
  type?: string
}

export interface Point {
  x: number
  y: number
}

export interface FleetLayout {
  positions: Map<string, Point>
  layers: Map<string, number>
}

/** `cascade` propagates a stun; `watch` is a dependency the cascade stops at. */
export type EdgeKind = 'cascade' | 'watch'

export interface RoutedEdge {
  key: string
  /** `edge.to`: the agent depended upon. Upper end, where a failure starts. */
  dependency: string
  /** `edge.from`: the agent that needs it. Lower end, where the failure lands. */
  dependent: string
  kind: EdgeKind
  /** How many layers the link spans. 1 is adjacent. */
  span: number
  /**
   * Guide polygon. Waypoints for a routed edge, control polygon for a curve --
   * either way the drawn path stays inside its convex hull, so testing this
   * bounds the drawing.
   */
  points: Point[]
  /** SVG `d`, from the dependency's bottom border to the dependent's top border. */
  path: string
}

// ── Layering ────────────────────────────────────────────────────────────────

/**
 * Longest-path layering over the dependency relation.
 *
 * `layer(v) = 0` when v depends on nothing, else `1 + max(layer(d))` over its
 * dependencies. Longest path rather than BFS depth is what guarantees every
 * edge points strictly downward: with shortest-path layering the SRE monitor,
 * which depends on both the root vault and the agent three levels under it,
 * lands on layer 1 and half its links have to be drawn back up through the
 * cards. That was the old bug, and it is why four of the five agents used to
 * sit in a single flat row with their real dependencies drawn as horizontal
 * lines straight across the diagram.
 */
export function fleetLayers(agents: FleetNodeLike[], edges: FleetEdge[]): Map<string, number> {
  const known = new Set(agents.map(a => a.id))
  const deps = new Map<string, string[]>()
  for (const { from, to } of edges) {
    if (!known.has(from) || !known.has(to) || from === to) continue
    deps.set(from, [...(deps.get(from) ?? []), to])
  }

  const layers = new Map<string, number>()
  const visiting = new Set<string>()

  const resolve = (id: string): number => {
    const cached = layers.get(id)
    if (cached !== undefined) return cached
    // Cycles cannot come from fleet-manager (BuildDAG rejects them) but a
    // half-applied config could still produce one, and a stack overflow is a
    // blank page. Break the cycle at layer 0 and carry on drawing.
    if (visiting.has(id)) return 0
    visiting.add(id)
    let layer = 0
    for (const dep of deps.get(id) ?? []) layer = Math.max(layer, resolve(dep) + 1)
    visiting.delete(id)
    layers.set(id, layer)
    return layer
  }

  for (const agent of agents) resolve(agent.id)
  return layers
}

// ── Ordering within a layer ─────────────────────────────────────────────────

/**
 * Barycentre ordering: put each card near the average position of the cards it
 * connects to on the neighbouring layers. Standard Sugiyama crossing
 * reduction, and the reason the links now read as a hierarchy instead of a
 * bundle. Positions are compared as a fraction of their layer's width so that
 * a layer of one and a layer of four still line up sensibly.
 */
function orderLayers(
  agents: FleetNodeLike[],
  edges: FleetEdge[],
  layers: Map<string, number>,
): Map<number, string[]> {
  const byLayer = new Map<number, string[]>()
  for (const agent of agents) {
    const layer = layers.get(agent.id) ?? 0
    byLayer.set(layer, [...(byLayer.get(layer) ?? []), agent.id])
  }

  const known = new Set(agents.map(a => a.id))
  const up = new Map<string, string[]>()   // id -> its dependencies (above)
  const down = new Map<string, string[]>() // id -> agents depending on it (below)
  for (const { from, to } of edges) {
    if (!known.has(from) || !known.has(to) || from === to) continue
    up.set(from, [...(up.get(from) ?? []), to])
    down.set(to, [...(down.get(to) ?? []), from])
  }

  const depths = [...byLayer.keys()].sort((a, b) => a - b)

  /** Position of `id` in its own layer, normalised to 0..1. */
  const fraction = (id: string): number => {
    const row = byLayer.get(layers.get(id) ?? 0) ?? []
    const index = row.indexOf(id)
    return row.length < 2 ? 0.5 : index / (row.length - 1)
  }

  for (let sweep = 0; sweep < ORDER_SWEEPS; sweep++) {
    const neighbours = sweep % 2 === 0 ? up : down
    const order = sweep % 2 === 0 ? depths : [...depths].reverse()
    for (const depth of order) {
      const row = byLayer.get(depth)!
      const keyed = row.map((id, index) => {
        const linked = (neighbours.get(id) ?? []).filter(other => layers.has(other))
        const bary = linked.length === 0
          ? row.length < 2 ? 0.5 : index / (row.length - 1)
          : linked.reduce((sum, other) => sum + fraction(other), 0) / linked.length
        return { id, bary, index }
      })
      keyed.sort((a, b) => a.bary - b.bary || a.index - b.index)
      byLayer.set(depth, keyed.map(k => k.id))
    }
  }

  return byLayer
}

// ── Positions ───────────────────────────────────────────────────────────────

/** Layer the fleet, order each layer to reduce crossings, then place the cards. */
export function layoutFleet(agents: FleetNodeLike[], edges: FleetEdge[]): FleetLayout {
  const layers = fleetLayers(agents, edges)
  const byLayer = orderLayers(agents, edges, layers)

  const positions = new Map<string, Point>()
  for (const [depth, ids] of [...byLayer].sort((a, b) => a[0] - b[0])) {
    const totalWidth = ids.length * NODE_W + (ids.length - 1) * H_GAP
    const startX = -totalWidth / 2
    ids.forEach((id, index) => {
      positions.set(id, {
        x: startX + index * (NODE_W + H_GAP),
        y: depth * (NODE_H + V_GAP),
      })
    })
  }

  return { positions, layers }
}

// ── Path building ───────────────────────────────────────────────────────────

/** `d` for a polyline whose right-angled corners are rounded off. */
function roundedPath(points: Point[], radius: number): string {
  if (points.length < 2) return ''
  const parts = [`M${round(points[0].x)},${round(points[0].y)}`]

  for (let i = 1; i < points.length - 1; i++) {
    const prev = points[i - 1]
    const corner = points[i]
    const next = points[i + 1]
    // Never round further than halfway along either arm, or short segments
    // swallow their own corners and the path folds back on itself.
    const r = Math.min(
      radius,
      Math.hypot(corner.x - prev.x, corner.y - prev.y) / 2,
      Math.hypot(next.x - corner.x, next.y - corner.y) / 2,
    )
    const entry = towards(corner, prev, r)
    const exit = towards(corner, next, r)
    parts.push(`L${round(entry.x)},${round(entry.y)}`)
    parts.push(`Q${round(corner.x)},${round(corner.y)} ${round(exit.x)},${round(exit.y)}`)
  }

  const last = points[points.length - 1]
  parts.push(`L${round(last.x)},${round(last.y)}`)
  return parts.join(' ')
}

function towards(from: Point, to: Point, distance: number): Point {
  const length = Math.hypot(to.x - from.x, to.y - from.y)
  if (length === 0) return { ...from }
  const ratio = distance / length
  return { x: from.x + (to.x - from.x) * ratio, y: from.y + (to.y - from.y) * ratio }
}

/** Two decimals is well under a device pixel and keeps the `d` readable. */
function round(value: number): number {
  return Math.round(value * 100) / 100
}

// ── Routing ─────────────────────────────────────────────────────────────────

/** card id -> edge key -> which of that card's border slots the edge gets. */
type AnchorIndex = Map<string, Map<string, { index: number; total: number }>>

interface Pending {
  edge: FleetEdge
  key: string
  span: number
  kind: EdgeKind
}

/**
 * Turn the fleet's dependency list into drawable paths.
 *
 * Adjacent layers get a plain vertical cubic. Anything spanning two or more
 * layers is routed out past the widest layer, down a side channel and back in,
 * because the direct line would cross whatever sits between the two ends. Both
 * shapes attach to a card BORDER, fanned across its width by how many links
 * that card has, so a card with four links shows four attachment points rather
 * than one overloaded dot.
 */
export function routeFleetEdges(
  agents: FleetNodeLike[],
  edges: FleetEdge[],
  layout: FleetLayout,
): RoutedEdge[] {
  const { positions, layers } = layout
  const types = new Map(agents.map(a => [a.id, a.type]))

  const pending: Pending[] = []
  for (const edge of edges) {
    if (!positions.has(edge.from) || !positions.has(edge.to) || edge.from === edge.to) continue
    pending.push({
      edge,
      key: `${edge.from}-${edge.to}`,
      span: (layers.get(edge.from) ?? 0) - (layers.get(edge.to) ?? 0),
      kind: types.get(edge.from) === 'observability' ? 'watch' : 'cascade',
    })
  }
  if (pending.length === 0) return []

  const centreX = (id: string) => positions.get(id)!.x + NODE_W / 2

  // Attachment points, fanned across the border. Sorting by the other end's
  // horizontal position is what stops the fan from crossing itself.
  const exits = anchorIndex(pending.map(p => [p.edge.to, p.key, centreX(p.edge.from)]))
  const entries = anchorIndex(pending.map(p => [p.edge.from, p.key, centreX(p.edge.to)]))

  const xs = [...positions.values()].map(p => p.x)
  const blockLeft = Math.min(...xs)
  const blockRight = Math.max(...xs) + NODE_W
  const blockCentre = (blockLeft + blockRight) / 2

  // Outermost channel to the longest link: a short bypass nested inside a long
  // one cannot cross it.
  const bypassing = pending
    .filter(p => p.span !== 1)
    .sort((a, b) => b.span - a.span || a.key.localeCompare(b.key))
  const channels = new Map<string, { x: number; drop: number }>()
  let leftUsed = 0
  let rightUsed = 0
  bypassing.forEach((p, order) => {
    const from = anchorX(exits, p.edge.to, positions.get(p.edge.to)!, p.key)
    const to = anchorX(entries, p.edge.from, positions.get(p.edge.from)!, p.key)
    const onLeft = (from + to) / 2 < blockCentre
    const slot = onLeft ? leftUsed++ : rightUsed++
    channels.set(p.key, {
      x: onLeft
        ? blockLeft - CHANNEL_GAP * (slot + 1)
        : blockRight + CHANNEL_GAP * (slot + 1),
      // Staggered globally, not per side, so no two bypasses share a
      // horizontal run even when they leave on opposite sides.
      drop: GUTTER_DROP + order * GUTTER_STEP,
    })
  })

  return pending.map(({ edge, key, span, kind }) => {
    const upper = positions.get(edge.to)!
    const lower = positions.get(edge.from)!
    const start: Point = { x: anchorX(exits, edge.to, upper, key), y: upper.y + NODE_H }
    const end: Point = { x: anchorX(entries, edge.from, lower, key), y: lower.y }

    const channel = channels.get(key)
    if (!channel) {
      const midY = (start.y + end.y) / 2
      const points = [start, { x: start.x, y: midY }, { x: end.x, y: midY }, end]
      const path =
        `M${round(start.x)},${round(start.y)} ` +
        `C${round(start.x)},${round(midY)} ${round(end.x)},${round(midY)} ` +
        `${round(end.x)},${round(end.y)}`
      return { key, dependency: edge.to, dependent: edge.from, kind, span, points, path }
    }

    const points: Point[] = [
      start,
      { x: start.x, y: start.y + channel.drop },
      { x: channel.x, y: start.y + channel.drop },
      { x: channel.x, y: end.y - channel.drop },
      { x: end.x, y: end.y - channel.drop },
      end,
    ]
    return {
      key,
      dependency: edge.to,
      dependent: edge.from,
      kind,
      span,
      points,
      path: roundedPath(points, CORNER_R),
    }
  })
}

/**
 * For each card, the running order of the links touching one of its borders.
 * `[cardId, edgeKey, sortBy]` in; `cardId -> edgeKey -> {index, total}` out.
 */
function anchorIndex(claims: [string, string, number][]): AnchorIndex {
  const grouped = new Map<string, [string, number][]>()
  for (const [cardId, edgeKey, sortBy] of claims) {
    grouped.set(cardId, [...(grouped.get(cardId) ?? []), [edgeKey, sortBy]])
  }

  const result: AnchorIndex = new Map()
  for (const [cardId, links] of grouped) {
    links.sort((a, b) => a[1] - b[1] || a[0].localeCompare(b[0]))
    const slots = new Map<string, { index: number; total: number }>()
    links.forEach(([edgeKey], index) => slots.set(edgeKey, { index, total: links.length }))
    result.set(cardId, slots)
  }
  return result
}

/** Where along a card's border a given link attaches. */
function anchorX(index: AnchorIndex, cardId: string, card: Point, edgeKey: string): number {
  const slot = index.get(cardId)?.get(edgeKey)
  if (!slot) return card.x + NODE_W / 2
  return card.x + (NODE_W * (slot.index + 1)) / (slot.total + 1)
}
