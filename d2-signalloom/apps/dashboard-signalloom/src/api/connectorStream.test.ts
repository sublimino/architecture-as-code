import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { SseParser, openConnectorStream, toConnectorStreamEvent, type ConnectorStreamHandle } from './connectorStream'
import type { ConnectorStreamEvent } from './connectorsClient'
import { createSseTestServer, type SseTestServer } from './__fixtures__/sseServer'

// ── Parser ────────────────────────────────────────────────────────────────

describe('SseParser', () => {
  it('dispatches an event only at the blank line that ends it', () => {
    const p = new SseParser()
    expect(p.push('event: remote_agent.upserted\ndata: {"a":1}\n')).toEqual([])
    expect(p.push('\n')).toEqual([{ event: 'remote_agent.upserted', data: '{"a":1}', id: '' }])
  })

  it('reassembles an event split at every possible chunk boundary', () => {
    const wire = 'id: 41\r\nevent: connector.sync_state\r\ndata: {"x":"é"}\r\n\r\n'
    for (let cut = 1; cut < wire.length; cut++) {
      const p = new SseParser()
      const got = [...p.push(wire.slice(0, cut)), ...p.push(wire.slice(cut))]
      expect(got, `cut at ${cut}`).toEqual([{ event: 'connector.sync_state', data: '{"x":"é"}', id: '41' }])
    }
  })

  it('treats a CR split from its LF across chunks as one line ending', () => {
    const p = new SseParser()
    expect(p.push('data: one\r')).toEqual([])
    // The \n completes the \r\n pair; it must not count as a blank line.
    expect(p.push('\ndata: two\r')).toEqual([])
    expect(p.push('\n\r\n')).toEqual([{ event: 'message', data: 'one\ntwo', id: '' }])
  })

  it('accepts bare CR line endings', () => {
    const p = new SseParser()
    expect(p.push('data: a\r\r')).toEqual([{ event: 'message', data: 'a', id: '' }])
  })

  it('joins multi-line data with newlines', () => {
    const p = new SseParser()
    expect(p.push('data: {\ndata: "k": 1\ndata: }\n\n')).toEqual([{ event: 'message', data: '{\n"k": 1\n}', id: '' }])
  })

  it('ignores comments, including the heartbeat, and does not dispatch on them', () => {
    const p = new SseParser()
    expect(p.push(': heartbeat\n\n')).toEqual([])
    expect(p.push(': heartbeat\ndata: x\n: mid-event comment\n\n')).toEqual([{ event: 'message', data: 'x', id: '' }])
  })

  it('strips exactly one leading space from a value', () => {
    const p = new SseParser()
    expect(p.push('data:  two spaces\ndata:none\n\n')).toEqual([{ event: 'message', data: ' two spaces\nnone', id: '' }])
  })

  it('tracks id across events and commits it only when an event block ends', () => {
    const p = new SseParser()
    p.push('id: 7\ndata: a\n\n')
    expect(p.lastEventId).toBe('7')
    p.push('id: 8\ndata: b\n')
    // The block carrying id 8 has not finished: resuming from 8 would skip it.
    expect(p.lastEventId).toBe('7')
    expect(p.push('\n')).toEqual([{ event: 'message', data: 'b', id: '8' }])
    expect(p.lastEventId).toBe('8')
  })

  it('ignores an id containing NUL', () => {
    const p = new SseParser()
    p.push('id: 3\ndata: a\n\nid: bad\u0000id\ndata: b\n\n')
    expect(p.lastEventId).toBe('3')
  })

  it('reads retry only when it is all digits', () => {
    const p = new SseParser()
    p.push('retry: 2500\n\n')
    expect(p.retry).toBe(2500)
    p.push('retry: 1e3\n\nretry: -5\n\n')
    expect(p.retry).toBe(2500)
  })

  it('resets the event type after each dispatch', () => {
    const p = new SseParser()
    expect(p.push('event: remote_agent.gone\ndata: 1\n\ndata: 2\n\n')).toEqual([
      { event: 'remote_agent.gone', data: '1', id: '' },
      { event: 'message', data: '2', id: '' },
    ])
  })
})

