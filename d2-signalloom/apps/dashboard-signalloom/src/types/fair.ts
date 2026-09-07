/**
 * The wire contract for live OpenFAIR risk, mirrored on the frontend.
 *
 * ─── Where these field names come from, and why that matters ───────────────
 *
 * They are NOT invented here. Every name below is read off the output that
 * `riskctl --json` already produces and that this repo already carries at
 * `risk/out/baseline-*.json`. `fair.test.ts` parses that exact file and drives
 * it through `normalizeAgentRisk()`, so the artifact — not this file, and not
 * whoever writes the server — is the authority on the shape.
 *
 * That is deliberate. The service half of this contract (CRKC-P2-1) is being
 * built in a separate worktree at the same time as this client half. Two agents
 * each authoring a shape from their own imagination is how this repo previously
 * shipped a GCP hand-off whose emitter and consumer were both green and both
 * wrong, in the same shape, because each side's fixtures carried only the enum
 * values that side's author had thought of. Deriving both halves from the tool
 * removes the opportunity.
 *
 * ─── Units ─────────────────────────────────────────────────────────────────
 *
 * LEF is a FREQUENCY: loss events per year, a bare number. Everything else is a
 * MAGNITUDE and is therefore `Money`, never a bare number — `money/money.ts`
 * carries the reasoning for that rule (the currency used to be welded into the
 * field name, so a refactor could rename a value into a different currency with
 * nothing to catch it).
 *
 * ─── PML ───────────────────────────────────────────────────────────────────
 *
 * `riskctl` emits no field called PML. It emits `ale`, `var95`, `tvar` and
 * `carried`. Probable Maximum Loss in OpenFAIR/insurance practice is a
 * high-percentile loss, and `var95` — the 95th-percentile bad year — is this
 * engine's. So `pml` below IS `var95`, mapped once, here, in the open.
 *
 * `tvar` (the mean loss BEYOND var95) travels beside it rather than being
 * folded in, because a PML quoted without its tail is the kind of number that
 * cannot be defended in a review. `tailDominated` — the engine's own flag for
 * "the tail is doing the work" — is carried through for the same reason.
 */

import type { Money } from '../money/money'
import type { CurrencyCode } from '../money/currency'

/**
 * A PERT three-point estimate, exactly as the engine models it.
 *
 * `mode` rather than `likely`: that is the field name in
 * `policy-engine/fair/fair.go`'s `RiskTriple` and in the emitted JSON
 * (`{"min":0.01,"mode":0.05,"max":0.2}`). Renaming it on the way in would put a
 * translation layer between the audit trail and the screen.
 */
export interface FairTriple {
  min: number
  mode: number
  max: number
}

/** The engine's own count of the times it had to clamp or substitute. */
export interface FairGuards {
  shapeClamped: number
  midpointSubstituted: number
  gammaNonFinite: number
  poissonLoopCapped: number
}

/** Simulation provenance — what produced these numbers. */
export interface FairSimulation {
  iterations: number
  seed: number
  riskLoad: number
  tailDominated: boolean
  guards?: FairGuards
}

/**
 * Where a risk figure came from.
 *
 * Rendered on screen. An operator looking at a loss figure has to be able to
 * tell a fixture from an attested computation without reading the URL bar —
 * that is the entire point of Phase 2, and a priced figure with no stated
 * provenance is indistinguishable from the invented ones it replaces.
 */
export type FairSource = 'fixture' | 'riskctl'

/** Live OpenFAIR risk for one agent. */
export interface AgentRisk {
  agentId: string
  currency: CurrencyCode
  /** Loss Event Frequency — events per year. Dimensionless, never Money. */
  lef: FairTriple
  /** Loss Magnitude — the per-event loss triple. */
  lossMagnitude: { min: Money; mode: Money; max: Money }
  /** Annualised Loss Expectancy — the mean annual loss. */
  ale: Money
  /** Probable Maximum Loss. See the header: this IS var95. */
  pml: Money
  /** 95th-percentile bad year, carried explicitly so `pml`'s basis is legible. */
  var95: Money
  /** Mean loss beyond var95 — the tail behind the PML. */
  tvar: Money
  /** TVaR plus the risk load: what carrying this exposure actually costs. */
  carried: Money
  /** Posture tier the engine assigned, e.g. "caged". Optional: pre-tier payloads exist. */
  tier?: string
  simulation?: FairSimulation
  computedAt: string
  source: FairSource
}

/** Fleet-level rollup. */
export interface FleetRisk {
  currency: CurrencyCode
  agentCount: number
  ale: Money
  pml: Money
  tvar: Money
  carried: Money
  /** Highest-ALE agents first. May be empty; never null. */
  topAgents: Array<{ agentId: string; ale: Money }>
  computedAt: string
  source: FairSource
}

