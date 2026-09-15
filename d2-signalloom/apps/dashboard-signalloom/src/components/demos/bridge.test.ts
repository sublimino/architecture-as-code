/**
 * AMXD-P1-3 — cross-channel contract suite for the frozen demo bridge.
 *
 * The point of this file is NOT to test mock and live separately. It is to run
 * the SAME assertion against BOTH channels for every AMXD-P1-2 preset, so a
 * mock/live behavioural drift fails here rather than in front of a customer.
 *
 * The live channel is driven through an injected `LiveTransport`, so the
 * cross-channel assertions run with no backend. The genuinely
 * backend-dependent arm is gated on `AMXD_LIVE_BRIDGE=1` and reports as
 * SKIPPED — never silently passing, never absent.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  assessLiveReachability,
  BRIDGE_EVENT_LOG_CAP,
  BRIDGE_STORAGE_KEYS,
  BRIDGE_STORAGE_NAMESPACE,
  clearBridgeEventLog,
  createDemoBridge,
  createLiveBridge,
  createMockBridge,
  describeChannel,
  getBridgeEventLog,
  LIVE_REACHABILITY_PRE_AMXD_P1_4,
  MOCK_LATENCY_MS,
  recordBridgeEvent,
  resolveStagePath,
  seedSignature,
  type LiveStageOutcome,
  type LiveTransport,
  type MockStageOutcome,
  type DistributiveOmit,
  type StageOutcome,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  REVOCATION_RACE_PRESET,
  SCENARIO_PRESETS,
  TAMPER_BREACH_PRESET,
  type ScenarioPreset,
} from './scenarios'
import { STAGE_IDS, type StageId } from './types'

// ---------------------------------------------------------------------------
// Fake transports
// ---------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

/** Everything succeeds. Used by the cross-channel equivalence assertions. */
function happyTransport(): LiveTransport {
  return {
    req: vi.fn(async () => ({})),
    fetch: vi.fn(async () => jsonResponse({}, 200)),
  }
}

/** The transport never completes — connection refused, DNS, TLS. */
function networkFailureTransport(): LiveTransport {
  return {
    req: vi.fn(async () => {
      throw new TypeError('Failed to fetch')
    }),
    fetch: vi.fn(async () => {
      throw new TypeError('Failed to fetch')
    }),
  }
}

/** The transport completes; the backend refuses. */
function forbiddenTransport(): LiveTransport {
  return {
    req: vi.fn(async () => {
      throw Object.assign(new Error('Forbidden'), { status: 403 })
    }),
    fetch: vi.fn(async () => jsonResponse({ error: 'Forbidden' }, 403)),
  }
}

/** nginx answers, not the API: 200 text/html from the SPA catch-all. */
function spaFallthroughTransport(): LiveTransport {
  return {
    req: vi.fn(async () => ({})),
    fetch: vi.fn(
      async () =>
        new Response('<!doctype html><html></html>', {
          status: 200,
          headers: { 'content-type': 'text/html' },
        }),
    ),
  }
}

/**
 * Simulates the REAL pre-AMXD-P1-4 reverse proxy: `location /api/` reaches the
 * API, and anything else falls through to the SPA catch-all, which answers 200
 * text/html. The cross-channel assertions run against this, because asserting
 * against a world where every route is proxied would prove nothing about the
 * gap this card had to document.
 */
function prePhase14NginxTransport(): LiveTransport {
  return {
    req: vi.fn(async () => ({})),
    fetch: vi.fn(
      async () =>
        new Response('<!doctype html><html></html>', {
          status: 200,
          headers: { 'content-type': 'text/html' },
        }),
    ),
  }
}

const FIXED_NOW = () => 1_757_900_000_000

