import { useEffect, useId, useMemo, useRef, useState } from 'react'
import {
  Background,
  BackgroundVariant,
  Controls,
  ReactFlow,
  ReactFlowProvider,
  ViewportPortal,
  useReactFlow,
  type Node,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import type { AgentState } from '../../api/fleetApi'
import {
  NODE_W,
  NODE_H,
  layoutFleet,
  routeFleetEdges,
  type EdgeKind,
  type RoutedEdge,
} from './topologyLayout'

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

const CASCADE_STAGGER_MS = 200

/** Stroke per link class. Broken wins over both of the others. */
const EDGE_STROKE: Record<EdgeKind | 'broken', string> = {
  cascade: 'var(--cyan)',
  watch: 'var(--violet)',
  broken: 'var(--error)',
}

/**
 * React Flow's zoom controls, in this product's colours.
 *
 * They shipped in the vendor default, which is `#fefefe` buttons with a
 * `#eee` divider and a drop shadow (see the `-default` custom properties in
 * @xyflow/react/dist/style.css). Against this dashboard that renders as a
 * small white block floating in the bottom-right corner of the panel, which is
 * what it looked like: an artifact, not a control. The library's own dark
 * palette is gated behind a `.dark` ancestor class this app does not use, so
 * the fix is to supply the four button variables directly. They are set on the
 * container and inherit to the buttons, which is where the CSS reads them.
 */
const CONTROLS_STYLE = {
  '--xy-controls-button-background-color': 'var(--surface)',
  '--xy-controls-button-background-color-hover': 'var(--surface2)',
  '--xy-controls-button-color': 'var(--text)',
  '--xy-controls-button-color-hover': 'var(--cyan)',
  '--xy-controls-button-border-color': 'var(--border)',
  '--xy-controls-box-shadow': 'none',
  border: '1px solid var(--border)',
  borderRadius: 8,
  overflow: 'hidden',
} as React.CSSProperties

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

interface DrawnEdge extends RoutedEdge {
  broken: boolean
}

/** Marker ids have to be unique per mount, and `useId` output contains colons. */
function markerId(scope: string, name: string): string {
  return `fleet-arrow-${scope}-${name}`
}

/**
 * Edges are drawn here rather than by React Flow because React Flow attaches
 * to Handles, and these nodes deliberately have none: the graph is read-only,
 * nothing is connectable, and the interesting routing (bypass channels for
 * links that skip a layer) is not something the built-in edge types do.
 *
 * `zIndex: 0` is load-bearing. `.react-flow__renderer` sits at z-index 4
 * inside the viewport's stacking context, so the previous value of 5 painted
 * every line ON TOP of the cards -- the lines appeared to run straight through
 * the agents rather than between them.
 */
function FleetEdgeSvg({ edges, scope }: { edges: DrawnEdge[]; scope: string }) {
  return (
    <svg
      data-testid="fleet-edge-layer"
      style={{ position: 'absolute', overflow: 'visible', width: 1, height: 1, zIndex: 0, pointerEvents: 'none' }}
    >
      <defs>
        {(['cascade', 'watch', 'broken'] as const).map(kind => (
          <marker
            key={kind}
            id={markerId(scope, kind)}
            viewBox="0 0 8 8"
            refX={7}
            refY={4}
            markerWidth={5}
            markerHeight={5}
            orient="auto-start-reverse"
          >
            <path d="M0,0 L8,4 L0,8 z" fill={EDGE_STROKE[kind]} />
          </marker>
        ))}
      </defs>

      {edges.map(({ key, path, kind, broken, span }) => {
        const stroke = broken ? EDGE_STROKE.broken : EDGE_STROKE[kind]
        return (
          <path
            key={key}
            d={path}
            data-testid={`fleet-edge-${key}`}
            data-edge-kind={kind}
            data-edge-span={span}
            data-broken={broken || undefined}
            fill="none"
            stroke={stroke}
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
            // Dashed says "this link is not carrying a live cascade": either it
            // never will (watch) or it has already failed (broken).
            strokeDasharray={broken ? '7 5' : kind === 'watch' ? '2 6' : undefined}
            opacity={broken ? 0.9 : kind === 'watch' ? 0.55 : 0.8}
            markerEnd={`url(#${markerId(scope, broken ? 'broken' : kind)})`}
          />
        )
      })}
    </svg>
  )
}

// ── Legend ──────────────────────────────────────────────────────────────────

function LegendSwatch({ stroke, dash }: { stroke: string; dash?: string }) {
  return (
    <svg width={22} height={8} aria-hidden style={{ flexShrink: 0 }}>
      <path d="M1,4 L21,4" stroke={stroke} strokeWidth={2} strokeDasharray={dash} strokeLinecap="round" fill="none" />
    </svg>
  )
}

/**
 * Without this the lines are just lines. The distinction it names -- a
 * dependency into the SRE monitor does NOT propagate a stun, because
 * fleet-manager's CascadeTargets skips observability agents -- is invisible
 * otherwise, and it is the one thing an audience always asks about.
 */
function FleetLegend() {
  const rows: { stroke: string; dash?: string; text: string }[] = [
    { stroke: EDGE_STROKE.cascade, text: 'Cascade: stun the agent above and this one goes with it' },
    { stroke: EDGE_STROKE.watch, dash: '2 4', text: 'Watch only: a dependency the cascade stops at' },
    { stroke: EDGE_STROKE.broken, dash: '5 3', text: 'Broken: one end has lost its credentials' },
  ]

  return (
    <div
      data-testid="fleet-topology-legend"
      style={{
        position: 'absolute',
        left: 12,
        bottom: 12,
        zIndex: 6,
        maxWidth: 300,
        padding: '9px 11px',
        borderRadius: 8,
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        display: 'flex',
        flexDirection: 'column',
        gap: 5,
        pointerEvents: 'none',
      }}
    >
      <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--muted)' }}>
        Read downward: each line points at what breaks next
      </div>
      {rows.map(row => (
        <div key={row.text} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11, color: 'var(--text)' }}>
          <LegendSwatch stroke={row.stroke} dash={row.dash} />
          <span>{row.text}</span>
        </div>
      ))}
    </div>
  )
}

