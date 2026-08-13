// The SSE log transport, at the seam.
//
// Two things are under test and they fail differently. The FRAMER is pure: a
// network read is not an event, and every way a read can be cut — mid-frame,
// several frames at once, nothing but a keepalive comment — has to survive a
// round trip through the parser without inventing or losing an event. The
// TRANSPORT is about the wire: which URL, which header, and (the part that
// matters most) that the bearer token is never written into the URL.
//
// The panel's behaviour on top of this — the fallback to polling, the exact-
// offset guard — is covered in pages/supercredInstructor.test.tsx.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  parseSseFrames,
  streamDemoRunLog,
  type DemoRunLogChunk,
  type DemoRunStreamEnd,
} from './demoRunner'

/** Feed a buffer through the parser one network read at a time. */
function framesFrom(reads: string[]) {
  let rest = ''
  const seen: { event: string; data: string }[] = []
  for (const read of reads) {
    const parsed = parseSseFrames(rest + read)
    seen.push(...parsed.frames)
    rest = parsed.rest
  }
  return { frames: seen, rest }
}

function logFrame(chunk: Partial<DemoRunLogChunk> = {}): string {
  const payload: DemoRunLogChunk = {
    run_id: 'run-1', offset: 0, next_offset: 0, chunk: '', truncated: false, eof: false, ...chunk,
  }
  return `event: log\ndata: ${JSON.stringify(payload)}\n\n`
}

describe('SSE framing', () => {
  it('reads several events out of one network read', () => {
    const { frames } = framesFrom([
      'event: log\ndata: {"a":1}\n\nevent: log\ndata: {"a":2}\n\nevent: end\ndata: {"a":3}\n\n',
    ])
    expect(frames.map(f => f.event)).toEqual(['log', 'log', 'end'])
    expect(frames.map(f => f.data)).toEqual(['{"a":1}', '{"a":2}', '{"a":3}'])
  })

  it('holds a frame split across two network reads until it is whole', () => {
    // TCP does not respect frame boundaries and neither does a proxy. Emitting
    // the half — or dropping it — is how a log loses a line at exactly the
    // moment the buffer fills, which is exactly when output is interesting.
    let rest = ''
    const first = parseSseFrames('event: log\ndata: {"chu')
    expect(first.frames).toEqual([])
    rest = first.rest
    const second = parseSseFrames(rest + 'nk":"hello"}\n\n')
    expect(second.frames).toEqual([{ event: 'log', data: '{"chunk":"hello"}' }])
    expect(second.rest).toBe('')
  })

  it('swallows the keepalive comment without emitting an event', () => {
    // The runner sends a bare `:` comment every ~15s so an idle proxy does not
    // close the connection. It is not an event; a parser that reports it as one
    // hands the panel a frame with no data to parse and takes the stream down.
    const { frames, rest } = framesFrom([': keepalive\n\n', ':\n\n', logFrame({ chunk: 'real' })])
    expect(frames).toHaveLength(1)
    expect(JSON.parse(frames[0].data).chunk).toBe('real')
    expect(rest).toBe('')
  })

  it('keeps a trailing partial frame as rest rather than parsing it', () => {
    const parsed = parseSseFrames(`${logFrame({ chunk: 'done' })}event: log\ndata: {"chunk":"par`)
    expect(parsed.frames).toHaveLength(1)
    expect(parsed.rest).toBe('event: log\ndata: {"chunk":"par')
  })

  it('joins multi-line data with a newline, as the SSE spec requires', () => {
    const { frames } = framesFrom(['event: log\ndata: one\ndata: two\n\n'])
    expect(frames).toEqual([{ event: 'log', data: 'one\ntwo' }])
  })

  it('defaults an unnamed frame to the message event', () => {
    const { frames } = framesFrom(['data: {"a":1}\n\n'])
    expect(frames[0].event).toBe('message')
  })

  it('handles CRLF line endings, including a CR split off the end of a read', () => {
    // A lone trailing CR may be the first half of a CRLF the next read
    // completes. Normalising it immediately would end a line that has not
    // ended, and the frame after it would be misparsed.
    const first = parseSseFrames('event: log\r\ndata: {"a":1}\r')
    expect(first.frames).toEqual([])
    const second = parseSseFrames(`${first.rest}\n\r\n`)
    expect(second.frames).toEqual([{ event: 'log', data: '{"a":1}' }])
  })

  it('ignores fields it has no use for rather than treating them as data', () => {
    const { frames } = framesFrom(['id: 7\nretry: 3000\nevent: log\ndata: {"a":1}\n\n'])
    expect(frames).toEqual([{ event: 'log', data: '{"a":1}' }])
  })
})

// ─── Transport ────────────────────────────────────────────────────────────────

interface Recorded {
  url: string
  headers: HeadersInit | undefined
  signal: AbortSignal | null | undefined
}

let calls: Recorded[] = []

/**
 * A streaming Response whose body is produced on demand.
 *
 * `push` releases one network read into the stream, so a test can assert what
 * the caller has seen BETWEEN reads. A mock that hands over the whole body at
 * once can only ever prove the final state, which is the blind spot these
 * tests exist to close.
 */
