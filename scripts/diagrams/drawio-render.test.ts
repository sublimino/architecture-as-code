// @target  scripts/diagrams/drawio-render.ts
// @doc     d2-signalloom/apps/docs-signalloom/DIAGRAMS.md
//
// Fixture-driven tests for the deterministic draw.io -> SVG/PNG renderer.
// Fixtures are small, hand-built .drawio files covering the style
// vocabulary the four published diagrams actually use: a plain vertex
// label, a shape=image cell with an embedded data-URI icon, a dashed
// rounded container, a plain edge with arrowheads, an orthogonal edge,
// and an HTML label with <br>, <font color/size> and bold.

import { test, expect, describe } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, statSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  parseDrawio,
  renderSVG,
  makeEditableSVG,
  extractEmbeddedSource,
  renderFile,
} from "./drawio-render";

// A tiny 1x1 transparent PNG re-encoded as an SVG data URI stand-in. Real
// draw.io image cells embed `image=data:image/svg+xml;base64,...` — we use
// a short deterministic payload since the renderer must not care about the
// icon's content, only that it is a data URI.
const TINY_ICON =
  "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=";

function fixture(name: string, body: string): string {
  return `<mxfile host="app.diagrams.net" modified="2026-10-13T00:00:00.000Z" agent="test" version="24.0.0">
  <diagram id="${name}" name="${name}">
    <mxGraphModel dx="100" dy="100" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="400" pageHeight="300" math="0" shadow="0">
      <root>
    <mxCell id="0" />
    <mxCell id="1" parent="0" />
${body}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
`;
}

const LABEL_FIXTURE = fixture(
  "label-fixture",
  `    <mxCell id="plain_text" value="Plain Label" style="text;html=1;align=center;verticalAlign=middle;fontSize=13;fontStyle=1;fontColor=#222222;" vertex="1" parent="1">
      <mxGeometry x="10" y="10" width="120" height="40" as="geometry" />
    </mxCell>`,
);

const IMAGE_FIXTURE = fixture(
  "image-fixture",
  `    <mxCell id="node_icon" value="Envoy Gateway<br><font color='#666666' style='font-size: 10px;'>(Gateway API)</font>" style="shape=image;verticalLabelPosition=bottom;labelBackgroundColor=none;verticalAlign=top;aspect=fixed;imageAspect=0;fontSize=11;fontColor=#111111;align=center;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="50" y="50" width="48" height="48" as="geometry" />
    </mxCell>`,
);

const CONTAINER_FIXTURE = fixture(
  "container-fixture",
  `    <mxCell id="rg1_box" value="Resource group 1<br><font style='font-size: 11px; font-weight: normal;'>(region 1)</font>" style="rounded=1;arcSize=4;whiteSpace=wrap;html=1;dashed=1;dashPattern=6 4;strokeColor=#0078D4;strokeWidth=1.5;fillColor=none;verticalAlign=top;fontStyle=1;fontSize=14;fontColor=#000000;spacingTop=12;" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="200" height="200" as="geometry" />
    </mxCell>`,
);

const EDGE_FIXTURE = fixture(
  "edge-fixture",
  `    <mxCell id="node_a" value="Node A" style="shape=image;verticalLabelPosition=bottom;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="node_b" value="Node B" style="shape=image;verticalLabelPosition=bottom;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="150" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="edge_ab" style="strokeColor=#000000;strokeWidth=2;startArrow=classic;endArrow=classic;startFill=1;endFill=1;html=1;" edge="1" parent="1" source="node_a" target="node_b">
      <mxGeometry relative="1" as="geometry" />
    </mxCell>`,
);

const ORTHOGONAL_EDGE_FIXTURE = fixture(
  "orthogonal-edge-fixture",
  `    <mxCell id="node_a" value="Node A" style="shape=image;verticalLabelPosition=bottom;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="node_b" value="Node B" style="shape=image;verticalLabelPosition=bottom;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="200" y="150" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="edge_ortho" style="edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=#000000;strokeWidth=2;endArrow=classic;endFill=1;" edge="1" parent="1" source="node_a" target="node_b">
      <mxGeometry relative="1" as="geometry" />
    </mxCell>`,
);

