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

const DEMO_AGENTS: AgentState[] = [
  makeAgent({ id: 'agent-cardvault', name: 'Card Vault', type: 'data-vault', team: 'data', trustProfile: 'high' }),
  makeAgent({ id: 'agent-pipeline', name: 'Data Pipeline', type: 'data-pipeline', team: 'data', trustProfile: 'medium' }),
  makeAgent({ id: 'agent-llm', name: 'LLM Inference', type: 'llm-inference', team: 'ai', trustProfile: 'medium' }),
  makeAgent({ id: 'agent-gateway', name: 'API Gateway', type: 'api-gateway', team: 'platform', trustProfile: 'low' }),
  makeAgent({ id: 'agent-monitor', name: 'Monitor', type: 'observability', team: 'sre', trustProfile: 'high' }),
]

const DEMO_EDGES = [
  { from: 'agent-cardvault', to: 'agent-pipeline' },
  { from: 'agent-pipeline', to: 'agent-llm' },
  { from: 'agent-llm', to: 'agent-gateway' },
  { from: 'agent-gateway', to: 'agent-monitor' },
]

// ── Tests ───────────────────────────────────────────────────────────────────

describe('FleetCascadeAnimation', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('sequences timed cascade animation transitions with vi.useFakeTimers()', async () => {
    const cascadeList = ['agent-cardvault', 'agent-pipeline', 'agent-llm']
    const onCascadeStep = vi.fn()

    const { rerender } = render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={[]}
        onCascadeStep={onCascadeStep}
      />
    )

    // All agents initially active
    expect(screen.getByTestId('fleet-node-agent-cardvault')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-agent-pipeline')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-agent-llm')).toHaveAttribute('data-agent-state', 'active')

    // Trigger cascade
    rerender(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={cascadeList}
        onCascadeStep={onCascadeStep}
      />
    )

    // Step 0 (0ms stagger): First node transitions to stunned immediately
    await act(async () => {
      vi.advanceTimersByTime(50)
    })

    const cardvaultNode = screen.getByTestId('fleet-node-agent-cardvault')
    expect(cardvaultNode).toHaveAttribute('data-agent-state', 'stunned')
    expect(cardvaultNode).toHaveAttribute('data-cascading', 'true')
    expect(cardvaultNode.className).toContain('sl-node-cascade-pulse')
    expect(screen.getByTestId('fleet-node-agent-pipeline')).toHaveAttribute('data-agent-state', 'active')
    expect(screen.getByTestId('fleet-node-agent-llm')).toHaveAttribute('data-agent-state', 'active')
    expect(onCascadeStep).toHaveBeenCalledWith('agent-cardvault', 0, ['agent-cardvault'])

    // Step 1 (200ms stagger): Second node transitions to stunned
    await act(async () => {
      vi.advanceTimersByTime(200)
    })

    const pipelineNode = screen.getByTestId('fleet-node-agent-pipeline')
    expect(pipelineNode).toHaveAttribute('data-agent-state', 'stunned')
    expect(pipelineNode).toHaveAttribute('data-cascading', 'true')
    expect(pipelineNode.className).toContain('sl-node-cascade-pulse')
    expect(screen.getByTestId('fleet-node-agent-llm')).toHaveAttribute('data-agent-state', 'active')
    expect(onCascadeStep).toHaveBeenCalledWith('agent-pipeline', 1, ['agent-cardvault', 'agent-pipeline'])

    // Step 2 (400ms stagger): Third node transitions to stunned
    await act(async () => {
      vi.advanceTimersByTime(200)
    })

    const llmNode = screen.getByTestId('fleet-node-agent-llm')
    expect(llmNode).toHaveAttribute('data-agent-state', 'stunned')
    expect(llmNode).toHaveAttribute('data-cascading', 'true')
    expect(llmNode.className).toContain('sl-node-cascade-pulse')
    expect(onCascadeStep).toHaveBeenCalledWith('agent-llm', 2, ['agent-cardvault', 'agent-pipeline', 'agent-llm'])
  })

  it('verifies agent-monitor remains green/active during cascade transitions', async () => {
    // Explicitly include agent-monitor in cascadeInProgress list to verify exclusion rule
    const cascadeWithMonitor = ['agent-cardvault', 'agent-pipeline', 'agent-monitor']
    const onCascadeStep = vi.fn()

    render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={cascadeWithMonitor}
        onCascadeStep={onCascadeStep}
      />
    )

    // Monitor is active at t=0
    await act(async () => {
      vi.advanceTimersByTime(50)
    })

    const monitorNode = screen.getByTestId('fleet-node-agent-monitor')
    expect(monitorNode).toHaveAttribute('data-agent-state', 'active')
    expect(monitorNode).not.toHaveAttribute('data-cascading')
    expect(monitorNode.className).not.toContain('sl-node-cascade-pulse')

    const monitorDot = screen.getByTestId('fleet-state-dot-agent-monitor')
    expect(monitorDot.style.background).toBe('var(--cyan)')
    expect(monitorDot.className).not.toContain('sl-dot-cascade-pulse')

    // Advance past all cascade steps
    await act(async () => {
      vi.advanceTimersByTime(600)
    })

    // Monitor is STILL active and green
    expect(monitorNode).toHaveAttribute('data-agent-state', 'active')
    expect(monitorNode).not.toHaveAttribute('data-cascading')
    expect(monitorDot.style.background).toBe('var(--cyan)')

    // Verify onCascadeStep was never called for agent-monitor
    expect(onCascadeStep).not.toHaveBeenCalledWith('agent-monitor', expect.anything(), expect.anything())
  })

  it('renders pulse animation styles on state indicator dot during cascade', async () => {
    render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={['agent-cardvault']}
      />
    )

    await act(async () => {
      vi.advanceTimersByTime(50)
    })

    const dotEl = screen.getByTestId('fleet-state-dot-agent-cardvault')
    expect(dotEl.className).toContain('sl-dot-cascade-pulse')
    expect(dotEl.style.background).toBe('var(--error)')
  })

  it('marks edges broken sequentially as upstream and downstream nodes cascade', async () => {
    render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={['agent-cardvault', 'agent-pipeline']}
      />
    )

    // Initially at 50ms only cardvault is stunned
    await act(async () => {
      vi.advanceTimersByTime(50)
    })

    const edge1 = screen.getByTestId('fleet-edge-agent-cardvault-agent-pipeline')
    expect(edge1).toHaveAttribute('data-broken', 'true')

    const edge2 = screen.getByTestId('fleet-edge-agent-pipeline-agent-llm')
    expect(edge2).not.toHaveAttribute('data-broken')

    // At 250ms pipeline is stunned
    await act(async () => {
      vi.advanceTimersByTime(200)
    })

    expect(edge2).toHaveAttribute('data-broken', 'true')
  })

  it('respects prefers-reduced-motion by applying final stunned states immediately', () => {
    const matchMediaMock = vi.fn().mockImplementation((query: string) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))
    window.matchMedia = matchMediaMock

    const onCascadeStep = vi.fn()
    render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={['agent-cardvault', 'agent-pipeline']}
        onCascadeStep={onCascadeStep}
      />
    )

    // Stunned immediately without timer advance
    expect(screen.getByTestId('fleet-node-agent-cardvault')).toHaveAttribute('data-agent-state', 'stunned')
    expect(screen.getByTestId('fleet-node-agent-pipeline')).toHaveAttribute('data-agent-state', 'stunned')
    expect(onCascadeStep).toHaveBeenCalled()
  })

  it('enforces the zero em-dashes constraint in component text and labels', () => {
    const { container } = render(
      <FleetTopology
        agents={DEMO_AGENTS}
        edges={DEMO_EDGES}
        cascadeInProgress={['agent-cardvault']}
      />
    )

    expect(container.textContent).not.toMatch(/\u2014/)
    expect(container.textContent).not.toMatch(/\u2013/)
  })
})
