# AgentMaxxing Demo Bridge — Frozen Contract Snapshot

**Card:** AMXD-P1-3
**Frozen at:** 2026-09-15
**Implementation:** `src/components/demos/bridge.ts`
**Consumes:** AMXD-P1-1 (`types.ts`), AMXD-P1-2 (`scenarios.ts`)
**Consumed by:** AMXD-P2-1, P2-2, P3-1, P3-2, P4-1, P4-2, P5-1, P6-1

Later cards diff against this file rather than re-deriving the interface. A change
to anything under **Frozen** is a breaking-change decision for every card above,
not a silent edit. Anything under **Open** may be extended without renegotiation.

---

## Frozen — do not change without a recorded breaking-change decision

### Channel discriminant

```ts
interface MockChannel { readonly kind: 'mock'; readonly presetId: string; readonly fixtureSource: 'preset' }
interface LiveChannel { readonly kind: 'live'; readonly requestPath: string; readonly transport: 'req' | 'fetch' }
type DemoChannel = MockChannel | LiveChannel
```

The discriminant field is `kind`. Its values are the string literals `'mock'` and
`'live'`. Nothing else may be added to the union.

### Per-channel outcomes (mutually non-assignable)

```ts
interface MockStageSuccess<S extends StageId> {
  readonly channel: MockChannel
  readonly status: 'ok'
  readonly stage: S
  readonly payload: StagePayloadMap[S]
  readonly declaredHttpStatus: number   // mock-only brand
  readonly fixtureId: string            // mock-only brand
}
interface MockStageFailure<S extends StageId> {
  readonly channel: MockChannel
  readonly status: 'error'
  readonly stage: S
  readonly error: BridgeError
  readonly fixtureId: string            // mock-only brand
}
interface LiveStageSuccess<S extends StageId> {
  readonly channel: LiveChannel
  readonly status: 'ok'
  readonly stage: S
  readonly payload: StagePayloadMap[S]
  readonly httpStatus: number           // live-only brand
  readonly requestPath: string          // live-only brand
}
interface LiveStageFailure<S extends StageId> {
  readonly channel: LiveChannel
  readonly status: 'error'
  readonly stage: S
  readonly error: BridgeError
  readonly requestPath: string          // live-only brand
}

type MockStageOutcome<S extends StageId> = MockStageSuccess<S> | MockStageFailure<S>
type LiveStageOutcome<S extends StageId> = LiveStageSuccess<S> | LiveStageFailure<S>
type StageOutcome<S extends StageId>     = MockStageOutcome<S> | LiveStageOutcome<S>
```

**Why two brands and not one discriminant.** A two-member union alone is not
enough: a function returning the *union* lets a caller receive either and the
compiler is content. Non-assignability bites only because each side is separately
named in a signature **and** carries a required property the other lacks. If a
future edit "repairs" the `kind` literals, the missing-property check still
fails. `bridge.test.ts` pins both directions with `@ts-expect-error`, so relaxing
the boundary fails `bun run typecheck`.

### Deriving prop types — use `DistributiveOmit`, never `Omit` or `Partial`

```ts
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never
```

`Omit` is **not** distributive over a union. `Omit<StageOutcome<S>, 'stage'>`
produces one object type with neither channel's brand and a widened
`channelKind`, silently collapsing the separation. `Partial` is worse — it makes
mock and live mutually assignable again. React prop plumbing reaches for both by
reflex, so `DistributiveOmit` is the sanctioned form and `bridge.test.ts` pins
with `@ts-expect-error` that it preserves the boundary.

### Error taxonomy

```ts
type BridgeErrorKind = 'network' | 'application' | 'aborted' | 'unsupported'

interface BridgeNetworkError     { kind: 'network';     message: string; cause?: string }
interface BridgeApplicationError { kind: 'application'; httpStatus: number; message: string; bodyExcerpt?: string }
interface BridgeAbortedError     { kind: 'aborted';     message: string }
interface BridgeUnsupportedError { kind: 'unsupported'; reason: 'nginx-no-v1-location-pre-amxd-p1-4' | 'spa-catch-all-fallthrough'; path: string; message: string }
```

`network` and `application` are the distinction AMXD-P4-2 needs: "unreachable,
try again" versus "the backend answered 403". `unsupported` is neither — the
network is fine and the backend never saw the request.

### Bridge surface

