// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * SLDC-P4-2 - the live cockpit against a scripted SSE stream.
 *
 * The real hook, the real transport and the real frame parser; only `fetch`
 * is replaced, by a stream this file writes frames into. That keeps the test
 * offline while still exercising subscription, heartbeats, drops, reconnect
 * and the polling fallback.
 */
import { Profiler } from 'react'
import { act, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import AgentCockpitTelemetry from './AgentCockpitTelemetry'
import { appendWindow, backoffDelay } from '../hooks/useAgentTelemetry'
import type { TelemetrySample } from '../api/agentTelemetry'

// Stable identity, like the real hook: the token getter is passed explicitly
// below, so this only keeps react-oidc-context from logging its missing
// provider on every render.
vi.mock('../auth/oidc', () => {
  const auth = Object.freeze({ getAccessTokenSilently: async () => 'unused' })
  return { useAuth0: () => auth }
})

const POD = 'kusari-agent-0'
const CPU_FORMAT = /^[0-9]+\.[0-9]{3} mCPU$/
const FAST = { initialBackoffMs: 5, maxBackoffMs: 20, pollIntervalMs: 15, getToken: async () => 'test-token' }

interface ScriptedStream {
  response: Response
  send(payload: unknown): void
  comment(): void
  close(): void
  fail(): void
}

function scriptedStream(): ScriptedStream {
  let ctrl!: ReadableStreamDefaultController<Uint8Array>
  const body = new ReadableStream<Uint8Array>({ start(c) { ctrl = c } })
  const enc = new TextEncoder()
  return {
    response: new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } }),
    send: (p) => ctrl.enqueue(enc.encode(`event: telemetry\ndata: ${JSON.stringify(p)}\n\n`)),
    comment: () => ctrl.enqueue(enc.encode(': keepalive\n\n')),
    close: () => ctrl.close(),
    fail: () => ctrl.error(new Error('connection reset')),
  }
}

function frame(cpu: number, extra: Record<string, unknown> = {}) {
  return { pod_name: POD, namespace: 'tenant-kusari', cpu_millicores: cpu, memory_rss_bytes: 42 * 1024 * 1024, ...extra }
}

/** A fetch mock that hands out a fresh scripted stream per connection. */
function streamingFetch() {
  const streams: ScriptedStream[] = []
  const fetchImpl = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => {
    const s = scriptedStream()
    streams.push(s)
    return s.response
  })
  return { fetchImpl: fetchImpl as unknown as typeof fetch, calls: fetchImpl.mock.calls, streams }
}

const cpuText = () => screen.getByTestId('cockpit-cpu-metric').textContent ?? ''

afterEach(() => {
  vi.restoreAllMocks()
})

