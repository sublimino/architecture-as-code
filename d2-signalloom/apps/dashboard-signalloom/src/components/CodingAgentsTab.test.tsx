// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { CodingAgentsTab } from './CodingAgentsTab'
import { FAKE_CODING_AGENT_TELEMETRY, FAKE_CODING_AGENT_AGGREGATE } from '../api/fakeCodingAgentData'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockList = vi.fn()
const mockAggregate = vi.fn()

vi.mock('../api/client', () => ({
  api: {
    codingAgents: {
      list: (token: string) => mockList(token),
      aggregate: (token: string) => mockAggregate(token),
    },
  },
}))

describe('CodingAgentsTab', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockList.mockResolvedValue(FAKE_CODING_AGENT_TELEMETRY)
    mockAggregate.mockResolvedValue(FAKE_CODING_AGENT_AGGREGATE)
  })

  it('renders aggregate stat cards and all coding agent cards', async () => {
    render(<CodingAgentsTab />)

    await waitFor(() => {
      expect(screen.getByText('Active Sessions')).toBeInTheDocument()
      expect(screen.getByText('Total Token Throughput')).toBeInTheDocument()
      expect(screen.getByText('Cumulative Steps')).toBeInTheDocument()
      expect(screen.getByText('Anonymity Cohort')).toBeInTheDocument()
    })

    // Check cards are rendered
    expect(screen.getByText('claude')).toBeInTheDocument()
    expect(screen.getByText('antigravity')).toBeInTheDocument()
    expect(screen.getByText('codex')).toBeInTheDocument()
    expect(screen.getByText('cpai')).toBeInTheDocument()
  })

  it('filters coding agents by harness selection', async () => {
    render(<CodingAgentsTab />)

    await waitFor(() => {
      expect(screen.getByText('claude')).toBeInTheDocument()
    })

    // Select 'antigravity' harness from dropdown
    const harnessSelect = screen.getByDisplayValue(/All Harnesses/i)
    fireEvent.change(harnessSelect, { target: { value: 'antigravity' } })

    expect(screen.getByText('antigravity')).toBeInTheDocument()
    expect(screen.queryByText('claude')).not.toBeInTheDocument()
    expect(screen.queryByText('codex')).not.toBeInTheDocument()
  })

  it('filters coding agents by search query (task ID)', async () => {
    render(<CodingAgentsTab />)

    await waitFor(() => {
      expect(screen.getByText('claude')).toBeInTheDocument()
    })

    const searchInput = screen.getByPlaceholderText(/Search task, session, PID/i)
    fireEvent.change(searchInput, { target: { value: 'SLCD-P5-2' } })

    expect(screen.getByText('claude')).toBeInTheDocument()
    expect(screen.queryByText('antigravity')).not.toBeInTheDocument()
  })

  it('displays empty state when filter matches nothing', async () => {
    render(<CodingAgentsTab />)

    await waitFor(() => {
      expect(screen.getByText('claude')).toBeInTheDocument()
    })

    const searchInput = screen.getByPlaceholderText(/Search task, session, PID/i)
    fireEvent.change(searchInput, { target: { value: 'non-existent-task-id' } })

    expect(screen.getByText(/No coding agents found/i)).toBeInTheDocument()
  })
})
