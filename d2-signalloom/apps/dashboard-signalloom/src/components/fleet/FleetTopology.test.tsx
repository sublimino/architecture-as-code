import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import FleetTopology from './FleetTopology'
import type { AgentState } from '../../api/fleetApi'

// ── Fixtures ────────────────────────────────────────────────────────────────

function makeAgent(overrides: Partial<AgentState> & { id: string }): AgentState {
  return {
    name: overrides.id,
    type: 'data-vault',
    team: 'platform',
    trustProfile: 'high',
    state: 'active',
    ...overrides,
  }
}

const FIVE_AGENTS: AgentState[] = [
  makeAgent({ id: 'agent-cardvault', name: 'Card Vault', type: 'data-vault', team: 'data', trustProfile: 'high' }),
  makeAgent({ id: 'agent-pipeline', name: 'Data Pipeline', type: 'data-pipeline', team: 'data', trustProfile: 'medium' }),
  makeAgent({ id: 'agent-llm', name: 'LLM Inference', type: 'llm-inference', team: 'ai', trustProfile: 'medium' }),
  makeAgent({ id: 'agent-gateway', name: 'API Gateway', type: 'api-gateway', team: 'platform', trustProfile: 'low' }),
  makeAgent({ id: 'agent-monitor', name: 'Monitor', type: 'observability', team: 'sre', trustProfile: 'high' }),
]

const EDGES = [
  { from: 'agent-cardvault', to: 'agent-pipeline' },
  { from: 'agent-pipeline', to: 'agent-llm' },
  { from: 'agent-llm', to: 'agent-gateway' },
  { from: 'agent-gateway', to: 'agent-monitor' },
]

// ── Tests ───────────────────────────────────────────────────────────────────

