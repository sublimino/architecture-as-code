// The diagram's maths, tested where it can actually be tested.
//
// jsdom has no layout engine, so every coordinate computed inside a rendered
// component during a test is computed against zeroes. That is exactly why the
// layout lives in pure functions: these assertions run against real numbers,
// and they cover the things a screenshot review is worst at noticing --
// boundaries that overlap by eight pixels, a wall placed at the midpoint
// instead of at the wall, a label parked on top of another label.

import { describe, expect, it } from 'vitest'
import { trustEdges, trustNodes } from '../../pages/AgentTrustTopologyPage'
import { NODE_H, NODE_W, deriveBoundaries, deriveExternalBand, type Boundary } from './trustBoundaries'
import { borderPoint, edgeGeometry, pointAt, splitQuadratic, wallFraction } from './trustGeometry'
import { shortVerb, visual } from './trustVisuals'
import type { TrustNode } from './trustTypes'

const byId = (id: string): TrustNode => {
  const node = trustNodes.find(item => item.id === id)
  if (!node) throw new Error(`No such node: ${id}`)
  return node
}

function overlaps(a: Boundary, b: Boundary): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

describe('trust boundaries', () => {
  const boundaries = deriveBoundaries(trustNodes)

  it('draws a boundary for every tenant and multi-member project', () => {
    expect(boundaries.map(b => b.id).sort()).toEqual([
      'boundary-acme',
      'boundary-acme-payments',
      'boundary-acme-risk',
      'boundary-northstar',
      'boundary-northstar-investigations',
    ])
  })

  // The failure this catches shipped once: with the pre-redesign coordinates the
  // Acme Payments and Acme Risk boxes intersected by ~60px, so the diagram drew
  // two project boundaries claiming the same region and their captions printed
  // over each other. Overlapping walls are not a cosmetic defect on a page whose
  // whole subject is containment.
  it('never lets two sibling boundaries of the same rank intersect', () => {
    const collisions: string[] = []
    for (const a of boundaries) {
      for (const b of boundaries) {
        if (a.id >= b.id || a.depth !== b.depth) continue
        if (overlaps(a, b)) collisions.push(`${a.id} ∩ ${b.id}`)
      }
    }
    expect(collisions).toEqual([])
  })

  it('nests every project boundary wholly inside its tenant boundary', () => {
    const acme = boundaries.find(b => b.id === 'boundary-acme')!
    for (const child of boundaries.filter(b => b.tenant === 'acme' && b.kind === 'project')) {
      expect(child.x).toBeGreaterThanOrEqual(acme.x)
      expect(child.y).toBeGreaterThanOrEqual(acme.y)
      expect(child.x + child.width).toBeLessThanOrEqual(acme.x + acme.width)
      expect(child.y + child.height).toBeLessThanOrEqual(acme.y + acme.height)
    }
  })

  // A cloud workload is not inside the project's trust boundary — that is the
  // entire meaning of marking it lower-assurance. If the box stretched to
  // enclose it, the diagram would assert the opposite of the contract, and the
  // enrolment edge would no longer be seen crossing anything.
  it('excludes external workloads from every boundary', () => {
    const externals = trustNodes.filter(n => n.location === 'external')
    expect(externals.length).toBeGreaterThan(0)
    for (const node of externals) {
      for (const boundary of boundaries) {
        expect(boundary.memberIds).not.toContain(node.id)
        const inside = node.x > boundary.x && node.x < boundary.x + boundary.width
          && node.y > boundary.y && node.y < boundary.y + boundary.height
        expect(inside).toBe(false)
      }
    }
  })

  it('keeps the external band clear of every in-cluster boundary', () => {
    const band = deriveExternalBand(trustNodes, 740)!
    expect(band.count).toBe(3)
    const lowestWall = Math.max(...boundaries.map(b => b.y + b.height))
    expect(band.y).toBeGreaterThan(lowestWall)
  })

  it('collapses a boundary whose members are filtered away', () => {
    const acmeOnly = trustNodes.filter(node => node.tenant === 'acme' || node.tenant === 'shared')
    const ids = deriveBoundaries(acmeOnly).map(b => b.id)
    expect(ids).toContain('boundary-acme')
    expect(ids).not.toContain('boundary-northstar')
  })

  it('does not ring a lone node in a boundary of its own', () => {
    expect(deriveBoundaries([byId('acme'), byId('platform')])).toEqual([])
  })
})

