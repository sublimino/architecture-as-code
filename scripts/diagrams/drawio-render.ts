#!/usr/bin/env bun
// @id      drawio-render
// @doc     d2-signalloom/apps/docs-signalloom/DIAGRAMS.md
// @tests   scripts/diagrams/drawio-render.test.ts
//
// Deterministic draw.io (.drawio / mxfile) -> SVG/PNG renderer.
//
// The .drawio file is the single source of truth for every published
// architecture diagram. This script regenerates its three outputs:
//   <name>.svg         plain SVG, for embedding in docs
//   <name>.drawio.svg  the same SVG with the source mxfile XML embedded in
//                      the root `content` attribute, so draw.io reopens it
//                      as an editable diagram
//   <name>.png         rasterized via /usr/bin/rsvg-convert, ~1.5x page width
//
// Running it twice on the same input gives byte-identical output: no
// timestamps, no random ids, no Math.random. The renderer only understands
// the style vocabulary the four published diagrams actually use (see
// DIAGRAMS.md): dashed/rounded containers, shape=image cells with embedded
// data-URI icons, HTML labels (<br>, <font color/size>, <b>), and edges
// with classic arrowheads, explicit waypoints, and orthogonal routing.

export interface Geometry {
  x: number;
  y: number;
  width: number;
  height: number;
  points?: { x: number; y: number }[];
}

export interface Cell {
  id: string;
  value: string;
  style: Record<string, string>;
  vertex: boolean;
  edge: boolean;
  parent?: string;
  source?: string;
  target?: string;
  geometry?: Geometry;
}

export interface ParsedDiagram {
  pageWidth: number;
  pageHeight: number;
  cells: Cell[];
  byId: Map<string, Cell>;
}

// ---------------------------------------------------------------------------
// XML entity handling
//
// draw.io's mxCell `value` attribute is double-quoted but routinely contains
// unescaped `<br>` / `<font ...>` markup — not strict XML, but every file we
// must parse does this, so entity decoding/encoding is handled explicitly
// rather than deferring to a general-purpose XML parser.
// ---------------------------------------------------------------------------

function decodeXmlEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&amp;/g, "&");
}

