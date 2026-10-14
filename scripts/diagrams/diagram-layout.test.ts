// @target  d2-signalloom/apps/docs-signalloom/public/diagrams/*.drawio
// @doc     d2-signalloom/apps/docs-signalloom/DIAGRAMS.md
//
// Layout gate for the published diagrams. The focus gate only checks which
// labels appear; it cannot see where a cell sits. On 2026-10-13 four Azure
// resource-group-2 icons were copied with resource-group-1 coordinates, so
// they rendered on top of their twins and edges crossed the whole page while
// every label check stayed green. Two icons occupying the same box is never
// intended, so any intersection fails here.

import { test, expect, describe } from "bun:test";
import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { parseDrawio, getEdgePoints, type Cell } from "./drawio-render";

const DIAGRAMS = join(import.meta.dir, "../../d2-signalloom/apps/docs-signalloom/public/diagrams");

export function iconOverlaps(xml: string): string[] {
  const icons = parseDrawio(xml).cells.filter((c: Cell) => c.vertex && c.geometry && c.style.image);
  const out: string[] = [];
  for (let i = 0; i < icons.length; i++) {
    for (let j = i + 1; j < icons.length; j++) {
      const a = icons[i].geometry!;
      const b = icons[j].geometry!;
      const apart = a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y;
      if (!apart) out.push(`${icons[i].id} overlaps ${icons[j].id}`);
    }
  }
  return out;
}

type Point = { x: number; y: number };
type Segment = { p1: Point; p2: Point; edgeId: string; index: number };

function crossProduct(a: Point, b: Point, c: Point): number {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

function distSq(a: Point, b: Point): number {
  return (a.x - b.x) ** 2 + (a.y - b.y) ** 2;
}

function segmentsCrossOrOverlap(s1: Segment, s2: Segment, eps = 1e-4): { cross: boolean; reason?: string } {
  const { p1, p2 } = s1;
  const { p1: p3, p2: p4 } = s2;

  const sameP1P3 = distSq(p1, p3) < eps;
  const sameP1P4 = distSq(p1, p4) < eps;
  const sameP2P3 = distSq(p2, p3) < eps;
  const sameP2P4 = distSq(p2, p4) < eps;
  const sharedEndpoints = Number(sameP1P3) + Number(sameP1P4) + Number(sameP2P3) + Number(sameP2P4);

  const cp1 = crossProduct(p1, p2, p3);
  const cp2 = crossProduct(p1, p2, p4);
  const cp3 = crossProduct(p3, p4, p1);
  const cp4 = crossProduct(p3, p4, p2);

  const isCollinear = Math.abs(cp1) < eps && Math.abs(cp2) < eps && Math.abs(cp3) < eps && Math.abs(cp4) < eps;

  if (isCollinear) {
    const minAx = Math.min(p1.x, p2.x), maxAx = Math.max(p1.x, p2.x);
    const minAy = Math.min(p1.y, p2.y), maxAy = Math.max(p1.y, p2.y);
    const minBx = Math.min(p3.x, p4.x), maxBx = Math.max(p3.x, p4.x);
    const minBy = Math.min(p3.y, p4.y), maxBy = Math.max(p3.y, p4.y);

    const overlapX = Math.min(maxAx, maxBx) - Math.max(minAx, minBx);
    const overlapY = Math.min(maxAy, maxBy) - Math.max(minAy, minBy);

    const isHoriz = Math.abs(p1.y - p2.y) < eps && Math.abs(p3.y - p4.y) < eps;
    const isVert = Math.abs(p1.x - p2.x) < eps && Math.abs(p3.x - p4.x) < eps;

    if (isHoriz && overlapX > 0.5) {
      return { cross: true, reason: `collinear horizontal overlap of ${overlapX.toFixed(1)}px` };
    }
    if (isVert && overlapY > 0.5) {
      return { cross: true, reason: `collinear vertical overlap of ${overlapY.toFixed(1)}px` };
    }
    if (!isHoriz && !isVert && (overlapX > 0.5 || overlapY > 0.5)) {
      return { cross: true, reason: `collinear diagonal overlap` };
    }
    return { cross: false };
  }

  if (sharedEndpoints > 0) {
    return { cross: false };
  }

  const s12_3 = crossProduct(p1, p2, p3);
  const s12_4 = crossProduct(p1, p2, p4);
  const s34_1 = crossProduct(p3, p4, p1);
  const s34_2 = crossProduct(p3, p4, p2);

  const straddles1 = (s12_3 > eps && s12_4 < -eps) || (s12_3 < -eps && s12_4 > eps);
  const straddles2 = (s34_1 > eps && s34_2 < -eps) || (s34_1 < -eps && s34_2 > eps);

  if (straddles1 && straddles2) {
    return { cross: true, reason: `X-crossing` };
  }

  function onSegment(p: Point, a: Point, b: Point): boolean {
    const cp = Math.abs(crossProduct(a, b, p));
    if (cp > eps) return false;
    const minX = Math.min(a.x, b.x) + eps, maxX = Math.max(a.x, b.x) - eps;
    const minY = Math.min(a.y, b.y) + eps, maxY = Math.max(a.y, b.y) - eps;
    return p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY;
  }

  if (onSegment(p3, p1, p2) || onSegment(p4, p1, p2) || onSegment(p1, p3, p4) || onSegment(p2, p3, p4)) {
    return { cross: true, reason: `T-junction strike` };
  }

  return { cross: false };
}

export function edgeCrossings(xml: string): string[] {
  const parsed = parseDrawio(xml);
  const byId = new Map(parsed.cells.map((c: Cell) => [c.id, c]));
  const edges = parsed.cells.filter((c: Cell) => c.edge);

  const segments: Segment[] = [];
  for (const edge of edges) {
    const pts = getEdgePoints(edge, byId);
    for (let i = 0; i < pts.length - 1; i++) {
      segments.push({ p1: pts[i], p2: pts[i + 1], edgeId: edge.id, index: i });
    }
  }

  const crossings: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    for (let j = i + 1; j < segments.length; j++) {
      const s1 = segments[i];
      const s2 = segments[j];
      if (s1.edgeId === s2.edgeId) {
        if (Math.abs(s1.index - s2.index) > 1) {
          const res = segmentsCrossOrOverlap(s1, s2);
          if (res.cross) crossings.push(`self-intersection in ${s1.edgeId}: ${res.reason}`);
        }
      } else {
        const res = segmentsCrossOrOverlap(s1, s2);
        if (res.cross) crossings.push(`${s1.edgeId} crosses ${s2.edgeId} (${res.reason})`);
      }
    }
  }
  return crossings;
}

