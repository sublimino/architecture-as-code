interface Props {
  status: string
  variant?: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'
    | 'credential' | 'crypto' | 'provenance' | 'federation'
  /** Hover text: used where the badge is a claim that owes its provenance. */
  title?: string
  testId?: string
  /** Whether eBPF kernel enforcement / process freeze is active. */
  isFrozen?: boolean
  ebpfEnforced?: boolean
  lockIcon?: boolean
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
  Governed:  { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  governed:  { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  Suspended: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  suspended: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  Revoked:   { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
  revoked:   { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
  enrolled:       { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  registered:     { bg: tint(VAR.cyan, 0.12),  border: tint(VAR.cyan, 0.25),  color: VAR.cyan },
  active:         { bg: tint(VAR.teal, 0.12),  border: tint(VAR.teal, 0.25),  color: VAR.teal },
  stunned:        { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  decommissioned: { bg: tint(VAR.error, 0.12), border: tint(VAR.error, 0.25), color: VAR.error },
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
  compliant:              { bg: tint(VAR.teal, 0.12),      border: tint(VAR.teal, 0.25),  color: VAR.teal },
  non_compliant:          { bg: tint(VAR.error, 0.12),     border: tint(VAR.error, 0.25), color: VAR.error },
  pending:                { bg: tint(VAR.slateGray, 0.15), border: 'transparent',          color: VAR.muted },
  not_assessed:           { bg: tint(VAR.slateGray, 0.15), border: 'transparent',          color: VAR.muted },
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
  // A revocation that was attempted and did not complete: the credential may
  // still work, so it must not share revoked's colour.
  revocation_failed: { bg: tint(VAR.amber, 0.12), border: tint(VAR.amber, 0.25), color: VAR.amber },
  unknown: { bg: tint(VAR.slateGray, 0.15), border: 'transparent', color: VAR.muted },
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

export default function StatusBadge({
  status,
  variant,
  title,
  testId,
  isFrozen,
  ebpfEnforced,
  lockIcon,
}: Props) {
  const { bg, border, color } = getStatusColor(status, variant)
  const isSuspendedOrStunned = status.toLowerCase() === 'suspended' || status.toLowerCase() === 'stunned'
  const showLock = lockIcon ?? (isFrozen || ebpfEnforced || (variant === 'lifecycle' && isSuspendedOrStunned && isFrozen !== false && isFrozen !== undefined))
  const effectiveTitle = title || (showLock ? 'Sentinel eBPF kernel enforcement active: cgroup frozen and network dropped' : undefined)

  return (
    <span
      className="tag"
      data-testid={testId}
      title={effectiveTitle}
      style={{
        background: bg,
        borderColor: border,
        color,
        display: showLock ? 'inline-flex' : undefined,
        alignItems: showLock ? 'center' : undefined,
        gap: showLock ? 4 : undefined,
      }}
    >
      {showLock && (
        <svg
          aria-hidden="true"
          data-testid="ebpf-lock-icon"
          viewBox="0 0 24 24"
          width="11"
          height="11"
          fill="currentColor"
          style={{ flexShrink: 0 }}
        >
          <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" />
        </svg>
      )}
      {status.replace(/_/g, ' ')}
    </span>
  )
}