function encodeXmlEntities(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeHtmlText(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function parseStyle(style: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!style) return out;

  // `image=data:...;base64,....` embeds its own semicolon (mime;base64,...),
  // so it can't go through the naive split below. Every style string in the
  // diagrams this renders puts `image=` last, so split it off first and
  // parse the remainder normally.
  let rest = style;
  const imageIdx = style.indexOf("image=data:");
  if (imageIdx >= 0) {
    let value = style.slice(imageIdx + "image=".length);
    if (value.endsWith(";")) value = value.slice(0, -1);
    out.image = value;
    rest = style.slice(0, imageIdx);
  }

  for (const part of rest.split(";")) {
    if (!part) continue;
    const i = part.indexOf("=");
    if (i < 0) {
      out[part] = "1";
    } else {
      out[part.slice(0, i)] = part.slice(i + 1);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// mxCell scanning
//
// draw.io does not guarantee attribute order (id/value/style/vertex|edge/
// parent/source/target), and a hand-edited or differently-exported file can
// carry attributes in any order, or extra attributes this renderer doesn't
// care about. A fixed-order regex silently skips any cell that doesn't match
// that exact shape — the bug is invisible until a diagram quietly loses a
// box. So cells are scanned generically: walk `name="value"` pairs one at a
// time from right after `<mxCell`, which works regardless of order because
// every attribute value in these files is quote-delimited (literal `"`
// never appears unescaped inside one, even though `<`/`>` sometimes do via
// unescaped `<br>`/`<font>` markup in `value`). Only once no more
// `name="value"` pairs match do we look at what follows to decide whether
// the tag self-closes (`/>`) or opens a body that runs to the next
// `</mxCell>`.
//
// As a belt-and-braces check, the number of cells this produces must equal
// the number of raw `<mxCell` occurrences in the file (including the two
// root cells, ids "0" and "1") — if it doesn't, something was swallowed or
// miscounted and we throw rather than silently return a short diagram.
// ---------------------------------------------------------------------------

const ATTR_RE = /\s*([A-Za-z_:][-\w:.]*)="([^"]*)"/y;

interface RawTag {
  attrs: Record<string, string>;
  body?: string;
}

function scanTagsByName(xml: string, tagName: string, closeTag: string): RawTag[] {
  const results: RawTag[] = [];
  const openRe = new RegExp(`<${tagName}\\b`, "g");
  let om: RegExpExecArray | null;
  while ((om = openRe.exec(xml))) {
    let pos = om.index + om[0].length;
    const attrs: Record<string, string> = {};
    while (true) {
      ATTR_RE.lastIndex = pos;
      const am = ATTR_RE.exec(xml);
      if (!am) break;
      attrs[am[1]] = am[2];
      pos = ATTR_RE.lastIndex;
    }

    const rest = xml.slice(pos);
    const selfClose = /^\s*\/>/.exec(rest);
    if (selfClose) {
      results.push({ attrs });
      openRe.lastIndex = pos + selfClose[0].length;
      continue;
    }
    const open = /^\s*>/.exec(rest);
    if (open) {
      const bodyStart = pos + open[0].length;
      const closeIdx = xml.indexOf(closeTag, bodyStart);
      if (closeIdx === -1) {
        throw new Error(`malformed <${tagName}> tag: no matching ${closeTag} found after position ${bodyStart}`);
      }
      results.push({ attrs, body: xml.slice(bodyStart, closeIdx) });
      openRe.lastIndex = closeIdx + closeTag.length;
      continue;
    }
    throw new Error(`malformed <${tagName}> tag near position ${pos}: expected "/>" or ">"`);
  }
  return results;
}

// mxPoint is always self-closing in these files, so scanTagsByName's
// "closeTag" search path is never exercised for it — pass a close tag that
// can never legitimately match so a genuinely unclosed, non-self-closing
// `<mxPoint ...>` fails loudly instead of silently consuming the rest of
// the document looking for a tag that was never going to appear.
function parsePointsSafe(body: string): { x: number; y: number }[] {
  const points: { x: number; y: number }[] = [];
  const re = /<mxPoint\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body))) {
    let pos = m.index + m[0].length;
    const attrs: Record<string, string> = {};
    while (true) {
      ATTR_RE.lastIndex = pos;
      const am = ATTR_RE.exec(body);
      if (!am) break;
      attrs[am[1]] = am[2];
      pos = ATTR_RE.lastIndex;
    }
    const rest = body.slice(pos);
    const selfClose = /^\s*\/>/.exec(rest);
    if (!selfClose) {
      throw new Error(`malformed <mxPoint> tag near position ${pos}: expected "/>"`);
    }
    points.push({ x: Number(attrs.x ?? "0"), y: Number(attrs.y ?? "0") });
    re.lastIndex = pos + selfClose[0].length;
  }
  return points;
}

function parseGeometry(body: string): Geometry | undefined {
  const geomTags = scanTagsByName(body, "mxGeometry", "</mxGeometry>");
  if (!geomTags.length) return undefined;
  const { attrs, body: gbody } = geomTags[0];
  const x = Number(attrs.x ?? "0");
  const y = Number(attrs.y ?? "0");
  const width = Number(attrs.width ?? "0");
  const height = Number(attrs.height ?? "0");
  const geometry: Geometry = { x, y, width, height };
  if (gbody) {
    const points = parsePointsSafe(gbody);
    if (points.length) geometry.points = points;
  }
  return geometry;
}