// ─── Normalisation ──────────────────────────────────────────────────────────

/**
 * The failure a malformed risk payload produces.
 *
 * Typed, and thrown rather than defaulted, because the alternative is the
 * defect this whole card exists to remove: a missing `ale` that quietly reads
 * as £0 is a fabricated figure wearing an attested figure's clothes. An
 * operator cannot tell those apart; an exception is at least honest.
 */
export class FairContractError extends Error {
  readonly field: string
  constructor(field: string, detail: string) {
    super(`FAIR contract violation on "${field}": ${detail}`)
    this.name = 'FairContractError'
    this.field = field
  }
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

/**
 * Coerce a money-ish field to `Money`.
 *
 * Accepts `{amount, currency}` (what the engine emits) and a bare number (what
 * a hand-written handler emits before someone reads money.ts), using the
 * document currency for the latter. This is the same tolerance
 * `normalizePostureSummary()` in api/client.ts already applies, so the two
 * money paths behave alike.
 *
 * It does NOT accept absent. Tolerating a missing magnitude is the one coercion
 * that turns "we could not compute this" into "this is zero".
 */
function toMoney(value: unknown, currency: CurrencyCode, field: string): Money {
  if (typeof value === 'number' && Number.isFinite(value)) return { amount: value, currency }
  if (isRecord(value) && typeof value.amount === 'number' && Number.isFinite(value.amount)) {
    return {
      amount: value.amount,
      currency: (typeof value.currency === 'string' ? value.currency : currency) as CurrencyCode,
    }
  }
  throw new FairContractError(field, `expected Money or a finite number, got ${JSON.stringify(value)}`)
}

function toTriple(value: unknown, field: string): FairTriple {
  if (!isRecord(value)) {
    throw new FairContractError(field, `expected {min,mode,max}, got ${JSON.stringify(value)}`)
  }
  const out: Record<string, number> = {}
  for (const key of ['min', 'mode', 'max'] as const) {
    const n = value[key]
    if (typeof n !== 'number' || !Number.isFinite(n)) {
      throw new FairContractError(`${field}.${key}`, `expected a finite number, got ${JSON.stringify(n)}`)
    }
    out[key] = n
  }
  return out as unknown as FairTriple
}

function toMoneyTriple(
  value: unknown,
  currency: CurrencyCode,
  field: string,
): { min: Money; mode: Money; max: Money } {
  if (!isRecord(value)) {
    throw new FairContractError(field, `expected {min,mode,max}, got ${JSON.stringify(value)}`)
  }
  return {
    min: toMoney(value.min, currency, `${field}.min`),
    mode: toMoney(value.mode, currency, `${field}.mode`),
    max: toMoney(value.max, currency, `${field}.max`),
  }
}

/**
 * Read either spelling of a key.
 *
 * The engine's own top-level envelope is PascalCase (Go field names with no
 * json tag: `AgentName`, `Exposure`, `Currency`) while its nested money and
 * triple objects are lowercase-tagged (`ale`, `var95`, `min`). A Go handler
 * wrapping it may emit either, and which one arrives is a decision belonging to
 * CRKC-P2-1, not to this file. Reading both is cheaper and safer than betting
 * on one and failing loudly against a correct server.
 */
function pick(src: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) {
    if (src[k] !== undefined) return src[k]
  }
  return undefined
}

/**
 * Validate and normalise one agent's risk payload.
 *
 * Throws `FairContractError` on anything it cannot read. Callers are hooks,
 * and the hooks turn the throw into an error banner — the exception never
 * reaches a render.
 */