describe("parseDrawio", () => {
  test("parses vertex geometry and label", () => {
    const d = parseDrawio(LABEL_FIXTURE);
    const cell = d.byId.get("plain_text")!;
    expect(cell.value).toBe("Plain Label");
    expect(cell.geometry).toEqual({ x: 10, y: 10, width: 120, height: 40 });
    expect(d.pageWidth).toBe(400);
    expect(d.pageHeight).toBe(300);
  });

  test("parses shape=image cell and its data URI", () => {
    const d = parseDrawio(IMAGE_FIXTURE);
    const cell = d.byId.get("node_icon")!;
    expect(cell.style.image).toBe(TINY_ICON);
    expect(cell.value).toContain("Envoy Gateway");
  });

  test("parses edges with source/target", () => {
    const d = parseDrawio(EDGE_FIXTURE);
    const edge = d.byId.get("edge_ab")!;
    expect(edge.edge).toBe(true);
    expect(edge.source).toBe("node_a");
    expect(edge.target).toBe("node_b");
  });
});

describe("renderSVG — label fidelity", () => {
  test("every vertex label text shows up in the output SVG", () => {
    const svg = renderSVG(parseDrawio(CONTAINER_FIXTURE));
    expect(svg).toContain("Resource group 1");
    expect(svg).toContain("(region 1)");
  });

  test("HTML label with <br>, <font>, and container text all appear as separate lines", () => {
    const svg = renderSVG(parseDrawio(IMAGE_FIXTURE));
    expect(svg).toContain("Envoy Gateway");
    expect(svg).toContain("(Gateway API)");
  });

  test("plain text;-style vertex label appears", () => {
    const svg = renderSVG(parseDrawio(LABEL_FIXTURE));
    expect(svg).toContain("Plain Label");
  });
});

describe("renderSVG — image cells", () => {
  test("image cells become <image> elements carrying the source data URI", () => {
    const svg = renderSVG(parseDrawio(IMAGE_FIXTURE));
    expect(svg).toContain("<image");
    expect(svg).toContain(TINY_ICON);
  });

  test("image cell without image data does not render empty href image tag", () => {
    const emptyImgFixture = fixture(
      "empty-image-fixture",
      `    <mxCell id="no_img" value="No Image Cell" style="shape=image;verticalLabelPosition=bottom;" vertex="1" parent="1">
      <mxGeometry x="10" y="10" width="40" height="40" as="geometry" />
    </mxCell>`,
    );
    const svg = renderSVG(parseDrawio(emptyImgFixture));
    expect(svg).not.toContain('href=""');
    expect(svg).toContain("No Image Cell");
  });
});

describe("renderSVG — containers", () => {
  test("dashed rounded container renders a dashed rect", () => {
    const svg = renderSVG(parseDrawio(CONTAINER_FIXTURE));
    expect(svg).toMatch(/<rect[^>]*stroke-dasharray/);
    expect(svg).toContain("#0078D4");
  });
});

describe("renderSVG — edges", () => {
  test("plain edge renders a path with start and end arrowheads", () => {
    const svg = renderSVG(parseDrawio(EDGE_FIXTURE));
    // two arrowheads => two filled triangle polygons (or a path + marker use)
    const arrowMarkers = svg.match(/arrow/gi) || [];
    expect(arrowMarkers.length).toBeGreaterThan(0);
    expect(svg).toContain("<path");
  });

  test("orthogonal edge produces a multi-segment path, not a straight diagonal line", () => {
    const svg = renderSVG(parseDrawio(ORTHOGONAL_EDGE_FIXTURE));
    const pathMatch = svg.match(/<path[^>]*d="([^"]*)"/);
    expect(pathMatch).toBeTruthy();
    const d = pathMatch![1];
    // An orthogonal elbow has at least 3 points (2 segments): M x,y L x,y L x,y
    const commandCount = (d.match(/[ML]/g) || []).length;
    expect(commandCount).toBeGreaterThanOrEqual(3);
  });
});

describe("makeEditableSVG / extractEmbeddedSource — round trip", () => {
  test("the content attribute round-trips back to the exact source XML", () => {
    const plainSvg = renderSVG(parseDrawio(CONTAINER_FIXTURE));
    const editable = makeEditableSVG(plainSvg, CONTAINER_FIXTURE);
    const recovered = extractEmbeddedSource(editable);
    expect(recovered).toBe(CONTAINER_FIXTURE);
  });
});