function segmentIntersectsBox(p1: Point, p2: Point, b: { x: number; y: number; width: number; height: number }, eps = 1e-3): boolean {
  const xmin = b.x + eps;
  const xmax = b.x + b.width - eps;
  const ymin = b.y + eps;
  const ymax = b.y + b.height - eps;

  if (xmin >= xmax || ymin >= ymax) return false;

  let t0 = 0, t1 = 1;
  const dx = p2.x - p1.x;
  const dy = p2.y - p1.y;

  const checks = [
    [-dx, p1.x - xmin],
    [dx, xmax - p1.x],
    [-dy, p1.y - ymin],
    [dy, ymax - p1.y],
  ];

  for (const [p, q] of checks) {
    if (p === 0) {
      if (q < 0) return false;
    } else {
      const r = q / p;
      if (p < 0) {
        if (r > t1) return false;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return false;
        if (r < t1) t1 = r;
      }
    }
  }
  return t0 < t1 - 1e-5;
}

export function edgeIconStrikes(xml: string): string[] {
  const parsed = parseDrawio(xml);
  const byId = new Map(parsed.cells.map((c: Cell) => [c.id, c]));
  const edges = parsed.cells.filter((c: Cell) => c.edge);
  const icons = parsed.cells.filter((c: Cell) => c.vertex && c.geometry && (c.style.image || c.style.shape === "image"));

  const strikes: string[] = [];
  for (const edge of edges) {
    const pts = getEdgePoints(edge, byId);
    for (const icon of icons) {
      for (let i = 0; i < pts.length - 1; i++) {
        if (segmentIntersectsBox(pts[i], pts[i + 1], icon.geometry!)) {
          strikes.push(`${edge.id} strikes ${icon.id}`);
          break;
        }
      }
    }
  }
  return strikes;
}

const ICON = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=";
const cell = (id: string, x: number, y: number) =>
  `<mxCell id="${id}" value="${id}" style="shape=image;verticalLabelPosition=bottom;image=${ICON};" vertex="1" parent="1"><mxGeometry x="${x}" y="${y}" width="48" height="48" as="geometry" /></mxCell>`;
const doc = (cells: string) =>
  `<mxfile><diagram><mxGraphModel pageWidth="400" pageHeight="400"><root><mxCell id="0" /><mxCell id="1" parent="0" />${cells}</root></mxGraphModel></diagram></mxfile>`;

