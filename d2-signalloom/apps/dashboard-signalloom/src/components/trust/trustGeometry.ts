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
  // Scale the direction vector until it first touches a side of the box.
  const scale = Math.min(
    dx === 0 ? Infinity : halfW / Math.abs(dx),
    dy === 0 ? Infinity : halfH / Math.abs(dy),
  )
  return { x: from.x + dx * scale, y: from.y + dy * scale }
}

export type EdgeGeometry = {
  start: Point
  end: Point
  control: Point
  /** SVG path data for the quadratic curve. */
  d: string
  /** Curve length, approximated by the control polygon. Drives dash timing. */
  length: number
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
  const length = Math.hypot(control.x - start.x, control.y - start.y)
    + Math.hypot(end.x - control.x, end.y - control.y)
  return {
    start,
    end,
    control,
    d: `M ${start.x} ${start.y} Q ${control.x} ${control.y} ${end.x} ${end.y}`,
    length,
    mid: pointAt(start, control, end, 0.5),
  }
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

  // March along the curve and take the first sample that has left every
  // boundary the source sits inside.
  const STEPS = 60
  for (let i = 1; i <= STEPS; i += 1) {
    const t = i / STEPS
    const p = pointAt(geom.start, geom.control, geom.end, t)
    const outside = enclosing.every(b => p.x < b.x || p.x > b.x + b.width || p.y < b.y || p.y > b.y + b.height)
    if (outside) return t
  }
  return 0.5
}