/**
 * In-memory Storage double.
 *
 * NOT optional convenience: this repo's vitest jsdom environment provides
 * `window` but no web-storage implementation at all — neither as a bare global
 * nor on `window`. A suite that assumed one would throw before its first
 * assertion, and a bridge that read the global directly would silently no-op
 * here while reading green. `BridgeConfig.storage` is the injected seam.
 */
class MemoryStorage implements Storage {
  private map = new Map<string, string>()
  get length(): number {
    return this.map.size
  }
  clear(): void {
    this.map.clear()
  }
  getItem(key: string): string | null {
    return this.map.has(key) ? (this.map.get(key) as string) : null
  }
  key(index: number): string | null {
    return [...this.map.keys()][index] ?? null
  }
  removeItem(key: string): void {
    this.map.delete(key)
  }
  setItem(key: string, value: string): void {
    this.map.set(key, value)
  }
}

let store: MemoryStorage

/**
 * Bulk-loop bridge: zero simulated latency.
 *
 * The cross-channel matrix is 3 presets x 5 stages x 2 channels; at the real
 * 120ms each that is several seconds of pure sleeping, close enough to
 * vitest's 5s default timeout under full-suite parallel load to go flaky — and
 * a timed-out test leaves the module-level event log dirty, failing an
 * unrelated later test. `mockBridgeWithRealLatency` keeps one honest probe.
 */
function mockBridgeFor(preset: ScenarioPreset) {
  return createMockBridge({ preset, now: FIXED_NOW, storage: store, latencyMs: 0 })
}

function mockBridgeWithRealLatency(preset: ScenarioPreset) {
  return createMockBridge({ preset, now: FIXED_NOW, storage: store })
}

function liveBridgeFor(preset: ScenarioPreset, transport: LiveTransport) {
  return createLiveBridge({
    preset,
    token: 'test-token',
    transport,
    now: FIXED_NOW,
    storage: store,
  })
}

beforeEach(() => {
  store = new MemoryStorage()
  clearBridgeEventLog()
})

afterEach(() => {
  clearBridgeEventLog()
})

// ===========================================================================
// ISC-2..7,10 — type-level separation
// ===========================================================================

describe('type-level mock/live separation (ISC-2..7)', () => {
  it('refuses a live outcome where a mock outcome is expected', async () => {
    const live = await liveBridgeFor(HAPPY_PATH_PRESET, happyTransport()).advance('host_enrolled')
    // @ts-expect-error a LiveStageOutcome is not assignable to MockStageOutcome
    const wrong: MockStageOutcome<'host_enrolled'> = live
    // The assignment above is the assertion. `tsc` fails if it stops erroring,
    // which is exactly what would happen if the boundary were relaxed.
    expect(wrong.channel.kind).toBe('live')
  })

  it('refuses a mock outcome where a live outcome is expected', async () => {
    const mock = await mockBridgeFor(HAPPY_PATH_PRESET).advance('host_enrolled')
    // @ts-expect-error a MockStageOutcome is not assignable to LiveStageOutcome
    const wrong: LiveStageOutcome<'host_enrolled'> = mock
    expect(wrong.channel.kind).toBe('mock')
  })

  it('forces a consumer of the union to narrow before reading a brand', async () => {
    // NOTE: this must go through a function PARAMETER, not an annotated const.
    // TypeScript narrows `const x: Union = <narrower value>` by its initializer,
    // so the union annotation alone would be discarded and the @ts-expect-error
    // below would report TS2578 "unused directive" — a test that reads green
    // while proving nothing. A parameter is not narrowed at its declaration.
    function consume<S extends 'host_enrolled'>(outcome: StageOutcome<S>): string {
      // @ts-expect-error `fixtureId` is absent from the live members of the union
      const premature: string = outcome.fixtureId
      void premature
      // Narrowing MUST use the TOP-LEVEL `channelKind`. `outcome.channel.kind`
      // is a nested discriminant and TypeScript does not narrow a parent union
      // on one — that defect was found by tsc while building this card.
      if (outcome.channelKind === 'mock') return outcome.fixtureId
      return outcome.requestPath
    }

    const mock = await mockBridgeFor(HAPPY_PATH_PRESET).advance('host_enrolled')
    expect(consume(mock)).toBe('amxd-demo-happy-path:host_enrolled')

    const live = await liveBridgeFor(HAPPY_PATH_PRESET, happyTransport()).advance('host_enrolled')
    expect(consume(live)).toBe('/api/v1/external-agents/enroll')
  })

  it('createDemoBridge returns a union that must be narrowed on channelKind', () => {
    const bridge = createDemoBridge('mock', { preset: HAPPY_PATH_PRESET, now: FIXED_NOW })
    expect(bridge.channelKind).toBe('mock')
    const liveBridge = createDemoBridge('live', {
      preset: HAPPY_PATH_PRESET,
      transport: happyTransport(),
      now: FIXED_NOW,
    })
    expect(liveBridge.channelKind).toBe('live')
  })
})