function resolveAbsoluteGeometry(cells: Cell[], byId: Map<string, Cell>): void {
  const resolved = new Map<string, { x: number; y: number }>();

  function resolve(cell: Cell, stack: Set<string>): { x: number; y: number } {
    const cached = resolved.get(cell.id);
    if (cached) return cached;
    if (stack.has(cell.id)) {
      throw new Error(`cyclic parent chain involving cell "${cell.id}"`);
    }
    const base = cell.geometry ? { x: cell.geometry.x, y: cell.geometry.y } : { x: 0, y: 0 };
    let offset = { x: 0, y: 0 };
    if (cell.parent && cell.parent !== "0" && cell.parent !== "1") {
      const parentCell = byId.get(cell.parent);
      if (!parentCell) {
        throw new Error(`cell "${cell.id}" references parent "${cell.parent}", which does not exist`);
      }
      stack.add(cell.id);
      offset = resolve(parentCell, stack);
      stack.delete(cell.id);
    }
    const abs = { x: base.x + offset.x, y: base.y + offset.y };
    resolved.set(cell.id, abs);
    return abs;
  }

  for (const cell of cells) {
    if (!cell.geometry) continue;
    const abs = resolve(cell, new Set());
    cell.geometry.x = abs.x;
    cell.geometry.y = abs.y;
  }
}

export function parseDrawio(xml: string): ParsedDiagram {
  const pageMatch = /pageWidth="(\d+)"\s+pageHeight="(\d+)"/.exec(xml);
  const pageWidth = pageMatch ? Number(pageMatch[1]) : 1200;
  const pageHeight = pageMatch ? Number(pageMatch[2]) : 1520;

  const cells: Cell[] = [];
  const byId = new Map<string, Cell>();

  for (const tag of scanTagsByName(xml, "mxCell", "</mxCell>")) {
    const { attrs, body } = tag;
    const id = attrs.id ?? "";
    const cell: Cell = {
      id,
      value: attrs.value ? decodeXmlEntities(attrs.value) : "",
      style: parseStyle(attrs.style ?? ""),
      vertex: attrs.vertex === "1",
      edge: attrs.edge === "1",
      parent: attrs.parent,
      source: attrs.source,
      target: attrs.target,
    };

    if (body) {
      cell.geometry = parseGeometry(body);
    }

    cells.push(cell);
    byId.set(id, cell);
  }

  const rawCellTagCount = (xml.match(/<mxCell\b/g) ?? []).length;
  if (rawCellTagCount !== cells.length) {
    throw new Error(
      `parseDrawio: found ${rawCellTagCount} <mxCell> tags in the source but only parsed ${cells.length} — a cell was silently dropped`,
    );
  }

  resolveAbsoluteGeometry(cells, byId);

  return { pageWidth, pageHeight, cells, byId };
}

// ---------------------------------------------------------------------------
// HTML label -> SVG tspans
//
// Supports exactly the markup the published diagrams use: <br> line breaks,
// <font color='#rrggbb' style='font-size: Npx[; font-weight: normal]'>, and
// <b>bold</b>.
// ---------------------------------------------------------------------------

interface LabelRun {
  text: string;
  color?: string;
  fontSize?: number;
  bold?: boolean;
}

type LabelLine = LabelRun[];

function parseLabel(value: string, baseColor: string, baseSize: number, baseBold: boolean): LabelLine[] {
  const lines: LabelLine[] = [[]];
  let i = 0;
  const stack: { color?: string; fontSize?: number; bold?: boolean }[] = [];

  function current(): { color?: string; fontSize?: number; bold?: boolean } {
    return stack.length ? stack[stack.length - 1] : {};
  }

  while (i < value.length) {
    if (value.startsWith("<br>", i) || value.startsWith("<br/>", i)) {
      lines.push([]);
      i += value.startsWith("<br/>", i) ? 5 : 4;
      continue;
    }
    if (value.startsWith("<b>", i)) {
      stack.push({ ...current(), bold: true });
      i += 3;
      continue;
    }
    if (value.startsWith("</b>", i)) {
      stack.pop();
      i += 4;
      continue;
    }
    const fontOpen = /^<font\s+([^>]*)>/.exec(value.slice(i));
    if (fontOpen) {
      const attrs = fontOpen[1];
      const colorM = /color=(?:'([^']*)'|"([^"]*)")/.exec(attrs);
      const sizeM = /font-size:\s*(\d+)px/.exec(attrs);
      const weightNormalM = /font-weight:\s*normal/.exec(attrs);
      stack.push({
        color: colorM ? colorM[1] || colorM[2] : current().color,
        fontSize: sizeM ? Number(sizeM[1]) : current().fontSize,
        bold: weightNormalM ? false : current().bold,
      });
      i += fontOpen[0].length;
      continue;
    }
    if (value.startsWith("</font>", i)) {
      stack.pop();
      i += 7;
      continue;
    }
    // Plain text run up to the next tag.
    const nextTag = value.slice(i).search(/<(br\/?|b|\/b|font|\/font)/);
    const textEnd = nextTag === -1 ? value.length : i + nextTag;
    const text = value.slice(i, textEnd);
    if (text) {
      const ctx = current();
      lines[lines.length - 1].push({
        text,
        color: ctx.color ?? baseColor,
        fontSize: ctx.fontSize ?? baseSize,
        bold: ctx.bold ?? baseBold,
      });
    }
    i = textEnd;
  }

  return lines.filter((line) => line.some((r) => r.text.length > 0));
}