describe('FleetTopology', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders five nodes in the topology', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} />)
    expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
    for (const agent of FIVE_AGENTS) {
      expect(screen.getByTestId(`fleet-node-${agent.id}`)).toBeInTheDocument()
    }
  })

  it('colours nodes correctly per state', () => {
    const agents = [
      makeAgent({ id: 'a1', state: 'active' }),
      makeAgent({ id: 'a2', state: 'stunned' }),
      makeAgent({ id: 'a3', state: 'non-compliant' }),
      makeAgent({ id: 'a4', state: 'deploying' }),
      makeAgent({ id: 'a5', state: 'absent' }),
    ]

    render(<FleetTopology agents={agents} edges={[]} />)

    expect(screen.getByTestId('fleet-node-a1')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-a2')).toHaveAttribute('data-agent-state', 'stunned')
    expect(screen.getByTestId('fleet-node-a3')).toHaveAttribute('data-agent-state', 'non-compliant')
    expect(screen.getByTestId('fleet-node-a4')).toHaveAttribute('data-agent-state', 'deploying')
    expect(screen.getByTestId('fleet-node-a5')).toHaveAttribute('data-agent-state', 'absent')
  })

  it('shows state indicator dots on each node', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} />)
    for (const agent of FIVE_AGENTS) {
      expect(screen.getByTestId(`fleet-state-dot-${agent.id}`)).toBeInTheDocument()
    }
  })

  it('shows trust profile badges', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} />)
    for (const agent of FIVE_AGENTS) {
      const badge = screen.getByTestId(`fleet-trust-${agent.id}`)
      expect(badge.textContent?.toLowerCase()).toBe(agent.trustProfile)
    }
  })

  it('renders the edge layer SVG', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} />)
    expect(screen.getByTestId('fleet-edge-layer')).toBeInTheDocument()
  })

  it('marks edges as broken when an endpoint is stunned', () => {
    const agents = [
      makeAgent({ id: 'a1', state: 'stunned' }),
      makeAgent({ id: 'a2', state: 'active' }),
    ]
    const edges = [{ from: 'a1', to: 'a2' }]

    render(<FleetTopology agents={agents} edges={edges} />)
    const edgeEl = screen.getByTestId('fleet-edge-a1-a2')
    expect(edgeEl).toHaveAttribute('data-broken')
  })

  it('does not mark edges as broken when both endpoints are active', () => {
    const agents = [
      makeAgent({ id: 'a1', state: 'active' }),
      makeAgent({ id: 'a2', state: 'active' }),
    ]
    const edges = [{ from: 'a1', to: 'a2' }]

    render(<FleetTopology agents={agents} edges={edges} />)
    const edgeEl = screen.getByTestId('fleet-edge-a1-a2')
    expect(edgeEl).not.toHaveAttribute('data-broken')
  })

  it('cascade animation sequences nodes in order', async () => {
    const agents = [
      makeAgent({ id: 'a1', state: 'active' }),
      makeAgent({ id: 'a2', state: 'active' }),
      makeAgent({ id: 'a3', state: 'active' }),
    ]
    const edges = [
      { from: 'a1', to: 'a2' },
      { from: 'a2', to: 'a3' },
    ]

    const { rerender } = render(
      <FleetTopology agents={agents} edges={edges} cascadeInProgress={[]} />
    )

    // All nodes start active.
    expect(screen.getByTestId('fleet-node-a1')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-a2')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-a3')).toHaveAttribute('data-agent-state', 'active')

    // Trigger cascade.
    rerender(
      <FleetTopology agents={agents} edges={edges} cascadeInProgress={['a1', 'a2', 'a3']} />
    )

    // First node stunned immediately (0ms stagger).
    await act(async () => { vi.advanceTimersByTime(50) })
    expect(screen.getByTestId('fleet-node-a1')).toHaveAttribute('data-agent-state', 'stunned')
    // Second not yet.
    expect(screen.getByTestId('fleet-node-a2')).toHaveAttribute('data-agent-state', 'active')

    // Second node stunned after 200ms.
    await act(async () => { vi.advanceTimersByTime(200) })
    expect(screen.getByTestId('fleet-node-a2')).toHaveAttribute('data-agent-state', 'stunned')

    // Third node stunned after another 200ms.
    await act(async () => { vi.advanceTimersByTime(200) })
    expect(screen.getByTestId('fleet-node-a3')).toHaveAttribute('data-agent-state', 'stunned')
  })

  it('monitor node stays green during a cascade that does not include it', async () => {
    const agents = [
      makeAgent({ id: 'agent-cardvault', state: 'active' }),
      makeAgent({ id: 'agent-monitor', type: 'observability', state: 'active' }),
    ]
    const edges = [{ from: 'agent-cardvault', to: 'agent-monitor' }]

    render(
      <FleetTopology agents={agents} edges={edges} cascadeInProgress={['agent-cardvault']} />
    )

    await act(async () => { vi.advanceTimersByTime(50) })

    expect(screen.getByTestId('fleet-node-agent-cardvault')).toHaveAttribute('data-agent-state', 'stunned')
    // Monitor stays active since it was not in cascadeInProgress.
    expect(screen.getByTestId('fleet-node-agent-monitor')).toHaveAttribute('data-agent-state', 'active')
  })

  it('audience mode renders no Controls component', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} audience />)
    // React Flow Controls renders buttons with class react-flow__controls
    const controls = document.querySelector('.react-flow__controls')
    expect(controls).toBeNull()
  })

  it('renders agent names and team labels', () => {
    render(<FleetTopology agents={FIVE_AGENTS} edges={EDGES} />)
    expect(screen.getByText('Card Vault')).toBeInTheDocument()
    expect(screen.getByText('Data Pipeline')).toBeInTheDocument()
    expect(screen.getByText('LLM Inference')).toBeInTheDocument()
    expect(screen.getByText('API Gateway')).toBeInTheDocument()
    expect(screen.getByText('Monitor')).toBeInTheDocument()
  })

  it('handles empty agents gracefully', () => {
    render(<FleetTopology agents={[]} edges={[]} />)
    expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
  })
})

// ─── The diagram ────────────────────────────────────────────────────────────
//
// The lines used to be drawn from the bottom-centre of one card to the
// top-centre of another, over a layout that put the SRE monitor on top and
// every other agent in one flat row beneath it. Four of the five real
// dependencies were therefore between cards on the SAME row, which draws as a
// horizontal line straight across the diagram, and the edge layer sat at
// z-index 5 -- above React Flow's renderer -- so those lines were painted over
// the cards rather than between them.
//
// The fixture below is the real fleet from fleet-manager/base/fleet-config.yaml.
// Nothing here is a magic number; the counts come off the dependency record.

const FLEET_DEPENDENCIES: Record<string, string[]> = {
  'agent-cardvault': [],
  'agent-txn-pipeline': ['agent-cardvault'],
  'agent-llm-classifier': ['agent-txn-pipeline'],
  'agent-api-gateway': ['agent-cardvault'],
  'agent-monitor': [
    'agent-cardvault',
    'agent-txn-pipeline',
    'agent-llm-classifier',
    'agent-api-gateway',
  ],
}

