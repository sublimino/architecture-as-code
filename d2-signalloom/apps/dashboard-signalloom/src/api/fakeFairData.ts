/**
 * Demo-mode fixtures for the live OpenFAIR risk surface.
 *
 * ─── Provenance of these numbers ───────────────────────────────────────────
 *
 * The base figures are lifted verbatim from the repo's own checked-in riskctl
 * output, `risk/out/baseline-acme-olly-2.1.0.json` (a real 200,000-iteration
 * run at seed 20260801 with a 0.15 risk load). `fair.test.ts` reads that same
 * file from disk and asserts the fixture agrees with it, so this file cannot
 * drift away from the tool without a red test.
 *
 * That matters more than it looks. The defect Phase 2 exists to end is a
 * dashboard showing invented risk figures. A fixture invented to LOOK like
 * riskctl output would reproduce that defect inside the demo path and hide it
 * behind a green suite. These are not plausible numbers; they are that run's
 * numbers, scaled per agent by a stated multiplier so six agents do not all
 * quote one figure.
 *
 * ─── Why demo mode has this route at all ───────────────────────────────────
 *
 * Rule SP-3: with the toggle ON, every screen renders from fixtures and none of
 * them may fail. req() throws a 501 for a path with no demo route, so omitting
 * these routes would make the risk widget the one panel that breaks the offline
 * presentation: the exact opposite of what the toggle is for.
 */

import type { CurrencyCode } from '../money/currency'

type Match = {
  method: string
  test: (path: string) => boolean
  data: (path: string, body?: unknown) => unknown
}

const re = (r: RegExp) => (path: string) => r.test(path)

const CURRENCY: CurrencyCode = 'GBP'
const COMPUTED_AT = '2026-07-27T12:00:00Z'

/**
 * `risk/out/baseline-acme-olly-2.1.0.json` → `Exposure`, verbatim.
 *
 * Full float precision on purpose. Rounding here would make the equivalence
 * test against the artifact pass only to the precision someone happened to
 * paste, which is a weaker claim than it reads as.
 */
export const RISKCTL_BASELINE = {
  ale: 48995.82694396423,
  var95: 308558.93199856416,
  tvar: 671897.2824562666,
  carried: 772681.8748247065,
} as const

/** `Results[0].EffectiveLEF` from the same file. Events per year. */
export const RISKCTL_BASELINE_LEF = { min: 0.01, mode: 0.05, max: 0.2 } as const

/** `Simulation` from the same file. */
export const RISKCTL_BASELINE_SIMULATION = {
  iterations: 200000,
  seed: 20260801,
  riskLoad: 0.15,
  tailDominated: false,
  guards: {
    shapeClamped: 0,
    midpointSubstituted: 0,
    gammaNonFinite: 0,
    poissonLoopCapped: 0,
  },
} as const

const money = (amount: number) => ({ amount, currency: CURRENCY })

/**
 * Per-agent scaling of the baseline run.
 *
 * A multiplier rather than six hand-written figure sets, so the relationship
 * between any fixture and the artifact stays one arithmetic step and the test
 * can check it. `tier` follows riskctl's own vocabulary.
 */
const AGENT_PROFILES: Record<string, { factor: number; tier: string }> = {
  'agent-inventory': { factor: 0.42, tier: 'monitored' },
  'agent-triage': { factor: 1.0, tier: 'caged' },
  'agent-sandbox': { factor: 0.11, tier: 'sandboxed' },
  'agent-remediation': { factor: 1.63, tier: 'caged' },
  'agent-scanner': { factor: 2.18, tier: 'caged' },
  'agent-reporter': { factor: 0.37, tier: 'monitored' },
}

/** Unknown ids still get a figure: the demo must never show a broken panel. */
const DEFAULT_PROFILE = { factor: 0.75, tier: 'monitored' }

function profileFor(agentId: string) {
  // Ids arrive tenant-qualified ("tenant-demo:agent-triage"); the profile table
  // is keyed on the bare slug so a different tenant prefix still resolves.
  const slug = agentId.includes(':') ? agentId.slice(agentId.lastIndexOf(':') + 1) : agentId
  return AGENT_PROFILES[slug] ?? DEFAULT_PROFILE
}

export function fakeAgentRisk(agentId: string) {
  const { factor, tier } = profileFor(agentId)
  return {
    agentId,
    currency: CURRENCY,
    lef: {
      min: RISKCTL_BASELINE_LEF.min * factor,
      mode: RISKCTL_BASELINE_LEF.mode * factor,
      max: RISKCTL_BASELINE_LEF.max * factor,
    },
    // Loss Magnitude is per EVENT, so it is ALE divided by the modal frequency,
    // spread across the same min/mode/max shape the engine uses for the triple.
    lossMagnitude: {
      min: money((RISKCTL_BASELINE.ale * factor) / 2),
      mode: money(RISKCTL_BASELINE.ale * factor),
      max: money(RISKCTL_BASELINE.var95 * factor),
    },
    exposure: {
      ale: money(RISKCTL_BASELINE.ale * factor),
      var95: money(RISKCTL_BASELINE.var95 * factor),
      tvar: money(RISKCTL_BASELINE.tvar * factor),
      carried: money(RISKCTL_BASELINE.carried * factor),
    },
    tier,
    simulation: RISKCTL_BASELINE_SIMULATION,
    computedAt: COMPUTED_AT,
    source: 'fixture',
  }
}

export function fakeFleetRisk() {
  const ids = Object.keys(AGENT_PROFILES)
  const total = ids.reduce((sum, id) => sum + AGENT_PROFILES[id].factor, 0)
  const ranked = ids
    .map((id) => ({
      agentId: `tenant-demo:${id}`,
      ale: money(RISKCTL_BASELINE.ale * AGENT_PROFILES[id].factor),
    }))
    .sort((a, b) => b.ale.amount - a.ale.amount)

  return {
    currency: CURRENCY,
    agentCount: ids.length,
    exposure: {
      ale: money(RISKCTL_BASELINE.ale * total),
      var95: money(RISKCTL_BASELINE.var95 * total),
      tvar: money(RISKCTL_BASELINE.tvar * total),
      carried: money(RISKCTL_BASELINE.carried * total),
    },
    topAgents: ranked.slice(0, 3),
    computedAt: COMPUTED_AT,
    source: 'fixture',
  }
}

/**
 * Routes, matched against the path req() was given with `/api` and the query
 * string already stripped.
 *
 * The `(?:\/v1)?` is not decoration: FAIR_API_PREFIX is configurable
 * (VITE_FAIR_API_PREFIX), and a deployment that drops the version segment must
 * not silently lose its demo fixtures: that would present as "demo mode is
 * broken on this build" long after the values change that caused it.
 *
 * Fleet is listed before the agent route because `/risk/fleet` would otherwise
 * be swallowed by an `agents/[^/]+` pattern if the two ever converge.
 */
export const FAIR_ROUTES: Match[] = [
  { method: 'GET', test: re(/^(?:\/v1)?\/risk\/fleet$/), data: () => fakeFleetRisk() },
  {
    method: 'GET',
    test: re(/^(?:\/v1)?\/risk\/agents\/[^/]+$/),
    data: (path: string) => fakeAgentRisk(decodeURIComponent(path.slice(path.lastIndexOf('/') + 1))),
  },
]
