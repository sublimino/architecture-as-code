/**
 * AgentMaxxing Demo Console: FROZEN mock/live bridge contract (AMXD-P1-3)
 *
 * =============================================================================
 * WHAT THIS IS
 * =============================================================================
 * The single seam between the demo console's UI (AMXD-P2-1 .. P5-1) and the two
 * places a stage transition's data can come from:
 *
 *   - the MOCK channel: client-held fixtures sourced from AMXD-P1-2's presets
 *   - the LIVE channel: real HTTP against the Signal Loom API
 *
 * The two channels never share a return type. `MockStageOutcome<S>` and
 * `LiveStageOutcome<S>` are mutually non-assignable for two independent
 * reasons, so weakening either one still fails to compile:
 *
 *   1. `channel.kind` is the literal `'mock'` vs the literal `'live'`.
 *   2. Mock outcomes carry a required `fixtureId`; live outcomes carry a
 *      required `httpStatus` / `requestPath`. Neither side has the other's.
 *
 * This is deliberately NOT the `client.ts` pattern. `client.ts:225` branches on
 * `isDemoMode()` inside `req()` and returns the same static type either way, so
 * after a refactor a fixture can silently become the value a live-mode caller
 * receives. `bridge.test.ts` pins the separation here with `@ts-expect-error`
 * assertions, which fail the ordinary `bun run typecheck` if the boundary is
 * ever relaxed.
 *
 * =============================================================================
 * LIVE REACHABILITY AFTER AMXD-P1-4 LANDED  (state as of 2026-09-15)
 * =============================================================================
 * `apps/dashboard-signalloom/nginx.conf` proxies `location /api/` AND
 * `location /v1/` to fe-signalloom-api (the `/v1/` block was added by
 * AMXD-P1-4 and lives at `nginx.conf:118`, passthrough via `$api$request_uri`
 * with `Authorization` forwarded). Anything not matching a proxy location
 * falls through to the SPA catch-all `location /`, which answers 200 with
 * `index.html`: a success status carrying a web page.
 *
 * Therefore, per preset stage (paths taken from AMXD-P1-2 `scenarios.ts`):
 *
 *   | Preset           | Stage                  | Path                                                  | Post-P1-4 |
 *   |------------------|------------------------|-------------------------------------------------------|-----------|
 *   | all three        | operator_init          | /api/v1/external-agents/registrations/{id}/token       | REACHABLE |
 *   | all three        | host_enrolled          | /api/v1/external-agents/enroll                         | REACHABLE |
 *   | all three        | confinement_streaming  | /api/v1/external-agents/evidence-uploads               | REACHABLE |
 *   | happy, tamper    | adversarial_tamper     | /api/v1/external-agents/evidence-uploads               | REACHABLE |
 *   | revocation-race  | adversarial_tamper     | /v1/external-agents/hosts/{host_id}/revoke             | REACHABLE |
 *   | happy, tamper    | revocation_denied      | /api/v1/agents/{agent_id}/external-evidence            | REACHABLE |
 *   | revocation-race  | revocation_denied      | /api/v1/external-agents/evidence-uploads               | REACHABLE |
 *
 * Every stage of every preset is now live-reachable. P4-2's revocation stage is
 * no longer blocked. The SPA-fallthrough detection below is retained anyway:
 * it is what stops a 200 `text/html` from masquerading as a successful
 * revocation if the proxy table ever regresses.
 *
 * REACHABILITY AND TRANSPORT ARE TWO DIFFERENT QUESTIONS. Do not conflate them
 * Note: AMXD-P1-GOV found that a single predicate answering both is a trap:
 *   - "Is this path proxied by nginx?"    -> `NGINX_PROXIED_API_PREFIXES`
 *   - "Which client transport carries it?" -> `REQ_TRANSPORT_PREFIXES`
 * Now that `/v1/` IS proxied, answering the transport question with the
 * reachability predicate would route the revoke through `client.ts`'s `req()`,
 * which auto-prefixes `/api` and produces `/api/v1/external-agents/hosts/...`
 * : a route FastAPI never registered. Only `/api/`-prefixed paths may use
 * `req()`; bare paths must use a direct `fetch`.
 *
 * Backend route provenance (verified by source inspection, not assumed):
 *   - `/v1/external-agents/hosts/{host_id}/revoke` is mounted ONLY on
 *     `v1_router` (`external_agent_registration.py:1231`). It was never added to
 *     `router` (`/api/v1/external-agents`), so routing it through `client.ts`'s
 *     `req()` (which auto-prefixes `/api` at `client.ts:241`) would call a path
 *     FastAPI never registered. The live channel uses a direct `fetch` for it,
 *     the same way `agentClaim.ts:111` does for its own bare paths.
 *
 * IF THE PROXY TABLE CHANGES AGAIN, THIS COMMENT AND `LIVE_REACHABILITY` MUST
 * BE UPDATED IN THE SAME COMMIT, but you will not be relying on that promise:
 * `bridge.test.ts` now parses `nginx.conf` itself and fails if
 * `NGINX_PROXIED_API_PREFIXES` disagrees with the real `location` blocks.
 *
 * =============================================================================
 * RESET / SEED: WHAT IS HONESTLY CLAIMED
 * =============================================================================
 * There is NO backend demo/reset or demo/seed HTTP endpoint. Verified:
 * `rg -n 'reset|seed'` over `external_agent_registration.py`,
 * `host_credential.py`, and `host_enrollment.py` returns exactly two matches:
 * `reset_external_agent_state()` (external_agent_registration.py:54) and
 * `reset_host_enrollment_state()` (host_enrollment.py:50). Both are
 * undecorated module-level functions that clear in-process dictionaries; neither
 * is mounted on any router; their only non-test caller is
 * `api_compat.py:2353 reset_tenant_state()`, whose docstring reads "Nothing in
 * the running application calls this."
 *
 * `resetEstate()` therefore clears ONLY state this console created: its own
 * `amxd.demo.`-namespaced localStorage keys, its in-memory bridge state, and its
 * event log. `ResetEstateResult.backendStateCleared` is typed as the literal
 * `false` so no future implementation can claim otherwise without a deliberate
 * type change. `seedEstate()` is IDEMPOTENT, not destructive: re-running it
 * mid-demo re-establishes the same known state and is safe in front of an
 * audience.
 *
 * =============================================================================
 * FROZEN vs OPEN
 * =============================================================================
 * See `BRIDGE-CONTRACT.md` in this directory. Changing anything listed as frozen
 * is a breaking-change decision for P2-1 .. P6-1, not a silent edit.
 */

