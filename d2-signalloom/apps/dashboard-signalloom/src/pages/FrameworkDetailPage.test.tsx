import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import FrameworkDetailPage from './FrameworkDetailPage'
import { api } from '../api/client'
import type { FrameworkResponse, PostureResponse } from '../types/api'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/client', () => ({
  api: {
    compliance: {
      frameworks: vi.fn(),
      posture: vi.fn(),
    },
    agents: {
      reassess: vi.fn(),
    },
  },
}))

const MOCK_FRAMEWORK: FrameworkResponse = {
  id: 'fw-soc2',
  name: 'SOC 2 Type II',
  version: '2022',
  regulatory_body: 'AICPA',
  compliance_deadline: '2026-12-31T00:00:00Z',
  control_count: 2,
  controls: [
    {
      id: 'ctrl-cc6.1',
      name: 'CC6.1 Access Control',
      description: 'Logical access security',
      control_order: 1,
    },
    {
      id: 'ctrl-cc6.6',
      name: 'CC6.6 Boundary Defense',
      description: 'Network perimeter and egress filtering',
      control_order: 2,
    },
  ],
}

const MOCK_POSTURE: PostureResponse = {
  agents: [
    {
      agent_id: 'agent-cardvault',
      agent_name: 'Cardvault Agent (kagent)',
      posture_score: 100,
      results: [
        {
          agent_id: 'agent-cardvault',
          control_id: 'ctrl-cc6.1',
          control_name: 'CC6.1 Access Control',
          framework_name: 'SOC 2 Type II',
          status: 'pass',
          assessed_at: '2026-08-01T10:00:00Z',
          evidence_ref: null,
        },
        {
          agent_id: 'agent-cardvault',
          control_id: 'ctrl-cc6.6',
          control_name: 'CC6.6 Boundary Defense',
          framework_name: 'SOC 2 Type II',
          status: 'pass',
          assessed_at: '2026-08-01T10:00:00Z',
          evidence_ref: null,
        },
      ],
    },
    {
      agent_id: 'cpai-engineer',
      agent_name: 'CPAI Engineer (custom)',
      posture_score: 50,
      results: [
        {
          agent_id: 'cpai-engineer',
          control_id: 'ctrl-cc6.1',
          control_name: 'CC6.1 Access Control',
          framework_name: 'SOC 2 Type II',
          status: 'pass',
          assessed_at: '2026-08-01T10:00:00Z',
          evidence_ref: null,
        },
        {
          agent_id: 'cpai-engineer',
          control_id: 'ctrl-cc6.6',
          control_name: 'CC6.6 Boundary Defense',
          framework_name: 'SOC 2 Type II',
          status: 'fail',
          assessed_at: '2026-08-01T10:00:00Z',
          evidence_ref: null,
        },
      ],
    },
  ],
}

function renderFrameworkPage(frameworkId = 'fw-soc2') {
  return render(
    <MemoryRouter initialEntries={[`/compliance/frameworks/${frameworkId}`]}>
      <Routes>
        <Route path="/compliance/frameworks/:frameworkId" element={<FrameworkDetailPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('FrameworkDetailPage — Agent Matrix and Framework Rendering', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(api.compliance.frameworks).mockResolvedValue([MOCK_FRAMEWORK])
    vi.mocked(api.compliance.posture).mockResolvedValue(MOCK_POSTURE)
  })

  it('renders framework header and stats cleanly', async () => {
    renderFrameworkPage()
    await waitFor(() => {
      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('SOC 2 Type II')
    })
    expect(screen.getByText(/2 controls/i)).toBeInTheDocument()
    expect(screen.getByText(/AICPA/i)).toBeInTheDocument()
  })

  it('renders kagent and custom framework agents in the matrix', async () => {
    renderFrameworkPage()
    await waitFor(() => {
      expect(screen.getByText('Cardvault Agent (kagent)')).toBeInTheDocument()
      expect(screen.getByText('CPAI Engineer (custom)')).toBeInTheDocument()
    })
    expect(screen.getByText('CC6.1 Access Control')).toBeInTheDocument()
    expect(screen.getByText('CC6.6 Boundary Defense')).toBeInTheDocument()
  })

  it('handles reassessment request modal when clicking a failed control', async () => {
    renderFrameworkPage()
    await waitFor(() => {
      expect(screen.getByText('CPAI Engineer (custom)')).toBeInTheDocument()
    })

    const failCell = screen.getByTitle(/fail — Click to request reassessment/i)
    fireEvent.click(failCell)

    expect(screen.getByRole('heading', { name: /request reassessment/i })).toBeInTheDocument()
    expect(screen.getAllByText(/CC6.6 Boundary Defense/i).length).toBeGreaterThanOrEqual(2)

    const submitBtn = screen.getByRole('button', { name: /request reassessment/i })
    fireEvent.click(submitBtn)

    await waitFor(() => {
      expect(api.agents.reassess).toHaveBeenCalledWith('test-token', 'cpai-engineer', 'ctrl-cc6.6')
    })
  })
})
