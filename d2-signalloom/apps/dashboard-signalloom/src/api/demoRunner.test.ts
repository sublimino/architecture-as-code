// The /demo-api client, at the seam.
//
// Every assertion here is about the wire: which URL, which method, which body,
// and what a non-2xx turns into. The panel's behaviour is covered in
// pages/supercredInstructor.test.tsx — this file exists so a contract change in
// the runner workload fails here first, with a message that names the endpoint.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  fetchDemoRun,
  fetchDemoRunLog,
  fetchDemoStatus,
  fetchDemoSteps,
  isRunActive,
  isRunFailure,
  makeCommandForStep,
  resetDemo,
  startDemoRun,
  type DemoRunView,
} from './demoRunner'

interface Recorded {
  url: string
  method: string
  body: unknown
}

let calls: Recorded[] = []

function mockFetch(handler: (url: string) => { status?: number; payload?: unknown; text?: string }) {
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    calls.push({
      url,
      method: (init?.method ?? 'GET').toUpperCase(),
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
    })
    const result = handler(url)
    const status = result.status ?? 200
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => result.payload,
      text: async () => result.text ?? '',
    } as Response
  }) as unknown as typeof fetch
}

function run(overrides: Partial<DemoRunView> = {}): DemoRunView {
  return {
    run_id: 'run-1',
    step_id: '3',
    kind: 'step',
    status: 'running',
    started_at: '2026-08-02T10:00:00Z',
    finished_at: null,
    exit_code: null,
    error: null,
    ...overrides,
  }
}

beforeEach(() => {
  calls = []
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('demoRunner endpoints', () => {
  it('reads the five phases from GET /demo-api/steps', async () => {
    mockFetch(() => ({
      payload: {
        steps: [
          { step_id: '1', title: 'Deploy', description: 'services + agent' },
          { step_id: '2', title: 'Credential chain', description: 'SPIFFE to OpenBao' },
        ],
      },
    }))
    const steps = await fetchDemoSteps()
    expect(calls[0]).toMatchObject({ url: '/demo-api/steps', method: 'GET' })
    expect(steps.map(s => s.step_id)).toEqual(['1', '2'])
  })

  it('tolerates a steps payload with no steps array rather than throwing', async () => {
    mockFetch(() => ({ payload: {} }))
    expect(await fetchDemoSteps()).toEqual([])
  })

  it('reads active, recent and script_available from GET /demo-api/status', async () => {
    mockFetch(() => ({ payload: { active: run(), recent: [run({ run_id: 'run-0' })], script_available: true } }))
    const status = await fetchDemoStatus()
    expect(calls[0].url).toBe('/demo-api/status')
    expect(status.active?.run_id).toBe('run-1')
    expect(status.recent).toHaveLength(1)
    expect(status.script_available).toBe(true)
  })

  it('treats a missing script_available as not available', async () => {
    // The runner not answering the question is not the same as answering yes,
    // and offering a button that cannot work is the worse of the two failures.
    mockFetch(() => ({ payload: { active: null, recent: [] } }))
    expect((await fetchDemoStatus()).script_available).toBe(false)
  })

  it('starts a step by POSTing {step} to /demo-api/runs', async () => {
    mockFetch(() => ({ status: 202, payload: run({ step_id: '4' }) }))
    const started = await startDemoRun('4')
    expect(calls[0]).toMatchObject({ url: '/demo-api/runs', method: 'POST', body: { step: '4' } })
    expect(started.run_id).toBe('run-1')
  })

  it('polls a single run by id', async () => {
    mockFetch(() => ({ payload: run({ status: 'succeeded' }) }))
    expect((await fetchDemoRun('run-1')).status).toBe('succeeded')
    expect(calls[0].url).toBe('/demo-api/runs/run-1')
  })

  it('reads the log incrementally from the supplied offset', async () => {
    mockFetch(() => ({
      payload: { run_id: 'run-1', offset: 40, next_offset: 96, chunk: 'more output', truncated: false, eof: false },
    }))
    const chunk = await fetchDemoRunLog('run-1', 40)
    expect(calls[0].url).toBe('/demo-api/runs/run-1/log?offset=40')
    expect(chunk.next_offset).toBe(96)
  })

  it('escapes a run id that would otherwise change the path', async () => {
    mockFetch(() => ({ payload: run() }))
    await fetchDemoRun('run/../reset')
    expect(calls[0].url).toBe('/demo-api/runs/run%2F..%2Freset')
  })

  it('resets by POSTing /demo-api/reset', async () => {
    mockFetch(() => ({ status: 202, payload: run({ step_id: '5', kind: 'reset' }) }))
    const reset = await resetDemo()
    expect(calls[0]).toMatchObject({ url: '/demo-api/reset', method: 'POST' })
    expect(reset.kind).toBe('reset')
  })

  it('names the endpoint and carries the server body into the error', async () => {
    mockFetch(() => ({ status: 409, text: 'a run is already active' }))
    await expect(startDemoRun('1')).rejects.toThrow(/Demo step 1 failed: 409 — a run is already active/)
  })

  it('reports an unreachable runner rather than returning empty status', async () => {
    mockFetch(() => ({ status: 404, text: 'not found' }))
    await expect(fetchDemoStatus()).rejects.toThrow(/Demo status failed: 404/)
  })
})

describe('demoRunner run predicates', () => {
  it('treats only running as active', () => {
    expect(isRunActive(run({ status: 'running' }))).toBe(true)
    for (const status of ['succeeded', 'failed', 'cancelled', 'timed_out'] as const) {
      expect(isRunActive(run({ status }))).toBe(false)
    }
    expect(isRunActive(null)).toBe(false)
  })

  it('treats failed, timed_out and cancelled as failures the instructor must see', () => {
    for (const status of ['failed', 'timed_out', 'cancelled'] as const) {
      expect(isRunFailure(run({ status }))).toBe(true)
    }
    expect(isRunFailure(run({ status: 'succeeded' }))).toBe(false)
    expect(isRunFailure(run({ status: 'running' }))).toBe(false)
    expect(isRunFailure(null)).toBe(false)
  })

  it('names the real Makefile target for each phase', () => {
    expect(makeCommandForStep('3')).toBe('make demo-signalloom-supercred-3')
  })
})