import { req as defaultReq } from '../../api/client'
import {
  executeAsyncGate,
  INITIAL_STEPPER_STATE,
  STAGE_IDS,
  type AdversarialTamperPayload,
  type ConfinementStreamingPayload,
  type DemoStepperState,
  type HostEnrolledPayload,
  type OperatorInitPayload,
  type RevocationDeniedPayload,
  type StageId,
  type StagePayloadMap,
} from './types'
import type { PresetStage, ScenarioPreset } from './scenarios'

// ============================================================================
// 1. Channel descriptors: the discriminated union
// ============================================================================

/** Provenance tag for data produced by the client-held AMXD-P1-2 fixtures. */
export interface MockChannel {
  readonly kind: 'mock'
  /** Which AMXD-P1-2 preset the fixture came from. */
  readonly presetId: string
  /** Always `'preset'`. Present so a mock channel cannot be spelled by hand. */
  readonly fixtureSource: 'preset'
}

/** Provenance tag for data produced by a real HTTP call to the backend. */
export interface LiveChannel {
  readonly kind: 'live'
  /** The exact path called, after template substitution. */
  readonly requestPath: string
  /**
   * Which transport carried it. `'req'` = `client.ts`'s `req()` (auto-prefixes
   * `/api`); `'fetch'` = direct fetch, required for bare `/v1/` paths.
   */
  readonly transport: 'req' | 'fetch'
}

/**
 * The frozen channel discriminant. Every value this module returns carries one,
 * and every consumer that needs to know where data came from reads it from here
 * rather than inferring it.
 */
export type DemoChannel = MockChannel | LiveChannel

// ============================================================================
// 2. Error taxonomy: network failure is NOT application failure
// ============================================================================

/**
 * AMXD-P4-2's revocation panel must render "the backend is unreachable, try
 * again" differently from "the backend answered 403". A single `Error` type
 * makes that distinction unrecoverable downstream, so the bridge keeps them
 * apart at the type level.
 */
export type BridgeErrorKind = 'network' | 'application' | 'aborted' | 'unsupported'

/** Transport never completed: DNS, connection refused, TLS, timeout. */
export interface BridgeNetworkError {
  readonly kind: 'network'
  readonly message: string
  readonly cause?: string
}

/** Transport completed; the backend answered with a non-2xx status. */
export interface BridgeApplicationError {
  readonly kind: 'application'
  readonly httpStatus: number
  readonly message: string
  readonly bodyExcerpt?: string
}

/** The caller's AbortSignal fired. Identical shape on both channels. */
export interface BridgeAbortedError {
  readonly kind: 'aborted'
  readonly message: string
}

/**
 * The call could not honestly be attempted or its answer could not be trusted.
 * Distinct from `network` because nothing is wrong with the network: the route
 * is not wired up yet.
 */
export interface BridgeUnsupportedError {
  readonly kind: 'unsupported'
  /**
   * AMXD-P1-GOV: `'nginx-no-v1-location-pre-amxd-p1-4'` was replaced by
   * `'nginx-no-matching-location'`. The old literal named a specific card's
   * pending work as a permanent error vocabulary entry; once AMXD-P1-4 landed
   * it described a world that no longer exists, and an operator reading it
   * would chase a fix that is already in the tree.
   */
  readonly reason: 'nginx-no-matching-location' | 'spa-catch-all-fallthrough'
  readonly path: string
  readonly message: string
}

export type BridgeError =
  | BridgeNetworkError
  | BridgeApplicationError
  | BridgeAbortedError
  | BridgeUnsupportedError

// ============================================================================
// 3. Per-channel outcome types: mutually non-assignable by construction
// ============================================================================

export interface MockStageSuccess<S extends StageId> {
  /**
   * TOP-LEVEL DISCRIMINANT. TypeScript does not narrow a parent union on a
   * NESTED property, so `outcome.channel.kind === 'mock'` would not narrow
   * `outcome`. This field is what consumers switch on. It is a literal type,
   * as is `channel.kind`, so the two cannot hold different values.
   */
  readonly channelKind: 'mock'
  readonly channel: MockChannel
  readonly status: 'ok'
  readonly stage: S
  readonly payload: StagePayloadMap[S]
  /** MOCK-ONLY BRAND. The preset's declared status; no response was received. */
  readonly declaredHttpStatus: number
  /** MOCK-ONLY BRAND. Identifies the fixture that produced this value. */
  readonly fixtureId: string
}

export interface MockStageFailure<S extends StageId> {
  readonly channelKind: 'mock'
  readonly channel: MockChannel
  readonly status: 'error'
  readonly stage: S
  readonly error: BridgeError
  /** MOCK-ONLY BRAND. */
  readonly fixtureId: string
}

export interface LiveStageSuccess<S extends StageId> {
  readonly channelKind: 'live'
  readonly channel: LiveChannel
  readonly status: 'ok'
  readonly stage: S
  readonly payload: StagePayloadMap[S]
  /** LIVE-ONLY BRAND. A status actually returned by the backend. */
  readonly httpStatus: number
  /** LIVE-ONLY BRAND. */
  readonly requestPath: string
}

export interface LiveStageFailure<S extends StageId> {
  readonly channelKind: 'live'
  readonly channel: LiveChannel
  readonly status: 'error'
  readonly stage: S
  readonly error: BridgeError
  /** LIVE-ONLY BRAND. */
  readonly requestPath: string
}