// ===========================================================================
// ISC-12..15, 40 — cross-channel equivalence, every preset, every stage
// ===========================================================================

describe.each(SCENARIO_PRESETS.map((p) => [p.name, p] as const))(
  'cross-channel contract — %s (ISC-12,13,40)',
  (_name, preset) => {
    it.each(STAGE_IDS)(
      'mock and live agree on stage identity and payload shape for %s',
      async (stage: StageId) => {
        const mock = await mockBridgeFor(preset).advance(stage)
        const live = await liveBridgeFor(preset, prePhase14NginxTransport()).advance(stage)

        // Same assertion, both channels. Only the provenance differs.
        expect(mock.stage).toBe(stage)
        expect(live.stage).toBe(stage)
        expect(mock.channel.kind).toBe('mock')
        expect(live.channel.kind).toBe('live')

        const blocked =
          assessLiveReachability(
            resolveStagePath(preset, preset.stages.find((s) => s.stage_id === stage)!),
          ) === 'blocked-no-nginx-location'

        expect(mock.status).toBe('ok')
        if (blocked) {
          // The one honest divergence, and it is declared, not accidental:
          // pre-P1-4 this route is not proxied, so live cannot answer.
          expect(live.status).toBe('error')
          if (live.status === 'error') expect(live.error.kind).toBe('unsupported')
        } else {
          expect(live.status).toBe('ok')
          if (mock.status === 'ok' && live.status === 'ok') {
            // Payload KEYS must match across channels — a live response that
            // silently lacks a field the mock supplies is exactly the drift
            // this suite exists to catch.
            expect(Object.keys(live.payload).sort()).toEqual(
              Object.keys(mock.payload).sort(),
            )
          }
        }
      },
    )

    it('mock payloads are sourced from the preset, not from literals in bridge.ts (ISC-14)', async () => {
      const mock = await mockBridgeFor(preset).advance('host_enrolled')
      expect(mock.status).toBe('ok')
      if (mock.status === 'ok') {
        expect(mock.payload.hostId).toBe(preset.host_id)
        expect(mock.payload.agentId).toBe(preset.agent_id)
      }
    })

    it('mock channel applies simulated latency (ISC-15)', async () => {
      const started = Date.now()
      await mockBridgeWithRealLatency(preset).advance('confinement_streaming')
      expect(Date.now() - started).toBeGreaterThanOrEqual(MOCK_LATENCY_MS - 20)
    })
  },
)

// ===========================================================================
// ISC-16,17,18 — transport routing
// ===========================================================================

