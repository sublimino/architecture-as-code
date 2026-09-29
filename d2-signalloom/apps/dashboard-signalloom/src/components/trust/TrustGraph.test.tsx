import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import TrustGraph, { layoutNodes, RANK_Y } from './TrustGraph'
import type { TrustEdge, TrustNode } from './trustTypes'

// Mock ReactFlow modules
vi.mock('@xyflow/react', async () => {
  const actual = await vi.importActual<any>('@xyflow/react')
  return {
    ...actual,
    useReactFlow: () => ({
      fitView: vi.fn(),
    }),
    ReactFlow: ({ children, nodes, onNodeClick }: any) => (
      <div data-testid="mock-react-flow">
        {nodes?.map((n: any) => (
          <div
            key={n.id}
            data-testid={`flow-node-${n.id}`}
            onClick={(e) => onNodeClick?.(e, n)}
          >
            {n.data?.label || n.data?.node?.label || n.id}
          </div>
        ))}
        {children}
      </div>
    ),
    ViewportPortal: ({ children }: any) => <div data-testid="viewport-portal">{children}</div>,
    MiniMap: () => <div data-testid="mock-minimap" />,
    Controls: () => <div data-testid="mock-controls" />,
    Background: () => <div data-testid="mock-background" />,
  }
})

describe('layoutNodes', () => {
  const sampleNodes: TrustNode[] = [
    {
      id: 'platform',
      label: 'Signal Loom platform',
      kind: 'platform',
      evidence: 'modeled',
      assurance: 'lower',
      freshness: 'unknown',
      source: 'model',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'root',
      tenant: 'shared',
      location: 'in-cluster',
      x: 0,
      y: 0,
    },
    {
      id: 'auth-svc',
      label: 'Auth Service',
      kind: 'service',
      evidence: 'modeled',
      assurance: 'lower',
      freshness: 'unknown',
      source: 'model',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'service',
      tenant: 'shared',
      location: 'in-cluster',
      x: 0,
      y: 0,
    },
    {
      id: 'tenant-a',
      label: 'Tenant A',
      kind: 'tenant',
      evidence: 'modeled',
      assurance: 'lower',
      freshness: 'unknown',
      source: 'model',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'tenant',
      tenant: 'tenant-a',
      location: 'in-cluster',
      x: 0,
      y: 0,
    },
    {
      id: 'agent-1',
      label: 'Agent 1',
      kind: 'agent',
      evidence: 'observed',
      assurance: 'medium',
      freshness: 'unknown',
      source: 'k8s',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'agent',
      tenant: 'tenant-a',
      location: 'in-cluster',
      x: 0,
      y: 0,
    },
    {
      id: 'agent-2',
      label: 'Agent 2',
      kind: 'agent',
      evidence: 'observed',
      assurance: 'medium',
      freshness: 'unknown',
      source: 'k8s',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'agent',
      tenant: 'tenant-a',
      location: 'in-cluster',
      x: 0,
      y: 0,
    },
  ]

  it('assigns vertical tiers matching RANK_Y hierarchy', () => {
    const positioned = layoutNodes(sampleNodes)
    const platform = positioned.find((n) => n.id === 'platform')
    const service = positioned.find((n) => n.id === 'auth-svc')
    const tenant = positioned.find((n) => n.id === 'tenant-a')
    const agent1 = positioned.find((n) => n.id === 'agent-1')

    expect(platform?.y).toBe(RANK_Y.platform)
    expect(service?.y).toBe(RANK_Y.service)
    expect(tenant?.y).toBe(RANK_Y.tenant)
    expect(agent1?.y).toBe(RANK_Y.agent)
  })

  it('computes non-overlapping horizontal positions for nodes in the same rank', () => {
    const positioned = layoutNodes(sampleNodes)
    const agent1 = positioned.find((n) => n.id === 'agent-1')
    const agent2 = positioned.find((n) => n.id === 'agent-2')

    expect(agent1).toBeDefined()
    expect(agent2).toBeDefined()
    expect(agent1?.x).not.toBe(agent2?.x)
    expect(Math.abs((agent1?.x ?? 0) - (agent2?.x ?? 0))).toBeGreaterThanOrEqual(200)
  })

  it('preserves existing custom coordinates when total rank count is 1', () => {
    const singleNode: TrustNode[] = [
      {
        id: 'custom-node',
        label: 'Custom Node',
        kind: 'agent',
        evidence: 'observed',
        assurance: 'medium',
        freshness: 'unknown',
        source: 'k8s',
        observedAt: '2026-08-11T16:00:00Z',
        reason: 'agent',
        tenant: 'shared',
        location: 'in-cluster',
        x: 420,
        y: 840,
      },
    ]
    const positioned = layoutNodes(singleNode)
    expect(positioned[0].x).toBe(420)
    expect(positioned[0].y).toBe(840)
  })
})