export type MockStageOutcome<S extends StageId> = MockStageSuccess<S> | MockStageFailure<S>
export type LiveStageOutcome<S extends StageId> = LiveStageSuccess<S> | LiveStageFailure<S>

/**
 * The union. A consumer holding this is statically forced to narrow on
 * `outcome.channel.kind` before it can touch a channel-specific brand.
 */
export type StageOutcome<S extends StageId> = MockStageOutcome<S> | LiveStageOutcome<S>

/** Anything the bridge returns that carries provenance. */
export interface ChannelBearing {
  readonly channel: DemoChannel
}

/**
 * Use this instead of `Omit` when deriving a prop type from an outcome.
 *
 * `Omit` is NOT distributive over a union: `Omit<StageOutcome<S>, 'stage'>`
 * produces ONE object type with neither channel's brand and a widened
 * `channelKind`, silently collapsing the separation this contract exists to
 * enforce. `Partial` is worse: it makes mock and live mutually assignable
 * again. React prop plumbing reaches for both by reflex, so this helper is the
 * sanctioned form and `bridge.test.ts` pins that it preserves the boundary.
 */
export type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never

// ============================================================================
// 4. describeChannel: the ONE source of the mock-vs-live label
// ============================================================================

export interface ChannelDescriptor {
  /** Machine-readable. Panels branch on this, never on `label`. */
  readonly kind: 'mock' | 'live'
  /** Human-readable. Wording may change; nothing should string-match it. */
  readonly label: string
  /** Structured provenance for conditional styling. */
  readonly provenance: 'client-held-fixture' | 'live-backend'
  /** Where the value came from, for tooltips and the event drawer. */
  readonly origin: string
}

/**
 * Single shared source of the "this came from the mock fixture" vs "this came
 * from the live backend" distinction. Reads `source.channel.kind` (the same
 * field `recordBridgeEvent` records) so the label and the event log cannot
 * disagree for the same call. `bridge.test.ts` pins that invariant.
 */
export function describeChannel(source: ChannelBearing): ChannelDescriptor {
  if (source.channel.kind === 'mock') {
    return {
      kind: 'mock',
      label: 'Mock fixture',
      provenance: 'client-held-fixture',
      origin: `preset:${source.channel.presetId}`,
    }
  }
  return {
    kind: 'live',
    label: 'Live backend',
    provenance: 'live-backend',
    origin: `${source.channel.transport}:${source.channel.requestPath}`,
  }
}

// ============================================================================
// 5. Live reachability: derived from the real nginx rule, then pinned
// ============================================================================

export type LiveReachability = 'reachable' | 'blocked-no-nginx-location'

/**
 * The prefixes `nginx.conf` actually proxies to the API upstream: a
 * `location /api/` block and (since AMXD-P1-4) a `location /v1/` block.
 *
 * This list answers ONE question: "would nginx route this path to the API?"
 * It does NOT answer "which client transport should carry it": see
 * `REQ_TRANSPORT_PREFIXES`. Conflating the two was the live defect
 * AMXD-P1-GOV found: once `/v1/` became proxied, a shared predicate would
 * have promoted the revoke path onto `req()` and broken it.
 *
 * `bridge.test.ts` derives the expected value by parsing `nginx.conf`, so this
 * constant cannot drift from the proxy table the way it did between AMXD-P1-3
 * and AMXD-P1-4.
 */
export const NGINX_PROXIED_API_PREFIXES: readonly string[] = ['/api/', '/v1/']

/**
 * The prefixes that may be carried by `client.ts`'s `req()`, which
 * unconditionally auto-prefixes `/api` (`client.ts:241`). ONLY `/api/` paths
 * qualify. A bare `/v1/` path handed to `req()` becomes `/api/v1/...`, a route
 * FastAPI never registered: reachable through nginx, 404 at the app.
 */
export const REQ_TRANSPORT_PREFIXES: readonly string[] = ['/api/']

/** Derive reachability from the path, using the same rule nginx applies. */
export function assessLiveReachability(path: string): LiveReachability {
  return NGINX_PROXIED_API_PREFIXES.some((p) => path.startsWith(p))
    ? 'reachable'
    : 'blocked-no-nginx-location'
}

/**
 * Which transport must carry this path. Deliberately NOT derived from
 * `assessLiveReachability`: reachability and transport are independent.
 */
export function selectTransport(path: string): 'req' | 'fetch' {
  return REQ_TRANSPORT_PREFIXES.some((p) => path.startsWith(p)) ? 'req' : 'fetch'
}

export interface StageReachability {
  readonly presetId: string
  readonly stage: StageId
  readonly path: string
  readonly reachability: LiveReachability
}

/**
 * The current answer, frozen here so P2 .. P4 can read it without re-deriving
 * the nginx table. `bridge.test.ts` asserts every entry agrees with
 * `assessLiveReachability()` run over the live preset data AND that
 * `NGINX_PROXIED_API_PREFIXES` agrees with `nginx.conf` itself: the second
 * assertion is the one that matters, because the first alone is satisfied by
 * two copies of the same wrong answer.
 *
 * Dated against the nginx state at 2026-09-15, AFTER AMXD-P1-4 added
 * `location /v1/` (`nginx.conf:118`). Every stage is now reachable.
 *
 * Renamed from `LIVE_REACHABILITY_PRE_AMXD_P1_4` by AMXD-P1-GOV: the old name
 * asserted a precondition that no longer holds, and a name that lies is worse
 * than no name. No consumer outside this module and its tests existed at the
 * time of the rename (AMXD-P2-1 had not started).
 */
export const LIVE_REACHABILITY: Readonly<
  Record<string, Readonly<Record<StageId, LiveReachability>>>