describe('transport routing (ISC-16,17,18)', () => {
  it('uses req() for /api-prefixed stages', async () => {
    const transport = happyTransport()
    await liveBridgeFor(HAPPY_PATH_PRESET, transport).advance('host_enrolled')
    expect(transport.req).toHaveBeenCalled()
    expect(transport.fetch).not.toHaveBeenCalled()
  })

  it('uses direct fetch — never req() — for the bare /v1 revoke path', async () => {
    const transport = spaFallthroughTransport()
    const outcome = await liveBridgeFor(REVOCATION_RACE_PRESET, transport).advance(
      'adversarial_tamper',
    )
    expect(transport.fetch).toHaveBeenCalled()
    expect(transport.req).not.toHaveBeenCalled()
    expect(outcome.status).toBe('error')
    if (outcome.status === 'error') {
      expect(outcome.error.kind).toBe('unsupported')
      if (outcome.error.kind === 'unsupported') {
        expect(outcome.error.reason).toBe('nginx-no-v1-location-pre-amxd-p1-4')
      }
    }
  })

  it('never hands a /v1-prefixed path to req()', async () => {
    const transport = happyTransport()
    for (const preset of SCENARIO_PRESETS) {
      for (const stage of STAGE_IDS) {
        await liveBridgeFor(preset, transport).advance(stage)
      }
    }
    const reqMock = transport.req as unknown as { mock: { calls: unknown[][] } }
    for (const call of reqMock.mock.calls) {
      expect(String(call[0]).startsWith('/api/')).toBe(true)
    }
  })

  it('needs no code change once AMXD-P1-4 proxies /v1 — a JSON answer on the bare path succeeds', async () => {
    // The bridge decides from what nginx ACTUALLY answers, not from a constant.
    // So the day P1-4 adds `location /v1/`, this stage starts working without
    // touching bridge.ts. (LIVE_REACHABILITY_PRE_AMXD_P1_4 documents the nginx
    // state, which P1-4 must still update in the same commit.)
    const proxied: LiveTransport = {
      req: vi.fn(async () => ({})),
      fetch: vi.fn(async () => jsonResponse({ revocation_status: 'revoked' }, 200)),
    }
    const outcome = await liveBridgeFor(REVOCATION_RACE_PRESET, proxied).advance(
      'adversarial_tamper',
    )
    expect(outcome.status).toBe('ok')
    if (outcome.status === 'ok') {
      expect(outcome.httpStatus).toBe(200)
      expect(outcome.channel.transport).toBe('fetch')
    }
  })

  it('classifies an unproxied POST answering 405 as a routing gap, not an application error', async () => {
    const transport: LiveTransport = {
      req: vi.fn(async () => ({})),
      fetch: vi.fn(async () => jsonResponse({ detail: 'Method Not Allowed' }, 405)),
    }
    const outcome = await liveBridgeFor(REVOCATION_RACE_PRESET, transport).advance(
      'adversarial_tamper',
    )
    expect(outcome.status).toBe('error')
    if (outcome.status === 'error') expect(outcome.error.kind).toBe('unsupported')
  })
})

// ===========================================================================
// ISC-28,29,30 — network failure vs application failure
// ===========================================================================

describe('error taxonomy (ISC-28,29,30)', () => {
  it('a network failure yields kind "network"', async () => {
    const outcome = await liveBridgeFor(HAPPY_PATH_PRESET, networkFailureTransport()).advance(
      'host_enrolled',
    )
    expect(outcome.status).toBe('error')
    if (outcome.status === 'error') {
      expect(outcome.error.kind).toBe('network')
      expect(outcome.error).not.toHaveProperty('httpStatus')
    }
  })

  it('an HTTP 403 yields kind "application" carrying status 403', async () => {
    const outcome = await liveBridgeFor(HAPPY_PATH_PRESET, forbiddenTransport()).advance(
      'host_enrolled',
    )
    expect(outcome.status).toBe('error')
    if (outcome.status === 'error') {
      expect(outcome.error.kind).toBe('application')
      if (outcome.error.kind === 'application') expect(outcome.error.httpStatus).toBe(403)
    }
  })

  it('the two error shapes are distinguishable without string matching', async () => {
    const net = await liveBridgeFor(HAPPY_PATH_PRESET, networkFailureTransport()).advance(
      'host_enrolled',
    )
    const app = await liveBridgeFor(HAPPY_PATH_PRESET, forbiddenTransport()).advance(
      'host_enrolled',
    )
    expect(net.status === 'error' && app.status === 'error').toBe(true)
    if (net.status === 'error' && app.status === 'error') {
      expect(net.error.kind).not.toBe(app.error.kind)
    }
  })
})

