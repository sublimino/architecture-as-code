// Pure geometry for the topology edges.
//
// Kept out of the React components so it can be unit-tested without a renderer.
// jsdom gives no layout, so anything computed inside a component during a test
// is computed against zeroes; anything computed here is computed for real.

import type { Boundary } from './trustBoundaries'
import { NODE_H, NODE_W } from './trustBoundaries'

export type Point = { x: number; y: number }

/**
 * Where a ray from `from` towards `to` leaves the box centred on `from`.
 * Edges attach to the border of a node rather than to a fixed handle, so a
 * relationship between two nodes on the same row reads as a sideways call
 * instead of looping out of the bottom and back into the top.
 */
export function borderPoint(from: Point, to: Point, gap = 6): Point {
  const dx = to.x - from.x
  const dy = to.y - from.y
  if (dx === 0 && dy === 0) return { ...from }
  const halfW = NODE_W / 2 + gap
  const halfH = NODE_H / 2 + gap
  // Scale the direction vector until it first touches a side of the box, but
  // never PAST the target: clamping at 1 keeps the attachment point between the
  // two nodes. Unclamped, a target closer than half a box width scaled the
  // vector beyond it and the edge came out drawn backwards. Not reachable at
  // the current spacing, but the layout is hand-tuned numbers and one nudge
  // would have reached it.
  const scale = Math.min(
    dx === 0 ? Infinity : halfW / Math.abs(dx),
    dy === 0 ? Infinity : halfH / Math.abs(dy),
    1,
  )
  return { x: from.x + dx * scale, y: from.y + dy * scale }
}

export type EdgeGeometry = {
  start: Point
  end: Point
  control: Point
  /** SVG path data for the quadratic curve. */
  d: string
  mid: Point
}

/**
 * A shallow arc rather than a straight line. Two reasons, both practical:
 * parallel relationships between the same pair of rows stop overlapping, and a
 * curve gives the flow animation a direction the eye can follow at a glance.
 */
export function edgeGeometry(source: Point, target: Point, bow = 0): EdgeGeometry {
  const dx0 = target.x - source.x
  const dy0 = target.y - source.y
  const span = Math.hypot(dx0, dy0) || 1
  // Negative bow arcs "upward" (against the perpendicular), which is what
  // same-row relationships need: a straight line between two agents in the same
  // project passes straight through whatever sits between them, so the
  // cross-project denial appeared to originate at `triage` rather than at
  // `planner`. Arcing over the intervening node states the real source, and
  // opens enough clearance for the label, which had been clipped into "invoke"
  // by the 30px gap between the two boxes.
  const lift = Math.min(Math.max(span * 0.22, 20), 70) * bow
  const control = {
    x: (source.x + target.x) / 2 + (-dy0 / span) * lift,
    y: (source.y + target.y) / 2 + (dx0 / span) * lift,
  }
  // Attach towards the control point, not the far centre, so the curve leaves
  // and meets each box along its actual tangent instead of kinking at the border.
  const start = borderPoint(source, control)
  const end = borderPoint(target, control)
  return {
    start,
    end,
    control,
    d: `M ${start.x} ${start.y} Q ${control.x} ${control.y} ${end.x} ${end.y}`,
    mid: pointAt(start, control, end, 0.5),
  }
}

/**
 * How hard an edge should arc, given where its endpoints sit.
 *
 * Exported so the canvas and the tests cannot disagree about it. They did: a
 * test hardcoded 0.35 for an edge the canvas draws at -1, which put the two
 * control points 94.5px apart. The suite's most important geometric assertion
 * was being made about a curve the application never draws.
 */
export function bowFor(from: Point, to: Point): number {
  // Same-row edges arc upward to clear whatever sits between them.
  return Math.abs(from.y - to.y) < NODE_H ? -1 : 0.35
}

/** Quadratic Bezier evaluation. */
export function pointAt(p0: Point, c: Point, p1: Point, t: number): Point {
  const u = 1 - t
  return {
    x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
    y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y,
  }
}

/**
 * Splits the curve at t into the part before the wall and the part after.
 *
 * De Casteljau, so both halves are exact quadratics rather than resampled
 * approximations. The point is to be able to draw the two halves differently:
 * traffic reached the wall, and nothing at all happened beyond it. Drawing the
 * far half at full strength -- which is what a single path with one opacity
 * does -- shows a connection that the contract says was refused.
 */
export function splitQuadratic(p0: Point, c: Point, p1: Point, t: number): { before: string; after: string } {
  const lerp = (a: Point, b: Point, k: number): Point => ({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k })
  const a = lerp(p0, c, t)
  const b = lerp(c, p1, t)
  const mid = lerp(a, b, t)
  return {
    before: `M ${p0.x} ${p0.y} Q ${a.x} ${a.y} ${mid.x} ${mid.y}`,
    after: `M ${mid.x} ${mid.y} Q ${b.x} ${b.y} ${p1.x} ${p1.y}`,
  }
}

/** Unit tangent at t, used to stand the denial wall square across the path. */
export function tangentAt(p0: Point, c: Point, p1: Point, t: number): Point {
  const x = 2 * (1 - t) * (c.x - p0.x) + 2 * t * (p1.x - c.x)
  const y = 2 * (1 - t) * (c.y - p0.y) + 2 * t * (p1.y - c.y)
  const len = Math.hypot(x, y) || 1
  return { x: x / len, y: y / len }
}

