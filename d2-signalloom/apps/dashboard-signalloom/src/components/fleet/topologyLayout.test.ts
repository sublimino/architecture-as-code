import { describe, it, expect } from 'vitest'
import {
  NODE_W,
  NODE_H,
  V_GAP,
  fleetLayers,
  layoutFleet,
  routeFleetEdges,
  type FleetEdge,
  type Point,
} from './topologyLayout'

// ── Fixture: the real fleet ─────────────────────────────────────────────────
//
// Copied from apps/fleet-manager/base/fleet-config.yaml, which is the single
// source of truth for the DAG the demo actually serves. Every count in this
// file is derived from this record rather than written as a literal, so the
// tests move when the fleet definition moves.

const FLEET_DEPENDENCIES: Record<string, string[]> = {
  'agent-cardvault': [],
  'agent-txn-pipeline': ['agent-cardvault'],
  'agent-llm-classifier': ['agent-txn-pipeline'],
  'agent-api-gateway': ['agent-cardvault'],
  'agent-monitor': [
    'agent-cardvault',
    'agent-txn-pipeline',
    'agent-llm-classifier',
    'agent-api-gateway',
  ],
}

const AGENT_TYPES: Record<string, string> = {
  'agent-cardvault': 'data-vault',
  'agent-txn-pipeline': 'data-pipeline',
  'agent-llm-classifier': 'llm-inference',
  'agent-api-gateway': 'api-gateway',
  'agent-monitor': 'observability',
}

const AGENTS = Object.keys(FLEET_DEPENDENCIES).map(id => ({ id, type: AGENT_TYPES[id] }))

/** The API emits one edge per declared dependency, `from` = dependent. */
const EDGES: FleetEdge[] = Object.entries(FLEET_DEPENDENCIES).flatMap(([from, deps]) =>
  deps.map(to => ({ from, to })),
)

// ── Geometry helpers used only by the assertions ────────────────────────────

interface Rect { x: number; y: number; w: number; h: number }

function cardRects(positions: Map<string, Point>): Map<string, Rect> {
  const rects = new Map<string, Rect>()
  for (const [id, p] of positions) rects.set(id, { x: p.x, y: p.y, w: NODE_W, h: NODE_H })
  return rects
}

/**
 * Overlap against the OPEN interval `(lo, hi)`. A zero-length span counts only
 * when it sits strictly inside, so a segment lying exactly along a border is
 * not an overlap. Every edge lands on two borders by construction.
 */
function overlapsOpen(a1: number, a2: number, lo: number, hi: number): boolean {
  const start = Math.min(a1, a2)
  const end = Math.max(a1, a2)
  if (start === end) return start > lo && start < hi
  return Math.max(start, lo) < Math.min(end, hi)
}

/** True when an axis-aligned segment passes through the card's interior. */
function segmentEntersCard(a: Point, b: Point, r: Rect): boolean {
  return overlapsOpen(a.x, b.x, r.x, r.x + r.w) && overlapsOpen(a.y, b.y, r.y, r.y + r.h)
}

// ── Layering ────────────────────────────────────────────────────────────────

describe('fleetLayers', () => {
  it('puts the agent that depends on nothing at the top', () => {
    const layers = fleetLayers(AGENTS, EDGES)
    expect(layers.get('agent-cardvault')).toBe(0)
  })

  it('gives every agent a layer strictly below every agent it depends on', () => {
    const layers = fleetLayers(AGENTS, EDGES)
    for (const edge of EDGES) {
      const dependent = layers.get(edge.from)!
      const dependency = layers.get(edge.to)!
      expect(dependency).toBeLessThan(dependent)
    }
  })

  it('uses the longest dependency path, so no edge skips backwards', () => {
    // agent-monitor depends on cardvault (depth 0) AND on llm-classifier
    // (depth 2). Shortest-path layering would put it at 1 and draw the
    // llm-classifier link upwards; longest-path puts it below everything.
    const layers = fleetLayers(AGENTS, EDGES)
    expect(layers.get('agent-txn-pipeline')).toBe(1)
    expect(layers.get('agent-api-gateway')).toBe(1)
    expect(layers.get('agent-llm-classifier')).toBe(2)
    expect(layers.get('agent-monitor')).toBe(3)
  })

  it('places an agent with no edges at all on the top layer', () => {
    const layers = fleetLayers([{ id: 'lonely' }], [])
    expect(layers.get('lonely')).toBe(0)
  })

  it('terminates on a cycle rather than recursing forever', () => {
    const layers = fleetLayers(
      [{ id: 'a' }, { id: 'b' }],
      [{ from: 'a', to: 'b' }, { from: 'b', to: 'a' }],
    )
    expect(layers.size).toBe(2)
  })

  it('ignores edges naming an agent that is not in the fleet', () => {
    const layers = fleetLayers([{ id: 'a' }], [{ from: 'a', to: 'ghost' }])
    expect(layers.get('a')).toBe(0)
    expect(layers.has('ghost')).toBe(false)
  })
})

// ── Positions ───────────────────────────────────────────────────────────────

