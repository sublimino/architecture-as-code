// Server-Sent Events client for GET /api/connectors/stream.
//
// EventSource cannot send an Authorization header, so this reads the response
// body of a plain fetch and parses the event-stream format itself
// (https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation).
// It reconnects with exponential backoff (the server's retry: hint is the
// base), resumes with Last-Event-ID, asks for a fresh token on every attempt,
// and treats a connection that goes quiet past the idle timeout (the server
// sends a heartbeat comment every 15 s) as dropped.

import type { ConnectorStreamEvent, ConnectorSyncState, RemoteAgent } from './connectorsClient'

export interface SseMessage {
  event: string
  data: string
  /** The last event ID in force when this event was dispatched. */
  id: string
}

export class SseParser {
  /** The id to resume from: committed only when an event block has ended. */
  lastEventId = ''
  /** The latest valid retry: hint, in milliseconds. */
  retry: number | null = null

  private buffer = ''
  private skipLeadingLF = false
  private data: string[] = []
  private eventType = ''
  private pendingId: string | null = null

  push(chunk: string): SseMessage[] {
    let text = chunk
    // A CR that ended the previous chunk may be the first half of a CRLF.
    if (this.skipLeadingLF && text.startsWith('\n')) text = text.slice(1)
    this.skipLeadingLF = false
    this.buffer += text

    const out: SseMessage[] = []
    let pos = 0
    for (;;) {
      const lf = this.buffer.indexOf('\n', pos)
      const cr = this.buffer.indexOf('\r', pos)
      const end = lf === -1 ? cr : cr === -1 ? lf : Math.min(lf, cr)
      if (end === -1) break
      const line = this.buffer.slice(pos, end)
      if (this.buffer[end] === '\r') {
        if (end + 1 === this.buffer.length) {
          pos = end + 1
          this.skipLeadingLF = true
        } else {
          pos = end + (this.buffer[end + 1] === '\n' ? 2 : 1)
        }
      } else {
        pos = end + 1
      }
      const msg = this.line(line)
      if (msg) out.push(msg)
    }
    this.buffer = this.buffer.slice(pos)
    return out
  }

  private line(line: string): SseMessage | null {
    if (line === '') return this.dispatch()
    if (line.startsWith(':')) return null
    const colon = line.indexOf(':')
    const field = colon === -1 ? line : line.slice(0, colon)
    let value = colon === -1 ? '' : line.slice(colon + 1)
    if (value.startsWith(' ')) value = value.slice(1)
    switch (field) {
      case 'event':
        this.eventType = value
        break
      case 'data':
        this.data.push(value)
        break
      case 'id':
        if (!value.includes('\u0000')) this.pendingId = value
        break
      case 'retry':
        if (/^\d+$/.test(value)) this.retry = Number(value)
        break
    }
    return null
  }

