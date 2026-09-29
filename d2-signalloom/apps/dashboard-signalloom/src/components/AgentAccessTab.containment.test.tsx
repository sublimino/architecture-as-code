/**
 * Containment claims need an observation.
 *
 * The Access tab used to fill every gap with a confident default: eBPF
 * "active" and "attached" when nothing reported either, "UNCONFINED" and
 * "UNRESTRICTED" when no telemetry existed, and 142 dropped packets whenever
 * TC said drop without a count. The discovery normaliser invented a frozen
 * cgroup and a 42 ms latency from the stun label. None of that was observed.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentAccessTab from './AgentAccessTab'
import type { AgentResponse } from '../types/api'
import { claimedDossierAgentFixture } from '../api/fakeData'
import { isKernelContained, proxyRecordToDiscovery } from '../data/agentDiscovery'

function agent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return { ...claimedDossierAgentFixture, ...overrides }
}

function renderTab(a: AgentResponse) {
  return render(<MemoryRouter><AgentAccessTab agent={a} /></MemoryRouter>)
}

describe('AgentAccessTab without kernel observations', () => {
  it('claims no confinement, no eBPF state and no drop count when there is no telemetry', () => {
    renderTab(agent({ kernel_telemetry: null }))
    const text = document.body.textContent ?? ''
    expect(text).not.toMatch(/UNCONFINED|UNRESTRICTED/)
    expect(text).not.toMatch(/eBPF Sentinel Active|Sentinel Inactive/)
    expect(text).not.toMatch(/kprobe attached|Detached/)
    expect(text).not.toMatch(/packets dropped|Sentinel drops/)
    expect(text).not.toMatch(/THAWED|= PASS|TC action: INACTIVE|Kernel-observed/)
  })

  it('never fills a missing drop count with 142', () => {
    renderTab(agent({
      lifecycle_state: 'stunned',
      kernel_telemetry: { cgroup_state: 'unknown', traffic_control_state: 'drop', sentinel_drop_count: undefined, source: 'unavailable' },
    }))
    expect(document.body.textContent ?? '').not.toMatch(/142/)
    expect(screen.getAllByText(/TC: DROP|Packet drop active/).length).toBeGreaterThan(0)
  })

  it('still renders eBPF state when the telemetry reports it', () => {
    renderTab(agent({
      kernel_telemetry: { cgroup_state: 'thawed', traffic_control_state: 'allow', ebpf_active: true, ebpf_program_attached: true },
    }))
    expect(screen.getByText('eBPF Sentinel Active')).toBeInTheDocument()
    expect(screen.getByText('cls_bpf / kprobe attached')).toBeInTheDocument()
  })
})

describe('proxyRecordToDiscovery kernel telemetry', () => {
  const base = { id: 'agent-x', labels: { 'signalloom.ai/agent': 'true' } }

  it('a stun label without a kernel observation is not a frozen cgroup', () => {
    const record = proxyRecordToDiscovery({ ...base, state: 'stunned' }, 'live')
    expect(record.kernel_telemetry?.cgroup_state).toBe('unknown')
    expect(record.kernel_telemetry?.cgroup_frozen).not.toBe(true)
    expect(record.kernel_telemetry?.containment_latency_ms ?? null).toBeNull()
    expect(isKernelContained(record)).toBe(false)
  })

  it('kernel_state frozen from the proxy is a frozen cgroup', () => {
    const record = proxyRecordToDiscovery({ ...base, state: 'idle', kernel_state: 'frozen' }, 'live')
    expect(record.kernel_telemetry?.cgroup_state).toBe('frozen')
    expect(record.kernel_telemetry?.cgroup_frozen).toBe(true)
    expect(isKernelContained(record)).toBe(true)
  })

  it('kernel_state running from the proxy is a thawed cgroup', () => {
    const record = proxyRecordToDiscovery({ ...base, kernel_state: 'running' }, 'live')
    expect(record.kernel_telemetry?.cgroup_state).toBe('thawed')
    expect(isKernelContained(record)).toBe(false)
  })
})
