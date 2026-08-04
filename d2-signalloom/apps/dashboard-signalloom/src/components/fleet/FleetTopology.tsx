import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Background,
  BackgroundVariant,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  ViewportPortal,
  useReactFlow,
  type Node,
  type Edge as FlowEdge,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import type { AgentState } from '../../api/fleetApi'

// ── Types ───────────────────────────────────────────────────────────────────

export interface FleetTopologyProps {
  agents: AgentState[]
  edges: { from: string; to: string }[]
  /** Ordered list of agent IDs being cascade-stunned. */
  cascadeInProgress?: string[]
  onStun?: (agentId: string) => void
  onRecover?: () => void
  /** Audience mode: no controls, auto-layout, full-screen. */
  audience?: boolean
}

// ── Constants ───────────────────────────────────────────────────────────────

const NODE_W = 200
const NODE_H = 80
const H_GAP = 40
const V_GAP = 60
const CASCADE_STAGGER_MS = 200

const TYPE_ICONS: Record<string, string> = {
  'data-vault': '\uD83C\uDFE6',     // bank
  'data-pipeline': '\uD83D\uDD04',   // cycle arrows
  'llm-inference': '\uD83E\uDD16',   // robot
  'api-gateway': '\uD83C\uDF10',     // globe
  'observability': '\uD83D\uDC41\uFE0F', // eye
}

function stateColour(state: AgentState['state']): string {
  switch (state) {
    case 'active': return 'var(--cyan)'
    case 'non-compliant': return 'var(--amber)'
    case 'stunned': return 'var(--error)'
    case 'deploying': return 'var(--muted)'
    case 'grace-period': return 'var(--amber)'
    case 'absent':
    default: return 'var(--surface2)'
  }
}

function trustBadgeColour(profile: AgentState['trustProfile']): string {
  switch (profile) {
    case 'high': return 'var(--teal)'
    case 'medium': return 'var(--amber)'
    case 'low': return 'var(--error)'
  }
}

// ── Hierarchical layout (no dagre dependency) ───────────────────────────────

interface LayoutNode {
  id: string
  depth: number
  children: string[]
}

/**
 * Simple top-to-bottom layout. The root is the node with no incoming edges,
 * the leaves are nodes with no outgoing edges. When there are multiple nodes
 * at the same depth they are spread horizontally.
 */
function hierarchicalLayout(
  agents: AgentState[],
  edges: { from: string; to: string }[],
): Map<string, { x: number; y: number }> {
  const byId = new Map(agents.map(a => [a.id, a]))
  const incoming = new Set(edges.map(e => e.to))
  const outgoing = new Map<string, string[]>()

  for (const e of edges) {
    const list = outgoing.get(e.from) ?? []
    list.push(e.to)
    outgoing.set(e.from, list)
  }

  // BFS from roots (nodes with no incoming edges).
  const roots = agents.filter(a => !incoming.has(a.id)).map(a => a.id)
  if (roots.length === 0 && agents.length > 0) roots.push(agents[0].id)

  const depth = new Map<string, number>()
  const queue = roots.map(id => ({ id, d: 0 }))
  while (queue.length > 0) {
    const { id, d } = queue.shift()!
    if (depth.has(id)) continue
    depth.set(id, d)
    for (const child of outgoing.get(id) ?? []) {
      if (!depth.has(child)) queue.push({ id: child, d: d + 1 })
    }
  }

  // Any disconnected nodes get placed at depth 0.
  for (const a of agents) {
    if (!depth.has(a.id)) depth.set(a.id, 0)
  }

  // Group by depth, compute x positions.
  const byDepth = new Map<number, string[]>()
  for (const [id, d] of depth) {
    const list = byDepth.get(d) ?? []
    list.push(id)
    byDepth.set(d, list)
  }

  const positions = new Map<string, { x: number; y: number }>()
  for (const [d, ids] of byDepth) {
    const totalWidth = ids.length * NODE_W + (ids.length - 1) * H_GAP
    const startX = -totalWidth / 2
    ids.forEach((id, i) => {
      positions.set(id, {
        x: startX + i * (NODE_W + H_GAP),
        y: d * (NODE_H + V_GAP),
      })
    })
  }

  return positions
}

