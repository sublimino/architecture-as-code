// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentsPage from './AgentsPage'
import { FAKE_CODING_AGENT_TELEMETRY, FAKE_CODING_AGENT_AGGREGATE } from '../api/fakeCodingAgentData'

// Mock demoMode
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => true,
  isProductionEnv: false,
  showDemoToggle: true,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockAgentsList = vi.fn()
const mockCodingAgentsList = vi.fn()
const mockCodingAgentsAggregate = vi.fn()

vi.mock('../api/client', () => ({
  api: {
    agents: {
      list: (token: string) => mockAgentsList(token),
      register: vi.fn(),
    },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(),
      dismissAccount: vi.fn(),
    },
    compliancePolicy: {
      scan: vi.fn(),
    },
    codingAgents: {
      list: (token: string) => mockCodingAgentsList(token),
      aggregate: (token: string) => mockCodingAgentsAggregate(token),
    },
  },
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: {
    getObservations: vi.fn().mockResolvedValue([]),
    getActors: vi.fn().mockResolvedValue([]),
    getCoverage: vi.fn().mockResolvedValue({}),
    getActor: vi.fn().mockResolvedValue(null),
    promoteActor: vi.fn(),
    runCorrelation: vi.fn(),
  },
}))

describe('AgentsPage — Coding Agents Integration', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockAgentsList.mockResolvedValue({
      agents: [
        {
          id: 'tenant-demo:agent-triage',
          name: 'Triage Agent',
          type: 'triage',
          owner: 'demo-user',
          tenant_id: 'tenant-demo',
          lifecycle_state: 'active',
          last_transition_at: '2026-08-01T10:00:00Z',
          eu_ai_act_risk_class: 'limited',
          compliance_summary: { total_controls: 6, passing: 5, failing: 0, pending: 1, posture_score: 83 },
        },
      ],
      total: 1,
    })
    mockCodingAgentsList.mockResolvedValue(FAKE_CODING_AGENT_TELEMETRY)
    mockCodingAgentsAggregate.mockResolvedValue(FAKE_CODING_AGENT_AGGREGATE)
  })

  it('renders tab buttons for Governed Workloads and Detected Coding Agents', async () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <AgentsPage />
      </MemoryRouter>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('tab-governed-agents')).toBeInTheDocument()
      expect(screen.getByTestId('tab-coding-agents')).toBeInTheDocument()
    })
  })

  it('switches to CodingAgentsTab when Detected Coding Agents tab is clicked', async () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <AgentsPage />
      </MemoryRouter>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('tab-coding-agents')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId('tab-coding-agents'))

    await waitFor(() => {
      expect(screen.getByTestId('coding-agents-tab')).toBeInTheDocument()
      expect(screen.getByText('Autonomous Coding Agent Telemetry (SLCD Host Detective)')).toBeInTheDocument()
    })
  })

  it('renders CodingAgentsTab directly when ?tab=coding-agents query parameter is supplied', async () => {
    render(
      <MemoryRouter initialEntries={['/agents?tab=coding-agents']}>
        <AgentsPage />
      </MemoryRouter>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('coding-agents-tab')).toBeInTheDocument()
      expect(screen.getByText('Active Sessions')).toBeInTheDocument()
    })
  })
})