describe('toConnectorStreamEvent', () => {
  it('decodes the three contract events', () => {
    const agent = { external_id: 'agt_1', kind: 'agent', name: 'A', model: null, status: 'running', version: null, external_updated_at: null, first_seen_at: null, last_seen_at: null, last_changed_at: null, gone_at: null }
    expect(
      toConnectorStreamEvent({ event: 'remote_agent.upserted', data: JSON.stringify({ provider_id: 'claude', connector_id: 'c1', agent }), id: '1' }),
    ).toEqual({ type: 'remote_agent.upserted', provider_id: 'claude', connector_id: 'c1', agent })
    expect(
      toConnectorStreamEvent({ event: 'remote_agent.gone', data: '{"provider_id":"claude","connector_id":"c1","external_id":"agt_1","gone_at":"2026-10-16T10:00:00Z"}', id: '' }),
    ).toEqual({ type: 'remote_agent.gone', provider_id: 'claude', connector_id: 'c1', external_id: 'agt_1', gone_at: '2026-10-16T10:00:00Z' })
    const sync_state = { mode: 'poll', last_poll_at: null, last_success_at: null, last_error: null, next_poll_at: null }
    expect(
      toConnectorStreamEvent({ event: 'connector.sync_state', data: JSON.stringify({ provider_id: 'openai', connector_id: 'c2', sync_state }), id: '' }),
    ).toEqual({ type: 'connector.sync_state', provider_id: 'openai', connector_id: 'c2', sync_state })
  })

  it('decodes stream.reset, which carries no provider (the server cannot replay: refetch everything)', () => {
    expect(toConnectorStreamEvent({ event: 'stream.reset', data: '{}', id: '7' })).toEqual({ type: 'stream.reset' })
    expect(toConnectorStreamEvent({ event: 'stream.reset', data: 'not json', id: '' })).toBeNull()
  })

  it('drops unknown event types and malformed payloads instead of guessing', () => {
    expect(toConnectorStreamEvent({ event: 'message', data: '{}', id: '' })).toBeNull()
    expect(toConnectorStreamEvent({ event: 'remote_agent.upserted', data: 'not json', id: '' })).toBeNull()
    expect(toConnectorStreamEvent({ event: 'remote_agent.upserted', data: '{"provider_id":"claude"}', id: '' })).toBeNull()
    expect(toConnectorStreamEvent({ event: 'remote_agent.gone', data: '{"provider_id":"claude","connector_id":"c"}', id: '' })).toBeNull()
  })
})

// ── Client over fetch ─────────────────────────────────────────────────────

const UPSERT = (id: string, extId: string, status = 'running') =>
  `id: ${id}\nevent: remote_agent.upserted\ndata: ${JSON.stringify({
    provider_id: 'claude',
    connector_id: 'c1',
    agent: { external_id: extId, kind: 'agent', name: extId, model: null, status, version: null, external_updated_at: null, first_seen_at: null, last_seen_at: null, last_changed_at: null, gone_at: null },
  })}\n\n`

