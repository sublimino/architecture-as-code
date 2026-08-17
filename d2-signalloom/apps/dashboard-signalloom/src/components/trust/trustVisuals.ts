// The visual grammar of the trust topology.
//
// THE RULE THIS FILE EXISTS TO ENFORCE: motion is proportional to evidence.
//
// The page's whole reason for being is that none of this topology is
// runtime-observed. A diagram that animates modeled relationships as
// confidently as observed ones would quietly launder assumption into proof --
// which is exactly the failure the page's amber banner warns about. So the
// animation budget is spent in proportion to how much we actually know:
//
//   observed  fast, opaque, continuous       "this is happening"
//   fixture   slower, dotted, translucent    "this was proved in a test"
//   modeled   slowest, faintest, drifting    "this is an assumption"
//   stale     stuttering amber, steps()      "this used to be true"
//
// A viewer who never reads the legend should still come away trusting the
// solid confident lines more than the ghost-drifting ones. That is the point.

import type { EvidenceState } from './trustTypes'

export type EvidenceVisual = {
  /** Legend copy. Kept byte-identical to the pre-redesign strings: tests assert on them. */
  label: string
  /** SVG stroke-dasharray. 'none' renders solid. */
  dash: string
  /**
   * CSS border-style for node boxes — the DOM equivalent of `dash`.
   *
   * These must stay in step with each other AND with the legend wording,
   * because colour cannot be relied on to carry evidence state. For any viewer
   * with a colour vision deficiency, dashed-vs-dotted is the ONLY thing
   * distinguishing a modeled node from a fixture-tested one, in every theme.
   *
   * This used to be true of every viewer under "andy", which mapped --teal,
   * --violet, --cyan and --amber onto four near-identical reds. That theme has
   * since been rebuilt on the Signal Loom brand ramp and its accents are now
   * at least 29.9 degrees apart in hue, but the redundancy stays: it was always
   * load-bearing for colour vision deficiency, and themes.test.ts now guards
   * the hue separation independently.
   */
  borderStyle: 'solid' | 'dashed' | 'dotted'
  color: string
  /**
   * Low-alpha fill, mixed from the theme-switched base.
   *
   * NOT --cyan-bg and friends: those live only in global.css's :root and are
   * absent from CSS_VAR_NAMES, so applyTheme never rewrites them. They stayed
   * frozen at their dark-theme values in every theme -- which put teal-cyan
   * fills on three nodes in the then-all-red "andy" theme, and two different
   * cyans in one component under Light. color-mix on the base tracks the theme.
   */
  tint: string
  /** Seconds for one flow cycle. Higher = less convincing, by design. */
  flowSeconds: number
  /** Stroke opacity at rest. */
  restOpacity: number
  /** CSS timing function for the flow. `steps()` reads as broken, deliberately. */
  timing: string
  /** Plain-language confidence, shown in the inspector and legend tooltip. */
  confidence: string
}

export const visual: Record<EvidenceState, EvidenceVisual> = {
  observed: {
    label: 'Runtime-observed / solid',
    dash: 'none',
    borderStyle: 'solid',
    color: 'var(--teal)',
    tint: 'color-mix(in srgb, var(--teal) 20%, transparent)',
    flowSeconds: 2.2,
    restOpacity: 1,
    timing: 'linear',
    confidence: 'Observed at runtime — highest confidence available on this page',
  },
  modeled: {
    label: 'Modeled / dashed',
    dash: '9 5',
    borderStyle: 'dashed',
    color: 'var(--violet)',
    tint: 'color-mix(in srgb, var(--violet) 20%, transparent)',
    flowSeconds: 6,
    restOpacity: 0.72,
    timing: 'linear',
    confidence: 'Contract assumption — never proved, drawn faint on purpose',
  },
  fixture: {
    label: 'Fixture-tested / dotted',
    dash: '2 5',
    borderStyle: 'dotted',
    color: 'var(--cyan)',
    tint: 'color-mix(in srgb, var(--cyan) 20%, transparent)',
    flowSeconds: 3.4,
    restOpacity: 0.9,
    timing: 'linear',
    confidence: 'Proved by a fixture test — real evidence, not live evidence',
  },
  stale: {
    label: 'Stale / dotted warning',
    dash: '2 5',
    borderStyle: 'dotted',
    color: 'var(--amber)',
    tint: 'color-mix(in srgb, var(--amber) 20%, transparent)',
    flowSeconds: 4.5,
    restOpacity: 0.8,
    timing: 'steps(9, end)',
    confidence: 'Last known good — treat as unverified until refreshed',
  },
}

/** Trust rank. Drives entrance stagger, node scale and boundary nesting order. */
export const rankOf: Record<string, number> = {
  platform: 0,
  service: 1,
  tenant: 1,
  project: 2,
  agent: 3,
}

/**
 * Tenant hue. Boundaries are tinted per tenant so a viewer can see at a glance
 * which side of the cross-tenant wall something sits on -- the denial that
 * matters most on this page is precisely the one that crosses it.
 */
export const tenantAccent: Record<string, string> = {
  shared: 'var(--slate-gray)',
  acme: 'var(--cyan)',
  northstar: 'var(--violet)',
}

export function accentFor(tenant: string): string {
  return tenantAccent[tenant] ?? 'var(--slate-gray)'
}

/**
 * The on-canvas label for a relationship.
 *
 * Every verb in the contract is prefixed with its own evidence state --
 * "modeled SPIRE issues SVID", "fixture-tested planner invokes triage". On the
 * canvas that prefix is pure duplication: the line is already dashed for
 * modeled and dotted for fixture-tested, and the legend says so. Repeating it
 * in text costs horizontal space the diagram does not have and pushes labels
 * across the boundaries underneath them.
 *
 * The full verb is untouched everywhere it is the only description available --
 * the selectable button list, the inspector heading, the hover title.
 */
export function shortVerb(verb: string): string {
  return verb.replace(/^(modeled|fixture-tested|runtime-observed|stale)\s+/i, '')
}

/**
 * Denials are not one thing, and the page goes out of its way to say so.
 * A network block never reaches the target; an authorization rejection does
 * reach it and is turned away. The diagram animates those two differently, so
 * this returns which treatment an edge gets.
 */
export type DenialTreatment = 'wall' | 'rebound' | 'none'

export function denialTreatment(
  decision: string,
  denialKind?: 'network-block' | 'application-authorization-rejection',
): DenialTreatment {
  if (decision !== 'denied') return 'none'
  return denialKind === 'network-block' ? 'wall' : 'rebound'
}