describe('TrustGraph Component', () => {
  const mockNodes: TrustNode[] = [
    {
      id: 'agent-planner',
      label: 'Planner Agent',
      kind: 'agent',
      evidence: 'observed',
      assurance: 'medium',
      freshness: 'unknown',
      source: 'k8s',
      observedAt: '2026-08-11T16:00:00Z',
      reason: 'running',
      tenant: 'acme',
      location: 'in-cluster',
      x: 100,
      y: 200,
    },
  ]
  const mockEdges: TrustEdge[] = []

  it('renders graph nodes and canvas container', () => {
    render(
      <TrustGraph
        nodes={mockNodes}
        edges={mockEdges}
        selected={{ type: 'node', id: 'agent-planner' }}
        onSelectNode={vi.fn()}
        onSelectEdge={vi.fn()}
      />,
    )

    expect(screen.getByTestId('trust-graph-container')).toBeInTheDocument()
    expect(screen.getByTestId('trust-canvas')).toBeInTheDocument()
    expect(screen.getByTestId('flow-node-agent-planner')).toBeInTheDocument()
  })

  it('displays the Hidden Nodes badge when hiddenCount > 0', async () => {
    const handleReset = vi.fn()
    const user = userEvent.setup()

    render(
      <TrustGraph
        nodes={mockNodes}
        edges={mockEdges}
        selected={{ type: 'node', id: 'agent-planner' }}
        onSelectNode={vi.fn()}
        onSelectEdge={vi.fn()}
        hiddenCount={4}
        onResetFilters={handleReset}
      />,
    )

    const badge = screen.getByTestId('hidden-nodes-badge')
    expect(badge).toBeInTheDocument()
    expect(badge).toHaveTextContent('4 Hidden Nodes')

    const resetBtn = screen.getByTestId('reset-filters-btn')
    await user.click(resetBtn)
    expect(handleReset).toHaveBeenCalledTimes(1)
  })

  it('hides the Hidden Nodes badge when hiddenCount is 0', () => {
    render(
      <TrustGraph
        nodes={mockNodes}
        edges={mockEdges}
        selected={{ type: 'node', id: 'agent-planner' }}
        onSelectNode={vi.fn()}
        onSelectEdge={vi.fn()}
        hiddenCount={0}
      />,
    )

    expect(screen.queryByTestId('hidden-nodes-badge')).not.toBeInTheDocument()
  })

  it('triggers onSelectNode and onOpenDrawer on node click', async () => {
    const handleSelectNode = vi.fn()
    const handleOpenDrawer = vi.fn()
    const user = userEvent.setup()

    render(
      <TrustGraph
        nodes={mockNodes}
        edges={mockEdges}
        selected={{ type: 'node', id: 'agent-planner' }}
        onSelectNode={handleSelectNode}
        onSelectEdge={vi.fn()}
        onOpenDrawer={handleOpenDrawer}
      />,
    )

    const nodeElement = screen.getByTestId('flow-node-agent-planner')
    await user.click(nodeElement)

    expect(handleSelectNode).toHaveBeenCalledWith('agent-planner')
    expect(handleOpenDrawer).toHaveBeenCalledWith('agent-planner')
  })
})