describe('openConnectorStream', () => {
  let server: SseTestServer
  let handle: ConnectorStreamHandle | null
  const events: ConnectorStreamEvent[] = []
  const opens: Array<{ reconnect: boolean }> = []
  const drops: Array<{ error: string; retryInMs: number }> = []
  let tokens: string[]

  function open(extra: Partial<Parameters<typeof openConnectorStream>[0]> = {}) {
    let n = 0
    handle = openConnectorStream({
      url: '/api/connectors/stream',
      getToken: async () => tokens[Math.min(n++, tokens.length - 1)],
      onEvent: (e) => events.push(e),
      onOpen: (info) => opens.push(info),
      onDrop: (info) => drops.push(info),
      initialRetryMs: 5,
      maxRetryMs: 40,
      ...extra,
    })
    return handle
  }

  beforeEach(() => {
    server = createSseTestServer()
    vi.stubGlobal('fetch', server.fetch)
    handle = null
    events.length = 0
    opens.length = 0
    drops.length = 0
    tokens = ['tok-1', 'tok-2', 'tok-3', 'tok-4']
  })

  afterEach(() => {
    handle?.close()
    vi.unstubAllGlobals()
  })

  it('authenticates with a bearer token and asks for an event stream', async () => {
    open()
    await vi.waitFor(() => expect(server.connections).toHaveLength(1))
    const c = server.connections[0]
    expect(c.url).toBe('/api/connectors/stream')
    expect(c.headers.Authorization).toBe('Bearer tok-1')
    expect(c.headers.Accept).toBe('text/event-stream')
    expect(c.headers['Last-Event-ID']).toBeUndefined()
  })

  it('delivers decoded events and decodes UTF-8 split across byte chunks', async () => {
    open()
    await vi.waitFor(() => expect(opens).toHaveLength(1))
    const bytes = new TextEncoder().encode(UPSERT('1', 'agt_é'))
    const split = bytes.indexOf(0xc3) + 1 // inside the two-byte é
    server.connections[0].sendBytes(bytes.slice(0, split))
    server.connections[0].sendBytes(bytes.slice(split))
    await vi.waitFor(() => expect(events).toHaveLength(1))
    expect(events[0]).toMatchObject({ type: 'remote_agent.upserted', agent: { external_id: 'agt_é' } })
  })

  it('reconnects after a drop with a fresh token and the last committed event id', async () => {
    open()
    await vi.waitFor(() => expect(opens).toHaveLength(1))
    server.connections[0].send(UPSERT('41', 'agt_1'))
    // A second event starts but never finishes before the drop.
    server.connections[0].send('id: 42\nevent: remote_agent.upserted\ndata: {"partial"')
    await vi.waitFor(() => expect(events).toHaveLength(1))
    server.connections[0].fail()

    await vi.waitFor(() => expect(server.connections).toHaveLength(2))
    const second = server.connections[1]
    expect(second.headers['Last-Event-ID']).toBe('41')
    expect(second.headers.Authorization).toBe('Bearer tok-2')
    await vi.waitFor(() => expect(opens).toEqual([{ reconnect: false }, { reconnect: true }]))
    expect(drops).toHaveLength(1)
  })

  it('reconnects when the server ends the stream cleanly', async () => {
    open()
    await vi.waitFor(() => expect(opens).toHaveLength(1))
    server.connections[0].end()
    await vi.waitFor(() => expect(server.connections).toHaveLength(2))
  })

  it("honours the server's retry hint as the reconnect delay", async () => {
    open({ initialRetryMs: 10_000 })
    await vi.waitFor(() => expect(opens).toHaveLength(1))
    server.connections[0].send('retry: 15\n\n')
    await new Promise((r) => setTimeout(r, 5))
    server.connections[0].fail()
    // With the 10 s default this would never happen inside the wait window.
    await vi.waitFor(() => expect(server.connections).toHaveLength(2), { timeout: 1000 })
    expect(drops[0].retryInMs).toBe(15)
  })

  it('backs off exponentially on repeated failures, capped, and resets after a successful open', async () => {
    server.rejectNext(503)
    server.rejectNext(503)
    server.rejectNext(503)
    server.rejectNext(503)
    open()
    await vi.waitFor(() => expect(opens).toHaveLength(1), { timeout: 2000 })
    expect(drops.map((d) => d.retryInMs)).toEqual([5, 10, 20, 40])
    expect(drops[0].error).toMatch(/503/)
    server.connections[4].fail()
    await vi.waitFor(() => expect(drops).toHaveLength(5))
    expect(drops[4].retryInMs).toBe(5)
  })

  it('reconnects when the connection goes silent past the idle timeout (missed heartbeats)', async () => {
    open({ idleTimeoutMs: 30, initialRetryMs: 500 })
    await vi.waitFor(() => expect(opens).toHaveLength(1), { interval: 2 })
    await vi.waitFor(() => expect(drops).toHaveLength(1), { timeout: 1000, interval: 2 })
    expect(server.connections[0].signal?.aborted).toBe(true)
    expect(drops[0].error).toMatch(/idle|heartbeat/i)
  })

  it('keeps a connection that heartbeats alive past the idle timeout', async () => {
    open({ idleTimeoutMs: 120 })
    await vi.waitFor(() => expect(opens).toHaveLength(1), { interval: 2 })
    for (let i = 0; i < 8; i++) {
      server.connections[0].send(': heartbeat\n\n')
      await new Promise((r) => setTimeout(r, 40))
    }
    // 320 ms elapsed against a 120 ms idle timeout: only the heartbeats kept it.
    expect(server.connections).toHaveLength(1)
    expect(drops).toHaveLength(0)
  })

  it('aborts the request on close and never reconnects', async () => {
    const h = open()
    await vi.waitFor(() => expect(opens).toHaveLength(1))
    h.close()
    expect(server.connections[0].signal?.aborted).toBe(true)
    await new Promise((r) => setTimeout(r, 30))
    expect(server.connections).toHaveLength(1)
    expect(drops).toHaveLength(0)
  })

  it('stops cleanly when closed during the reconnect wait', async () => {
    const h = open({ initialRetryMs: 60 })
    await vi.waitFor(() => expect(opens).toHaveLength(1), { interval: 2 })
    server.connections[0].fail()
    await vi.waitFor(() => expect(drops).toHaveLength(1), { interval: 2 })
    h.close()
    await new Promise((r) => setTimeout(r, 120))
    expect(server.connections).toHaveLength(1)
  })
})