describe('edge geometry', () => {
  it('attaches to the node border rather than to a fixed handle', () => {
    const from = { x: 0, y: 0 }
    const point = borderPoint(from, { x: 500, y: 0 })
    expect(point.y).toBe(0)
    expect(point.x).toBeCloseTo(NODE_W / 2 + 6)
  })

  it('leaves a gap on both sides so a line never touches the box it names', () => {
    const geom = edgeGeometry({ x: 0, y: 0 }, { x: 0, y: 400 })
    expect(geom.start.y).toBeGreaterThan(NODE_H / 2)
    expect(geom.end.y).toBeLessThan(400 - NODE_H / 2)
  })

  // Regression: with a straight line, planner -> risk-reader passed through
  // `triage`, which sits between them on the same row. On screen the denial
  // appeared to originate at triage — the diagram named the wrong agent as the
  // one being refused. Arcing over the intervening node states the real source.
  it('arcs a same-row relationship clear of the node sitting between its ends', () => {
    const planner = byId('planner')
    const triage = byId('triage')
    const riskReader = byId('risk-reader')
    expect(planner.y).toBe(triage.y)

    const geom = edgeGeometry({ x: planner.x, y: planner.y }, { x: riskReader.x, y: riskReader.y }, -1)
    // Sample the curve where it passes over triage and confirm it clears the box.
    const samples = Array.from({ length: 41 }, (_, i) => pointAt(geom.start, geom.control, geom.end, i / 40))
    const overTriage = samples.filter(p => Math.abs(p.x - triage.x) < NODE_W / 2)
    expect(overTriage.length).toBeGreaterThan(0)
    for (const point of overTriage) {
      expect(point.y).toBeLessThan(triage.y - NODE_H / 2)
    }
  })

  it('splits a curve into two halves that meet exactly at the split point', () => {
    const geom = edgeGeometry({ x: 0, y: 0 }, { x: 400, y: 300 })
    const { before, after } = splitQuadratic(geom.start, geom.control, geom.end, 0.4)
    const joinOfBefore = before.slice(before.lastIndexOf('Q')).trim().split(/\s+/).slice(3).map(Number)
    const startOfAfter = after.slice(1, after.indexOf('Q')).trim().split(/\s+/).map(Number)
    expect(joinOfBefore[0]).toBeCloseTo(startOfAfter[0], 6)
    expect(joinOfBefore[1]).toBeCloseTo(startOfAfter[1], 6)

    const expected = pointAt(geom.start, geom.control, geom.end, 0.4)
    expect(startOfAfter[0]).toBeCloseTo(expected.x, 6)
    expect(startOfAfter[1]).toBeCloseTo(expected.y, 6)
  })
})

describe('the denial wall', () => {
  const boundaries = deriveBoundaries(trustNodes)

  // The wall is the point of the network-block treatment. Parked at the
  // midpoint it is decoration; parked where the path leaves the tenant it says
  // which boundary did the blocking.
  it('stands where the blocked path leaves the tenant boundary, not at the midpoint', () => {
    const edge = trustEdges.find(item => item.denialKind === 'network-block')!
    const from = byId(edge.from)
    const to = byId(edge.to)
    const geom = edgeGeometry({ x: from.x, y: from.y }, { x: to.x, y: to.y }, 0.35)
    const t = wallFraction(geom, boundaries, edge.from)

    expect(t).not.toBe(0.5)

    const acme = boundaries.find(b => b.id === 'boundary-acme')!
    const at = pointAt(geom.start, geom.control, geom.end, t)
    const justBefore = pointAt(geom.start, geom.control, geom.end, Math.max(0, t - 0.03))
    const inside = (p: { x: number; y: number }) =>
      p.x >= acme.x && p.x <= acme.x + acme.width && p.y >= acme.y && p.y <= acme.y + acme.height

    expect(inside(justBefore)).toBe(true)
    expect(inside(at)).toBe(false)
  })

  it('falls back to the midpoint when no boundary is on screen to cross', () => {
    const geom = edgeGeometry({ x: 0, y: 0 }, { x: 400, y: 0 })
    expect(wallFraction(geom, [], 'planner')).toBe(0.5)
  })
})

describe('the evidence-to-motion contract', () => {
  // This is the page's central honesty claim expressed as a number. If a future
  // change makes modeled edges flow as fast as fixture-tested ones, the diagram
  // starts presenting assumptions with the same confidence as tested facts.
  it('never animates weaker evidence faster than stronger evidence', () => {
    expect(visual.observed.flowSeconds).toBeLessThan(visual.fixture.flowSeconds)
    expect(visual.fixture.flowSeconds).toBeLessThan(visual.modeled.flowSeconds)
  })

  it('never draws weaker evidence more opaquely than stronger evidence', () => {
    expect(visual.observed.restOpacity).toBeGreaterThan(visual.fixture.restOpacity)
    expect(visual.fixture.restOpacity).toBeGreaterThan(visual.modeled.restOpacity)
  })

  it('reserves the solid line for runtime-observed evidence alone', () => {
    expect(visual.observed.dash).toBe('none')
    for (const key of ['modeled', 'fixture', 'stale'] as const) {
      expect(visual[key].dash).not.toBe('none')
    }
  })

  it('keeps the legend wording the page and its tests already depend on', () => {
    expect(visual.stale.label).toBe('Stale / dotted warning')
    expect(visual.stale.color).toBe('var(--amber)')
  })

  // Colour cannot be trusted to carry evidence state. The "andy" theme maps
  // --teal, --violet, --cyan and --amber onto four near-indistinguishable reds,
  // so a node's border style is the only cue left there -- and the same is true
  // for a colourblind viewer in any theme. This binds the border style to the
  // word the legend actually prints, so the two cannot drift apart.
  it('backs every evidence colour with a line style the legend names', () => {
    for (const [state, v] of Object.entries(visual)) {
      const named = v.label.toLowerCase()
      expect(named, `${state} legend must name its line style`).toContain(v.borderStyle)
    }
  })

  it('gives modeled and fixture-tested distinguishable line styles', () => {
    expect(visual.modeled.borderStyle).not.toBe(visual.fixture.borderStyle)
    expect(visual.modeled.dash).not.toBe(visual.fixture.dash)
    expect(visual.observed.borderStyle).toBe('solid')
  })
})

describe('on-canvas labels', () => {
  it('drops the evidence prefix the line style already states', () => {
    expect(shortVerb('modeled SPIRE issues SVID')).toBe('SPIRE issues SVID')
    expect(shortVerb('fixture-tested planner invokes triage')).toBe('planner invokes triage')
  })

  it('leaves a verb alone when it carries no evidence prefix', () => {
    expect(shortVerb('planner invokes triage')).toBe('planner invokes triage')
  })

  // The full verb has to survive somewhere: it is the accessible name of the
  // selectable button and the inspector heading.
  it('never shortens away the whole verb', () => {
    for (const edge of trustEdges) {
      expect(shortVerb(edge.verb).length).toBeGreaterThan(0)
    }
  })
})