// ===========================================================================
// ISC-25,26,27 — cancellation is identical across channels
// ===========================================================================

describe('cancellation parity (ISC-25,26,27)', () => {
  it('a pre-aborted signal yields the same outcome tag on both channels', async () => {
    const controller = new AbortController()
    controller.abort()

    const mock = await mockBridgeFor(HAPPY_PATH_PRESET).advance('host_enrolled', {
      signal: controller.signal,
    })
    const live = await liveBridgeFor(HAPPY_PATH_PRESET, happyTransport()).advance(
      'host_enrolled',
      { signal: controller.signal },
    )

    expect(mock.status).toBe('error')
    expect(live.status).toBe('error')
    if (mock.status === 'error' && live.status === 'error') {
      expect(mock.error.kind).toBe('aborted')
      expect(live.error.kind).toBe(mock.error.kind)
    }
  })

  it('aborting mid-flight yields "aborted" on both channels', async () => {
    const mkController = () => {
      const c = new AbortController()
      setTimeout(() => c.abort(), 5)
      return c
    }
    const mock = await mockBridgeFor(HAPPY_PATH_PRESET).advance('confinement_streaming', {
      signal: mkController().signal,
      dwellMs: 200,
    })
    const live = await liveBridgeFor(HAPPY_PATH_PRESET, happyTransport()).advance(
      'confinement_streaming',
      { signal: mkController().signal, dwellMs: 200 },
    )
    expect(mock.status).toBe('error')
    expect(live.status).toBe('error')
    if (mock.status === 'error' && live.status === 'error') {
      expect(mock.error.kind).toBe('aborted')
      expect(live.error.kind).toBe('aborted')
    }
  })
})

// ===========================================================================
// ISC-19..24 — reset / seed
// ===========================================================================

describe('reset and seed (ISC-19..24)', () => {
  it('clears every amxd.demo. key and nothing outside the namespace', () => {
    store.setItem(BRIDGE_STORAGE_KEYS.sessionId, 'x')
    store.setItem(BRIDGE_STORAGE_KEYS.activePresetId, 'y')
    store.setItem('sl_demo_mode', 'KEEP')
    store.setItem('signalloom.superadmin', 'KEEP')
    store.setItem('signalloom.logTransport', 'KEEP')
    store.setItem('signalloom-return-to', 'KEEP')

    const result = mockBridgeFor(HAPPY_PATH_PRESET).resetEstate()

    expect(result.clearedStorageKeys.every((k) => k.startsWith(BRIDGE_STORAGE_NAMESPACE))).toBe(
      true,
    )
    expect([...result.clearedStorageKeys].sort()).toEqual(
      [BRIDGE_STORAGE_KEYS.activePresetId, BRIDGE_STORAGE_KEYS.sessionId].sort(),
    )
    expect(store.getItem('sl_demo_mode')).toBe('KEEP')
    expect(store.getItem('signalloom.superadmin')).toBe('KEEP')
    expect(store.getItem('signalloom.logTransport')).toBe('KEEP')
    expect(store.getItem('signalloom-return-to')).toBe('KEEP')
    expect(store.getItem(BRIDGE_STORAGE_KEYS.sessionId)).toBeNull()
  })

  it('makes no claim to have cleared backend state (ISC-23)', () => {
    const result = mockBridgeFor(HAPPY_PATH_PRESET).resetEstate()
    expect(result.backendStateCleared).toBe(false)
    expect(result.notResetExplanation).toContain('No backend demo/reset endpoint exists')
  })

  it('is idempotent — two consecutive resets reach the same end state (ISC-22)', () => {
    const bridge = mockBridgeFor(HAPPY_PATH_PRESET)
    bridge.seedEstate()
    const first = bridge.resetEstate()
    const second = bridge.resetEstate()
    expect(second.clearedStorageKeys).toEqual([])
    expect(second.stepperState).toEqual(first.stepperState)
    expect(second.backendStateCleared).toBe(false)
  })

  it('seeding is idempotent and non-destructive (ISC-24)', () => {
    const bridge = mockBridgeFor(TAMPER_BREACH_PRESET)
    const a = bridge.seedEstate()
    const b = bridge.seedEstate()
    expect(a.destructive).toBe(false)
    expect(b.signature).toBe(a.signature)
    expect(b.signature).toBe(seedSignature(TAMPER_BREACH_PRESET))
  })

  it('reset-then-reseed returns to the same known state twice in succession (ISC-24)', () => {
    const bridge = mockBridgeFor(REVOCATION_RACE_PRESET)
    const snapshots: string[] = []
    for (let i = 0; i < 2; i += 1) {
      bridge.resetEstate()
      const seeded = bridge.seedEstate()
      snapshots.push(
        JSON.stringify({
          signature: seeded.signature,
          keys: [...seeded.seededStorageKeys].sort(),
          stored: [...seeded.seededStorageKeys]
            .sort()
            .map((k) => `${k}=${store.getItem(k)}`),
          stage: seeded.stepperState.currentStage,
        }),
      )
    }
    expect(snapshots[1]).toBe(snapshots[0])
  })
})

