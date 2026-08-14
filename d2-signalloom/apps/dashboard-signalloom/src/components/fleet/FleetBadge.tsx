/**
 * FleetBadge — the diagram's own colour vocabulary, in a table cell.
 *
 * WHY THIS IS NOT `StatusBadge`. The shared badge is the right component and
 * this borrows its markup verbatim: the same `.tag` class, the same
 * `tint(token, 0.12 / 0.25)` fill-and-border formula, exported from
 * StatusBadge rather than copied. What it cannot supply is the MAP, and the
 * two maps this page needs are both wrong in `StatusBadge`:
 *
 *   - Trust profile is `high | medium | low`, and none of those three words
 *     appears in any of StatusBadge's ten maps. The lookup falls through all
 *     of them to the muted default, so all three render identical grey and
 *     the column carries no information at all. `risk` looks close but its
 *     keys are `high_risk`/`low_risk`, and its polarity is inverted anyway:
 *     high risk is bad, high trust is good.
 *
 *   - Fleet lifecycle overlaps `lifecycle` on exactly one word. `active`
 *     resolves there to TEAL, and this page's diagram has drawn an active
 *     agent CYAN since it was written (`stateColour` in FleetTopology.tsx).
 *     The other five states — absent, deploying, non-compliant, grace-period,
 *     stunned — are not in that map either.
 *
 * The alternative was adding a `fleet` and a `trust` variant to StatusBadge,
 * which is the right long-term answer and is what should happen once the ten
 * concurrent design-system migrations have landed and that file is safe to
 * touch. Until then the failure mode of doing it here is a colour drifting
 * from the diagram, and the mitigation is that both maps below are asserted
 * against FleetTopology's in FleetBadge.test.tsx.
 */
import { tint } from '../StatusBadge'
import type { AgentState } from '../../api/fleetApi'

/**
 * Mirrors `stateColour` in FleetTopology.tsx exactly.
 *
 * `absent` is the one deliberate divergence: the diagram paints an absent node
 * in `--surface2` because it is drawing a hollow placeholder card, and a
 * `--surface2` word on a `--surface2` fill would be invisible in a table cell.
 * Muted is the same "nothing here" reading in the medium that works.
 */
const STATE_TOKEN: Record<AgentState['state'], string> = {
  active: 'var(--cyan)',
  'non-compliant': 'var(--amber)',
  stunned: 'var(--error)',
  deploying: 'var(--muted)',
  'grace-period': 'var(--amber)',
  absent: 'var(--muted)',
}

/** Mirrors `trustBadgeColour` in FleetTopology.tsx exactly. */
const TRUST_TOKEN: Record<AgentState['trustProfile'], string> = {
  high: 'var(--teal)',
  medium: 'var(--amber)',
  low: 'var(--error)',
}

export function stateToken(state: AgentState['state']): string {
  return STATE_TOKEN[state] ?? 'var(--muted)'
}

export function trustToken(profile: AgentState['trustProfile']): string {
  return TRUST_TOKEN[profile] ?? 'var(--muted)'
}

interface Props {
  /** The word shown in the badge. Hyphens stay: `non-compliant` is the API's word. */
  label: string
  /** A CSS custom property reference. Never a literal colour — see cssVarUsage.test.ts. */
  token: string
  testId?: string
}

export default function FleetBadge({ label, token, testId }: Props) {
  return (
    <span
      className="tag"
      data-testid={testId}
      style={{ background: tint(token, 0.12), borderColor: tint(token, 0.25), color: token }}
    >
      {label}
    </span>
  )
}
