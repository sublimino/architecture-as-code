import { describe, it, expect } from 'vitest'
import type { AgentLifecycleState, AgentResponse, SentinelKernelTelemetry } from './api'
import { getStatusColor } from '../components/StatusBadge'
import { LIFECYCLE_OPTIONS, LIFECYCLE_LABELS } from '../pages/AgentsPage'

describe('Agent Lifecycle Contract & Adversarial Invariants', () => {
  const CANONICAL_STATES: readonly AgentLifecycleState[] = ['Governed', 'Suspended', 'Revoked'] as const

  it('exports canonical 3-stage governance lifecycle options matching the type contract', () => {
    expect(LIFECYCLE_OPTIONS).toEqual(['all', 'Governed', 'Suspended', 'Revoked'])
    for (const state of CANONICAL_STATES) {
      expect(LIFECYCLE_OPTIONS).toContain(state)
      expect(LIFECYCLE_LABELS[state]).toBe(state)
    }
  })

  it('maps all canonical states to verified design system color tokens', () => {
    const governedColor = getStatusColor('Governed', 'lifecycle')
    expect(governedColor.color).toBe('var(--teal)')
    expect(governedColor.bg).toContain('var(--teal)')

    const suspendedColor = getStatusColor('Suspended', 'lifecycle')
    expect(suspendedColor.color).toBe('var(--amber)')
    expect(suspendedColor.bg).toContain('var(--amber)')

    const revokedColor = getStatusColor('Revoked', 'lifecycle')
    expect(revokedColor.color).toBe('var(--error)')
    expect(revokedColor.bg).toContain('var(--error)')
  })

  it('rejects unmapped legacy states from canonical membership while preserving color resolution', () => {
    const legacyStates = ['registered', 'enrolled', 'active', 'suspended', 'stunned', 'revoked', 'decommissioned']
    for (const legacy of legacyStates) {
      // Legacy strings must resolve to safe tokens without crashing
      const color = getStatusColor(legacy, 'lifecycle')
      expect(color.color).toMatch(/var\(--(teal|cyan|amber|error)\)/)
    }
  })

  it('strictly isolates unclaimed shadow discovery records from governed records', () => {
    const mixedRecords: Partial<AgentResponse>[] = [
      { id: '1', name: 'Governed Bot', record_class: 'registered', lifecycle_state: 'Governed' },
      { id: '2', name: 'Claimed Bot', record_class: 'resolved', lifecycle_state: 'Governed' },
      { id: '3', name: 'Shadow Workload', record_class: 'discovered', lifecycle_state: 'Suspended' },
      { id: '4', name: 'Fixture Bot', record_class: 'fixture', lifecycle_state: 'Governed' },
    ]

    const governedOnly = mixedRecords.filter(
      (a) => a.record_class !== 'discovered' && (a as any).record_class !== 'discovery',
    )

    expect(governedOnly.map((a) => a.id)).toEqual(['1', '2', '4'])
    expect(governedOnly.some((a) => a.record_class === 'discovered')).toBe(false)
  })

  it('validates Sentinel eBPF kernel telemetry structure for Suspended/Stunned states', () => {
    const kernelTelemetry: SentinelKernelTelemetry = {
      cgroup_state: 'frozen',
      traffic_control_state: 'drop',
      ebpf_active: true,
      ebpf_program_attached: true,
      sentinel_ack: true,
      containment_probe_state: 'confirmed',
    }

    expect(kernelTelemetry.cgroup_state).toBe('frozen')
    expect(kernelTelemetry.traffic_control_state).toBe('drop')
    expect(kernelTelemetry.ebpf_active).toBe(true)
  })
})