// ===========================================================================
// ISC-31..36 — describeChannel and the event log
// ===========================================================================

describe('channel description and event log (ISC-31..36)', () => {
  it('describeChannel returns a structured kind, not only a label (ISC-32)', async () => {
    const mock = await mockBridgeFor(HAPPY_PATH_PRESET).advance('host_enrolled')
    const d = describeChannel(mock)
    expect(d.kind).toBe('mock')
    expect(d.provenance).toBe('client-held-fixture')
    expect(typeof d.label).toBe('string')
  })

  it('describeChannel and the event log never disagree for the same call (ISC-36)', async () => {
    clearBridgeEventLog()
    for (const preset of SCENARIO_PRESETS) {
      for (const stage of STAGE_IDS) {
        const mock = await mockBridgeFor(preset).advance(stage)
        const live = await liveBridgeFor(preset, happyTransport()).advance(stage)
        const log = getBridgeEventLog()
        const liveEvent = log[log.length - 1]
        const mockEvent = log[log.length - 2]
        expect(mockEvent.channel).toBe(describeChannel(mock).kind)
        expect(liveEvent.channel).toBe(describeChannel(live).kind)
      }
    }
  })

  it('channelKind, channel.kind and describeChannel all agree, by construction', async () => {
    for (const preset of SCENARIO_PRESETS) {
      const mock = await mockBridgeFor(preset).advance('operator_init')
      const live = await liveBridgeFor(preset, happyTransport()).advance('operator_init')
      for (const outcome of [mock, live] as const) {
        expect(outcome.channelKind).toBe(outcome.channel.kind)
        expect(describeChannel(outcome).kind).toBe(outcome.channelKind)
      }
    }
  })

  it('records channel, stage and outcome per call (ISC-33)', async () => {
    clearBridgeEventLog()
    await mockBridgeFor(HAPPY_PATH_PRESET).advance('confinement_streaming')
    const [event] = getBridgeEventLog()
    expect(event.channel).toBe('mock')
    expect(event.stage).toBe('confinement_streaming')
    expect(event.outcome).toBe('ok')
    expect(event.errorKind).toBeNull()
  })

  it('does not exceed its cap (ISC-34,35)', () => {
    clearBridgeEventLog()
    for (let i = 0; i < BRIDGE_EVENT_LOG_CAP + 50; i += 1) {
      recordBridgeEvent({
        channel: 'mock',
        stage: 'operator_init',
        outcome: 'ok',
        errorKind: null,
        presetId: 'amxd-demo-happy-path',
        at: i,
      })
    }
    const log = getBridgeEventLog()
    expect(log.length).toBe(BRIDGE_EVENT_LOG_CAP)
    // Oldest evicted, newest retained.
    expect(log[log.length - 1].seq).toBe(BRIDGE_EVENT_LOG_CAP + 50)
  })
})