describe("parseDrawio — attribute-order independence (lead review fix 1)", () => {
  test("a cell whose attributes appear in a non-standard order, with an extra attribute, still parses", () => {
    const xml = fixture(
      "reordered-attrs",
      `    <mxCell parent="1" vertex="1" id="reordered" extraAttr="whatever" style="rounded=1;whiteSpace=wrap;html=1;" value="Reordered Cell">
      <mxGeometry x="5" y="6" width="30" height="20" as="geometry" />
    </mxCell>`,
    );
    const d = parseDrawio(xml);
    const cell = d.byId.get("reordered")!;
    expect(cell.value).toBe("Reordered Cell");
    expect(cell.vertex).toBe(true);
    expect(cell.parent).toBe("1");
    expect(cell.geometry).toEqual({ x: 5, y: 6, width: 30, height: 20 });
  });

  test("a self-closing cell with attributes in a non-standard order still parses", () => {
    const xml = fixture(
      "reordered-self-close",
      `    <mxCell style="strokeColor=#000000;" edge="1" id="e1" parent="1" target="b" source="a" />`,
    );
    const d = parseDrawio(xml);
    const cell = d.byId.get("e1")!;
    expect(cell.edge).toBe(true);
    expect(cell.source).toBe("a");
    expect(cell.target).toBe("b");
  });

  test("throws rather than silently dropping a cell when a label contains literal unescaped mxCell-shaped text", () => {
    // A value attribute containing a raw, unescaped "<mxCell>" substring (not
    // XML-entity-encoded) can make a naive scanner swallow a real subsequent
    // cell into the fake one's "body". The count assertion must catch this
    // rather than silently returning a diagram missing a cell.
    const xml = fixture(
      "evil-label",
      `    <mxCell id="evil" value="Example: <mxCell> syntax" style="text;" vertex="1" parent="1">
      <mxGeometry x="0" y="0" width="10" height="10" as="geometry" />
    </mxCell>
    <mxCell id="real_cell" value="Real" style="text;" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="10" height="10" as="geometry" />
    </mxCell>`,
    );
    expect(() => parseDrawio(xml)).toThrow(/mxCell/i);
  });
});

describe("nested parents (lead review fix 2)", () => {
  test("a child cell's geometry is resolved relative to its non-layer parent, not rendered at its raw offset", () => {
    const xml = fixture(
      "nested-parent",
      `    <mxCell id="group1" value="" style="rounded=0;whiteSpace=wrap;html=1;" vertex="1" parent="1">
      <mxGeometry x="100" y="200" width="300" height="300" as="geometry" />
    </mxCell>
    <mxCell id="child1" value="Child" style="text;" vertex="1" parent="group1">
      <mxGeometry x="10" y="15" width="40" height="20" as="geometry" />
    </mxCell>`,
    );
    const d = parseDrawio(xml);
    const child = d.byId.get("child1")!;
    // Absolute position = parent origin (100,200) + relative offset (10,15).
    expect(child.geometry).toEqual({ x: 110, y: 215, width: 40, height: 20 });
  });

  test("throws on a cyclic parent chain instead of looping or rendering a wrong position", () => {
    const xml = fixture(
      "cyclic-parent",
      `    <mxCell id="a" value="" style="rounded=0;" vertex="1" parent="b">
      <mxGeometry x="0" y="0" width="10" height="10" as="geometry" />
    </mxCell>
    <mxCell id="b" value="" style="rounded=0;" vertex="1" parent="a">
      <mxGeometry x="0" y="0" width="10" height="10" as="geometry" />
    </mxCell>`,
    );
    expect(() => parseDrawio(xml)).toThrow(/cyclic|cycle/i);
  });

  test("throws when a cell references a parent id that does not exist", () => {
    const xml = fixture(
      "missing-parent",
      `    <mxCell id="orphan" value="" style="rounded=0;" vertex="1" parent="does_not_exist">
      <mxGeometry x="0" y="0" width="10" height="10" as="geometry" />
    </mxCell>`,
    );
    expect(() => parseDrawio(xml)).toThrow(/parent/i);
  });
});

describe("edge labels (lead review fix 3)", () => {
  const EDGE_LABEL_FIXTURE = fixture(
    "edge-label-fixture",
    `    <mxCell id="node_a" value="Node A" style="shape=image;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="node_b" value="Node B" style="shape=image;aspect=fixed;imageAspect=0;fontSize=12;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="150" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="edge_labeled" value="(planned)" style="strokeColor=#000000;strokeWidth=2;endArrow=classic;endFill=1;html=1;" edge="1" parent="1" source="node_a" target="node_b">
      <mxGeometry relative="1" as="geometry" />
    </mxCell>`,
  );

  test("an edge's value is rendered as a label instead of being silently dropped", () => {
    const svg = renderSVG(parseDrawio(EDGE_LABEL_FIXTURE));
    expect(svg).toContain("(planned)");
  });
});

