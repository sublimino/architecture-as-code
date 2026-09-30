// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLDC-P4-2 - offline rendering contract for the cockpit view.
 *
 * Mock telemetry only; no stream. Idle (1.2 mCPU), spike (98.4 mCPU) and
 * frozen (0.000 mCPU) are the three states Appendix D.3 names.
 */
import { render, screen, within } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import {
  AgentCockpitTelemetryView,
  FLATLINE_PATH,
  TelemetryErrorBoundary,
} from '../AgentCockpitTelemetry'
import {
  formatMillicores,
  normalizeSample,
  runStateOf,
  utilisationBand,
  type TelemetrySample,
} from '../../api/agentTelemetry'

const POD = 'kusari-agent-0'
const CPU_FORMAT = /^[0-9]+\.[0-9]{3} mCPU$/

function sample(cpu: number, mem: number | null = 42, frozen = false, i = 0): TelemetrySample {
  return { podName: POD, namespace: 'tenant-kusari', ts: 1_000 + i * 2000, cpuMillicores: cpu, memoryRssMiB: mem, frozen }
}

function series(values: number[], opts: { frozenFrom?: number; mem?: number } = {}): TelemetrySample[] {
  return values.map((v, i) => sample(v, opts.mem ?? 42, opts.frozenFrom !== undefined && i >= opts.frozenFrom, i))
}

function renderView(samples: TelemetrySample[]) {
  return render(<AgentCockpitTelemetryView podName={POD} samples={samples} connection="live" />)
}

describe('AgentCockpitTelemetryView - idle (1.2 mCPU)', () => {
  it('renders the reading with three decimals and an ACTIVE badge', () => {
    renderView(series([0.9, 1.1, 1.2]))
    const cpu = screen.getByTestId('cockpit-cpu-metric')
    expect(cpu).toHaveTextContent(/^1\.200 mCPU$/)
    expect(cpu.textContent).toMatch(CPU_FORMAT)
    expect(cpu.id).toBe('cockpit-cpu-metric')
    const badge = screen.getByTestId('cockpit-state-badge')
    expect(badge).toHaveTextContent(/^ACTIVE$/)
    expect(badge).toHaveAttribute('data-state', 'active')
    expect(screen.queryByTestId('cockpit-containment-pill')).toBeNull()
    expect(screen.queryByTestId('cockpit-flatline')).toBeNull()
  })

  it('colours the sparkline green in the normal band', () => {
    renderView(series([1.2, 1.2]))
    const path = screen.getByTestId('cockpit-cpu-path')
    expect(path).toHaveAttribute('data-band', 'normal')
    expect(path).toHaveAttribute('stroke', 'var(--teal)')
  })

  it('shows resident memory in MiB alongside CPU', () => {
    renderView(series([1.2], { mem: 42 }))
    expect(screen.getByTestId('cockpit-memory-metric')).toHaveTextContent(/^42\.0 MiB$/)
  })
})

describe('AgentCockpitTelemetryView - spike (98.4 mCPU)', () => {
  it('renders the spike and colours the path red (critical band)', () => {
    renderView(series([1.2, 45, 98.4]))
    expect(screen.getByTestId('cockpit-cpu-metric')).toHaveTextContent(/^98\.400 mCPU$/)
    const path = screen.getByTestId('cockpit-cpu-path')
    expect(path).toHaveAttribute('data-band', 'critical')
    expect(path).toHaveAttribute('stroke', 'var(--error)')
  })

  it('uses amber for the elevated 20-80 band', () => {
    renderView(series([1.2, 45]))
    expect(screen.getByTestId('cockpit-cpu-path')).toHaveAttribute('stroke', 'var(--amber)')
  })
})

describe('AgentCockpitTelemetryView - frozen (0.000 mCPU)', () => {
  const frozen = series([1.2, 98.4, 98.4, 0, 0], { frozenFrom: 3, mem: 42 })

  it('renders exactly 0.000 mCPU, the STUNNED badge and the CONTAINED pill', () => {
    renderView(frozen)
    expect(screen.getByTestId('cockpit-cpu-metric')).toHaveTextContent(/^0\.000 mCPU$/)
    const badge = screen.getByTestId('cockpit-state-badge')
    expect(badge).toHaveTextContent(/^STUNNED \(CGROUP FROZEN\)$/)
    expect(badge).toHaveAttribute('data-state', 'frozen')
    expect(screen.getByTestId('cockpit-containment-pill')).toHaveTextContent(/^CONTAINED: FROZEN$/)
  })

  it('keeps memory steady - frozen in place, not terminated', () => {
    renderView(frozen)
    expect(screen.getByTestId('cockpit-memory-metric')).toHaveTextContent(/^42\.0 MiB$/)
  })

  it('draws a perfectly horizontal flatline on the zero axis', () => {
    renderView(frozen)
    const flat = screen.getByTestId('cockpit-flatline')
    const d = flat.getAttribute('d') ?? ''
    expect(d).toBe(FLATLINE_PATH)
    const ys = [...d.matchAll(/[ML] [\d.]+ ([\d.]+)/g)].map((m) => Number(m[1]))
    expect(ys).toHaveLength(2)
    expect(new Set(ys).size).toBe(1)
    const axis = screen.getByTestId('cockpit-sparkline').querySelector('line')
    expect(Number(axis?.getAttribute('y1'))).toBe(ys[0])
    // The live CPU trace is replaced, not overlaid.
    expect(screen.queryByTestId('cockpit-cpu-path')).toBeNull()
  })

  it('clamps residual floating-point CPU to 0.000 when the cgroup reports frozen', () => {
    renderView([sample(0.00042, 42, true)])
    expect(screen.getByTestId('cockpit-cpu-metric')).toHaveTextContent(/^0\.000 mCPU$/)
    expect(formatMillicores(0.0009, true)).toBe('0.000 mCPU')
    expect(formatMillicores(0.00009)).toBe('0.000 mCPU')
  })

  it('does NOT claim containment from a bare zero without the freeze signal', () => {
    // SLDC-P4-PRE: cAdvisor refreshes every ~15 s, so a 2 s window reads 0 on
    // a healthy agent. That must not render as STUNNED.
    renderView([sample(0, 42, false)])
    expect(screen.getByTestId('cockpit-cpu-metric')).toHaveTextContent(/^0\.000 mCPU$/)
    expect(screen.getByTestId('cockpit-state-badge')).toHaveAttribute('data-state', 'idle')
    expect(screen.queryByText(/STUNNED/)).toBeNull()
    expect(screen.queryByTestId('cockpit-containment-pill')).toBeNull()
  })

  it('distinguishes termination: RSS released to zero', () => {
    renderView([sample(0, 0, false)])
    expect(screen.getByTestId('cockpit-state-badge')).toHaveAttribute('data-state', 'terminated')
    expect(screen.queryByText(/STUNNED/)).toBeNull()
  })
})