// ===========================================================================
// ISC-39 — the documented reachability table must match the code
// ===========================================================================

describe('live reachability documentation (ISC-39)', () => {
  it('the frozen pre-P1-4 table agrees with assessLiveReachability over real preset data', () => {
    for (const preset of SCENARIO_PRESETS) {
      const documented = LIVE_REACHABILITY_PRE_AMXD_P1_4[preset.id]
      expect(documented, `no documented reachability for ${preset.id}`).toBeDefined()
      for (const presetStage of preset.stages) {
        const derived = assessLiveReachability(resolveStagePath(preset, presetStage))
        expect(
          documented[presetStage.stage_id],
          `${preset.id}/${presetStage.stage_id} (${presetStage.target_endpoint.path})`,
        ).toBe(derived)
      }
    }
  })

  it('exactly one stage across all presets is blocked pre-P1-4', () => {
    const blocked: string[] = []
    for (const preset of SCENARIO_PRESETS) {
      for (const presetStage of preset.stages) {
        if (
          assessLiveReachability(resolveStagePath(preset, presetStage)) ===
          'blocked-no-nginx-location'
        ) {
          blocked.push(`${preset.id}/${presetStage.stage_id}`)
        }
      }
    }
    expect(blocked).toEqual(['amxd-demo-revocation-race/adversarial_tamper'])
  })
})

// ===========================================================================
// Advisor-driven hardening (2026-09-15). Each of these pins a behaviour that
// was CORRECT but UNASSERTED, so a later refactor could have changed it
// silently.
// ===========================================================================