```ts
interface MockDemoBridge {
  readonly channelKind: 'mock'
  readonly preset: ScenarioPreset
  advance<S extends StageId>(stage: S, options?: AdvanceOptions): Promise<MockStageOutcome<S>>
  resetEstate(): ResetEstateResult
  seedEstate(): SeedEstateResult
  reachability(stage: StageId): LiveReachability
}
interface LiveDemoBridge { /* identical, with channelKind 'live' and LiveStageOutcome */ }
type DemoBridge = MockDemoBridge | LiveDemoBridge

function createDemoBridge(selector: 'mock' | 'live', config: BridgeConfig): DemoBridge
function createMockBridge(config: BridgeConfig): MockDemoBridge
function createLiveBridge(config: BridgeConfig): LiveDemoBridge

interface AdvanceOptions { readonly signal?: AbortSignal; readonly dwellMs?: number; readonly timeoutMs?: number }
interface BridgeConfig   { readonly preset: ScenarioPreset; readonly token?: string; readonly transport?: LiveTransport; readonly now?: () => number }
```

### Reset / seed

```ts
interface ResetEstateResult {
  readonly channel: DemoChannel
  readonly clearedStorageKeys: readonly string[]
  readonly clearedInMemoryKeys: readonly string[]
  readonly stepperState: DemoStepperState
  readonly backendStateCleared: false      // LITERAL false, not boolean
  readonly notResetExplanation: string
  readonly idempotent: true
}
interface SeedEstateResult {
  readonly channel: DemoChannel
  readonly destructive: false              // LITERAL false
  readonly idempotent: true
  readonly presetId: string
  readonly seededStorageKeys: readonly string[]
  readonly stepperState: DemoStepperState
  readonly signature: string
}
```

**Reset semantics — exactly what is claimed.** `resetEstate()` removes every
`localStorage` key under `amxd.demo.` (enumerated, not hardcoded), clears the
in-memory bridge event log, and returns `INITIAL_STEPPER_STATE`. It does **not**
clear backend rows. There is no backend endpoint that would let it.
`rg -n 'reset|seed'` over `external_agent_registration.py`, `host_credential.py`,
and `host_enrollment.py` returns two matches. Both are undecorated in-process
helpers (`external_agent_registration.py:54`, `host_enrollment.py:50`) with no
router mount. Their sibling `api_compat.py:2353` is documented "Nothing in the
running application calls this." `backendStateCleared` is typed as the literal
`false` so this cannot be quietly changed.

**Seed semantics — idempotent, never destructive.** `seedEstate()` writes the
same three keys with the same values for a given preset. A presenter
re-running it mid-demo therefore re-establishes the known state rather than
losing anything. `signature` is a deterministic digest of the preset, which is
how "returned to a known state twice in succession" is asserted mechanically.

### Storage namespace

```
amxd.demo.sessionId
amxd.demo.activePresetId
amxd.demo.lastResetAt
amxd.demo.seedSignature
```

Prefix `amxd.demo.` is frozen. It does not collide with `sl_demo_mode`
(`api/demoMode.ts:11`), `signalloom.superadmin`, `signalloom.logTransport`
(`api/demoRunner.ts:227`), `signalloom-return-to` (`auth/oidc.tsx:45`), or
`demoMode`.

### Channel label

```ts
interface ChannelDescriptor {
  readonly kind: 'mock' | 'live'
  readonly label: string
  readonly provenance: 'client-held-fixture' | 'live-backend'
  readonly origin: string
}
function describeChannel(source: { readonly channel: DemoChannel }): ChannelDescriptor
```

Panels branch on `kind` or `provenance`, never on `label` — the wording is free
to change. `describeChannel` and the event log both read `source.channel.kind`,
one field, so they cannot disagree for the same call.

### Event log

```ts
const BRIDGE_EVENT_LOG_CAP = 200
interface BridgeEvent {
  readonly seq: number
  readonly channel: 'mock' | 'live'
  readonly stage: StageId | 'reset_estate' | 'seed_estate'
  readonly outcome: 'ok' | 'error'
  readonly errorKind: BridgeErrorKind | null
  readonly presetId: string
  readonly at: number
}
function getBridgeEventLog(): readonly BridgeEvent[]
function clearBridgeEventLog(): void
```

AMXD-P6-1 reads this to assert which channel actually served a stage. If its
assertion window ever needs more than 200 entries, **raise the cap** — do not
shorten the spec.

### Live reachability

