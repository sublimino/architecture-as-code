import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import TrustFlowEdge, { calculateFlowDuration } from './TrustFlowEdge'
import type { TrustEdge } from './trustTypes'
import { edgeGeometry } from './trustGeometry'

const mockEdge: TrustEdge = {
  id: 'test-edge',
  from: 'planner',
  to: 'triage',
  verb: 'planner invokes triage',
  plane: 'authorization',
  decision: 'allowed',
  evidence: 'fixture',
  source: 'contract',
  observedAt: '2026-09-29T06:00:00Z',
  freshness: 'fixture',
  assurance: 'medium',
  reason: 'authorized A2A',
  throughputPps: 150,
  latencyMs: 1.2,
  mtlsEnforced: true,
}

const mockGeom = edgeGeometry({ x: 100, y: 100 }, { x: 300, y: 300 }, 0)

describe('calculateFlowDuration', () => {
  it('returns base seconds when no throughput or latency is specified', () => {
    expect(calculateFlowDuration(4.0)).toBe(4.0)
    expect(calculateFlowDuration(2.5, undefined, undefined)).toBe(2.5)
  })

  it('speeds up animation (reduces duration) with high throughput', () => {
    const fastDuration = calculateFlowDuration(4.0, 200, 1.0)
    expect(fastDuration).toBeLessThan(4.0)
    expect(fastDuration).toBeGreaterThanOrEqual(0.4)
  })

  it('slows down animation (increases duration) with low throughput and high latency', () => {
    const slowDuration = calculateFlowDuration(4.0, 10, 30.0)
    expect(slowDuration).toBeGreaterThan(4.0)
    expect(slowDuration).toBeLessThanOrEqual(12.0)
  })
})

describe('TrustFlowEdge SVG rendering', () => {
  it('renders SVG flow path with mTLS color coding and telemetry data', () => {
    const { container } = render(
      <svg>
        <TrustFlowEdge
          edge={mockEdge}
          geom={mockGeom}
          wallAt={0.5}
          labelAt={0.5}
          labelOffset={0}
          selected={false}
          hot={false}
          dim={false}
          onSelect={vi.fn()}
          onHover={vi.fn()}
        />
      </svg>,
    )

    const edgeGroup = screen.getByTestId('trust-flow-edge-test-edge')
    expect(edgeGroup).toBeInTheDocument()
    expect(edgeGroup).toHaveAttribute('data-mtls', 'true')

    const flowPath = container.querySelector('.trust-edge__flow')
    expect(flowPath).toBeInTheDocument()
    expect(flowPath).toHaveAttribute('stroke', 'var(--teal)')
  })

  it('renders amber hue when mTLS is unauthenticated or unverified', () => {
    const unverifiedEdge: TrustEdge = {
      ...mockEdge,
      mtlsEnforced: false,
    }

    const { container } = render(
      <svg>
        <TrustFlowEdge
          edge={unverifiedEdge}
          geom={mockGeom}
          wallAt={0.5}
          labelAt={0.5}
          labelOffset={0}
          selected={false}
          hot={false}
          dim={false}
          onSelect={vi.fn()}
          onHover={vi.fn()}
        />
      </svg>,
    )

    const flowPath = container.querySelector('.trust-edge__flow')
    expect(flowPath).toHaveAttribute('stroke', 'var(--amber)')
  })

  it('renders error red stroke when edge decision is denied', () => {
    const deniedEdge: TrustEdge = {
      ...mockEdge,
      decision: 'denied',
      denialKind: 'application-authorization-rejection',
    }

    const { container } = render(
      <svg>
        <TrustFlowEdge
          edge={deniedEdge}
          geom={mockGeom}
          wallAt={0.5}
          labelAt={0.5}
          labelOffset={0}
          selected={false}
          hot={false}
          dim={false}
          onSelect={vi.fn()}
          onHover={vi.fn()}
        />
      </svg>,
    )

    const linePath = container.querySelector('.trust-edge__line')
    expect(linePath).toHaveAttribute('stroke', 'var(--error)')
  })

  it('respects prefers-reduced-motion media query by freezing animation into static dotted lines', () => {
    // Mock matchMedia to simulate prefers-reduced-motion: reduce
    const originalMatchMedia = window.matchMedia
    window.matchMedia = vi.fn().mockImplementation(query => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))

    const { container } = render(
      <svg>
        <TrustFlowEdge
          edge={mockEdge}
          geom={mockGeom}
          wallAt={0.5}
          labelAt={0.5}
          labelOffset={0}
          selected={false}
          hot={false}
          dim={false}
          onSelect={vi.fn()}
          onHover={vi.fn()}
        />
      </svg>,
    )

    const flowPath = container.querySelector('.trust-edge__flow--static')
    expect(flowPath).toBeInTheDocument()
    expect(flowPath).toHaveAttribute('stroke-dasharray', '2 6')
    expect(flowPath).toHaveStyle({ animation: 'none', animationDuration: '0s' })

    window.matchMedia = originalMatchMedia
  })
})