export function normalizeAgentRisk(raw: unknown, fallbackAgentId = ''): AgentRisk {
  if (!isRecord(raw)) {
    throw new FairContractError('<root>', `expected an object, got ${JSON.stringify(raw)}`)
  }

  const currency = ((pick(raw, 'currency', 'Currency') as string) ?? 'GBP') as CurrencyCode

  // `Exposure` is where riskctl puts the four magnitudes; a flatter handler may
  // hoist them to the root. Look in the nested object first, then the root.
  const exposureRaw = pick(raw, 'exposure', 'Exposure')
  const exposure: Record<string, unknown> = isRecord(exposureRaw) ? exposureRaw : raw

  const ale = toMoney(pick(exposure, 'ale', 'ALE'), currency, 'exposure.ale')
  const var95 = toMoney(pick(exposure, 'var95', 'VaR95'), currency, 'exposure.var95')
  const tvar = toMoney(pick(exposure, 'tvar', 'TVaR'), currency, 'exposure.tvar')
  const carried = toMoney(
    pick(exposure, 'carried', 'Carried', 'carriedGbp'),
    currency,
    'exposure.carried',
  )

  // PML: honour an explicit field if the server grows one, else map to var95.
  const pmlRaw = pick(raw, 'pml', 'PML') ?? pick(exposure, 'pml', 'PML')
  const pml = pmlRaw === undefined ? var95 : toMoney(pmlRaw, currency, 'pml')

  const lef = toTriple(pick(raw, 'lef', 'LEF', 'effectiveLef', 'EffectiveLEF'), 'lef')
  const lossMagnitude = toMoneyTriple(
    pick(raw, 'lossMagnitude', 'LossMagnitude', 'lm', 'LM'),
    currency,
    'lossMagnitude',
  )

  const simRaw = pick(raw, 'simulation', 'Simulation')
  const simulation: FairSimulation | undefined = isRecord(simRaw)
    ? {
        iterations: Number(simRaw.iterations ?? 0),
        seed: Number(simRaw.seed ?? 0),
        riskLoad: Number(simRaw.riskLoad ?? 0),
        tailDominated: Boolean(simRaw.tailDominated),
        guards: isRecord(simRaw.guards)
          ? {
              shapeClamped: Number(simRaw.guards.shapeClamped ?? 0),
              midpointSubstituted: Number(simRaw.guards.midpointSubstituted ?? 0),
              gammaNonFinite: Number(simRaw.guards.gammaNonFinite ?? 0),
              poissonLoopCapped: Number(simRaw.guards.poissonLoopCapped ?? 0),
            }
          : undefined,
      }
    : undefined

  const agentId =
    (pick(raw, 'agentId', 'agent_id', 'AgentName', 'agentName') as string) ?? fallbackAgentId
  if (!agentId) {
    throw new FairContractError('agentId', 'payload names no agent and no fallback was supplied')
  }

  const source = pick(raw, 'source', 'Source')
  const tier = pick(raw, 'tier', 'Tier')

  return {
    agentId,
    currency,
    lef,
    lossMagnitude,
    ale,
    pml,
    var95,
    tvar,
    carried,
    tier: typeof tier === 'string' ? tier : undefined,
    simulation,
    computedAt:
      (pick(raw, 'computedAt', 'computed_at', 'generatedAt', 'GeneratedAt') as string) ??
      new Date(0).toISOString(),
    // Defaulting to 'riskctl' rather than 'fixture' is deliberate: an
    // unlabelled payload arrived over the live path, and labelling live data
    // "fixture" would understate what the operator is looking at. The fixture
    // route sets this explicitly, so the default is only ever reached by a
    // server that forgot the field.
    source: source === 'fixture' ? 'fixture' : 'riskctl',
  }
}

/** Validate and normalise a fleet rollup. Same contract discipline as above. */
export function normalizeFleetRisk(raw: unknown): FleetRisk {
  if (!isRecord(raw)) {
    throw new FairContractError('<root>', `expected an object, got ${JSON.stringify(raw)}`)
  }
  const currency = ((pick(raw, 'currency', 'Currency') as string) ?? 'GBP') as CurrencyCode
  const exposureRaw = pick(raw, 'exposure', 'Exposure')
  const exposure: Record<string, unknown> = isRecord(exposureRaw) ? exposureRaw : raw

  const var95 = toMoney(pick(exposure, 'var95', 'VaR95'), currency, 'exposure.var95')
  const pmlRaw = pick(raw, 'pml', 'PML') ?? pick(exposure, 'pml', 'PML')

  const topRaw = pick(raw, 'topAgents', 'top_agents', 'TopAgents')
  const topAgents = Array.isArray(topRaw)
    ? topRaw.filter(isRecord).map((entry, i) => ({
        agentId:
          (pick(entry, 'agentId', 'agent_id', 'AgentName') as string) ?? `unknown-agent-${i}`,
        ale: toMoney(pick(entry, 'ale', 'ALE'), currency, `topAgents[${i}].ale`),
      }))
    : []

  const source = pick(raw, 'source', 'Source')

  return {
    currency,
    agentCount: Number(pick(raw, 'agentCount', 'agent_count', 'AgentCount') ?? topAgents.length),
    ale: toMoney(pick(exposure, 'ale', 'ALE'), currency, 'exposure.ale'),
    pml: pmlRaw === undefined ? var95 : toMoney(pmlRaw, currency, 'pml'),
    tvar: toMoney(pick(exposure, 'tvar', 'TVaR'), currency, 'exposure.tvar'),
    carried: toMoney(pick(exposure, 'carried', 'Carried'), currency, 'exposure.carried'),
    topAgents,
    computedAt:
      (pick(raw, 'computedAt', 'computed_at', 'generatedAt') as string) ??
      new Date(0).toISOString(),
    source: source === 'fixture' ? 'fixture' : 'riskctl',
  }
}