  private dispatch(): SseMessage | null {
    if (this.pendingId !== null) {
      this.lastEventId = this.pendingId
      this.pendingId = null
    }
    const hasData = this.data.length > 0
    const msg = hasData ? { event: this.eventType || 'message', data: this.data.join('\n'), id: this.lastEventId } : null
    this.data = []
    this.eventType = ''
    return msg
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function isString(v: unknown): v is string {
  return typeof v === 'string'
}

/** A typed connector event, or null for anything outside the contract. */
export function toConnectorStreamEvent(msg: SseMessage): ConnectorStreamEvent | null {
  let body: unknown
  try {
    body = JSON.parse(msg.data)
  } catch {
    return null
  }
  if (!isRecord(body) || !isString(body.provider_id) || !isString(body.connector_id)) return null
  const { provider_id, connector_id } = body
  switch (msg.event) {
    case 'remote_agent.upserted':
      return isRecord(body.agent) && isString(body.agent.external_id)
        ? { type: msg.event, provider_id, connector_id, agent: body.agent as unknown as RemoteAgent }
        : null
    case 'remote_agent.gone':
      return isString(body.external_id) && isString(body.gone_at)
        ? { type: msg.event, provider_id, connector_id, external_id: body.external_id, gone_at: body.gone_at }
        : null
    case 'connector.sync_state':
      return isRecord(body.sync_state) && isString(body.sync_state.mode)
        ? { type: msg.event, provider_id, connector_id, sync_state: body.sync_state as unknown as ConnectorSyncState }
        : null
    default:
      return null
  }
}

export interface ConnectorStreamOptions {
  url: string
  /** Called before every connection attempt, so a reconnect carries a current token. */
  getToken: () => Promise<string>
  onEvent: (event: ConnectorStreamEvent) => void
  /** reconnect is true for every successful open after the first. */
  onOpen?: (info: { reconnect: boolean }) => void
  onDrop?: (info: { error: string; retryInMs: number }) => void
  /** Base reconnect delay until the server sends retry:. */
  initialRetryMs?: number
  maxRetryMs?: number
  /** No bytes for this long counts as a dropped connection. */
  idleTimeoutMs?: number
}

export interface ConnectorStreamHandle {
  close(): void
}

function describe(err: unknown): string {
  if (err instanceof Error && err.message) return err.message
  return typeof err === 'string' && err ? err : 'connection failed'
}

export function openConnectorStream(opts: ConnectorStreamOptions): ConnectorStreamHandle {
  const maxRetryMs = opts.maxRetryMs ?? 30_000
  const idleTimeoutMs = opts.idleTimeoutMs ?? 45_000
  let retryBaseMs = opts.initialRetryMs ?? 1_000
  let lastEventId = ''
  let failures = 0
  let opened = false
  let closed = false
  let current: AbortController | null = null
  let wake: (() => void) | null = null
  let sleepTimer: ReturnType<typeof setTimeout> | undefined

  const sleep = (ms: number) =>
    new Promise<void>((resolve) => {
      wake = resolve
      sleepTimer = setTimeout(resolve, ms)
    })

  async function connectOnce(): Promise<string> {
    const ctrl = new AbortController()
    current = ctrl
    let idleTimer: ReturnType<typeof setTimeout> | undefined
    let idled = false
    const armIdle = () => {
      clearTimeout(idleTimer)
      idleTimer = setTimeout(() => {
        idled = true
        ctrl.abort()
      }, idleTimeoutMs)
    }
    try {
      const token = await opts.getToken()
      if (closed) return ''
      const headers: Record<string, string> = { Authorization: `Bearer ${token}`, Accept: 'text/event-stream' }
      if (lastEventId) headers['Last-Event-ID'] = lastEventId
      armIdle()
      const res = await fetch(opts.url, { headers, signal: ctrl.signal, cache: 'no-store' })
      if (!res.ok || !res.body) return `stream request failed (HTTP ${res.status})`
      failures = 0
      opts.onOpen?.({ reconnect: opened })
      opened = true
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      const parser = new SseParser()
      for (;;) {
        const { value, done } = await reader.read()
        if (done) return 'stream ended by server'
        armIdle()
        for (const msg of parser.push(decoder.decode(value, { stream: true }))) {
          const event = toConnectorStreamEvent(msg)
          if (!event) continue
          try {
            opts.onEvent(event)
          } catch {
            /* a consumer bug must not tear down the shared connection */
          }
        }
        if (parser.lastEventId) lastEventId = parser.lastEventId
        if (parser.retry !== null) retryBaseMs = parser.retry
      }
    } catch (err) {
      if (idled) return `no heartbeat for ${Math.round(idleTimeoutMs / 1000)} s (idle)`
      return describe(err)
    } finally {
      clearTimeout(idleTimer)
    }
  }

  void (async () => {
    while (!closed) {
      const error = await connectOnce()
      if (closed) break
      failures += 1
      const retryInMs = Math.min(maxRetryMs, retryBaseMs * 2 ** (failures - 1))
      opts.onDrop?.({ error, retryInMs })
      await sleep(retryInMs)
    }
  })()

  return {
    close() {
      if (closed) return
      closed = true
      current?.abort()
      clearTimeout(sleepTimer)
      wake?.()
    },
  }
}