function renderLabelLines(
  lines: LabelLine[],
  cx: number,
  startY: number,
  align: "middle" | "start",
  anchorX: number,
): string {
  const out: string[] = [];
  let y = startY;
  for (const line of lines) {
    const lineHeight = Math.max(...line.map((r) => r.fontSize ?? 12)) * 1.3;
    y += lineHeight;
    const tspans = line
      .map((r) => {
        const weight = r.bold ? ' font-weight="bold"' : "";
        // Edges routinely pass behind vertex and edge labels alike. A white
        // halo (paint the stroke before the fill, per paint-order) keeps
        // glyphs legible wherever a line crosses them, without needing to
        // compute a text-bbox background rect from font metrics we don't have.
        const halo = ' stroke="#ffffff" stroke-width="3" stroke-linejoin="round" paint-order="stroke"';
        return `<tspan fill="${r.color}" font-size="${r.fontSize}"${weight}${halo}>${escapeHtmlText(r.text)}</tspan>`;
      })
      .join("");
    out.push(
      `<text x="${anchorX}" y="${y.toFixed(2)}" text-anchor="${align === "middle" ? "middle" : "start"}" font-family="'DejaVu Sans', Helvetica, Arial, sans-serif">${tspans}</text>`,
    );
  }
  return out.join("\n");
}

// ---------------------------------------------------------------------------
// Edge geometry
// ---------------------------------------------------------------------------

interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

function boxCenter(b: Box): { x: number; y: number } {
  return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
}

// Point where a ray from the box center toward `toward` crosses the box
// perimeter — the standard rectangle/ray intersection used so edges visually
// touch the shape's edge rather than its center.
function perimeterPoint(b: Box, toward: { x: number; y: number }): { x: number; y: number } {
  const c = boxCenter(b);
  const dx = toward.x - c.x;
  const dy = toward.y - c.y;
  if (dx === 0 && dy === 0) return c;
  const halfW = b.width / 2;
  const halfH = b.height / 2;
  const scaleX = dx !== 0 ? halfW / Math.abs(dx) : Infinity;
  const scaleY = dy !== 0 ? halfH / Math.abs(dy) : Infinity;
  const t = Math.min(scaleX, scaleY);
  return { x: c.x + dx * t, y: c.y + dy * t };
}

function fixedAnchor(style: Record<string, string>, prefix: "exit" | "entry", b: Box): { x: number; y: number } | undefined {
  const xKey = `${prefix}X`;
  const yKey = `${prefix}Y`;
  if (style[xKey] === undefined || style[yKey] === undefined) return undefined;
  const fx = Number(style[xKey]);
  const fy = Number(style[yKey]);
  const dx = Number(style[`${prefix}Dx`] ?? 0);
  const dy = Number(style[`${prefix}Dy`] ?? 0);
  return { x: b.x + fx * b.width + dx, y: b.y + fy * b.height + dy };
}