```ts
type LiveReachability = 'reachable' | 'blocked-no-nginx-location'
const NGINX_PROXIED_API_PREFIXES: readonly string[]   // "is nginx routing this?"
const REQ_TRANSPORT_PREFIXES: readonly string[]       // "can req() carry this?"
function assessLiveReachability(path: string): LiveReachability
function selectTransport(path: string): 'req' | 'fetch'
const LIVE_REACHABILITY: Readonly<Record<string, Readonly<Record<StageId, LiveReachability>>>>
```

---

## Live-reachable stage transitions — AMXD-P1-4 HAS LANDED

Dated against the nginx state at **2026-09-15**: `nginx.conf` has a
`location /api/` block **and** a `location /v1/` block (`nginx.conf:118`).
AMXD-P1-4 added the `/v1/` block. It is a passthrough via `$api$request_uri`
with `Authorization` forwarded.

| Preset | Stage | Path | Post-P1-4 |
|---|---|---|---|
| all three | `operator_init` | `/api/v1/external-agents/registrations/{agent_id}/token` | reachable |
| all three | `host_enrolled` | `/api/v1/external-agents/enroll` | reachable |
| all three | `confinement_streaming` | `/api/v1/external-agents/evidence-uploads` | reachable |
| happy-path, tamper-breach | `adversarial_tamper` | `/api/v1/external-agents/evidence-uploads` | reachable |
| **revocation-race** | **`adversarial_tamper`** | **`/v1/external-agents/hosts/{host_id}/revoke`** | **reachable** |
| happy-path, tamper-breach | `revocation_denied` | `/api/v1/agents/{agent_id}/external-evidence` | reachable |
| revocation-race | `revocation_denied` | `/api/v1/external-agents/evidence-uploads` | reachable |

**What this means per card.** P2-1, P2-2, P3-1, P3-2 and **P4-2** may all build
against the live channel. Every stage of every preset is live-reachable. There
is no longer a blocked stage.

### Reachability and transport are two different questions

The revoke route is mounted **only** on `v1_router`
(`external_agent_registration.py:1231`) and was never added to `router`
(`/api/v1/external-agents`). It must therefore not be routed through `req()`,
which auto-prefixes `/api` at `client.ts:241`. The live channel uses a direct
`fetch`, the same way `agentClaim.ts:111` does.

That constraint is **independent of reachability** and survives AMXD-P1-4.
A single predicate answering both questions is a trap. Once `/v1/` became
proxied, a reachability-driven transport choice would promote the revoke onto
`req()`. That would mangle it into `/api/v1/external-agents/hosts/...`, a route
FastAPI never registered. `assessLiveReachability` and `selectTransport` are
therefore deliberately separate, backed by two separate prefix lists.

### How this table is kept honest

AMXD-P1-GOV found that the previous guard was a **tautology**: `bridge.test.ts`
asserted `LIVE_REACHABILITY_PRE_AMXD_P1_4` agreed with `assessLiveReachability()`,
but both read the same `NGINX_PROXIED_API_PREFIXES` constant. Two copies of the
same wrong answer agree perfectly. That is exactly why AMXD-P1-4 could add
`location /v1/` without a single test going red. The bridge was left reporting a
reachable stage as blocked.

`bridge.test.ts` now **parses `nginx.conf` itself** and fails if
`NGINX_PROXIED_API_PREFIXES` disagrees with the real `location` blocks. The
parser asserts it found at least one block, so a broken parser cannot pass
vacuously. Verified by mutation: reverting the constant to `['/api/']` fails 6
tests.

---

## Open — later cards may extend these without renegotiation

- **`ChannelDescriptor.label` wording.** Free to change. Nothing string-matches it.
- **`BridgeEvent` additive fields.** New optional fields may be appended. `seq`,
  `channel`, `stage`, `outcome` are frozen.
- **`BRIDGE_EVENT_LOG_CAP` value.** Raising it is expected and safe.
- **`adaptLivePayload` per-stage mapping.** How a backend response maps onto
  `StagePayloadMap[S]` will sharpen as P2–P4 see real shapes. The *return type*
  is frozen. The mapping is not.
- **`BridgeUnsupportedError.reason` union.** New reasons may be added.
- **`AdvanceOptions` additive fields.** `signal`, `dwellMs`, `timeoutMs` are frozen.
- **Additional `amxd.demo.`-prefixed storage keys.** The prefix is frozen. The key
  set is not.
- **`MOCK_LATENCY_MS`.** Tunable.

## Explicitly NOT in this contract

- Any backend reset or seed endpoint. None exists. None is added here.
- Any nginx route change. AMXD-P1-4 owns `nginx.conf`.
- Any enforcement against a real workload, or any display of real customer data.
