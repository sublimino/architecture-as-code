// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import AgentCockpitSection, { resolveAgentPod } from './AgentCockpitSection'
import type { AgentResponse } from '../types/api'
import type { TelemetrySample } from '../api/agentTelemetry'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently: async () => 'test-token' }),
}))

vi.mock('../hooks/useAgentTelemetry', () => ({
  useEstateTelemetry: () => ({
    pods: [
      { podName: 'agent-cardvault-1d5f7', namespace: 'fe-signalloom-agents', ts: '2026-08-01T12:00:00Z', cpuMillicores: 12.4, memoryRssMiB: 42.0, frozen: false },
      { podName: 'kusari-agent-0', namespace: 'fe-signalloom-agents', ts: '2026-08-01T12:00:00Z', cpuMillicores: 0, memoryRssMiB: 50.0, frozen: false },
    ],
    summary: null,
    connection: 'live',
  }),
  useAgentTelemetry: (podName: string | null) => ({
    samples: podName ? [{ podName, ts: '2026-08-01T12:00:00Z', cpuMillicores: 10.5, memoryRssMiB: 35.0, frozen: false }] : [],
    latest: podName ? { podName, ts: '2026-08-01T12:00:00Z', cpuMillicores: 10.5, memoryRssMiB: 35.0, frozen: false } : null,
    connection: 'live',
    stale: false,
  }),
}))

const baseAgent: AgentResponse = {
  id: 'agent-cardvault',
  name: 'Card Vault',
  type: 'autonomous',
  tenant_id: 'acme-corp',
  lifecycle_state: 'active',
  last_transition_at: '2026-08-01T12:00:00Z',
  eu_ai_act_risk_class: 'high',
  compliance_summary: {
    total_controls: 6,
    passing: 6,
    failing: 0,
    pending: 0,
    posture_score: 1.0,
  },
  created_at: '2026-08-01T00:00:00Z',
}

describe('resolveAgentPod', () => {
  const pods: TelemetrySample[] = [
    { podName: 'agent-cardvault-1d5f7', ts: 1785585600000, cpuMillicores: 10, memoryRssMiB: 20, frozen: false },
    { podName: 'sentinel-bot', ts: 1785585600000, cpuMillicores: 0, memoryRssMiB: 30, frozen: false },
  ]

  it('returns null for null or undefined agent', () => {
    expect(resolveAgentPod(null, pods)).toBeNull()
    expect(resolveAgentPod(undefined, pods)).toBeNull()
  })

  it('prefers explicit runtime.pod_name if present', () => {
    const agent: AgentResponse = {
      ...baseAgent,
      runtime: { pod_name: 'custom-explicit-pod' },
    }
    expect(resolveAgentPod(agent, pods)).toBe('custom-explicit-pod')
  })

  it('resolves pod via prefix match in monitored telemetry pods', () => {
    expect(resolveAgentPod(baseAgent, pods)).toBe('agent-cardvault-1d5f7')
  })

  it('resolves pod via exact match in monitored telemetry pods', () => {
    const agent: AgentResponse = { ...baseAgent, id: 'sentinel-bot', name: 'Sentinel Bot' }
    expect(resolveAgentPod(agent, pods)).toBe('sentinel-bot')
  })

  it('strips prefix from composite IDs like supercred:agent-cardvault', () => {
    const agent: AgentResponse = { ...baseAgent, id: 'supercred:agent-cardvault' }
    expect(resolveAgentPod(agent, pods)).toBe('agent-cardvault-1d5f7')
  })

  it('falls back to agent id or name if no pod matched in telemetry', () => {
    const agent: AgentResponse = { ...baseAgent, id: 'unmatched-agent-uuid', name: 'Unmatched' }
    expect(resolveAgentPod(agent, pods)).toBe('unmatched-agent-uuid')
  })
})

describe('AgentCockpitSection Component', () => {
  it('renders Live containment cockpit header and section testid', () => {
    render(<AgentCockpitSection agent={baseAgent} />)
    expect(screen.getByTestId('agent-cockpit-section')).toBeInTheDocument()
    expect(screen.getByText('Live containment cockpit')).toBeInTheDocument()
  })

  it('defaults pod selection to the agent resolved pod', () => {
    render(<AgentCockpitSection agent={baseAgent} />)
    const select = screen.getByTestId('cockpit-pod-select') as HTMLSelectElement
    expect(select.value).toBe('agent-cardvault-1d5f7')
  })

  it('allows switching the pod from the selector dropdown', () => {
    render(<AgentCockpitSection agent={baseAgent} />)
    const select = screen.getByTestId('cockpit-pod-select') as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'kusari-agent-0' } })
    expect(select.value).toBe('kusari-agent-0')
  })

  it('updates selection when agent prop changes', () => {
    const { rerender } = render(<AgentCockpitSection agent={baseAgent} />)
    const select = screen.getByTestId('cockpit-pod-select') as HTMLSelectElement
    expect(select.value).toBe('agent-cardvault-1d5f7')

    const otherAgent: AgentResponse = {
      ...baseAgent,
      id: 'kusari-agent-0',
      name: 'Kusari Agent',
    }
    rerender(<AgentCockpitSection agent={otherAgent} />)
    expect(select.value).toBe('kusari-agent-0')
  })

  it('respects targetPod prop if explicitly passed', () => {
    render(<AgentCockpitSection targetPod="custom-target-pod" />)
    const select = screen.getByTestId('cockpit-pod-select') as HTMLSelectElement
    expect(select.value).toBe('custom-target-pod')
  })
})