> = {
  'amxd-demo-happy-path': {
    operator_init: 'reachable',
    host_enrolled: 'reachable',
    confinement_streaming: 'reachable',
    adversarial_tamper: 'reachable',
    revocation_denied: 'reachable',
  },
  'amxd-demo-tamper-breach': {
    operator_init: 'reachable',
    host_enrolled: 'reachable',
    confinement_streaming: 'reachable',
    adversarial_tamper: 'reachable',
    revocation_denied: 'reachable',
  },
  'amxd-demo-revocation-race': {
    operator_init: 'reachable',
    host_enrolled: 'reachable',
    confinement_streaming: 'reachable',
    // POST /v1/external-agents/hosts/{host_id}/revoke: mounted on v1_router
    // only. AMXD-P1-4 added `location /v1/` (nginx.conf:118), so nginx now
    // routes it to fe-signalloom-api. It still requires the `fetch` transport,
    // not `req()`: see REQ_TRANSPORT_PREFIXES.
    adversarial_tamper: 'reachable',
    revocation_denied: 'reachable',
  },
}

// ============================================================================
// 6. Bridge-owned localStorage namespace
// ============================================================================

/**
 * Every key this bridge writes lives under this prefix. Deliberately distinct
 * from the keys other dashboard features already own: `sl_demo_mode`
 * (`api/demoMode.ts:11`), `signalloom.superadmin`, `signalloom.logTransport`
 * (`api/demoRunner.ts:227`), `signalloom-return-to` (`auth/oidc.tsx:45`) and
 * `demoMode`, so a localStorage audit can attribute every key to its feature.
 */
export const BRIDGE_STORAGE_NAMESPACE = 'amxd.demo.' as const

export const BRIDGE_STORAGE_KEYS = {
  sessionId: 'amxd.demo.sessionId',
  activePresetId: 'amxd.demo.activePresetId',
  lastResetAt: 'amxd.demo.lastResetAt',
  seedSignature: 'amxd.demo.seedSignature',
} as const

/**
 * Guarded default accessor: the bridge must not throw where there is no DOM.
 *
 * Note this returns `null` more often than it looks: the repo's vitest jsdom
 * environment provides `window` but NO `localStorage` at all (neither as a bare
 * global nor on `window`). A bridge that only read the global would therefore
 * silently no-op under test while appearing to work, so `BridgeConfig.storage`
 * exists to inject a real one.
 */
function defaultStorage(): Storage | null {
  try {
    if (typeof localStorage !== 'undefined') return localStorage
  } catch {
    /* access can throw under strict privacy settings */
  }
  try {
    if (typeof window !== 'undefined' && window.localStorage) return window.localStorage
  } catch {
    /* same */
  }
  return null
}

function resolveStorage(config: BridgeConfig): Storage | null {
  return config.storage !== undefined ? config.storage : defaultStorage()
}

function namespacedKeys(store: Storage): string[] {
  const found: string[] = []
  for (let i = 0; i < store.length; i += 1) {
    const key = store.key(i)
    if (key !== null && key.startsWith(BRIDGE_STORAGE_NAMESPACE)) found.push(key)
  }
  return found
}

// ============================================================================
// 7. Capped in-memory event log
// ============================================================================

/**
 * Maximum retained bridge events. A conference-booth session runs for hours; an
 * unbounded array would grow without limit. AMXD-P6-1's acceptance spec reads
 * this log to assert which channel actually served a stage: if its assertion
 * window ever needs more than this, RAISE THE CAP rather than shortening the
 * spec.
 */
export const BRIDGE_EVENT_LOG_CAP = 200

export interface BridgeEvent {
  readonly seq: number
  /** Read from `outcome.channel.kind`: the same field `describeChannel` reads. */
  readonly channel: 'mock' | 'live'
  readonly stage: StageId | 'reset_estate' | 'seed_estate'
  readonly outcome: 'ok' | 'error'
  readonly errorKind: BridgeErrorKind | null
  readonly presetId: string
  readonly at: number
}

let eventLog: BridgeEvent[] = []
let eventSeq = 0

/** Append one event, evicting the oldest once the cap is reached. */
export function recordBridgeEvent(event: Omit<BridgeEvent, 'seq'>): BridgeEvent {
  eventSeq += 1
  const entry: BridgeEvent = { ...event, seq: eventSeq }
  eventLog.push(entry)
  if (eventLog.length > BRIDGE_EVENT_LOG_CAP) {
    eventLog = eventLog.slice(eventLog.length - BRIDGE_EVENT_LOG_CAP)
  }
  return entry
}

/** Newest-last snapshot of the retained events. */
export function getBridgeEventLog(): readonly BridgeEvent[] {
  return [...eventLog]
}

export function clearBridgeEventLog(): void {
  eventLog = []
  eventSeq = 0
}

function recordOutcome<S extends StageId>(
  outcome: StageOutcome<S>,
  presetId: string,
  at: number,
): BridgeEvent {
  return recordBridgeEvent({
    // Same discriminant describeChannel reads. One field, so they cannot differ.
    channel: outcome.channel.kind,
    stage: outcome.stage,
    outcome: outcome.status,
    errorKind: outcome.status === 'error' ? outcome.error.kind : null,
    presetId,
    at,
  })
}

// ============================================================================
// 8. Reset / seed contract
// ============================================================================

export interface ResetEstateResult extends ChannelBearing {
  readonly clearedStorageKeys: readonly string[]
  readonly clearedInMemoryKeys: readonly string[]
  /**
   * The active preset's declared `reset_contract.cleared_fields` (AMXD-P1-2).
   * This is the logical field scope a UI should render; `clearedStorageKeys` is
   * the physical storage scope this bridge actually purged. They answer
   * different questions and a panel that shows one while labelling it the other
   * is the defect AMXD-P1-GOV closed.
   */
  readonly clearedPresetFields: readonly string[]
  readonly stepperState: DemoStepperState
  /**
   * Typed as the literal `false`, not `boolean`. No backend demo/reset endpoint
   * exists (see the module header), so no implementation can ever claim to have
   * cleared backend state without changing this type, which is a reviewable
   * change, not a silent one.
   */
  readonly backendStateCleared: false
  /** Shown to the operator so nobody expects backend rows to have cleared. */
  readonly notResetExplanation: string
  readonly idempotent: true
}

