import { useCallback, useMemo, useState } from 'react'
import {
  Background,
  BackgroundVariant,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  ViewportPortal,
  type Node,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'

import type { EvidenceState, Selection, TrustEdge, TrustNode } from './trustTypes'
import { visual } from './trustVisuals'
import { NODE_H, NODE_W, deriveBoundaries, deriveExternalBand } from './trustBoundaries'
import { edgeGeometry, wallFraction } from './trustGeometry'
import TrustFlowNode from './TrustFlowNode'
import TrustBoundaryNode from './TrustBoundaryNode'
import TrustFlowEdge from './TrustFlowEdge'

const CANVAS_HEIGHT = 740

// Stable references. React Flow remounts every node when these change identity,
// which would restart the entrance animation on every render.
const nodeTypes = { trust: TrustFlowNode, boundary: TrustBoundaryNode }

export type TrustTopologyCanvasProps = {
  nodes: TrustNode[]
  edges: TrustEdge[]
  selected: Selection
  onSelectNode: (id: string) => void
  onSelectEdge: (id: string) => void
}

/**
 * Highlighting policy.
 *
 * Hovering traces a trust path: the thing under the cursor, everything one hop
 * from it, and any boundary it sits inside come forward; the rest recedes.
 *
 * Dimming is driven by HOVER ONLY, never by selection. The inspector on this
 * page is deliberately persistent -- it keeps showing what you last clicked --
 * and if selection also dimmed the canvas, the page would sit permanently in a
 * half-faded state with no way back to a plain overview.
 */
function computeHighlight(activeId: string | null, activeKind: 'node' | 'edge' | null, edges: TrustEdge[]) {
  if (!activeId || !activeKind) return { hotNodes: new Set<string>(), hotEdges: new Set<string>(), any: false }
  const hotNodes = new Set<string>()
  const hotEdges = new Set<string>()
  if (activeKind === 'node') {
    hotNodes.add(activeId)
    edges.forEach(edge => {
      if (edge.from !== activeId && edge.to !== activeId) return
      hotEdges.add(edge.id)
      hotNodes.add(edge.from)
      hotNodes.add(edge.to)
    })
  } else {
    const edge = edges.find(item => item.id === activeId)
    if (edge) {
      hotEdges.add(edge.id)
      hotNodes.add(edge.from)
      hotNodes.add(edge.to)
    }
  }
  return { hotNodes, hotEdges, any: true }
}

function Canvas({ nodes, edges, selected, onSelectNode, onSelectEdge }: TrustTopologyCanvasProps) {
  const [hover, setHover] = useState<Selection | null>(null)

  const boundaries = useMemo(() => deriveBoundaries(nodes), [nodes])
  const band = useMemo(() => deriveExternalBand(nodes, CANVAS_HEIGHT), [nodes])

  const highlight = useMemo(
    () => computeHighlight(hover?.id ?? null, hover?.type ?? null, edges),
    [edges, hover],
  )

  const hoverNode = useCallback((id: string | null) => setHover(id ? { type: 'node', id } : null), [])
  const hoverEdge = useCallback((id: string | null) => setHover(id ? { type: 'edge', id } : null), [])

  const flowNodes = useMemo<Node[]>(() => {
    const out: Node[] = []

    if (band) {
      const left = Math.min(...nodes.map(n => n.x - NODE_W / 2)) - 40
      const right = Math.max(...nodes.map(n => n.x + NODE_W / 2)) + 40
      out.push({
        id: 'band-external',
        type: 'boundary',
        position: { x: left, y: band.y },
        // Declared rather than measured. React Flow will not place an edge
        // until both endpoints have dimensions, and it only gets them from a
        // ResizeObserver callback -- which never fires without a layout engine.
        // Stating the size we already know makes the graph deterministic and
        // makes it render identically in a browser and in jsdom.
        width: right - left, height: band.height,
        draggable: false, selectable: false, focusable: false, zIndex: 0,
        data: {
          label: 'Outside the cluster',
          caption: `${band.count} modeled workloads · lower assurance · no runtime attestation ingested`,
          accent: 'var(--amber)',
          width: right - left,
          height: band.height,
          kind: 'external',
          hot: false,
          dim: false,
          enterDelay: 0,
        },
      })
    }

    boundaries.forEach((boundary, index) => {
      out.push({
        id: boundary.id,
        type: 'boundary',
        position: { x: boundary.x, y: boundary.y },
        width: boundary.width, height: boundary.height,
        draggable: false, selectable: false, focusable: false,
        zIndex: 1 + boundary.depth,
        data: {
          label: boundary.label,
          caption: boundary.caption,
          accent: boundary.accent,
          width: boundary.width,
          height: boundary.height,
          kind: boundary.kind,
          hot: boundary.memberIds.some(id => highlight.hotNodes.has(id)),
          dim: highlight.any && !boundary.memberIds.some(id => highlight.hotNodes.has(id)),
          enterDelay: index * 60,
        },
      })
    })

    nodes.forEach(node => {
      out.push({
        id: node.id,
        type: 'trust',
        // React Flow positions from the top-left; the contract data is centres.
        position: { x: node.x - NODE_W / 2, y: node.y - NODE_H / 2 },
        width: NODE_W, height: NODE_H,
        draggable: false,
        zIndex: 10,
        data: {
          node,
          selected: selected.type === 'node' && selected.id === node.id,
          hot: highlight.hotNodes.has(node.id),
          dim: highlight.any && !highlight.hotNodes.has(node.id),
        },
      })
    })

    return out
  }, [band, boundaries, highlight, nodes, selected])

  /**
   * Edges are drawn in a ViewportPortal rather than through React Flow's own
   * edge system.
   *
   * React Flow refuses to place an edge until it has measured the DOM bounds of
   * the handles on both endpoints, and those measurements only ever arrive via
   * a ResizeObserver callback. That is a hard dependency on a layout engine,
   * which meant every edge silently vanished under test -- the page rendered,
   * every assertion about nodes passed, and the relationships the page exists
   * to show were simply absent.
   *
   * None of that machinery earns its keep here. The layout is fixed by the
   * contract data, so the geometry is already known exactly (trustGeometry.ts)
   * and needs no measuring. Drawing into the portal keeps React Flow's viewport
   * transform -- pan and zoom still work on the edges -- while removing the
   * measurement dependency, so the diagram renders the same in a browser and in
   * jsdom, and a broken edge layer fails a test instead of shipping.
   */
  const drawnEdges = useMemo(() => {
    const byId = new Map(nodes.map(node => [node.id, node]))
    // Edges sharing an endpoint converge, so their midpoints collide. Counting
    // how many already touch each node -- at EITHER end, since two edges out of
    // one source overlap just as badly as two into one target -- lets each claim
    // a different slot along its own curve for its label.
    const touched = new Map<string, number>()
    return edges.flatMap(edge => {
      const from = byId.get(edge.from)
      const to = byId.get(edge.to)
      if (!from || !to) return []
      const slot = Math.max(touched.get(edge.from) ?? 0, touched.get(edge.to) ?? 0)
      touched.set(edge.from, slot + 1)
      touched.set(edge.to, slot + 1)
      // Same-row relationships arc upward so they clear the nodes between
      // them; everything else stays close to straight.
      const bow = Math.abs(from.y - to.y) < NODE_H ? -1 : 0.35
      const geom = edgeGeometry({ x: from.x, y: from.y }, { x: to.x, y: to.y }, bow)
      return [{
        edge,
        geom,
        wallAt: edge.denialKind === 'network-block' ? wallFraction(geom, boundaries, edge.from) : 0.5,
        labelAt: 0.5 + ((slot % 3) - 1) * 0.17,
        selected: selected.type === 'edge' && selected.id === edge.id,
        hot: highlight.hotEdges.has(edge.id),
        dim: highlight.any && !highlight.hotEdges.has(edge.id),
        onSelect: onSelectEdge,
        onHover: hoverEdge,
      }]
    })
  }, [boundaries, edges, highlight, hoverEdge, nodes, onSelectEdge, selected])

  return (
    <div className="trust-canvas" data-testid="trust-canvas">
      {/* Document-scoped arrow markers, one per evidence state so an arrowhead
          never contradicts the colour of the line it terminates. */}
      <svg width={0} height={0} style={{ position: 'absolute' }} aria-hidden="true" focusable="false">
        <defs>
          {(Object.keys(visual) as EvidenceState[]).map(key => (
            <marker
              key={key}
              id={`trust-arrow-${key}`}
              markerWidth="9"
              markerHeight="9"
              refX="7"
              refY="3.2"
              orient="auto"
            >
              <path d="M0,0 L0,6.4 L7,3.2 z" fill={visual[key].color} />
            </marker>
          ))}
        </defs>
      </svg>

      <ReactFlow
        nodes={flowNodes}
        edges={[]}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.08 }}
        minZoom={0.35}
        maxZoom={2.2}
        nodesConnectable={false}
        nodesDraggable={false}
        elementsSelectable
        proOptions={{ hideAttribution: true }}
        onNodeClick={(_, node) => { if (node.type === 'trust') onSelectNode(node.id) }}
        onNodeMouseEnter={(_, node) => { if (node.type === 'trust') hoverNode(node.id) }}
        onNodeMouseLeave={() => hoverNode(null)}
        onPaneClick={() => setHover(null)}
      >
        <ViewportPortal>
          {/* zIndex 0 keeps the relationships behind the nodes (which sit at 10),
              so a line never crosses over the box it terminates on. */}
          <svg
            className="trust-edge-layer"
            data-testid="trust-edge-layer"
            style={{ position: 'absolute', overflow: 'visible', width: 1, height: 1, zIndex: 0, pointerEvents: 'none' }}
          >
            {drawnEdges.map(item => (
              <g key={item.edge.id} style={{ pointerEvents: 'auto' }}>
                <TrustFlowEdge {...item} />
              </g>
            ))}
          </svg>
        </ViewportPortal>

        <Background variant={BackgroundVariant.Dots} gap={26} size={1} color="var(--border-subtle)" />
        {/* No minimap. fitView already frames all 15 nodes, so it navigated
            nothing and parked itself on top of the AWS Lambda node. */}
        <Controls showInteractive={false} position="bottom-right" />
      </ReactFlow>
    </div>
  )
}

/**
 * React Flow requires its provider for the hooks its internals use. Wrapping
 * here rather than at the page keeps that an implementation detail of the
 * canvas -- the page should not have to know the diagram library exists.
 */
export default function TrustTopologyCanvas(props: TrustTopologyCanvasProps) {
  return (
    <ReactFlowProvider>
      <Canvas {...props} />
    </ReactFlowProvider>
  )
}