// ── Custom node ─────────────────────────────────────────────────────────────

interface FleetNodeData {
  agent: AgentState
  cascadeActive: boolean
  [key: string]: unknown
}

const nodeTypes = { fleet: FleetNode }

function FleetNode({ data }: { data: FleetNodeData }) {
  const { agent, cascadeActive } = data
  const bg = stateColour(agent.state)

  return (
    <div
      data-testid={`fleet-node-${agent.id}`}
      data-agent-state={agent.state}
      style={{
        width: NODE_W,
        height: NODE_H,
        borderRadius: 10,
        border: `2px solid ${bg}`,
        background: 'var(--surface)',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
        padding: '8px 12px',
        position: 'relative',
        overflow: 'hidden',
        transition: cascadeActive ? 'border-color 0.3s, box-shadow 0.3s' : 'none',
        boxShadow: agent.state === 'stunned' ? `0 0 12px ${bg}` : 'none',
      }}
    >
      {/* Header: icon + name */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
        <span style={{ fontSize: 16 }}>{TYPE_ICONS[agent.type] ?? ''}</span>
        <span style={{
          fontSize: 13,
          fontWeight: 600,
          color: 'var(--text)',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
          flex: 1,
        }}>
          {agent.name}
        </span>
      </div>

      {/* Footer: team + trust badge */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 6 }}>
        <span style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
          {agent.team}
        </span>
        <span
          data-testid={`fleet-trust-${agent.id}`}
          style={{
            fontSize: 9,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
            padding: '1px 5px',
            borderRadius: 4,
            color: trustBadgeColour(agent.trustProfile),
            border: `1px solid ${trustBadgeColour(agent.trustProfile)}`,
          }}
        >
          {agent.trustProfile}
        </span>
      </div>

      {/* State indicator dot (top-right) */}
      <div
        data-testid={`fleet-state-dot-${agent.id}`}
        style={{
          position: 'absolute',
          top: 8,
          right: 8,
          width: 8,
          height: 8,
          borderRadius: '50%',
          background: bg,
        }}
      />
    </div>
  )
}

// ── Edge rendering via ViewportPortal ───────────────────────────────────────

interface DrawnEdge {
  from: { x: number; y: number }
  to: { x: number; y: number }
  broken: boolean
  key: string
}

function FleetEdgeSvg({ edges }: { edges: DrawnEdge[] }) {
  return (
    <svg
      data-testid="fleet-edge-layer"
      style={{ position: 'absolute', overflow: 'visible', width: 1, height: 1, zIndex: 5, pointerEvents: 'none' }}
    >
      {edges.map(({ from, to, broken, key }) => {
        const x1 = from.x + NODE_W / 2
        const y1 = from.y + NODE_H
        const x2 = to.x + NODE_W / 2
        const y2 = to.y
        const midY = (y1 + y2) / 2
        const d = `M${x1},${y1} C${x1},${midY} ${x2},${midY} ${x2},${y2}`

        return (
          <path
            key={key}
            d={d}
            data-testid={`fleet-edge-${key}`}
            data-broken={broken || undefined}
            fill="none"
            stroke={broken ? 'var(--error)' : 'var(--cyan)'}
            strokeWidth={2}
            strokeDasharray={broken ? '6 4' : undefined}
            opacity={broken ? 0.7 : 0.5}
          />
        )
      })}
    </svg>
  )
}

// ── Main canvas ─────────────────────────────────────────────────────────────

