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
