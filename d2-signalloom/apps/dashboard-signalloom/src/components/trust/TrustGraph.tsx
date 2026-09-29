import React, { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  ReactFlowProvider,
  ViewportPortal,
  useReactFlow,
  type Node,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'

import type { EvidenceState, Selection, TrustEdge, TrustNode } from './trustTypes'
import { visual } from './trustVisuals'
import { NODE_H, NODE_W, deriveBoundaries, deriveExternalBand } from './trustBoundaries'
import { bowFor, edgeGeometry, placeLabels, reservedForLabels, wallFraction } from './trustGeometry'
import TrustFlowNode from './TrustFlowNode'
import TrustBoundaryNode from './TrustBoundaryNode'
import TrustFlowEdge from './TrustFlowEdge'

const nodeTypes = { trust: TrustFlowNode, boundary: TrustBoundaryNode }

export const RANK_Y: Record<string, number> = {
  platform: 60,
  service: 160,
  tenant: 280,
  project: 400,
  agent: 530,
  external: 680,
  probe: 530,
  gap: 720,
}

export const RANK_ORDER: Record<string, number> = {
  platform: 0,
  service: 1,
  tenant: 2,
  project: 3,
  agent: 4,
  external: 5,
  probe: 4,
  gap: 6,
}

/**
 * Deterministic rank-based hierarchical layout engine.
 * Computes non-overlapping positions based on hierarchy tiers (platform -> services -> tenants -> projects -> agents -> external).
 */
export function layoutNodes(nodes: TrustNode[], _edges: TrustEdge[] = []): TrustNode[] {
  // If all nodes have explicit non-colliding coordinates (e.g. curated demo fixture), preserve them
  const coordSet = new Set<string>()
  let hasCollisionOrMissing = false
  for (const n of nodes) {
    if (n.x === undefined || n.y === undefined) {
      hasCollisionOrMissing = true
      break
    }
    const key = `${n.x},${n.y}`
    if (coordSet.has(key)) {
      hasCollisionOrMissing = true
      break
    }
    coordSet.add(key)
  }

  if (!hasCollisionOrMissing && nodes.length > 0) {
    return nodes
  }

  // Group nodes by hierarchy rank
  const groups = new Map<string, TrustNode[]>()
  for (const node of nodes) {
    const kind = node.kind || 'agent'
    if (!groups.has(kind)) groups.set(kind, [])
    groups.get(kind)!.push(node)
  }

  const result: TrustNode[] = []
  const centerX = 550
  const spacingX = 260
  const maxCols = 4
  const rowSpacingY = 130

  // Layout each rank group deterministically
  for (const [kind, groupNodes] of groups.entries()) {
    // Sort deterministically by parentId, then by id
    const sorted = [...groupNodes].sort((a, b) => {
      const pCompare = (a.parentId ?? '').localeCompare(b.parentId ?? '')
      if (pCompare !== 0) return pCompare
      return a.id.localeCompare(b.id)
    })

    const total = sorted.length
    const targetY = RANK_Y[kind] ?? 530

    sorted.forEach((node, index) => {
      const col = index % maxCols
      const row = Math.floor(index / maxCols)
      const rowTotal = Math.min(maxCols, total - row * maxCols)
      const rowStartX = centerX - ((rowTotal - 1) * spacingX) / 2
      const computedX = Math.round(rowStartX + col * spacingX)
      const computedY = targetY + row * rowSpacingY

      result.push({
        ...node,
        x: computedX,
        y: computedY,
      })
    })
  }

  return result
}

export interface TrustGraphProps {
  nodes: TrustNode[]
  edges: TrustEdge[]
  selected: Selection
  onSelectNode: (id: string) => void
  onSelectEdge: (id: string) => void
  onOpenDrawer?: (nodeId: string) => void
  hiddenCount?: number
  onResetFilters?: () => void
  showMinimap?: boolean
}

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
  return { hotNodes, hotEdges, any: hotNodes.size > 0 || hotEdges.size > 0 }
}

