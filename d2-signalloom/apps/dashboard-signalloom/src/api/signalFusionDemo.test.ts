/**
 * Tests for the Signal Fusion demo API client.
 *
 * Validates the client functions against a mock fetch — the same pattern
 * used by demoRunner.test.ts for the SuperCred client.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import {
  fetchSignalFusionSteps,
  startSignalFusionRun,
  fetchSignalFusionRunLog,
  resetSignalFusion,
  fetchSignalFusionStatus,
} from './signalFusionDemo'

const TOKEN = 'test-bearer-token'

function mockFetch(status: number, body: unknown): ReturnType<typeof vi.fn> {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  })
}

beforeEach(() => {
  vi.restoreAllMocks()
})

describe('fetchSignalFusionSteps', () => {
  it('returns the step list from the API', async () => {
    const steps = [
      { step_id: '1', title: 'Inferred', description: 'Act 1' },
      { step_id: '2', title: 'Attested', description: 'Act 2' },
      { step_id: '3', title: 'Issued', description: 'Act 3' },
    ]
    globalThis.fetch = mockFetch(200, { steps })

    const result = await fetchSignalFusionSteps(TOKEN)
    expect(result).toHaveLength(3)
    expect(result.map(s => s.step_id)).toEqual(['1', '2', '3'])
  })

  it('returns empty array when steps is missing', async () => {
    globalThis.fetch = mockFetch(200, {})
    const result = await fetchSignalFusionSteps(TOKEN)
    expect(result).toEqual([])
  })

  it('throws on non-200 response', async () => {
    globalThis.fetch = mockFetch(500, { error: 'boom' })
    await expect(fetchSignalFusionSteps(TOKEN)).rejects.toThrow(/failed/)
  })

  it('sends auth header when token provided', async () => {
    const fn = mockFetch(200, { steps: [] })
    globalThis.fetch = fn
    await fetchSignalFusionSteps(TOKEN)
    expect(fn).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({
        headers: { Authorization: `Bearer ${TOKEN}` },
      }),
    )
  })

  it('calls the signalfusion endpoint, not supercred', async () => {
    const fn = mockFetch(200, { steps: [] })
    globalThis.fetch = fn
    await fetchSignalFusionSteps(TOKEN)
    const url = fn.mock.calls[0][0] as string
    expect(url).toContain('/api/demo/signalfusion/')
    expect(url).not.toContain('supercred')
  })
})

describe('startSignalFusionRun', () => {
  it('POSTs the step ID and returns the run', async () => {
    const run = { run_id: 'abc123', step_id: '1', kind: 'step', status: 'running' }
    const fn = mockFetch(202, run)
    globalThis.fetch = fn

    const result = await startSignalFusionRun('1', TOKEN)
    expect(result.run_id).toBe('abc123')
    expect(result.status).toBe('running')

    const [url, opts] = fn.mock.calls[0]
    expect(url).toContain('/api/demo/signalfusion/runs')
    expect(JSON.parse(opts.body as string)).toEqual({ step: '1' })
  })
})

describe('fetchSignalFusionRunLog', () => {
  it('fetches log with offset and wait params', async () => {
    const chunk = { run_id: 'abc', offset: 0, next_offset: 42, chunk: 'hello', truncated: false, eof: false }
    const fn = mockFetch(200, chunk)
    globalThis.fetch = fn

    const result = await fetchSignalFusionRunLog('abc', 0, TOKEN, 2)
    expect(result.chunk).toBe('hello')
    expect(result.next_offset).toBe(42)

    const url = fn.mock.calls[0][0] as string
    expect(url).toContain('offset=0')
    expect(url).toContain('wait=2')
  })
})

describe('fetchSignalFusionStatus', () => {
  it('returns status with defaults for missing fields', async () => {
    globalThis.fetch = mockFetch(200, {})
    const result = await fetchSignalFusionStatus(TOKEN)
    expect(result.active).toBeNull()
    expect(result.recent).toEqual([])
    expect(result.script_available).toBe(false)
  })
})

describe('resetSignalFusion', () => {
  it('POSTs to the reset endpoint', async () => {
    const run = { run_id: 'reset1', step_id: '3', kind: 'reset', status: 'running' }
    const fn = mockFetch(202, run)
    globalThis.fetch = fn

    const result = await resetSignalFusion(TOKEN)
    expect(result.run_id).toBe('reset1')

    const url = fn.mock.calls[0][0] as string
    expect(url).toContain('/api/demo/signalfusion/reset')
  })
})