const REAL_TYPES: Record<string, AgentState['type']> = {
  'agent-cardvault': 'data-vault',
  'agent-txn-pipeline': 'data-pipeline',
  'agent-llm-classifier': 'llm-inference',
  'agent-api-gateway': 'api-gateway',
  'agent-monitor': 'observability',
}

const REAL_AGENTS: AgentState[] = Object.keys(FLEET_DEPENDENCIES).map(id =>
  makeAgent({ id, type: REAL_TYPES[id] }),
)

const REAL_EDGES = Object.entries(FLEET_DEPENDENCIES).flatMap(([from, deps]) =>
  deps.map(to => ({ from, to })),
)

describe('FleetTopology draws the dependency graph it is given', () => {
  it('draws one line per declared dependency, no more and no fewer', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    const declared = Object.values(FLEET_DEPENDENCIES).reduce((n, deps) => n + deps.length, 0)
    const drawn = screen.getByTestId('fleet-edge-layer').querySelectorAll('path[data-edge-kind]')
    expect(drawn).toHaveLength(declared)
    expect(drawn).toHaveLength(REAL_EDGES.length)
  })

  it('gives every declared dependency its own path', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    for (const { from, to } of REAL_EDGES) {
      expect(screen.getByTestId(`fleet-edge-${from}-${to}`)).toBeInTheDocument()
    }
  })

  it('marks a link into the observability agent as watch-only', () => {
    // fleet-manager's CascadeTargets skips observability agents, so a stun
    // never reaches the monitor. Drawing that link like a cascade link would
    // claim a blast radius the backend does not have.
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    for (const dep of FLEET_DEPENDENCIES['agent-monitor']) {
      expect(screen.getByTestId(`fleet-edge-agent-monitor-${dep}`))
        .toHaveAttribute('data-edge-kind', 'watch')
    }
    expect(screen.getByTestId('fleet-edge-agent-txn-pipeline-agent-cardvault'))
      .toHaveAttribute('data-edge-kind', 'cascade')
  })

  it('keeps the lines underneath the cards', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    // React Flow's renderer is z-index 4 inside the viewport's stacking
    // context. Anything above that paints over the agents.
    expect(Number(screen.getByTestId('fleet-edge-layer').style.zIndex)).toBeLessThan(4)
  })

  it('points every line at what fails next', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    for (const path of screen.getByTestId('fleet-edge-layer').querySelectorAll('path[data-edge-kind]')) {
      expect(path.getAttribute('marker-end')).toMatch(/^url\(#fleet-arrow-[a-zA-Z0-9-]+\)$/)
    }
  })

  it('names both link classes in a legend', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    const legend = screen.getByTestId('fleet-topology-legend')
    expect(legend.textContent).toMatch(/cascade/i)
    expect(legend.textContent).toMatch(/watch only/i)
    expect(legend.textContent).toMatch(/broken/i)
  })

  it('keeps the legend in audience mode, where nobody can ask what a line means', () => {
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} audience />)
    expect(screen.getByTestId('fleet-topology-legend')).toBeInTheDocument()
  })
})

describe('FleetTopology chrome', () => {
  it('themes the zoom controls instead of leaving the vendor white block', () => {
    // @xyflow/react/dist/style.css defaults these buttons to #fefefe on a
    // #eee divider, and its dark palette is gated behind a `.dark` ancestor
    // this app does not use. Unset, the control renders as a white rectangle
    // floating in the corner of the panel.
    render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    const controls = document.querySelector('.react-flow__controls') as HTMLElement
    expect(controls).not.toBeNull()
    for (const property of [
      '--xy-controls-button-background-color',
      '--xy-controls-button-color',
      '--xy-controls-button-border-color',
    ]) {
      expect(controls.style.getPropertyValue(property), property).toMatch(/^var\(--[a-z0-9-]+\)$/)
    }
  })

  it('uses no literal colour anywhere in the topology chrome', () => {
    const { container } = render(<FleetTopology agents={REAL_AGENTS} edges={REAL_EDGES} />)
    const legend = screen.getByTestId('fleet-topology-legend')
    expect(legend.outerHTML).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
    expect(container.querySelector('[data-testid="fleet-edge-layer"]')!.outerHTML)
      .not.toMatch(/(stroke|fill)="#/)
  })
})