const NOT_RESET_EXPLANATION =
  'Console-created state only. No backend demo/reset endpoint exists, so ' +
  'server-side rows created during a live-mode run are NOT cleared by this ' +
  'action and must be cleaned up out of band.'

export interface SeedEstateResult extends ChannelBearing {
  /**
   * Seeding is IDEMPOTENT. Re-running it mid-presentation re-establishes the
   * same known state; it never destroys anything a presenter would miss.
   */
  readonly destructive: false
  readonly idempotent: true
  readonly presetId: string
  readonly seededStorageKeys: readonly string[]
  readonly stepperState: DemoStepperState
  readonly signature: string
}

/**
 * Deterministic signature of the seeded state. Two seeds of the same preset
 * produce the same signature, which is how "returned to a known state twice in
 * succession" is asserted rather than asserted-by-eyeball.
 */
export function seedSignature(preset: ScenarioPreset): string {
  return [
    preset.schemaVersion,
    preset.id,
    preset.agent_id,
    preset.host_id,
    preset.tenant_id,
    preset.stages.map((s) => `${s.stage_id}:${s.expected_http_status}`).join(','),
  ].join('|')
}

// ============================================================================
// 9. Stage payload builders (mock) and adapters (live)
// ============================================================================

function fixtureString(stage: PresetStage, key: string, fallback: string): string {
  const raw = stage.payload_fixture?.[key]
  return typeof raw === 'string' ? raw : fallback
}

function fixtureNumber(stage: PresetStage, key: string, fallback: number): number {
  const raw = stage.payload_fixture?.[key]
  return typeof raw === 'number' ? raw : fallback
}

function fixtureBoolean(stage: PresetStage, key: string, fallback: boolean): boolean {
  const raw = stage.payload_fixture?.[key]
  return typeof raw === 'boolean' ? raw : fallback
}

/** Fixed clock so a mock run is reproducible from a cold start. */
const MOCK_CLOCK_ISO = '2026-09-15T02:00:00Z'

function buildOperatorInit(preset: ScenarioPreset, stage: PresetStage): OperatorInitPayload {
  const tokenId = fixtureString(stage, 'token_id', `${preset.id}-token`)
  return {
    tokenId,
    issuedAt: MOCK_CLOCK_ISO,
    ttlSeconds: fixtureNumber(stage, 'expires_in_seconds', 900),
    operatorId: preset.tenant_id,
    tokenPrefix: tokenId.slice(0, 12),
  }
}

function buildHostEnrolled(preset: ScenarioPreset, stage: PresetStage): HostEnrolledPayload {
  return {
    hostId: preset.host_id,
    agentId: preset.agent_id,
    publicKeyFingerprint: fixtureString(stage, 'key_id', `${preset.id}-key`),
    enrolledAt: MOCK_CLOCK_ISO,
    status: fixtureString(stage, 'status', 'enrolled') === 'enrolled' ? 'enrolled' : 'pending',
  }
}

function buildConfinementStreaming(
  preset: ScenarioPreset,
  stage: PresetStage,
): ConfinementStreamingPayload {
  const digest = fixtureString(stage, 'artifact_sha256', '0'.repeat(63))
  return {
    processComm: 'nono',
    cpuTicks: fixtureNumber(stage, 'cpu_time_ms', 0),
    rssBytes: fixtureNumber(stage, 'resident_memory_bytes', 0),
    openFds: fixtureNumber(stage, 'artifact_count', 3),
    expectedSha256: digest,
    observedSha256: digest,
    hashMatch: true,
    zeroPayloadVerified: true,
  }
}

function buildAdversarialTamper(
  preset: ScenarioPreset,
  stage: PresetStage,
): AdversarialTamperPayload {
  const injected = fixtureBoolean(stage, 'tamper_injected', false)
  const mockSite = preset.tamper_config?.mock_site
  const original = fixtureString(
    stage,
    'original_digest',
    mockSite?.original_value ?? '0'.repeat(63),
  )
  const tampered = fixtureString(
    stage,
    'tampered_digest',
    mockSite?.corrupted_value ?? original,
  )
  return {
    tamperType: 'hash_mismatch',
    injectedAt: MOCK_CLOCK_ISO,
    originalSha256: original,
    tamperedSha256: injected ? tampered : original,
    breachDetected: injected,
    containmentTriggered: injected,
    detectionLatencyMs: injected ? 12 : 0,
  }
}

function buildRevocationDenied(
  preset: ScenarioPreset,
  stage: PresetStage,
): RevocationDeniedPayload {
  const denied = stage.expected_http_status === 403
  return {
    hostId: preset.host_id,
    operatorAttribution:
      preset.revocation_config?.attribution_reason ??
      fixtureString(stage, 'reason', 'Operator initiated attributable revocation'),
    revokedAt: MOCK_CLOCK_ISO,
    attemptedEndpoint: stage.target_endpoint.path,
    responseStatusCode: 403,
    denialConfirmed: denied,
    proofDigest: `${preset.id}:${stage.stage_id}:403`,
  }
}

type PayloadBuilder = (preset: ScenarioPreset, stage: PresetStage) => StagePayloadMap[StageId]

const MOCK_STAGE_BUILDERS: Readonly<Record<StageId, PayloadBuilder>> = {
  operator_init: buildOperatorInit,
  host_enrolled: buildHostEnrolled,
  confinement_streaming: buildConfinementStreaming,
  adversarial_tamper: buildAdversarialTamper,
  revocation_denied: buildRevocationDenied,
}

// ============================================================================
// 10. Shared plumbing
// ============================================================================

export interface AdvanceOptions {
  /** Cancellation. Threaded identically into both channels' async gate. */
  readonly signal?: AbortSignal
  /** Minimum dwell before a transition may settle (AMXD-P1-1 dual-lock gate). */
  readonly dwellMs?: number
  readonly timeoutMs?: number
}

/**
 * How long a mock fixture pretends to be on the network, so the stepper cannot
 * tell the channels apart by feel. Matches `client.ts:62`'s `DEMO_LATENCY_MS`.
 */