describe('AgentCockpitTelemetryView - accessibility', () => {
  it('labels the region and the sparkline image', () => {
    renderView(series([1.2]))
    expect(screen.getByRole('region', { name: `Live telemetry for ${POD}` })).toBeInTheDocument()
    const img = screen.getByRole('img')
    expect(img.getAttribute('aria-label')).toMatch(/latest 1\.200 mCPU/)
  })

  it('announces state politely while active and assertively when frozen', () => {
    const { rerender } = renderView(series([1.2]))
    const live = screen.getByTestId('cockpit-live-region')
    expect(live).toHaveAttribute('role', 'status')
    expect(live).toHaveAttribute('aria-live', 'polite')
    expect(live).toHaveAttribute('aria-atomic', 'true')
    expect(live).toHaveTextContent(`${POD} active.`)

    rerender(<AgentCockpitTelemetryView podName={POD} samples={series([1.2, 0], { frozenFrom: 1 })} connection="live" />)
    expect(live).toHaveAttribute('aria-live', 'assertive')
    expect(live).toHaveTextContent(`${POD} stunned: cgroup frozen, CPU 0.000 mCPU, memory held at 42.0 MiB.`)
    expect(within(screen.getByRole('img')).queryByTestId('cockpit-flatline')).not.toBeNull()
    expect(screen.getByRole('img').getAttribute('aria-label')).toMatch(/flatlined at 0\.000/)
  })

  it('shows an awaiting state before the first sample, and a stale warning when told', () => {
    const { rerender } = render(<AgentCockpitTelemetryView podName={POD} samples={[]} connection="connecting" />)
    expect(screen.getByTestId('cockpit-awaiting')).toBeInTheDocument()
    expect(screen.getByTestId('cockpit-cpu-metric')).toHaveTextContent(/^awaiting$/)
    rerender(<AgentCockpitTelemetryView podName={POD} samples={series([45.2])} connection="reconnecting" stale />)
    expect(screen.getByTestId('cockpit-stale')).toBeInTheDocument()
    expect(screen.getByTestId('cockpit-connection')).toHaveTextContent('RECONNECTING')
  })
})

describe('TelemetryErrorBoundary', () => {
  it('replaces a crashed visualiser with a fallback message', () => {
    function Boom(): never {
      throw new Error('renderer fault')
    }
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    render(
      <TelemetryErrorBoundary podName={POD}>
        <Boom />
      </TelemetryErrorBoundary>,
    )
    expect(screen.getByTestId('cockpit-telemetry-fallback')).toHaveTextContent(`Live telemetry for ${POD} is unavailable`)
    spy.mockRestore()
    warn.mockRestore()
  })
})

describe('telemetry normalisation', () => {
  it('reads snake_case bytes and camelCase MiB, and the explicit freeze signal', () => {
    const a = normalizeSample({ pod_name: POD, cpu_millicores: 1.2, memory_rss_bytes: 44040192, ts: '2026-09-30T10:00:00Z' })
    expect(a?.memoryRssMiB).toBeCloseTo(42, 5)
    expect(a?.frozen).toBe(false)
    const b = normalizeSample({ podName: POD, cpuMillicores: '0', MemoryRssMB: 42, cgroup_state: 'frozen' })
    expect(b?.frozen).toBe(true)
    expect(runStateOf(b!)).toBe('frozen')
  })

  it('rejects payloads it would have to guess at', () => {
    expect(normalizeSample({ cpu_millicores: 1 })).toBeNull()
    expect(normalizeSample({ pod_name: POD })).toBeNull()
    expect(normalizeSample({ pod_name: POD, cpu_millicores: 'NaN' })).toBeNull()
    expect(normalizeSample('nope')).toBeNull()
  })

  it('clamps a negative rate (counter reset) to zero', () => {
    expect(normalizeSample({ pod_name: POD, cpu_millicores: -3 })?.cpuMillicores).toBe(0)
  })

  it('bands at the card thresholds', () => {
    expect(utilisationBand(19.999)).toBe('normal')
    expect(utilisationBand(20)).toBe('elevated')
    expect(utilisationBand(80)).toBe('elevated')
    expect(utilisationBand(80.001)).toBe('critical')
  })
})