// Point at the given fraction (0..1) along the total arc length of a
// multi-segment polyline — used to place an edge label at the visual middle
// of the path, not just the midpoint of its first/last points (which would
// be wrong for an orthogonal elbow or a routed edge with waypoints).
function pointAlongPath(points: { x: number; y: number }[], fraction: number): { x: number; y: number } {
  const segmentLengths: number[] = [];
  let total = 0;
  for (let i = 1; i < points.length; i++) {
    const len = Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y);
    segmentLengths.push(len);
    total += len;
  }
  if (total === 0) return points[0];

  let remaining = total * fraction;
  for (let i = 0; i < segmentLengths.length; i++) {
    const segLen = segmentLengths[i];
    if (remaining <= segLen || i === segmentLengths.length - 1) {
      const t = segLen === 0 ? 0 : Math.min(1, remaining / segLen);
      const a = points[i];
      const b = points[i + 1];
      return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
    }
    remaining -= segLen;
  }
  return points[points.length - 1];
}

function orthogonalElbow(
  start: { x: number; y: number },
  end: { x: number; y: number },
): { x: number; y: number }[] {
  if (Math.abs(start.x - end.x) < 1e-6 || Math.abs(start.y - end.y) < 1e-6) {
    return [start, end];
  }
  const midY = (start.y + end.y) / 2;
  return [start, { x: start.x, y: midY }, { x: end.x, y: midY }, end];
}

function arrowheadPolygon(tip: { x: number; y: number }, from: { x: number; y: number }): string {
  const size = 8;
  const angle = Math.atan2(tip.y - from.y, tip.x - from.x);
  const spread = Math.PI / 7;
  const p1 = {
    x: tip.x - size * Math.cos(angle - spread),
    y: tip.y - size * Math.sin(angle - spread),
  };
  const p2 = {
    x: tip.x - size * Math.cos(angle + spread),
    y: tip.y - size * Math.sin(angle + spread),
  };
  return `<polygon class="arrowhead" points="${tip.x.toFixed(2)},${tip.y.toFixed(2)} ${p1.x.toFixed(2)},${p1.y.toFixed(2)} ${p2.x.toFixed(2)},${p2.y.toFixed(2)}" fill="${"#000000"}" />`;
}

function renderEdge(cell: Cell, byId: Map<string, Cell>): string {
  const sourceCell = cell.source ? byId.get(cell.source) : undefined;
  const targetCell = cell.target ? byId.get(cell.target) : undefined;
  if (!cell.source || !cell.target || !sourceCell?.geometry || !targetCell?.geometry) {
    // An edge that can't be anchored at both ends is a diagram that drew
    // wrong, not one that drew nothing — surface it instead of silently
    // dropping the edge (and the connection it was supposed to document).
    throw new Error(
      `edge "${cell.id}" cannot be rendered: source "${cell.source ?? "(none)"}" or target "${cell.target ?? "(none)"}" is missing or has no geometry`,
    );
  }

  const sBox = sourceCell.geometry;
  const tBox = targetCell.geometry;
  const explicitPoints = cell.geometry?.points ?? [];

  const towardForStart = explicitPoints[0] ?? boxCenter(tBox);
  const towardForEnd = explicitPoints[explicitPoints.length - 1] ?? boxCenter(sBox);

  const start = fixedAnchor(cell.style, "exit", sBox) ?? perimeterPoint(sBox, towardForStart);
  const end = fixedAnchor(cell.style, "entry", tBox) ?? perimeterPoint(tBox, towardForEnd);

  let points: { x: number; y: number }[];
  if (explicitPoints.length) {
    points = [start, ...explicitPoints, end];
  } else if (cell.style.edgeStyle === "orthogonalEdgeStyle") {
    points = orthogonalElbow(start, end);
  } else {
    points = [start, end];
  }

  const d = points
    .map((p, idx) => `${idx === 0 ? "M" : "L"} ${p.x.toFixed(2)},${p.y.toFixed(2)}`)
    .join(" ");

  const strokeColor = cell.style.strokeColor ?? "#000000";
  const strokeWidth = cell.style.strokeWidth ?? "1";
  const parts = [`<path d="${d}" fill="none" stroke="${strokeColor}" stroke-width="${strokeWidth}" />`];

  if (cell.style.endArrow && cell.style.endArrow !== "none" && cell.style.endFill === "1") {
    parts.push(arrowheadPolygon(points[points.length - 1], points[points.length - 2]));
  }
  if (cell.style.startArrow && cell.style.startArrow !== "none" && cell.style.startFill === "1") {
    parts.push(arrowheadPolygon(points[0], points[1]));
  }

  if (cell.value) {
    const mid = pointAlongPath(points, 0.5);
    const lines = parseLabel(
      cell.value,
      cell.style.fontColor ?? "#333333",
      Number(cell.style.fontSize ?? "11"),
      cell.style.fontStyle === "1",
    );
    const totalHeight = lines.reduce((sum, l) => sum + Math.max(...l.map((r) => r.fontSize ?? 11)) * 1.3, 0);
    const startY = mid.y - totalHeight / 2;
    parts.push(renderLabelLines(lines, mid.x, startY, "middle", mid.x));
  }

  return parts.join("\n");
}

