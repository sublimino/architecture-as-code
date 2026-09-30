// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLDC-P4-2 - the top-navigation estate metrics bar.
 */
import { act, render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import MetricsTopBar, { MetricsTopBarView } from './MetricsTopBar'
import { summariseEstate } from '../hooks/useAgentTelemetry'
import type { TelemetrySample } from '../api/agentTelemetry'

vi.mock('../auth/oidc', () => {
  const auth = Object.freeze({ getAccessTokenSilently: async () => 'unused' })
  return { useAuth0: () => auth }
})

function s(pod: string, cpu: number, frozen = false, mem: number | null = 40): TelemetrySample {
  return { podName: pod, namespace: 'tenant-kusari', ts: 0, cpuMillicores: cpu, memoryRssMiB: mem, frozen }
}

describe('summariseEstate', () => {
  it('counts total, active and stunned, and sums CPU with frozen pods contributing zero', () => {
    const summary = summariseEstate([s('a', 1.2), s('b', 98.4), s('c', 0.0003, true), s('d', 0, false, 0)])
    expect(summary).toEqual({ total: 4, active: 2, stunned: 1, totalCpuMillicores: expect.closeTo(99.6, 9) })
  })
})

describe('MetricsTopBarView', () => {
  it('shows the active agent count and aggregate CPU', () => {
    render(<MetricsTopBarView summary={{ total: 3, active: 2, stunned: 1, totalCpuMillicores: 99.6 }} connection="live" />)
    expect(screen.getByTestId('metrics-total')).toHaveTextContent(/^3$/)
    expect(screen.getByTestId('metrics-active')).toHaveTextContent(/^2$/)
    expect(screen.getByTestId('metrics-stunned')).toHaveTextContent(/^1$/)
    expect(screen.getByTestId('metrics-cpu')).toHaveTextContent(/^99\.600 mCPU$/)
    expect(screen.getByRole('group', { name: 'Agent estate telemetry' })).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('1 agent stunned')
  })

  it('shows no numbers at all when telemetry is offline', () => {
    render(<MetricsTopBarView summary={null} connection="error" />)
    expect(screen.getByTestId('metrics-offline')).toHaveTextContent('Telemetry offline')
    expect(screen.queryByTestId('metrics-active')).toBeNull()
    expect(screen.queryByTestId('metrics-cpu')).toBeNull()
  })

  it('marks retained figures stale once the stream is lost', () => {
    render(<MetricsTopBarView summary={{ total: 1, active: 1, stunned: 0, totalCpuMillicores: 1.2 }} connection="reconnecting" />)
    expect(screen.getByTestId('metrics-stale')).toBeInTheDocument()
  })

  it('animates counter changes through a CSS transition flag', async () => {
    const { rerender } = render(<MetricsTopBarView summary={{ total: 1, active: 1, stunned: 0, totalCpuMillicores: 1.2 }} connection="live" />)
    expect(screen.getByTestId('metrics-stunned')).toHaveAttribute('data-flash', 'false')
    rerender(<MetricsTopBarView summary={{ total: 1, active: 0, stunned: 1, totalCpuMillicores: 0 }} connection="live" />)
    await waitFor(() => expect(screen.getByTestId('metrics-stunned')).toHaveAttribute('data-flash', 'true'))
    await waitFor(() => expect(screen.getByTestId('metrics-stunned')).toHaveAttribute('data-flash', 'false'), { timeout: 2000 })
  })
})

describe('MetricsTopBar (live estate stream)', () => {
  it('subscribes to the estate endpoint and aggregates per-pod frames', async () => {
    let ctrl!: ReadableStreamDefaultController<Uint8Array>
    const enc = new TextEncoder()
    const fetchImpl = vi.fn(async () =>
      new Response(new ReadableStream<Uint8Array>({ start(c) { ctrl = c } }), { status: 200, headers: { 'content-type': 'text/event-stream' } }),
    ) as unknown as typeof fetch
    render(<MetricsTopBar options={{ fetchImpl, getToken: async () => 't' }} />)
    await waitFor(() => expect(fetchImpl).toHaveBeenCalledTimes(1))
    expect(String((fetchImpl as unknown as { mock: { calls: unknown[][] } }).mock.calls[0][0])).toBe('/api/telemetry/agents')

    const send = (p: unknown) => ctrl.enqueue(enc.encode(`event: telemetry\ndata: ${JSON.stringify(p)}\n\n`))
    act(() => {
      send({ agents: [{ pod_name: 'a', cpu_millicores: 1.2, memory_rss_bytes: 1 }, { pod_name: 'b', cpu_millicores: 45, memory_rss_bytes: 1 }] })
    })
    await waitFor(() => expect(screen.getByTestId('metrics-active')).toHaveTextContent('2'))
    expect(screen.getByTestId('metrics-cpu')).toHaveTextContent('46.200 mCPU')

    // b is stunned: it moves from active to stunned and stops contributing CPU.
    act(() => send({ pod_name: 'b', cpu_millicores: 0, memory_rss_bytes: 1, frozen: true }))
    await waitFor(() => expect(screen.getByTestId('metrics-stunned')).toHaveTextContent('1'))
    expect(screen.getByTestId('metrics-active')).toHaveTextContent('1')
    expect(screen.getByTestId('metrics-total')).toHaveTextContent('2')
    expect(screen.getByTestId('metrics-cpu')).toHaveTextContent('1.200 mCPU')
  })
})

describe('MetricsTopBar (JSON estate endpoint)', () => {
  it('polls a JSON estate snapshot instead of flapping between LIVE and reconnecting', async () => {
    // fe-signalloom's estate route answers JSON keyed namespace/pod, never SSE.
    const estate = {
      'tenant-a/kusari-agent-0': { pod_name: 'kusari-agent-0', namespace: 'tenant-a', millicores: 1.5, memory_rss_mb: 40, status: 'ACTIVE' },
      'tenant-b/kusari-agent-0': { pod_name: 'kusari-agent-0', namespace: 'tenant-b', millicores: 2.5, memory_rss_mb: 40, status: 'ACTIVE' },
    }
    const fetchImpl = vi.fn(async () =>
      new Response(JSON.stringify(estate), { status: 200, headers: { 'content-type': 'application/json' } }),
    ) as unknown as typeof fetch
    render(<MetricsTopBar options={{ fetchImpl, getToken: async () => 't', initialBackoffMs: 5, maxBackoffMs: 20, pollIntervalMs: 15 }} />)
    await waitFor(() => expect(screen.getByTestId('metrics-top-bar')).toHaveAttribute('data-connection', 'polling'))
    expect(screen.getByTestId('metrics-total')).toHaveTextContent(/^2$/)
    expect(screen.getByTestId('metrics-cpu')).toHaveTextContent('4.000 mCPU')
    expect(screen.queryByTestId('metrics-stale')).toBeNull()
    const accepts = (fetchImpl as unknown as { mock: { calls: [unknown, RequestInit][] } }).mock.calls.map(([, init]) => (init.headers as Record<string, string>).Accept)
    expect(accepts.filter((a) => a === 'text/event-stream')).toHaveLength(1)
  })

  it('an estate 503 shows no numbers', async () => {
    const fetchImpl = vi.fn(async () =>
      new Response('{"error":{"code":"telemetry_unavailable","message":"x"}}', { status: 503, headers: { 'content-type': 'application/json' } }),
    ) as unknown as typeof fetch
    render(<MetricsTopBar options={{ fetchImpl, getToken: async () => 't', initialBackoffMs: 5, maxBackoffMs: 20, pollIntervalMs: 15, maxStreamFailures: 2 }} />)
    await waitFor(() => expect(screen.getByTestId('metrics-top-bar')).toHaveAttribute('data-connection', 'error'))
    expect(screen.getByTestId('metrics-offline')).toHaveTextContent('Telemetry offline')
    expect(screen.queryByTestId('metrics-cpu')).toBeNull()
  })
})