export const MOCK_LATENCY_MS = 120

const DEFAULT_DWELL_MS = 0
const DEFAULT_TIMEOUT_MS = 30_000

function stageFor(preset: ScenarioPreset, stage: StageId): PresetStage {
  const found = preset.stages.find((s) => s.stage_id === stage)
  if (found === undefined) {
    throw new Error(`Preset '${preset.id}' has no stage '${stage}'`)
  }
  return found
}

/** Substitute `{agent_id}` / `{host_id}` / `{tenant_id}` from the preset. */
export function resolveStagePath(preset: ScenarioPreset, stage: PresetStage): string {
  return stage.target_endpoint.path
    .replace('{agent_id}', encodeURIComponent(preset.agent_id))
    .replace('{host_id}', encodeURIComponent(preset.host_id))
    .replace('{tenant_id}', encodeURIComponent(preset.tenant_id))
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted === true) {
      reject(new DOMException('Aborted', 'AbortError'))
      return
    }
    const id = setTimeout(resolve, ms)
    signal?.addEventListener(
      'abort',
      () => {
        clearTimeout(id)
        reject(new DOMException('Aborted', 'AbortError'))
      },
      { once: true },
    )
  })
}

function isAbortLike(value: unknown): boolean {
  if (value instanceof Error) {
    return value.name === 'AbortError' || value.name === 'CanceledError'
  }
  return false
}

// ============================================================================
// 11. Live transport: injectable so contract tests run without a backend
// ============================================================================

export interface LiveTransport {
  /**
   * `client.ts`'s `req()`. Auto-prefixes `/api`; never pass a `/v1/` path.
   *
   * Deliberately NOT generic. The bridge only ever consumes the body as
   * `unknown` and adapts it, and a generic member here cannot be satisfied by a
   * concrete test double: `Mock<() => Promise<{}>>` is not assignable to
   * `<T>(...) => Promise<T>`, because T could be instantiated with anything.
   * The real generic `req` remains assignable to this narrower shape.
   */
  req(
    path: string,
    token: string,
    config?: { method?: string; data?: unknown; signal?: AbortSignal },
  ): Promise<unknown>
  /** Direct fetch, for bare paths `req()` would mangle. */
  fetch(input: string, init?: RequestInit): Promise<Response>
}

export const defaultLiveTransport: LiveTransport = {
  req: defaultReq,
  fetch: (input, init) => fetch(input, init),
}

function toBridgeError(raw: unknown, path: string): BridgeError {
  if (isAbortLike(raw)) {
    return { kind: 'aborted', message: 'Transition aborted by operator' }
  }
  const status = extractStatus(raw)
  if (status !== null) {
    return {
      kind: 'application',
      httpStatus: status,
      message: raw instanceof Error ? raw.message : `Backend answered ${status}`,
    }
  }
  return {
    kind: 'network',
    message: raw instanceof Error ? raw.message : `Request to ${path} did not complete`,
    cause: raw instanceof Error ? raw.name : undefined,
  }
}

function extractStatus(raw: unknown): number | null {
  if (typeof raw !== 'object' || raw === null) return null
  const direct = (raw as { status?: unknown }).status
  if (typeof direct === 'number') return direct
  const nested = (raw as { response?: { status?: unknown } }).response?.status
  return typeof nested === 'number' ? nested : null
}

// ============================================================================
// 12. Bridge interfaces: the frozen public surface
// ============================================================================

export interface MockDemoBridge {
  readonly channelKind: 'mock'
  readonly preset: ScenarioPreset
  advance<S extends StageId>(stage: S, options?: AdvanceOptions): Promise<MockStageOutcome<S>>
  resetEstate(): ResetEstateResult
  seedEstate(): SeedEstateResult
  reachability(stage: StageId): LiveReachability
}

export interface LiveDemoBridge {
  readonly channelKind: 'live'
  readonly preset: ScenarioPreset
  advance<S extends StageId>(stage: S, options?: AdvanceOptions): Promise<LiveStageOutcome<S>>
  resetEstate(): ResetEstateResult
  seedEstate(): SeedEstateResult
  reachability(stage: StageId): LiveReachability
}

/**
 * A caller holding a `DemoBridge` is statically forced to narrow on
 * `channelKind` before it can consume a channel-specific outcome brand.
 */
export type DemoBridge = MockDemoBridge | LiveDemoBridge

export interface BridgeConfig {
  readonly preset: ScenarioPreset
  /** Bearer token for live calls. Ignored entirely by the mock channel. */
  readonly token?: string
  readonly transport?: LiveTransport
  /** Injectable clock, so reset/seed evidence is reproducible. */
  readonly now?: () => number
  /**
   * Injectable key-value store. Omit in the browser to use `localStorage`; pass
   * an in-memory double under test; pass `null` to disable persistence.
   */
  readonly storage?: Storage | null
  /**
   * Simulated mock-channel latency. Defaults to `MOCK_LATENCY_MS`.
   *
   * Injectable because a contract suite that sleeps for real is slow enough to
   * approach vitest's default 5s timeout once the whole dashboard suite is
   * running in parallel, and a timeout mid-test leaves module-level state
   * dirty, which then fails an unrelated later test. Set 0 in bulk loops; leave
   * it alone in the one test that asserts the default.
   */
  readonly latencyMs?: number
}

// ============================================================================
// 13. Shared reset / seed implementation
// ============================================================================

const IN_MEMORY_STATE_KEYS: readonly string[] = [
  'stepperState',
  'eventLog',
  'activePreset',
]