// ---------------------------------------------------------------------------
// Vertex rendering
// ---------------------------------------------------------------------------

function renderContainer(cell: Cell): string {
  const g = cell.geometry!;
  const style = cell.style;
  const arcSize = Number(style.arcSize ?? "0");
  const strokeWidth = Number(style.strokeWidth ?? "1");
  const rx = arcSize ? Math.min(g.width, g.height) * (arcSize / 100) : 0;
  const dashArray = style.dashed === "1" ? (style.dashPattern ?? "4 2").trim().replace(/\s+/g, ",") : undefined;
  const strokeColor = style.strokeColor ?? "#000000";
  const fillColor = !style.fillColor || style.fillColor === "none" ? "none" : style.fillColor;

  const rect = `<rect x="${g.x}" y="${g.y}" width="${g.width}" height="${g.height}" rx="${rx.toFixed(2)}" ry="${rx.toFixed(2)}" fill="${fillColor}" stroke="${strokeColor}" stroke-width="${strokeWidth}"${dashArray ? ` stroke-dasharray="${dashArray}"` : ""} />`;

  const lines = parseLabel(cell.value, style.fontColor ?? "#000000", Number(style.fontSize ?? "12"), style.fontStyle === "1");
  const verticalAlign = style.verticalAlign ?? "middle";
  const spacingTop = Number(style.spacingTop ?? "4");
  const spacingBottom = Number(style.spacingBottom ?? "4");
  let labelY: number;
  if (verticalAlign === "top") {
    labelY = g.y + spacingTop;
  } else if (verticalAlign === "bottom") {
    const totalHeight = lines.reduce((sum, l) => sum + Math.max(...l.map((r) => r.fontSize ?? 12)) * 1.3, 0);
    labelY = g.y + g.height - spacingBottom - totalHeight;
  } else {
    labelY = g.y + g.height / 2 - (lines.length * 14) / 2;
  }

  const label = renderLabelLines(lines, g.x + g.width / 2, labelY, "middle", g.x + g.width / 2);
  return `${rect}\n${label}`;
}

function renderImageCell(cell: Cell): string {
  const g = cell.geometry!;
  const style = cell.style;
  const image = `<image x="${g.x}" y="${g.y}" width="${g.width}" height="${g.height}" href="${style.image}" />`;

  const lines = parseLabel(cell.value, style.fontColor ?? "#111111", Number(style.fontSize ?? "12"), false);
  const gap = 6;
  const label = renderLabelLines(lines, g.x + g.width / 2, g.y + g.height + gap, "middle", g.x + g.width / 2);
  return `${image}\n${label}`;
}

function renderTextCell(cell: Cell): string {
  const g = cell.geometry!;
  const style = cell.style;
  const lines = parseLabel(cell.value, style.fontColor ?? "#000000", Number(style.fontSize ?? "12"), style.fontStyle === "1");
  const totalHeight = lines.reduce((sum, l) => sum + Math.max(...l.map((r) => r.fontSize ?? 12)) * 1.3, 0);
  const startY = g.y + g.height / 2 - totalHeight / 2;
  return renderLabelLines(lines, g.x + g.width / 2, startY, "middle", g.x + g.width / 2);
}

