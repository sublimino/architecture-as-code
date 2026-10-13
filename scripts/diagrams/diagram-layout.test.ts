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
import { parseDrawio, type Cell } from "./drawio-render";

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