function doResetEstate(
  channel: DemoChannel,
  now: () => number,
  store: Storage | null,
  preset: ScenarioPreset,
): ResetEstateResult {
  const cleared = store === null ? [] : namespacedKeys(store)
  // Enumerated, not hardcoded: removes every amxd.demo. key and, by
  // construction, nothing outside the namespace.
  for (const key of cleared) store?.removeItem(key)
  clearBridgeEventLog()

  const at = now()
  recordBridgeEvent({
    channel: channel.kind,
    stage: 'reset_estate',
    outcome: 'ok',
    errorKind: null,
    presetId: channel.kind === 'mock' ? channel.presetId : channel.requestPath,
    at,
  })

  return {
    channel,
    clearedStorageKeys: cleared,
    clearedInMemoryKeys: IN_MEMORY_STATE_KEYS,
    // AMXD-P1-2 declares a per-preset `reset_contract.cleared_fields`. Until
    // AMXD-P1-GOV, nothing in this module read it: the three presets declared
    // three different scopes and `doResetEstate` implemented one universal one,
    // so the contract and the execution point described the same behaviour two
    // incompatible ways and no test compared them. Reporting the preset's own
    // declared list makes AMXD-P1-2's contract load-bearing instead of dead
    // data that a Phase 2 panel would render and be wrong about.
    clearedPresetFields: preset.reset_contract.cleared_fields,
    stepperState: INITIAL_STEPPER_STATE,
    backendStateCleared: false,
    notResetExplanation: NOT_RESET_EXPLANATION,
    idempotent: true,
  }
}

function doSeedEstate(
  channel: DemoChannel,
  preset: ScenarioPreset,
  now: () => number,
  store: Storage | null,
): SeedEstateResult {
  const signature = seedSignature(preset)
  const at = now()
  // Idempotent: the same preset always writes the same values to the same keys.
  const written: Record<string, string> = {
    [BRIDGE_STORAGE_KEYS.sessionId]: `${preset.id}-session`,
    [BRIDGE_STORAGE_KEYS.activePresetId]: preset.id,
    [BRIDGE_STORAGE_KEYS.seedSignature]: signature,
  }
  for (const [key, value] of Object.entries(written)) store?.setItem(key, value)

  recordBridgeEvent({
    channel: channel.kind,
    stage: 'seed_estate',
    outcome: 'ok',
    errorKind: null,
    presetId: preset.id,
    at,
  })

  return {
    channel,
    destructive: false,
    idempotent: true,
    presetId: preset.id,
    seededStorageKeys: Object.keys(written),
    stepperState: INITIAL_STEPPER_STATE,
    signature,
  }
}

// ============================================================================
// 14. Mock channel
// ============================================================================

export function createMockBridge(config: BridgeConfig): MockDemoBridge {
  const { preset } = config
  const now = config.now ?? (() => Date.now())
  const store = resolveStorage(config)
  const latencyMs = config.latencyMs ?? MOCK_LATENCY_MS
  const channel: MockChannel = {
    kind: 'mock',
    presetId: preset.id,
    fixtureSource: 'preset',
  }

  async function advance<S extends StageId>(
    stage: S,
    options?: AdvanceOptions,
  ): Promise<MockStageOutcome<S>> {
    const presetStage = stageFor(preset, stage)
    const fixtureId = `${preset.id}:${stage}`

    // Same dual-lock gate the live channel uses, with the same signal, so an
    // abandoned stage behaves identically whichever channel is active.
    const gate = await executeAsyncGate<StagePayloadMap[StageId]>({
      dwellMs: options?.dwellMs ?? DEFAULT_DWELL_MS,
      timeoutMs: options?.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      signal: options?.signal,
      confirmationPromise: async () => {
        await delay(latencyMs, options?.signal)
        return MOCK_STAGE_BUILDERS[stage](preset, presetStage)
      },
    })

    let outcome: MockStageOutcome<S>
    if (gate.status === 'resolved') {
      outcome = {
        channelKind: 'mock',
        channel,
        status: 'ok',
        stage,
        payload: gate.data as StagePayloadMap[S],
        declaredHttpStatus: presetStage.expected_http_status,
        fixtureId,
      }
    } else if (gate.status === 'aborted') {
      outcome = {
        channelKind: 'mock',
        channel,
        status: 'error',
        stage,
        error: { kind: 'aborted', message: gate.reason },
        fixtureId,
      }
    } else {
      outcome = {
        channelKind: 'mock',
        channel,
        status: 'error',
        stage,
        error: isAbortLike(gate.error)
          ? { kind: 'aborted', message: gate.reason }
          : { kind: 'network', message: gate.reason },
        fixtureId,
      }
    }

    recordOutcome(outcome, preset.id, now())
    return outcome
  }

  return {
    channelKind: 'mock',
    preset,
    advance,
    resetEstate: () => doResetEstate(channel, now, store, preset),
    seedEstate: () => doSeedEstate(channel, preset, now, store),
    reachability: (stage) => assessLiveReachability(resolveStagePath(preset, stageFor(preset, stage))),
  }
}

// ============================================================================
// 15. Live channel
// ============================================================================

/**
 * A 200 carrying `text/html` is the SPA catch-all answering, not the API. Pre
 * AMXD-P1-4 that is exactly what a bare `/v1/` path receives, and reading it as
 * a successful revocation is the worst available failure: a green badge for a
 * revocation that never happened.
 */
function looksLikeSpaFallthrough(res: Response): boolean {
  const contentType = res.headers.get('content-type') ?? ''
  return contentType.includes('text/html')
}