describe('AgentCockpitTelemetry (live stream)', () => {
  it('subscribes to the per-pod SSE endpoint with a Bearer header, not a URL token', async () => {
    const { fetchImpl, calls } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(calls.length).toBe(1))
    const [url, init] = calls[0]
    expect(String(url)).toBe(`/api/telemetry/agents/${POD}`)
    expect(String(url)).not.toMatch(/token/i)
    const headers = init?.headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer test-token')
    expect(headers.Accept).toBe('text/event-stream')
  })

  it('renders live CPU and memory as samples arrive', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send(frame(1.2)))
    await waitFor(() => expect(cpuText()).toBe('1.200 mCPU'))
    expect(cpuText()).toMatch(CPU_FORMAT)
    expect(screen.getByTestId('cockpit-memory-metric')).toHaveTextContent('42.0 MiB')
    expect(screen.getByTestId('cockpit-connection')).toHaveAttribute('data-connection', 'live')
    expect(screen.getByTestId('cockpit-sparkline')).toBeInTheDocument()
  })

  it('renders 0.000 mCPU on cgroup freeze', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))

    // idle -> provocation spike -> stun: the sequence D.3 describes.
    act(() => streams[0].send(frame(1.2)))
    await waitFor(() => expect(cpuText()).toBe('1.200 mCPU'))
    expect(Number.parseFloat(cpuText())).toBeGreaterThan(0)
    act(() => streams[0].send(frame(98.4)))
    await waitFor(() => expect(cpuText()).toBe('98.400 mCPU'))
    const memBefore = screen.getByTestId('cockpit-memory-metric').textContent

    // Residual float from the rate calculation, plus the explicit freeze.
    act(() => streams[0].send(frame(0.00031, { frozen: true })))
    await waitFor(() => expect(screen.getByTestId('cockpit-state-badge')).toHaveAttribute('data-state', 'frozen'))
    expect(cpuText()).toMatch(/^0\.000 mCPU$/)
    expect(cpuText()).toMatch(CPU_FORMAT)
    expect(screen.getByTestId('cockpit-containment-pill')).toHaveTextContent(/^CONTAINED: FROZEN$/)
    expect(screen.getByTestId('cockpit-state-badge')).toHaveTextContent(/^STUNNED \(CGROUP FROZEN\)$/)
    expect(screen.getByTestId('cockpit-flatline')).toBeInTheDocument()
    expect(screen.getByTestId('cockpit-memory-metric').textContent).toBe(memBefore)
  })

  it('ignores keepalive comments without re-rendering', async () => {
    const { fetchImpl, streams } = streamingFetch()
    let commits = 0
    render(
      <Profiler id="cockpit" onRender={() => { commits += 1 }}>
        <AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />
      </Profiler>,
    )
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send(frame(1.2)))
    await waitFor(() => expect(cpuText()).toBe('1.200 mCPU'))
    // Let the stale-flag effect and any trailing commits settle.
    await act(async () => { await new Promise((r) => setTimeout(r, 30)) })
    const settled = commits
    await act(async () => {
      for (let i = 0; i < 10; i++) streams[0].comment()
      await new Promise((r) => setTimeout(r, 30))
    })
    expect(commits).toBe(settled)
    expect(cpuText()).toBe('1.200 mCPU')
  })

  it('reconnects after the stream drops mid-session and picks up the freeze', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send(frame(45.2)))
    await waitFor(() => expect(cpuText()).toBe('45.200 mCPU'))

    act(() => streams[0].fail())
    await waitFor(() => expect(streams.length).toBe(2))
    act(() => streams[1].send(frame(0, { frozen: true })))
    await waitFor(() => expect(cpuText()).toBe('0.000 mCPU'))
    expect(screen.getByTestId('cockpit-state-badge')).toHaveAttribute('data-state', 'frozen')
  })

  it('falls back to HTTP polling after repeated stream failures', async () => {
    let streamAttempts = 0
    const fetchImpl = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const accept = (init?.headers as Record<string, string>).Accept
      if (accept === 'text/event-stream') {
        streamAttempts += 1
        return new Response('upstream unavailable', { status: 503 })
      }
      return new Response(JSON.stringify(frame(0, { frozen: true })), { status: 200, headers: { 'content-type': 'application/json' } })
    }) as unknown as typeof fetch
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, maxStreamFailures: 2, fetchImpl }} />)
    await waitFor(() => expect(screen.getByTestId('cockpit-connection')).toHaveAttribute('data-connection', 'polling'))
    await waitFor(() => expect(cpuText()).toBe('0.000 mCPU'))
    expect(streamAttempts).toBe(2)
  })

  it('flags a reading stale when the stream goes quiet', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, staleAfterMs: 40, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send(frame(45.2)))
    await waitFor(() => expect(cpuText()).toBe('45.200 mCPU'))
    expect(screen.queryByTestId('cockpit-stale')).toBeNull()
    await waitFor(() => expect(screen.getByTestId('cockpit-stale')).toBeInTheDocument())
  })

  it('caps the rolling window at 15 points in a long session', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => {
      for (let i = 1; i <= 40; i++) streams[0].send(frame(i))
    })
    await waitFor(() => expect(cpuText()).toBe('40.000 mCPU'))
    const d = screen.getByTestId('cockpit-cpu-path').getAttribute('d') ?? ''
    expect(d.match(/[ML] /g)).toHaveLength(15)
  })

  it('drops frames for other pods', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send({ ...frame(99), pod_name: 'someone-else' }))
    act(() => streams[0].send(frame(1.2)))
    await waitFor(() => expect(cpuText()).toBe('1.200 mCPU'))
  })
})