function controllableStream() {
  let controller: ReadableStreamDefaultController<Uint8Array> | null = null
  const encoder = new TextEncoder()
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      controller = c
    },
  })
  /** Let the reader's microtasks run, so a push is observable before the assert. */
  const settle = () => new Promise(resolve => setTimeout(resolve, 0))
  return {
    body,
    push(text: string) {
      controller?.enqueue(encoder.encode(text))
      return settle()
    },
    close() {
      controller?.close()
      return settle()
    },
    /** What a real fetch body does when the request is aborted. */
    fail(reason: unknown) {
      controller?.error(reason)
    },
  }
}

type ControllableStream = ReturnType<typeof controllableStream>

function mockStreamFetch(opts: { stream?: ControllableStream; status?: number }) {
  const status = opts.status ?? 200
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), headers: init?.headers, signal: init?.signal })
    // Real fetch errors the body stream when the signal fires; the transport
    // relies on that to stop, so the mock has to reproduce it.
    init?.signal?.addEventListener('abort', () => {
      opts.stream?.fail(new DOMException('The operation was aborted.', 'AbortError'))
    })
    return {
      ok: status >= 200 && status < 300,
      status,
      body: opts.stream?.body ?? null,
      text: async () => 'not found',
      json: async () => ({}),
    } as unknown as Response
  }) as unknown as typeof fetch
}

beforeEach(() => {
  calls = []
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('streamDemoRunLog', () => {
  it('opens the stream at the requested offset and authenticates with a header', async () => {
    // The hard rule this pins: the token is a bearer JWT and never appears in
    // the URL. Query parameters land in nginx access logs, in every proxy
    // between the browser and the runner, and in browser history — all three
    // outlive the session the token belongs to. This is also the whole reason
    // the transport is fetch() and not EventSource, which cannot send headers.
    const stream = controllableStream()
    mockStreamFetch({ stream })

    const done = streamDemoRunLog('run-1', 128, { onChunk: () => true }, 'demo-token')
    await stream.close()
    await done

    expect(calls[0].url).toBe('/demo-api/runs/run-1/stream?offset=128')
    expect(calls[0].url).not.toContain('demo-token')
    expect(calls[0].headers).toMatchObject({ Authorization: 'Bearer demo-token' })
  })

  it('delivers each log chunk as it arrives, not all at the end', async () => {
    const stream = controllableStream()
    mockStreamFetch({ stream })

    const seen: string[] = []
    const done = streamDemoRunLog('run-1', 0, {
      onChunk: chunk => {
        seen.push(chunk.chunk)
        return true
      },
    })

    await stream.push(logFrame({ offset: 0, next_offset: 6, chunk: 'first\n' }))
    expect(seen).toEqual(['first\n'])
    await stream.push(logFrame({ offset: 6, next_offset: 13, chunk: 'second\n' }))
    expect(seen).toEqual(['first\n', 'second\n'])

    await stream.close()
    await done
  })

  it('reports the terminal status the end event carries', async () => {
    const stream = controllableStream()
    mockStreamFetch({ stream })

    let ended: DemoRunStreamEnd | null = null
    const done = streamDemoRunLog('run-1', 0, {
      onChunk: () => true,
      onEnd: end => {
        ended = end
      },
    })
    await stream.push(
      'event: end\ndata: {"run_id":"run-1","offset":9,"next_offset":9,"chunk":"","truncated":false,'
        + '"eof":true,"status":"failed","exit_code":1}\n\n',
    )
    await done

    expect(ended).toMatchObject({ status: 'failed', exit_code: 1, eof: true })
  })

  it('rejects when the runner has no stream endpoint, so the caller can poll instead', async () => {
    // An older runner image serves /log and 404s /stream. That is not an error
    // to show anybody — it is the signal to use the transport that does exist.
    mockStreamFetch({ status: 404 })
    await expect(streamDemoRunLog('run-1', 0, { onChunk: () => true })).rejects.toThrow(/404/)
  })

  it('rejects when the caller refuses a chunk, because the stream cannot re-ask', async () => {
    // A refused chunk means the caller's cursor is no longer where the stream
    // thinks it is. SSE has no way to re-request from the true cursor, so the
    // only correct move is to fail and let the polling path — which sends its
    // cursor with every read — take over.
    const stream = controllableStream()
    mockStreamFetch({ stream })

    // The rejection is attached before the chunk is pushed: the throw happens
    // inside the push's turn of the loop, and a promise nobody is watching yet
    // registers as an unhandled rejection.
    const rejects = expect(streamDemoRunLog('run-1', 0, { onChunk: () => false }))
      .rejects.toThrow(/cursor/i)
    await stream.push(logFrame({ offset: 40, next_offset: 50, chunk: 'out of step\n' }))
    await rejects
  })

  it('stops reading when the caller aborts', async () => {
    const stream = controllableStream()
    mockStreamFetch({ stream })
    const controller = new AbortController()

    const seen: string[] = []
    const done = streamDemoRunLog(
      'run-1', 0,
      { onChunk: chunk => { seen.push(chunk.chunk); return true } },
      undefined,
      controller.signal,
    ).catch(() => 'aborted')

    await stream.push(logFrame({ offset: 0, next_offset: 6, chunk: 'first\n' }))
    controller.abort()
    expect(await done).toBe('aborted')

    // The body is torn down, not merely ignored: enqueuing into it now throws
    // because the reader cancelled it. A transport that only stopped listening
    // would leave the connection — and the runner's writer — alive.
    expect(() => stream.push(logFrame({ offset: 6, next_offset: 13, chunk: 'second\n' }))).toThrow()
    expect(seen).toEqual(['first\n'])
    expect(calls[0].signal).toBe(controller.signal)
  })
})