export function createLiveBridge(config: BridgeConfig): LiveDemoBridge {
  const { preset } = config
  const token = config.token ?? ''
  const transport = config.transport ?? defaultLiveTransport
  const now = config.now ?? (() => Date.now())
  const store = resolveStorage(config)

  async function callStage(
    presetStage: PresetStage,
    path: string,
    signal?: AbortSignal,
  ): Promise<{ body: unknown; httpStatus: number; usedTransport: 'req' | 'fetch' }> {
    const method = presetStage.target_endpoint.method

    // NOTE: transport is selected by `selectTransport`, NOT by reachability.
    // Since AMXD-P1-4 made `/v1/` reachable, a reachability-driven choice here
    // would send the revoke through req() and mangle it into /api/v1/...
    if (selectTransport(path) === 'req') {
      // `/api`-prefixed: goes through client.ts's req(), which is where the
      // dashboard's auth, demo projection, and in-flight joining already live.
      const body = await transport.req(path, token, {
        method,
        data: method === 'POST' ? (presetStage.payload_fixture ?? {}) : undefined,
        signal,
      })
      return { body, httpStatus: presetStage.expected_http_status, usedTransport: 'req' }
    }

    // Bare path. req() would prepend `/api` (client.ts:241) and produce a route
    // FastAPI never registered, so use a direct fetch exactly as
    // agentClaim.ts:111 does.
    const res = await transport.fetch(path, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: method === 'POST' ? JSON.stringify(presetStage.payload_fixture ?? {}) : undefined,
      signal,
    })
    // Two shapes of "nginx never routed this", and they look nothing alike.
    // A GET at an unproxied path falls to the SPA catch-all and answers 200
    // text/html. A POST at the same path cannot be served from static files, so
    // nginx answers 405 (and 404 where no file matches at all). Classifying
    // either as an ordinary application error would tell AMXD-P4-2's panel that
    // the backend refused the revocation, when in fact nothing ever reached it.
    const routingGapStatus = res.status === 404 || res.status === 405
    if (looksLikeSpaFallthrough(res) || routingGapStatus) {
      throw Object.assign(
        new Error(`Route not proxied; nginx answered ${res.status}`),
        { __routingGap: true, status: res.status },
      )
    }
    if (!res.ok) {
      throw Object.assign(new Error(`Backend answered ${res.status}`), { status: res.status })
    }
    return { body: await res.json(), httpStatus: res.status, usedTransport: 'fetch' }
  }

  async function advance<S extends StageId>(
    stage: S,
    options?: AdvanceOptions,
  ): Promise<LiveStageOutcome<S>> {
    const presetStage = stageFor(preset, stage)
    const requestPath = resolveStagePath(preset, presetStage)
    const reachability = assessLiveReachability(requestPath)
    const channel: LiveChannel = {
      kind: 'live',
      requestPath,
      transport: reachability === 'reachable' ? 'req' : 'fetch',
    }

    const gate = await executeAsyncGate<{
      body: unknown
      httpStatus: number
      usedTransport: 'req' | 'fetch'
    }>({
      dwellMs: options?.dwellMs ?? DEFAULT_DWELL_MS,
      timeoutMs: options?.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      signal: options?.signal,
      confirmationPromise: () => callStage(presetStage, requestPath, options?.signal),
    })

    let outcome: LiveStageOutcome<S>
    if (gate.status === 'resolved') {
      outcome = {
        channelKind: 'live',
        channel: { ...channel, transport: gate.data.usedTransport },
        status: 'ok',
        stage,
        // The backend's own shape is adapted onto the stage payload contract.
        // Where the backend does not supply a field, the preset's fixture is the
        // declared default: this is the ONLY place the two meet, and it is a
        // live outcome throughout.
        payload: adaptLivePayload(stage, preset, presetStage, gate.data.body),
        httpStatus: gate.data.httpStatus,
        requestPath,
      }
    } else if (gate.status === 'aborted') {
      outcome = {
        channelKind: 'live',
        channel,
        status: 'error',
        stage,
        error: { kind: 'aborted', message: gate.reason },
        requestPath,
      }
    } else {
      const raw: unknown = gate.error
      const routingGap =
        typeof raw === 'object' && raw !== null && '__routingGap' in raw
      outcome = {
        channelKind: 'live',
        channel,
        status: 'error',
        stage,
        error: routingGap
          ? {
              kind: 'unsupported',
              reason:
                reachability === 'reachable'
                  ? 'spa-catch-all-fallthrough'
                  : 'nginx-no-matching-location',
              path: requestPath,
              message:
                reachability === 'reachable'
                  ? `${requestPath} matches a proxied prefix but nginx did not route it ` +
                    'to the API; the SPA catch-all answered. Either the proxy table has ' +
                    'regressed or the upstream never registered this route.'
                  : `${requestPath} is not proxied by nginx; the SPA catch-all answered. ` +
                    'No `location` block matches this prefix.',
            }
          : toBridgeError(raw, requestPath),
        requestPath,
      }
    }

    recordOutcome(outcome, preset.id, now())
    return outcome
  }

  const channelForState: LiveChannel = {
    kind: 'live',
    requestPath: '(console-local)',
    transport: 'req',
  }

  return {
    channelKind: 'live',
    preset,
    advance,
    resetEstate: () => doResetEstate(channelForState, now, store, preset),
    seedEstate: () => doSeedEstate(channelForState, preset, now, store),
    reachability: (stage) => assessLiveReachability(resolveStagePath(preset, stageFor(preset, stage))),
  }
}

/**
 * Adapt a backend response onto the stage payload contract. Falls back to the
 * preset's declared values for fields the backend does not supply, but the
 * result is still a LIVE outcome, so a consumer can never mistake it for a mock
 * one: only `LiveStageSuccess` carries `httpStatus` and `requestPath`.
 */
function adaptLivePayload<S extends StageId>(
  stage: S,
  preset: ScenarioPreset,
  presetStage: PresetStage,
  body: unknown,
): StagePayloadMap[S] {
  const base = MOCK_STAGE_BUILDERS[stage](preset, presetStage)
  if (typeof body !== 'object' || body === null) return base as StagePayloadMap[S]
  return { ...base, ...(body as Record<string, unknown>) } as unknown as StagePayloadMap[S]
}

// ============================================================================
// 16. Factory
// ============================================================================

export type ChannelSelector = 'mock' | 'live'

/**
 * The single entry point P2-1 .. P5-1 call. Returns a union, so the caller is
 * forced to narrow on `channelKind` before consuming a channel-specific brand.
 */
export function createDemoBridge(
  selector: ChannelSelector,
  config: BridgeConfig,
): DemoBridge {
  return selector === 'mock' ? createMockBridge(config) : createLiveBridge(config)
}

/** Every stage the bridge implements, in order. Re-exported for test coverage. */
export const BRIDGE_STAGE_IDS: readonly StageId[] = STAGE_IDS