describe("icon overlap gate", () => {
  test("flags two icons sharing a box", () => {
    expect(iconOverlaps(doc(cell("a", 10, 10) + cell("b", 30, 30)))).toEqual(["a overlaps b"]);
  });

  test("passes icons that only touch or sit apart", () => {
    expect(iconOverlaps(doc(cell("a", 10, 10) + cell("b", 58, 10) + cell("c", 200, 200)))).toEqual([]);
  });

  for (const name of readdirSync(DIAGRAMS).filter((f) => f.endsWith(".drawio")).sort()) {
    test(`${name} has no overlapping icons`, () => {
      expect(iconOverlaps(readFileSync(join(DIAGRAMS, name), "utf8"))).toEqual([]);
    });
  }
});

describe("edge crossings gate", () => {
  test("flags X-crossing", () => {
    const dX = doc(`
      <mxCell id="a" vertex="1" parent="1"><mxGeometry x="10" y="10" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="b" vertex="1" parent="1"><mxGeometry x="100" y="100" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="c" vertex="1" parent="1"><mxGeometry x="10" y="100" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="d" vertex="1" parent="1"><mxGeometry x="100" y="10" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="e1" edge="1" parent="1" source="a" target="b"><mxGeometry relative="1" as="geometry" /></mxCell>
      <mxCell id="e2" edge="1" parent="1" source="c" target="d"><mxGeometry relative="1" as="geometry" /></mxCell>
    `);
    expect(edgeCrossings(dX)).toEqual(["e1 crosses e2 (X-crossing)"]);
  });

  test("flags collinear overlap", () => {
    const dCollinear = doc(`
      <mxCell id="a" vertex="1" parent="1"><mxGeometry x="50" y="50" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="b" vertex="1" parent="1"><mxGeometry x="50" y="200" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="c" vertex="1" parent="1"><mxGeometry x="50" y="100" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="d" vertex="1" parent="1"><mxGeometry x="50" y="250" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="e1" edge="1" parent="1" source="a" target="b" style="exitX=0.5;exitY=1;entryX=0.5;entryY=0;"><mxGeometry relative="1" as="geometry" /></mxCell>
      <mxCell id="e2" edge="1" parent="1" source="c" target="d" style="exitX=0.5;exitY=1;entryX=0.5;entryY=0;"><mxGeometry relative="1" as="geometry" /></mxCell>
    `);
    expect(edgeCrossings(dCollinear)).toEqual(["e1 crosses e2 (collinear vertical overlap of 80.0px)"]);
  });

  test("passes shared junction", () => {
    const dJunction = doc(`
      <mxCell id="a" vertex="1" parent="1"><mxGeometry x="10" y="10" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="b" vertex="1" parent="1"><mxGeometry x="100" y="50" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="c" vertex="1" parent="1"><mxGeometry x="10" y="90" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="e1" edge="1" parent="1" source="a" target="b" style="exitX=1;exitY=0.5;entryX=0;entryY=0.5;"><mxGeometry relative="1" as="geometry" /></mxCell>
      <mxCell id="e2" edge="1" parent="1" source="c" target="b" style="exitX=1;exitY=0.5;entryX=0;entryY=0.5;"><mxGeometry relative="1" as="geometry" /></mxCell>
    `);
    expect(edgeCrossings(dJunction)).toEqual([]);
  });

  for (const name of readdirSync(DIAGRAMS).filter((f) => f.endsWith(".drawio")).sort()) {
    test(`${name} has zero edge crossings`, () => {
      expect(edgeCrossings(readFileSync(join(DIAGRAMS, name), "utf8"))).toEqual([]);
    });
  }
});

describe("edge icon strikes gate", () => {
  test("flags penetrating stroke through an icon", () => {
    const dPenetrate = doc(`
      <mxCell id="n1" value="icon1" style="shape=image;image=${ICON};" vertex="1" parent="1"><mxGeometry x="100" y="100" width="50" height="50" as="geometry" /></mxCell>
      <mxCell id="s" value="src" vertex="1" parent="1"><mxGeometry x="20" y="125" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="t" value="tgt" vertex="1" parent="1"><mxGeometry x="200" y="125" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="e1" edge="1" parent="1" source="s" target="t"><mxGeometry relative="1" as="geometry" /></mxCell>
    `);
    expect(edgeIconStrikes(dPenetrate)).toEqual(["e1 strikes n1"]);
  });

  test("passes perimeter departure from an icon", () => {
    const dPerimeter = doc(`
      <mxCell id="n1" value="icon1" style="shape=image;image=${ICON};" vertex="1" parent="1"><mxGeometry x="100" y="100" width="50" height="50" as="geometry" /></mxCell>
      <mxCell id="t" value="tgt" vertex="1" parent="1"><mxGeometry x="200" y="125" width="20" height="20" as="geometry" /></mxCell>
      <mxCell id="e1" edge="1" parent="1" source="n1" target="t" style="exitX=1;exitY=0.5;"><mxGeometry relative="1" as="geometry" /></mxCell>
    `);
    expect(edgeIconStrikes(dPerimeter)).toEqual([]);
  });

  for (const name of readdirSync(DIAGRAMS).filter((f) => f.endsWith(".drawio")).sort()) {
    test(`${name} has zero edge icon strikes`, () => {
      expect(edgeIconStrikes(readFileSync(join(DIAGRAMS, name), "utf8"))).toEqual([]);
    });
  }
});