describe('telemetry hook helpers', () => {
  it('backs off exponentially and caps', () => {
    expect([1, 2, 3, 4, 10].map((n) => backoffDelay(n, 1000, 30_000))).toEqual([1000, 2000, 4000, 8000, 30_000])
  })

  it('appendWindow never exceeds the window size', () => {
    let w: TelemetrySample[] = []
    for (let i = 0; i < 50; i++) {
      w = appendWindow(w, { podName: POD, ts: i, cpuMillicores: i, memoryRssMiB: 1, frozen: false }, 15)
      expect(w.length).toBeLessThanOrEqual(15)
    }
    expect(w[0].cpuMillicores).toBe(35)
    expect(w[14].cpuMillicores).toBe(49)
  })
})

describe('AgentCockpitTelemetry (error states never read as a reading)', () => {
  const json = (body: string, status = 200) =>
    new Response(body, { status, headers: { 'content-type': 'application/json' } })

  async function settlesOffline(respond: () => Response) {
    let streamAttempts = 0
    const fetchImpl = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      if ((init?.headers as Record<string, string>).Accept === 'text/event-stream') streamAttempts += 1
      return respond()
    }) as unknown as typeof fetch
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, maxStreamFailures: 2, fetchImpl }} />)
    await waitFor(() => expect(screen.getByTestId('cockpit-connection')).toHaveAttribute('data-connection', 'error'))
    // Each stream attempt failed and was retried: none was mistaken for a snapshot.
    expect(streamAttempts).toBe(2)
    expect(cpuText()).toBe('awaiting')
    expect(screen.queryByTestId('cockpit-state-badge')).toBeNull()
    expect(screen.getByTestId('cockpit-awaiting')).toHaveTextContent('Telemetry stream unavailable.')
  }

  it.each([401, 403, 404, 500, 503])('HTTP %i renders OFFLINE, never 0.000 mCPU', async (status) => {
    await settlesOffline(() => json(JSON.stringify({ error: { code: 'x', message: 'y' } }), status))
  })

  it('a network error renders OFFLINE', async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError('Failed to fetch')
    }) as unknown as typeof fetch
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, maxStreamFailures: 2, fetchImpl }} />)
    await waitFor(() => expect(screen.getByTestId('cockpit-connection')).toHaveAttribute('data-connection', 'error'))
    expect(cpuText()).toBe('awaiting')
  })

  it('malformed JSON is a failure, not a live connection', async () => {
    await settlesOffline(() => json('{"pod_name": "kusari-agent-0", "millicores": '))
  })

  it('a 200 HTML page (SPA fallback, login proxy) is a failure, not a live stream', async () => {
    await settlesOffline(() => new Response('<!doctype html><html></html>', { status: 200, headers: { 'content-type': 'text/html' } }))
  })

  it('a PENDING sample with null millicores is not rendered as 0.000', async () => {
    const { fetchImpl, streams } = streamingFetch()
    render(<AgentCockpitTelemetry podName={POD} options={{ ...FAST, fetchImpl }} />)
    await waitFor(() => expect(streams.length).toBe(1))
    act(() => streams[0].send({ pod_name: POD, namespace: 'n', millicores: null, memory_rss_mb: 42, status: 'PENDING' }))
    await act(async () => { await new Promise((r) => setTimeout(r, 30)) })
    expect(cpuText()).toBe('awaiting')
    expect(screen.queryByTestId('cockpit-state-badge')).toBeNull()
  })
})