function isContainerStyle(style: Record<string, string>): boolean {
  return style.rounded === "1" || (style.whiteSpace === "wrap" && !style.image);
}

// ---------------------------------------------------------------------------
// Top-level SVG rendering
// ---------------------------------------------------------------------------

export function renderSVG(diagram: ParsedDiagram): string {
  const vertices = diagram.cells.filter((c) => c.vertex && c.geometry);
  const edges = diagram.cells.filter((c) => c.edge);

  // Containers render first (so they sit behind their children), then plain
  // image/text vertices, then edges on top, matching draw.io's z-order of
  // "earlier in the file = lower in the stack" for this document shape.
  const containers = vertices.filter((c) => isContainerStyle(c.style));
  const leaves = vertices.filter((c) => !isContainerStyle(c.style));

  const body: string[] = [];
  for (const c of containers) body.push(renderContainer(c));
  for (const c of edges) body.push(renderEdge(c, diagram.byId));
  for (const c of leaves) {
    if (c.style.image) body.push(renderImageCell(c));
    else if (c.style.text === "1" || c.style["text"] !== undefined) body.push(renderTextCell(c));
    else body.push(renderImageCell(c));
  }

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${diagram.pageWidth}" height="${diagram.pageHeight}" viewBox="0 0 ${diagram.pageWidth} ${diagram.pageHeight}">`,
    `<rect x="0" y="0" width="${diagram.pageWidth}" height="${diagram.pageHeight}" fill="#ffffff" />`,
    ...body,
    `</svg>`,
    "",
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Editable SVG (content attribute embedding) + round trip
// ---------------------------------------------------------------------------

export function makeEditableSVG(plainSvg: string, originalXml: string): string {
  const encoded = encodeXmlEntities(originalXml);
  return plainSvg.replace(
    /^<svg /,
    `<svg content="${encoded}" `,
  );
}

export function extractEmbeddedSource(editableSvg: string): string {
  const m = /<svg[^>]*\scontent="((?:[^"\\]|\\.)*)"/.exec(editableSvg);
  if (!m) throw new Error("no content attribute found on <svg> root");
  return decodeXmlEntities(m[1]);
}

// ---------------------------------------------------------------------------
// CLI / file entry point
// ---------------------------------------------------------------------------

export function renderFile(srcPath: string): { svgPath: string; drawioSvgPath: string; pngPath: string } {
  const fs = require("fs") as typeof import("fs");
  const path = require("path") as typeof import("path");
  const { execFileSync } = require("child_process") as typeof import("child_process");

  const originalXml = fs.readFileSync(srcPath, "utf8");
  const diagram = parseDrawio(originalXml);
  const plainSvg = renderSVG(diagram);
  const editableSvg = makeEditableSVG(plainSvg, originalXml);

  const dir = path.dirname(srcPath);
  const base = path.basename(srcPath, path.extname(srcPath));
  const svgPath = path.join(dir, `${base}.svg`);
  const drawioSvgPath = path.join(dir, `${base}.drawio.svg`);
  const pngPath = path.join(dir, `${base}.png`);

  fs.writeFileSync(svgPath, plainSvg);
  fs.writeFileSync(drawioSvgPath, editableSvg);

  const pngWidth = Math.round(diagram.pageWidth * 1.5);
  execFileSync("/usr/bin/rsvg-convert", ["-w", String(pngWidth), "-o", pngPath, svgPath]);

  return { svgPath, drawioSvgPath, pngPath };
}

async function main() {
  const target = process.argv[2];
  if (!target) {
    console.error("usage: bun scripts/diagrams/drawio-render.ts <file.drawio>");
    process.exit(1);
  }
  const { svgPath, drawioSvgPath, pngPath } = renderFile(target);
  console.log(`wrote ${svgPath}`);
  console.log(`wrote ${drawioSvgPath}`);
  console.log(`wrote ${pngPath}`);
}

if (import.meta.main) {
  main();
}
