interface Props {
  status: string
  variant?: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'
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
  domain_admin:     { bg: tint(VAR.amber, 0.18),     border: tint(VAR.amber, 0.30), color: '#f97316' },
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

const ALL_MAPS: Record<string, ColorMap> = {
  lifecycle: LIFECYCLE,
  risk: RISK,
  privilege: PRIVILEGE,
  violation: VIOLATION,
  compliance: COMPLIANCE,
  nhi: NHI,
}

export function getStatusColor(status: string, variant?: string): { bg: string; border: string; color: string } {
  if (variant && ALL_MAPS[variant]?.[status]) return ALL_MAPS[variant][status]
  for (const m of Object.values(ALL_MAPS)) {
    if (m[status]) return m[status]
  }
  return { bg: tint(VAR.slateGray, 0.15), border: 'transparent', color: VAR.muted }
}

export default function StatusBadge({ status, variant }: Props) {
  const { bg, border, color } = getStatusColor(status, variant)
  return (
    <span className="tag" style={{ background: bg, borderColor: border, color }}>
      {status.replace(/_/g, ' ')}
    </span>
  )
}