// The warden is our own component, not a CNCF project, so it carries the
// Signal Loom logo. The first build reused the retired Olly Sentinel icon.
const LOGO = "data:image/png;base64," + readFileSync(join(import.meta.dir, "assets/signal-loom-logo-96.png")).toString("base64");

describe("warden branding", () => {
  for (const name of readdirSync(DIAGRAMS).filter((f) => f.endsWith(".drawio")).sort()) {
    test(`${name} draws every warden with the Signal Loom logo`, () => {
      const wardens = parseDrawio(readFileSync(join(DIAGRAMS, name), "utf8")).cells.filter((c: Cell) => c.vertex && /warden/i.test(c.value));
      expect(wardens.length).toBeGreaterThan(0);
      for (const w of wardens) expect(w.style.image === LOGO ? w.id : `${w.id} uses another icon`).toBe(w.id);
    });
  }
});

describe("diagram data integrity and XML balance across all diagrams", () => {
  for (const name of readdirSync(DIAGRAMS).filter((f) => f.endsWith(".drawio")).sort()) {
    test(`${name} all image vertices have non-empty data URI icons`, () => {
      const xml = readFileSync(join(DIAGRAMS, name), "utf8");
      const parsed = parseDrawio(xml);
      const imageCells = parsed.cells.filter((c: Cell) => c.vertex && (c.style.shape === "image" || c.style.image));
      expect(imageCells.length).toBeGreaterThan(0);
      for (const c of imageCells) {
        expect(c.style.image).toBeDefined();
        expect(c.style.image?.length).toBeGreaterThan(10);
        expect(c.style.image).toMatch(/^data:image\/(svg\+xml|png);base64,/);
      }
    });

    test(`${name} mxCell tags are properly balanced without dangling close tags`, () => {
      const xml = readFileSync(join(DIAGRAMS, name), "utf8");
      const openTags = (xml.match(/<mxCell\b/g) ?? []).length;
      const selfClosing = (xml.match(/<mxCell\b[^>]*\/>/g) ?? []).length;
      const closeTags = (xml.match(/<\/mxCell>/g) ?? []).length;
      expect(closeTags).toBe(openTags - selfClosing);
    });
  }
});

describe("sovereign kind diagram components and layout", () => {
  const xml = readFileSync(join(DIAGRAMS, "osramp-kind-sovereign-airgap.drawio"), "utf8");

  test("shows policy-engine, cert-manager, Landlock LSM, PostgreSQL, and receiver", () => {
    expect(xml).toContain("policy-engine");
    expect(xml).toContain("cert-manager");
    expect(xml).toContain("Landlock LSM");
    expect(xml).toContain("PostgreSQL");
    expect(xml).toMatch(/Receiver/i);
  });

  test("all image vertices have non-empty data URI icons", () => {
    const parsed = parseDrawio(xml);
    const imageCells = parsed.cells.filter((c: Cell) => c.vertex && c.style.shape === "image");
    expect(imageCells.length).toBeGreaterThan(0);
    for (const c of imageCells) {
      expect(c.style.image).toBeDefined();
      expect(c.style.image?.length).toBeGreaterThan(10);
      expect(c.style.image).toMatch(/^data:image\/(svg\+xml|png);base64,/);
    }
  });

  test("mxCell tags are properly balanced without dangling close tags", () => {
    const openTags = (xml.match(/<mxCell\b/g) ?? []).length;
    const selfClosing = (xml.match(/<mxCell\b[^>]*\/>/g) ?? []).length;
    const closeTags = (xml.match(/<\/mxCell>/g) ?? []).length;
    expect(closeTags).toBe(openTags - selfClosing);
  });

  test("osramp-kind-sovereign-airgap.drawio has zero icon overlaps", () => {
    expect(iconOverlaps(xml)).toEqual([]);
  });
});
