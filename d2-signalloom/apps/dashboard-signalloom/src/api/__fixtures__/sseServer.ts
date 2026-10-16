// Test double for GET /api/connectors/stream: a fetch replacement whose every
// call opens a connection the test drives by hand (send bytes, end, fail) and
// whose request (URL, headers, abort signal) the test can inspect. Test-only;
// nothing in src imports it outside *.test.* files.

export interface SseTestConnection {
  url: string
  headers: Record<string, string>
  signal: AbortSignal | undefined
  send(text: string): void
  sendBytes(bytes: Uint8Array): void
  end(): void
  fail(error?: unknown): void
}

export interface SseTestServer {
  fetch: (url: string, init?: RequestInit) => Promise<Response>
  connections: SseTestConnection[]
  /** The next connection attempt answers with this HTTP status and no body. */
  rejectNext(status: number): void
}

export function createSseTestServer(): SseTestServer {
  const encoder = new TextEncoder()
  const connections: SseTestConnection[] = []
  const rejections: number[] = []

  const fetchImpl = async (url: string, init?: RequestInit): Promise<Response> => {
    const headers = { ...((init?.headers as Record<string, string> | undefined) ?? {}) }
    const signal = init?.signal ?? undefined
    const status = rejections.shift()
    if (status !== undefined) {
      connections.push({ url, headers, signal, send() {}, sendBytes() {}, end() {}, fail() {} })
      return { ok: false, status, body: null } as unknown as Response
    }
    let controller!: ReadableStreamDefaultController<Uint8Array>
    let closed = false
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        controller = c
      },
    })
    const close = (fn: () => void) => {
      if (closed) return
      closed = true
      fn()
    }
    signal?.addEventListener('abort', () => close(() => controller.error(new DOMException('aborted', 'AbortError'))))
    connections.push({
      url,
      headers,
      signal,
      send: (text) => {
        if (!closed) controller.enqueue(encoder.encode(text))
      },
      sendBytes: (bytes) => {
        if (!closed) controller.enqueue(bytes)
      },
      end: () => close(() => controller.close()),
      fail: (error) => close(() => controller.error(error ?? new TypeError('network error'))),
    })
    return { ok: true, status: 200, body } as unknown as Response
  }

  return {
    fetch: fetchImpl,
    connections,
    rejectNext: (status) => {
      rejections.push(status)
    },
  }
}