// ── Main canvas ─────────────────────────────────────────────────────────────

function Canvas({ agents, edges, cascadeInProgress, audience }: FleetTopologyProps) {
  const { fitView } = useReactFlow()
  // SVG marker ids are document-global, so two canvases on one page would
  // otherwise share arrowheads. useId's output contains colons, which are not
  // legal in a `url(#…)` reference.
  const scope = useId().replace(/[^a-zA-Z0-9-]/g, '')
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
  const layout = useMemo(() => layoutFleet(agents, edges), [agents, edges])
  const positions = layout.positions

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

  // Build edge geometry for the ViewportPortal SVG. Routing is pure and lives
  // in topologyLayout.ts; the only thing decided here is whether a link is
  // currently carrying a failure.
  const drawnEdges: DrawnEdge[] = useMemo(() => {
    const agentMap = new Map(agents.map(a => [a.id, a]))
    const stunned = (id: string) => cascadeState.has(id) || agentMap.get(id)?.state === 'stunned'
    return routeFleetEdges(agents, edges, layout).map(edge => ({
      ...edge,
      broken: stunned(edge.dependency) || stunned(edge.dependent),
    }))
  }, [agents, edges, cascadeState, layout])

  // Fit view on agent changes. Padding covers the bypass channels, which sit
  // outside the card block and are not part of React Flow's node bounds.
  useEffect(() => {
    const t = setTimeout(() => fitView({ padding: 0.22, duration: 200 }), 50)
    return () => clearTimeout(t)
  }, [agents.length, edges.length, fitView])

  return (
    <div data-testid="fleet-topology" style={{ width: '100%', height: '100%', minHeight: 400, position: 'relative' }}>
      <ReactFlow
        nodes={flowNodes}
        edges={[]}
        nodeTypes={nodeTypes}
        fitView
        fitViewOptions={{ padding: 0.22 }}
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
          <FleetEdgeSvg edges={drawnEdges} scope={scope} />
        </ViewportPortal>

        <Background variant={BackgroundVariant.Dots} gap={26} size={1} color="var(--border-subtle)" />
        {!audience && <Controls showInteractive={false} position="bottom-right" style={CONTROLS_STYLE} />}
      </ReactFlow>

      <FleetLegend />
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