function Canvas({ agents, edges, cascadeInProgress, audience }: FleetTopologyProps) {
  const { fitView } = useReactFlow()
  const [cascadeState, setCascadeState] = useState<Set<string>>(new Set())
  const cascadeTimers = useRef<ReturnType<typeof setTimeout>[]>([])

  // Run the cascade animation when cascadeInProgress changes.
  useEffect(() => {
    // Clean up previous timers.
    cascadeTimers.current.forEach(t => clearTimeout(t))
    cascadeTimers.current = []

    if (!cascadeInProgress || cascadeInProgress.length === 0) {
      setCascadeState(new Set())
      return
    }

    // Respect prefers-reduced-motion.
    let reducedMotion = false
    try {
      reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    } catch { /* jsdom */ }

    if (reducedMotion) {
      setCascadeState(new Set(cascadeInProgress))
      return
    }

    // Animate each node in sequence with a stagger.
    const building = new Set<string>()
    cascadeInProgress.forEach((id, i) => {
      const timer = setTimeout(() => {
        building.add(id)
        setCascadeState(new Set(building))
      }, i * CASCADE_STAGGER_MS)
      cascadeTimers.current.push(timer)
    })

    return () => {
      cascadeTimers.current.forEach(t => clearTimeout(t))
    }
  }, [cascadeInProgress])

  // Compute layout positions.
  const positions = useMemo(() => hierarchicalLayout(agents, edges), [agents, edges])

  // Build React Flow nodes.
  const flowNodes: Node<FleetNodeData>[] = useMemo(() => {
    return agents.map(agent => {
      const pos = positions.get(agent.id) ?? { x: 0, y: 0 }
      // During cascade, override the agent state to stunned for visualisation.
      const effectiveAgent = cascadeState.has(agent.id)
        ? { ...agent, state: 'stunned' as const }
        : agent
      return {
        id: agent.id,
        type: 'fleet',
        position: pos,
        data: { agent: effectiveAgent, cascadeActive: cascadeState.size > 0 },
        draggable: false,
      }
    })
  }, [agents, cascadeState, positions])

  // Build edge geometry for the ViewportPortal SVG.
  const drawnEdges: DrawnEdge[] = useMemo(() => {
    const agentMap = new Map(agents.map(a => [a.id, a]))
    return edges.map(e => {
      const fromPos = positions.get(e.from)
      const toPos = positions.get(e.to)
      if (!fromPos || !toPos) return null

      const fromAgent = agentMap.get(e.from)
      const toAgent = agentMap.get(e.to)
      const fromStunned = cascadeState.has(e.from) || fromAgent?.state === 'stunned'
      const toStunned = cascadeState.has(e.to) || toAgent?.state === 'stunned'
      const broken = fromStunned || toStunned

      return { from: fromPos, to: toPos, broken, key: `${e.from}-${e.to}` }
    }).filter((e): e is DrawnEdge => e !== null)
  }, [agents, edges, cascadeState, positions])

  // Fit view on agent changes.
  useEffect(() => {
    const t = setTimeout(() => fitView({ padding: 0.15, duration: 200 }), 50)
    return () => clearTimeout(t)
  }, [agents.length, fitView])

  return (
    <div data-testid="fleet-topology" style={{ width: '100%', height: '100%', minHeight: 400 }}>
      <ReactFlow
        nodes={flowNodes}
        edges={[]}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.15 }}
        minZoom={0.3}
        maxZoom={2}
        nodesConnectable={false}
        nodesDraggable={false}
        nodesFocusable={false}
        edgesFocusable={false}
        disableKeyboardA11y
        elementsSelectable={false}
        proOptions={{ hideAttribution: true }}
      >
        <ViewportPortal>
          <FleetEdgeSvg edges={drawnEdges} />
        </ViewportPortal>

        <Background variant={BackgroundVariant.Dots} gap={26} size={1} color="var(--border-subtle)" />
        {!audience && <Controls showInteractive={false} position="bottom-right" />}
      </ReactFlow>
    </div>
  )
}

// ── Exported wrapper ────────────────────────────────────────────────────────

export default function FleetTopology(props: FleetTopologyProps) {
  return (
    <ReactFlowProvider>
      <Canvas {...props} />
    </ReactFlowProvider>
  )
}
