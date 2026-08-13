interface Props {
  status: string
  variant?: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'
    | 'credential' | 'crypto' | 'provenance' | 'federation'
  /** Hover text — used where the badge is a claim that owes its provenance. */
  title?: string
  testId?: string
}

type ColorMap = Record<string, { bg: string; border: string; color: string }>

const VAR = {
  cyan: 'var(--cyan)',
  teal: 'var(--teal)',
  amber: 'var(--amber)',
  error: 'var(--error)',
  violet: 'var(--violet)',
  muted: 'var(--muted)',
  slateGray: 'var(--slate-gray)',
} as const

export function tint(cssVar: string, opacity: number) {
  const alphaPct = (Math.round(opacity * 255) / 255) * 100
  return `color-mix(in srgb, ${cssVar} ${alphaPct}%, transparent)`
}

const LIFECYCLE: ColorMap = {
  enrolled:  { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  active:    { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  suspended: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  revoked:   { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
}

const RISK: ColorMap = {
  minimal_risk:      { bg: tint(VAR.teal, 0.12),   border: tint(VAR.teal, 0.25),   color: VAR.teal },
  limited_risk:      { bg: tint(VAR.teal, 0.12),   border: tint(VAR.teal, 0.25),   color: VAR.teal },
  high_risk:         { bg: tint(VAR.amber, 0.12),  border: tint(VAR.amber, 0.25),  color: VAR.amber },
  unacceptable_risk: { bg: tint(VAR.error, 0.12),  border: tint(VAR.error, 0.25),  color: VAR.error },
  gpai:              { bg: tint(VAR.violet, 0.12), border: tint(VAR.violet, 0.25), color: VAR.violet },
}

const PRIVILEGE: ColorMap = {
  standard:         { bg: tint(VAR.slateGray, 0.15), border: 'transparent',         color: VAR.muted },
  elevated:         { bg: tint(VAR.amber, 0.12),     border: tint(VAR.amber, 0.25), color: VAR.amber },
  domain_admin:     { bg: tint(VAR.amber, 0.18),     border: tint(VAR.amber, 0.30), color: 'var(--amber)' },
  enterprise_admin: { bg: tint(VAR.error, 0.12),     border: tint(VAR.error, 0.25), color: VAR.error },
}

const VIOLATION: ColorMap = {
  new:          { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
  acknowledged: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  resolved:     { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
}

const COMPLIANCE: ColorMap = {
  pass:                   { bg: tint(VAR.teal, 0.12),      border: tint(VAR.teal, 0.25),  color: VAR.teal },
  fail:                   { bg: tint(VAR.error, 0.12),     border: tint(VAR.error, 0.25), color: VAR.error },
  pending:                { bg: tint(VAR.slateGray, 0.15), border: 'transparent',          color: VAR.muted },
  reassessment_requested: { bg: tint(VAR.amber, 0.12),     border: tint(VAR.amber, 0.25), color: VAR.amber },
}

const NHI: ColorMap = {
  discovered:           { bg: tint(VAR.violet, 0.12),    border: tint(VAR.violet, 0.25), color: VAR.violet },
  enrollment_requested: { bg: tint(VAR.amber, 0.12),     border: tint(VAR.amber, 0.25),  color: VAR.amber },
  dismissed:            { bg: tint(VAR.slateGray, 0.15), border: 'transparent',           color: VAR.muted },
}

/**
 * A credential's own state, which is not an enrolment lifecycle.
 *
 * `pending` is the reason this is a separate map rather than extra keys on
 * LIFECYCLE: a pending credential is one whose exchange has not completed yet
 * (cyan, in flight), where COMPLIANCE's `pending` is an assessment nobody has
 * run (muted, inert). Same word, opposite reading.
 */
const CREDENTIAL: ColorMap = {
  active:  { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  pending: { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  expired: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  failed:  { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
  revoked: { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
}

/** Cryptographic posture: seal state, CA rotation, and PQC readiness. */
const CRYPTO: ColorMap = {
  active:    { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  unsealed:  { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  ready:     { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  renewing:  { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  hybrid:    { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  pending:   { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  expiring:  { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  degraded:  { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  classical: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  sealed:    { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
  revoked:   { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
}

/**
 * Where a row's facts came from, which is the most load-bearing colour on the
 * Credential Inventory page: teal was measured in-cluster, cyan is declared by
 * a manifest and never observed, amber is a fixture. Flattening these to one
 * neutral badge would erase the distinction the page exists to make.
 */
const PROVENANCE: ColorMap = {
  live:   { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  config: { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  demo:   { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
}

/** Cross-trust-zone federation state. */
const FEDERATION: ColorMap = {
  active:     { bg: tint(VAR.teal, 0.12), border: tint(VAR.teal, 0.25), color: VAR.teal },
  federated:  { bg: tint(VAR.teal, 0.12), border: tint(VAR.teal, 0.25), color: VAR.teal },
  connecting: { bg: tint(VAR.cyan, 0.12), border: tint(VAR.cyan, 0.25), color: VAR.cyan },
}

// Insertion order is load-bearing. A lookup with no `variant` falls through
// every map in order and takes the first match, so the six original maps stay
// first and the three added later go at the end: any status already resolved
// by an existing map resolves to exactly the same colour it did before, on
// every page, whether or not that page passes a variant.
const ALL_MAPS: Record<string, ColorMap> = {
  lifecycle: LIFECYCLE,
  risk: RISK,
  privilege: PRIVILEGE,
  violation: VIOLATION,
  compliance: COMPLIANCE,
  nhi: NHI,
  credential: CREDENTIAL,
  crypto: CRYPTO,
  provenance: PROVENANCE,
  federation: FEDERATION,
}

export function getStatusColor(status: string, variant?: string): { bg: string; border: string; color: string } {
  if (variant && ALL_MAPS[variant]?.[status]) return ALL_MAPS[variant][status]
  for (const m of Object.values(ALL_MAPS)) {
    if (m[status]) return m[status]
  }
  return { bg: tint(VAR.slateGray, 0.15), border: 'transparent', color: VAR.muted }
}

export default function StatusBadge({ status, variant, title, testId }: Props) {
  const { bg, border, color } = getStatusColor(status, variant)
  return (
    <span className="tag" data-testid={testId} title={title} style={{ background: bg, borderColor: border, color }}>
      {status.replace(/_/g, ' ')}
    </span>
  )
}