describe('layoutFleet', () => {
  it('gives every agent a position', () => {
    const { positions } = layoutFleet(AGENTS, EDGES)
    expect(positions.size).toBe(AGENTS.length)
  })

  it('puts agents on the same layer at the same y and never overlaps them', () => {
    const { positions, layers } = layoutFleet(AGENTS, EDGES)
    const byLayer = new Map<number, Point[]>()
    for (const [id, p] of positions) {
      const layer = layers.get(id)!
      byLayer.set(layer, [...(byLayer.get(layer) ?? []), p])
    }
    for (const points of byLayer.values()) {
      expect(new Set(points.map(p => p.y)).size).toBe(1)
      const xs = [...points].sort((a, b) => a.x - b.x)
      for (let i = 1; i < xs.length; i++) {
        expect(xs[i].x - xs[i - 1].x).toBeGreaterThanOrEqual(NODE_W)
      }
    }
  })

  it('leaves a clear horizontal gutter between consecutive layers', () => {
    const { positions, layers } = layoutFleet(AGENTS, EDGES)
    const depth = Math.max(...layers.values())
    for (let d = 0; d < depth; d++) {
      const upper = [...positions].filter(([id]) => layers.get(id) === d)[0][1]
      const lower = [...positions].filter(([id]) => layers.get(id) === d + 1)[0][1]
      expect(lower.y - (upper.y + NODE_H)).toBe(V_GAP)
    }
  })

  it('is deterministic', () => {
    const a = layoutFleet(AGENTS, EDGES).positions
    const b = layoutFleet(AGENTS, EDGES).positions
    expect([...a]).toEqual([...b])
  })
})

// ── Edge routing ────────────────────────────────────────────────────────────

describe('routeFleetEdges', () => {
  const layout = layoutFleet(AGENTS, EDGES)
  const routed = routeFleetEdges(AGENTS, EDGES, layout)

  it('draws exactly one path per declared dependency', () => {
    const declared = Object.values(FLEET_DEPENDENCIES).reduce((n, d) => n + d.length, 0)
    expect(routed).toHaveLength(declared)
    expect(routed).toHaveLength(EDGES.length)
    expect(new Set(routed.map(e => e.key)).size).toBe(declared)
  })

  it('draws each path downward, from the dependency to the agent that needs it', () => {
    for (const edge of routed) {
      const up = layout.positions.get(edge.dependency)!
      const down = layout.positions.get(edge.dependent)!
      const first = edge.points[0]
      const last = edge.points[edge.points.length - 1]
      // Leaves the bottom border of the agent that fails first.
      expect(first.y).toBe(up.y + NODE_H)
      expect(first.x).toBeGreaterThan(up.x)
      expect(first.x).toBeLessThan(up.x + NODE_W)
      // Arrives on the top border of the agent that fails because of it.
      expect(last.y).toBe(down.y)
      expect(last.x).toBeGreaterThan(down.x)
      expect(last.x).toBeLessThan(down.x + NODE_W)
    }
  })

  it('fans multiple links across the border instead of stacking them on one point', () => {
    const fromCardvault = routed.filter(e => e.dependency === 'agent-cardvault')
    expect(fromCardvault.length).toBeGreaterThan(1)
    expect(new Set(fromCardvault.map(e => e.points[0].x)).size).toBe(fromCardvault.length)

    const intoMonitor = routed.filter(e => e.dependent === 'agent-monitor')
    expect(intoMonitor.length).toBeGreaterThan(1)
    const arrivals = intoMonitor.map(e => e.points[e.points.length - 1].x)
    expect(new Set(arrivals).size).toBe(intoMonitor.length)
  })

  it('never runs a path through a node card', () => {
    const rects = cardRects(layout.positions)
    for (const edge of routed) {
      for (let i = 1; i < edge.points.length; i++) {
        const a = edge.points[i - 1]
        const b = edge.points[i]
        for (const [id, rect] of rects) {
          expect(
            segmentEntersCard(a, b, rect),
            `${edge.key} segment ${i} crosses ${id}`,
          ).toBe(false)
        }
      }
    }
  })

  it('routes a multi-layer link out to a side channel clear of every card', () => {
    const long = routed.filter(e => e.span > 1)
    expect(long.length).toBeGreaterThan(0)
    const xs = [...layout.positions.values()].map(p => p.x)
    const minX = Math.min(...xs)
    const maxX = Math.max(...xs) + NODE_W
    for (const edge of long) {
      const channel = edge.points.map(p => p.x).filter(x => x < minX || x > maxX)
      expect(channel.length, `${edge.key} should use a bypass channel`).toBeGreaterThan(0)
    }
  })

  it('curves adjacent-layer links directly rather than routing them round the outside', () => {
    const short = routed.filter(e => e.span === 1)
    expect(short.length).toBeGreaterThan(0)
    for (const edge of short) {
      expect(edge.path.startsWith('M')).toBe(true)
      expect(edge.path).toContain('C')
    }
  })

  it('marks links into an observability agent as watch-only, because the cascade stops there', () => {
    // fleet-manager's CascadeTargets skips observability agents, so drawing
    // them the same as a cascade link would be a lie on the diagram.
    for (const edge of routed) {
      const expected = AGENT_TYPES[edge.dependent] === 'observability' ? 'watch' : 'cascade'
      expect(edge.kind, edge.key).toBe(expected)
    }
    expect(routed.filter(e => e.kind === 'watch')).toHaveLength(
      FLEET_DEPENDENCIES['agent-monitor'].length,
    )
  })

  it('emits a path string for every edge', () => {
    for (const edge of routed) {
      expect(edge.path).toMatch(/^M-?[\d.]+,-?[\d.]+/)
      expect(edge.path.length).toBeGreaterThan(10)
    }
  })

  it('drops an edge whose endpoints are not both on the diagram', () => {
    const partial = layoutFleet([{ id: 'a' }], [])
    expect(routeFleetEdges([{ id: 'a' }], [{ from: 'a', to: 'ghost' }], partial)).toHaveLength(0)
  })

  it('is deterministic', () => {
    const again = routeFleetEdges(AGENTS, EDGES, layout)
    expect(again.map(e => e.path)).toEqual(routed.map(e => e.path))
  })
})