export type Rect = { x: number; y: number; width: number; height: number }

/**
 * Everything an edge label must not cover.
 *
 * Exported so the canvas and the tests share one definition. The last time a
 * layout rule existed in two places (the arc `bow`), the test asserted against
 * a curve the application never drew.
 */
export function reservedForLabels(
  nodes: { x: number; y: number }[],
  boundaries: Boundary[],
): Rect[] {
  return [
    // The strip at the top of each region carries its label and caption.
    ...boundaries.map(b => ({ x: b.x, y: b.y, width: b.width, height: 30 })),
    ...nodes.map(n => ({ x: n.x - NODE_W / 2 - 4, y: n.y - NODE_H / 2 - 4, width: NODE_W + 8, height: NODE_H + 8 })),
  ]
}

export type LabelCandidate = { id: string; geom: EdgeGeometry; text: string }
export type LabelPlacement = { id: string; at: number; offset: number }

/** Approximate width of a 10px label. Close enough to reserve space with. */
export function labelRect(geom: EdgeGeometry, text: string, at: number, offset: number): Rect {
  const p = pointAt(geom.start, geom.control, geom.end, at)
  const tangent = tangentAt(geom.start, geom.control, geom.end, at)
  // Push perpendicular to the curve, so a nudged label still reads as belonging
  // to its own line rather than drifting onto a neighbouring one.
  const width = Math.max(text.length * 5.4, 24)
  const height = 12
  return {
    x: p.x + -tangent.y * offset - width / 2,
    y: p.y + tangent.x * offset - 9 - height,
    width,
    height,
  }
}

function hits(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

/**
 * Places edge labels so they do not print on top of each other or of the
 * boundary captions.
 *
 * The previous approach staggered each label to a fixed slot chosen by how many
 * edges already touched its endpoints. That is the wrong variable: two labels
 * collide because of where they land on screen, not because of what they are
 * attached to. It left "SPIRE issues SVID" printing through "ACME RISK
 * BOUNDARY", and "planner invokes triage" through "cross-project application
 * denial" -- 43px and 68px of overlap measured in Chrome.
 *
 * This tries positions along the curve and perpendicular to it, takes the first
 * that is clear, and reserves it. Greedy and order-dependent, which is fine:
 * the input order is stable, so the layout is deterministic.
 */
export function placeLabels(candidates: LabelCandidate[], reserved: Rect[]): LabelPlacement[] {
  const ATS = [0.5, 0.38, 0.62, 0.3, 0.7, 0.24, 0.76]
  const OFFSETS = [0, -15, 15, -29, 29]
  const taken = [...reserved]
  const out: LabelPlacement[] = []

  for (const candidate of candidates) {
    let best: LabelPlacement = { id: candidate.id, at: 0.5, offset: 0 }
    let bestRect = labelRect(candidate.geom, candidate.text, 0.5, 0)
    let placed = false

    for (const offset of OFFSETS) {
      for (const at of ATS) {
        const rect = labelRect(candidate.geom, candidate.text, at, offset)
        if (taken.some(other => hits(rect, other))) continue
        best = { id: candidate.id, at, offset }
        bestRect = rect
        placed = true
        break
      }
      if (placed) break
    }

    taken.push(bestRect)
    out.push(best)
  }
  return out
}

/**
 * Where along the edge the blocking wall stands.
 *
 * A network block is not an abstract "no" -- it happens at a specific place,
 * the edge of the trust boundary the caller tried to leave. Finding that place
 * makes the denial legible: the packet visibly gets as far as the wall and no
 * further. Falls back to the midpoint when no boundary is on screen to cross,
 * which is honest enough (the block still happened somewhere between them).
 */
export function wallFraction(geom: EdgeGeometry, boundaries: Boundary[], sourceId: string): number {
  const enclosing = boundaries.filter(b => b.kind === 'tenant' && b.memberIds.includes(sourceId))
  if (enclosing.length === 0) return 0.5

  const isOutside = (t: number) => {
    const p = pointAt(geom.start, geom.control, geom.end, t)
    return enclosing.every(b => p.x < b.x || p.x > b.x + b.width || p.y < b.y || p.y > b.y + b.height)
  }

  // Coarse march to bracket the crossing, then bisect to land on it.
  //
  // Taking the first outside sample alone made the answer a function of STEPS
  // rather than of geometry: the wall was drawn 7.5px BEYOND the boundary it
  // represents, so the packet that "gets as far as the wall and no further"
  // visibly got past it. Bisection pins the crossing to well under a pixel.
  const STEPS = 60
  let lo = 0
  let hi = -1
  for (let i = 1; i <= STEPS; i += 1) {
    const t = i / STEPS
    if (isOutside(t)) { hi = t; break }
    lo = t
  }
  if (hi < 0) return 0.5

  for (let i = 0; i < 24; i += 1) {
    const mid = (lo + hi) / 2
    if (isOutside(mid)) hi = mid
    else lo = mid
  }
  return hi
}
