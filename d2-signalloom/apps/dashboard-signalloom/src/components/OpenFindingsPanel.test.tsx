/**
 * The phase-3 finding has to be readable as a sentence, name the agent it
 * belongs to, and disappear when it stops being reported.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import OpenFindingsPanel, { openFindings } from './OpenFindingsPanel'
import type { AgentPosture } from '../types/api'

function result(overrides: Partial<AgentPosture['results'][number]> = {}) {
  return {
    agent_id: 'supercred:agent-cardvault',
    control_id: 'SC-9',
    control_name: 'Pod securityContext defined',
    framework_name: 'NIST 800-53',
    status: 'fail',
    assessed_at: '2026-08-02T10:00:00Z',
    evidence_ref: null,
    ...overrides,
  } as AgentPosture['results'][number]
}

function agent(overrides: Partial<AgentPosture> = {}): AgentPosture {
  return {
    agent_id: 'supercred:agent-cardvault',
    agent_name: 'Cardvault Agent',
    posture_score: 42,
    results: [result()],
    ...overrides,
  } as AgentPosture
}

describe('openFindings — derivation', () => {
  it('reports only failing controls', () => {
    const findings = openFindings([
      agent({ results: [result(), result({ control_id: 'IA-4', status: 'pass' })] }),
    ])
    expect(findings.map((f) => f.controlId)).toEqual(['SC-9'])
  })

  it('ignores pending and reassessment-requested controls', () => {
    const findings = openFindings([
      agent({
        results: [
          result({ control_id: 'A', status: 'pending' }),
          result({ control_id: 'B', status: 'reassessment_requested' }),
        ],
      }),
    ])
    expect(findings).toEqual([])
  })

  it('carries the agent each finding belongs to', () => {
    const [finding] = openFindings([agent()])
    expect(finding.agentName).toBe('Cardvault Agent')
  })

  it('puts the most recently assessed finding first', () => {
    const findings = openFindings([
      agent({
        results: [
          result({ control_id: 'OLD', assessed_at: '2026-01-01T00:00:00Z' }),
          result({ control_id: 'NEW', assessed_at: '2026-08-02T10:00:00Z' }),
        ],
      }),
    ])
    expect(findings.map((f) => f.controlId)).toEqual(['NEW', 'OLD'])
  })

  it('orders deterministically when assessments share a timestamp', () => {
    // A list that reshuffles on every 2.5s poll is worse than no list.
    const input = [
      agent({
        agent_id: 'b', agent_name: 'Beta Agent',
        results: [result({ control_id: 'Z', control_name: 'Zulu' }), result({ control_id: 'A', control_name: 'Alpha' })],
      }),
      agent({ agent_id: 'a', agent_name: 'Alpha Agent', results: [result({ control_id: 'M', control_name: 'Mike' })] }),
    ]
    const once = openFindings(input).map((f) => `${f.agentName}:${f.controlName}`)
    const twice = openFindings(input).map((f) => `${f.agentName}:${f.controlName}`)
    expect(once).toEqual(twice)
    expect(once).toEqual(['Alpha Agent:Mike', 'Beta Agent:Alpha', 'Beta Agent:Zulu'])
  })

  it('tolerates an agent with no results array', () => {
    expect(() => openFindings([agent({ results: undefined as never })])).not.toThrow()
  })

  it('tolerates no agents at all', () => {
    expect(openFindings([])).toEqual([])
    expect(openFindings(undefined as never)).toEqual([])
  })
})

describe('OpenFindingsPanel — rendering', () => {
  it('renders nothing when there is nothing open — absence is the all-clear', () => {
    const { container } = render(<OpenFindingsPanel agents={[]} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('clears once the finding stops being reported (step 5 teardown)', () => {
    const { rerender, container } = render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByTestId('open-findings-panel')).toBeInTheDocument()

    rerender(<OpenFindingsPanel agents={[]} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('names the failing control', () => {
    render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByText('Pod securityContext defined')).toBeInTheDocument()
  })

  it('names the affected agent', () => {
    render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByText('Cardvault Agent')).toBeInTheDocument()
  })

  it('attributes the control to its framework', () => {
    render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByText(/NIST 800-53 · SC-9/)).toBeInTheDocument()
  })

  it('shows when the finding was assessed', () => {
    render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByText(/assessed 02 Aug 2026/)).toBeInTheDocument()
  })

  it('counts the findings, singular and plural', () => {
    const { rerender } = render(<OpenFindingsPanel agents={[agent()]} />)
    expect(screen.getByText(/1 OPEN COMPLIANCE FINDING$/)).toBeInTheDocument()

    rerender(
      <OpenFindingsPanel
        agents={[agent({ results: [result(), result({ control_id: 'SC-10' })] })]}
      />,
    )
    expect(screen.getByText(/2 OPEN COMPLIANCE FINDINGS$/)).toBeInTheDocument()
  })

  it('announces itself — it appears with no user action on the audience window', () => {
    render(<OpenFindingsPanel agents={[agent()]} />)
    const panel = screen.getByTestId('open-findings-panel')
    expect(panel).toHaveAttribute('role', 'status')
    expect(panel).toHaveAttribute('aria-live', 'polite')
  })

  it('never fills with amber — black-on-amber is 4.06:1 here and fails AA', () => {
    const { container } = render(<OpenFindingsPanel agents={[agent()]} />)
    expect(container.innerHTML).not.toMatch(/--amber/)
    expect(container.innerHTML).not.toMatch(/--warning/)
  })
})