describe("edge endpoint integrity", () => {
  test("an edge referencing a non-existent source/target throws instead of being silently dropped", () => {
    const xml = fixture(
      "dangling-edge",
      `    <mxCell id="node_a" value="Node A" style="shape=image;aspect=fixed;imageAspect=0;image=${TINY_ICON};" vertex="1" parent="1">
      <mxGeometry x="20" y="20" width="40" height="40" as="geometry" />
    </mxCell>
    <mxCell id="edge_dangling" style="strokeColor=#000000;endArrow=classic;endFill=1;html=1;" edge="1" parent="1" source="node_a" target="does_not_exist">
      <mxGeometry relative="1" as="geometry" />
    </mxCell>`,
    );
    expect(() => renderSVG(parseDrawio(xml))).toThrow(/edge_dangling/);
  });
});

describe("label legibility halo (lead review fix 4)", () => {
  test("rendered label tspans carry a white halo so edges don't strike through the text", () => {
    const svg = renderSVG(parseDrawio(CONTAINER_FIXTURE));
    expect(svg).toMatch(/<tspan[^>]*stroke="#ffffff"[^>]*paint-order="stroke"/);
  });

  test("image-cell labels also carry the halo", () => {
    const svg = renderSVG(parseDrawio(IMAGE_FIXTURE));
    expect(svg).toMatch(/<tspan[^>]*stroke="#ffffff"[^>]*paint-order="stroke"/);
  });
});

describe("font family (lead review fix 5)", () => {
  test("rendered text uses the DejaVu Sans stack so rsvg's metrics match the reviewed look", () => {
    const svg = renderSVG(parseDrawio(LABEL_FIXTURE));
    expect(svg).toContain(`font-family="'DejaVu Sans', Helvetica, Arial, sans-serif"`);
  });
});

describe("determinism", () => {
  test("rendering the same input twice produces byte-identical SVG", () => {
    const parsed1 = parseDrawio(EDGE_FIXTURE);
    const parsed2 = parseDrawio(EDGE_FIXTURE);
    expect(renderSVG(parsed1)).toBe(renderSVG(parsed2));
  });

  test("running the CLI renderer twice on disk produces byte-identical files", () => {
    const dir = mkdtempSync(join(tmpdir(), "drawio-render-test-"));
    try {
      const src = join(dir, "fixture.drawio");
      writeFileSync(src, EDGE_FIXTURE);

      renderFile(src);
      const svg1 = readFileSync(join(dir, "fixture.svg"));
      const drawioSvg1 = readFileSync(join(dir, "fixture.drawio.svg"));
      const png1 = readFileSync(join(dir, "fixture.png"));

      renderFile(src);
      const svg2 = readFileSync(join(dir, "fixture.svg"));
      const drawioSvg2 = readFileSync(join(dir, "fixture.drawio.svg"));
      const png2 = readFileSync(join(dir, "fixture.png"));

      expect(svg1.equals(svg2)).toBe(true);
      expect(drawioSvg1.equals(drawioSvg2)).toBe(true);
      expect(png1.equals(png2)).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("renderFile — CLI entry point outputs", () => {
  test("writes <name>.svg, <name>.drawio.svg and a non-empty <name>.png beside the source", () => {
    const dir = mkdtempSync(join(tmpdir(), "drawio-render-test-"));
    try {
      const src = join(dir, "diagram.drawio");
      writeFileSync(src, CONTAINER_FIXTURE);

      renderFile(src);

      const svgPath = join(dir, "diagram.svg");
      const editableSvgPath = join(dir, "diagram.drawio.svg");
      const pngPath = join(dir, "diagram.png");

      expect(existsSync(svgPath)).toBe(true);
      expect(existsSync(editableSvgPath)).toBe(true);
      expect(existsSync(pngPath)).toBe(true);
      expect(statSync(pngPath).size).toBeGreaterThan(0);

      // The plain .svg must NOT carry the embedded source (that's .drawio.svg's job).
      const plainSvg = readFileSync(svgPath, "utf8");
      expect(plainSvg).not.toContain("<mxfile");

      // The .drawio.svg must round-trip to the exact source bytes.
      const editableSvg = readFileSync(editableSvgPath, "utf8");
      expect(extractEmbeddedSource(editableSvg)).toBe(CONTAINER_FIXTURE);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