function GraphInternal({
  nodes,
  edges,
  selected,
  onSelectNode,
  onSelectEdge,
  onOpenDrawer,
  hiddenCount = 0,
  onResetFilters,
  showMinimap = false,
}: TrustGraphProps) {
  const [hover, setHover] = useState<Selection | null>(null)
  const { fitView } = useReactFlow()

  // Layout memoisation: deterministic non-overlapping coordinates
  const positionedNodes = useMemo(() => layoutNodes(nodes, edges), [nodes, edges])

  const visibleSignature = useMemo(() => positionedNodes.map(node => node.id).join('|'), [positionedNodes])
  useEffect(() => {
    fitView({ padding: 0.08, duration: 420 })
    setHover(null)
  }, [fitView, visibleSignature])

  const boundaries = useMemo(() => deriveBoundaries(positionedNodes), [positionedNodes])
  const band = useMemo(() => deriveExternalBand(positionedNodes), [positionedNodes])

  const highlight = useMemo(
    () => computeHighlight(hover?.id ?? null, hover?.type ?? null, edges),
    [edges, hover],
  )

  const hoverNode = useCallback((id: string | null) => setHover(id ? { type: 'node', id } : null), [])
  const hoverEdge = useCallback((id: string | null) => setHover(id ? { type: 'edge', id } : null), [])

  const flowNodes = useMemo<Node[]>(() => {
    const out: Node[] = []

    if (band) {
      const left = Math.min(...positionedNodes.map(n => n.x - NODE_W / 2)) - 40
      const right = Math.max(...positionedNodes.map(n => n.x + NODE_W / 2)) + 40
      out.push({
        id: 'band-external',
        type: 'boundary',
        position: { x: left, y: band.y },
        width: right - left,
        height: band.height,
        draggable: false,
        selectable: false,
        focusable: false,
        zIndex: 0,
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
        width: boundary.width,
        height: boundary.height,
        draggable: false,
        selectable: false,
        focusable: false,
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

    positionedNodes.forEach(node => {
      out.push({
        id: node.id,
        type: 'trust',
        position: { x: node.x - NODE_W / 2, y: node.y - NODE_H / 2 },
        width: NODE_W,
        height: NODE_H,
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
  }, [band, boundaries, highlight, positionedNodes, selected])

  const drawnEdges = useMemo(() => {
    const byId = new Map(positionedNodes.map(node => [node.id, node]))
    const geoms = edges.flatMap(edge => {
      const from = byId.get(edge.from)
      const to = byId.get(edge.to)
      if (!from || !to) return []
      return [{ edge, geom: edgeGeometry({ x: from.x, y: from.y }, { x: to.x, y: to.y }, bowFor(from, to)) }]
    })

    const reserved = reservedForLabels(positionedNodes, boundaries)
    const placements = new Map(
      placeLabels(geoms.map(g => ({ id: g.edge.id, geom: g.geom, text: g.edge.verb })), reserved).map(p => [
        p.id,
        p,
      ]),
    )

    return geoms.map(({ edge, geom }) => {
      const placement = placements.get(edge.id)
      return {
        edge,
        geom,
        wallAt: edge.denialKind === 'network-block' ? wallFraction(geom, boundaries, edge.from) : 0.5,
        labelAt: placement?.at ?? 0.5,
        labelOffset: placement?.offset ?? 0,
        selected: selected.type === 'edge' && selected.id === edge.id,
        hot: highlight.hotEdges.has(edge.id),
        dim: highlight.any && !highlight.hotEdges.has(edge.id),
        onSelect: onSelectEdge,
        onHover: hoverEdge,
      }
    })
  }, [boundaries, edges, highlight, hoverEdge, onSelectEdge, positionedNodes, selected])

  const handleNodeClick = useCallback(
    (_: React.MouseEvent, node: Node) => {
      if (node.type === 'trust') {
        onSelectNode(node.id)
        onOpenDrawer?.(node.id)
      }
    },
    [onOpenDrawer, onSelectNode],
  )

  return (
    <div
      className="trust-graph-container"
      data-testid="trust-graph-container"
      style={{ position: 'relative', width: '100%', height: '100%', minHeight: 520 }}
    >
      {/* Hidden Nodes counter badge */}
      {hiddenCount > 0 && (
        <div
          data-testid="hidden-nodes-badge"
          className="hidden-nodes-badge"
          style={{
            position: 'absolute',
            top: 12,
            right: 14,
            zIndex: 30,
            background: 'color-mix(in srgb, var(--amber) 18%, var(--surface))',
            border: '1px solid var(--amber)',
            borderRadius: 6,
            padding: '6px 12px',
            fontSize: 12,
            color: 'var(--text)',
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            boxShadow: '0 2px 8px rgba(0, 0, 0, 0.3)',
          }}
        >
          <span style={{ fontWeight: 700, color: 'var(--amber)' }}>
            {hiddenCount} Hidden {hiddenCount === 1 ? 'Node' : 'Nodes'}
          </span>
          <span style={{ fontSize: 11, color: 'var(--muted)' }}>(filtered)</span>
          {onResetFilters && (
            <button
              type="button"
              className="btn btn-secondary"
              data-testid="reset-filters-btn"
              onClick={onResetFilters}
              style={{ fontSize: 10, padding: '2px 6px', height: 'auto' }}
            >
              Reset
            </button>
          )}
        </div>
      )}

      <div className="trust-canvas" data-testid="trust-canvas" aria-hidden="true" style={{ width: '100%', height: '100%' }}>
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
          nodesFocusable={false}
          edgesFocusable={false}
          disableKeyboardA11y
          elementsSelectable
          proOptions={{ hideAttribution: true }}
          onNodeClick={handleNodeClick}
          onNodeMouseEnter={(_, node) => {
            if (node.type === 'trust') hoverNode(node.id)
          }}
          onNodeMouseLeave={() => hoverNode(null)}
          onPaneClick={() => setHover(null)}
        >
          <ViewportPortal>
            <svg
              className="trust-edge-layer"
              data-testid="trust-edge-layer"
              style={{ position: 'absolute', overflow: 'visible', width: 1, height: 1, zIndex: 5, pointerEvents: 'none' }}
            >
              {drawnEdges.map(item => (
                <g key={item.edge.id} style={{ pointerEvents: 'auto' }}>
                  <TrustFlowEdge {...item} />
                </g>
              ))}
            </svg>
          </ViewportPortal>

          <Background variant={BackgroundVariant.Dots} gap={26} size={1} color="var(--border-subtle)" />
          {showMinimap && (
            <MiniMap
              nodeStrokeColor="var(--border)"
              nodeColor="var(--surface2)"
              maskColor="rgba(0, 0, 0, 0.6)"
              style={{ background: 'var(--surface)', borderRadius: 8, border: '1px solid var(--border)' }}
            />
          )}
          <Controls showInteractive={false} position="bottom-right" />
        </ReactFlow>
      </div>
    </div>
  )
}

export function TrustGraph(props: TrustGraphProps) {
  return (
    <ReactFlowProvider>
      <GraphInternal {...props} />
    </ReactFlowProvider>
  )
}

export default TrustGraph