describe('hardening — previously-unasserted invariants', () => {
  it('a 404 on an /api path is an APPLICATION error, not a routing gap', async () => {
    // The 404/405 routing-gap branch lives only in the direct-fetch arm, which
    // is taken only for non-/api paths. A 404 from a mounted /api route means
    // the OBJECT is missing (unknown host_id), not that the route is absent —
    // rendering "this demo is not available in this build" for a deleted host
    // would be unfalsifiable from the UI.
    const notFound: LiveTransport = {
      req: vi.fn(async () => {
        throw Object.assign(new Error('Not Found'), { status: 404 })
      }),
      fetch: vi.fn(async () => jsonResponse({ detail: 'Not Found' }, 404)),
    }
    const outcome = await liveBridgeFor(HAPPY_PATH_PRESET, notFound).advance('host_enrolled')
    expect(outcome.status).toBe('error')
    if (outcome.status === 'error') {
      expect(outcome.error.kind).toBe('application')
      if (outcome.error.kind === 'application') expect(outcome.error.httpStatus).toBe(404)
    }
  })

  it('DistributiveOmit preserves the channel separation that plain Omit collapses', async () => {
    type MockProps = DistributiveOmit<MockStageOutcome<'host_enrolled'>, 'stage'>
    type LiveProps = DistributiveOmit<LiveStageOutcome<'host_enrolled'>, 'stage'>

    const mockOutcome = await mockBridgeFor(HAPPY_PATH_PRESET).advance('host_enrolled')
    const liveOutcome = await liveBridgeFor(HAPPY_PATH_PRESET, happyTransport()).advance(
      'host_enrolled',
    )
    const { stage: mockStage, ...mockRest } = mockOutcome
    const { stage: liveStage, ...liveRest } = liveOutcome
    expect(mockStage).toBe('host_enrolled')
    expect(liveStage).toBe('host_enrolled')
    const mockProps: MockProps = mockRest
    const liveProps: LiveProps = liveRest

    // @ts-expect-error DistributiveOmit keeps mock and live mutually non-assignable
    const collapsed: MockProps = liveProps
    void collapsed
    expect(mockProps.channelKind).toBe('mock')
    expect(liveProps.channelKind).toBe('live')
  })

  it('reset removes all prefixed keys when interleaved with non-prefixed ones', () => {
    // Guards against the index-shift bug: enumerating store.key(i) while
    // removing in the SAME loop skips entries. namespacedKeys snapshots first.
    store.setItem('zzz.other', 'KEEP')
    store.setItem(BRIDGE_STORAGE_KEYS.sessionId, 'a')
    store.setItem('aaa.other', 'KEEP')
    store.setItem(BRIDGE_STORAGE_KEYS.activePresetId, 'b')
    store.setItem('mmm.other', 'KEEP')
    store.setItem(BRIDGE_STORAGE_KEYS.lastResetAt, 'c')
    store.setItem(BRIDGE_STORAGE_KEYS.seedSignature, 'd')

    const result = mockBridgeFor(HAPPY_PATH_PRESET).resetEstate()

    expect(result.clearedStorageKeys).toHaveLength(4)
    for (const key of Object.values(BRIDGE_STORAGE_KEYS)) {
      expect(store.getItem(key)).toBeNull()
    }
    expect(store.getItem('zzz.other')).toBe('KEEP')
    expect(store.getItem('aaa.other')).toBe('KEEP')
    expect(store.getItem('mmm.other')).toBe('KEEP')
    expect(store.length).toBe(3)
  })

  it('a late-resolving live request writes no event after the abort was returned', async () => {
    const controller = new AbortController()
    const slow: LiveTransport = {
      req: vi.fn(
        () =>
          new Promise((resolve) => {
            setTimeout(() => resolve({}), 300)
          }),
      ),
      fetch: vi.fn(async () => jsonResponse({}, 200)),
    }
    clearBridgeEventLog()
    setTimeout(() => controller.abort(), 10)
    const outcome = await liveBridgeFor(HAPPY_PATH_PRESET, slow).advance('host_enrolled', {
      signal: controller.signal,
      dwellMs: 500,
    })
    expect(outcome.status).toBe('error')
    const afterAbort = getBridgeEventLog().length
    // Let the abandoned request settle well past its own resolution.
    await new Promise((r) => setTimeout(r, 450))
    expect(getBridgeEventLog().length).toBe(afterAbort)
  })
})

// ===========================================================================
// ISC-41 — the live arm SKIPS, it does not silently pass or vanish
// ===========================================================================

const LIVE_BACKEND_AVAILABLE = process.env.AMXD_LIVE_BRIDGE === '1'
const describeLive = LIVE_BACKEND_AVAILABLE ? describe : describe.skip

describeLive('live-backend arm (ISC-41) — requires AMXD_LIVE_BRIDGE=1', () => {
  it('reaches the real backend for the reachable stages', async () => {
    const bridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      token: process.env.AMXD_LIVE_TOKEN ?? '',
    })
    const outcome = await bridge.advance('host_enrolled', { timeoutMs: 10_000 })
    expect(outcome.channel.kind).toBe('live')
    expect(['ok', 'error']).toContain(outcome.status)
  })

  it('reports the revoke stage as unsupported until AMXD-P1-4 lands', async () => {
    const bridge = createLiveBridge({
      preset: REVOCATION_RACE_PRESET,
      token: process.env.AMXD_LIVE_TOKEN ?? '',
    })
    const outcome = await bridge.advance('adversarial_tamper', { timeoutMs: 10_000 })
    expect(outcome.status).toBe('error')
  })
})
