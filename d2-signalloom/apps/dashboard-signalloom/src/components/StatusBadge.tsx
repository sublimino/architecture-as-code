interface Props {
  status: string
  variant?: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'
}

type ColorMap = Record<string, { bg: string; color: string }>

// Pill colours resolve from the theme's CSS custom properties rather than the
// tokens.ts literals. Under Dark each variable holds exactly the literal it
// replaced, so Dark is unchanged; under Light the accents darken, which is what
// stops the chips rendering as light grey text on a light grey background.
const VAR = {
  cyan: 'var(--cyan)',
  teal: 'var(--teal)',
  amber: 'var(--amber)',
  error: 'var(--error)',
  violet: 'var(--violet)',
  muted: 'var(--muted)',
  slateGray: 'var(--slate-gray)',
} as const

// The chip background is the accent at low opacity. The previous implementation
// appended an 8-bit alpha to a hex literal, which var() cannot do — color-mix
// can. Quantising the percentage to the same n/255 step keeps the rendered
// colour identical to the hex form it replaces.
export function tint(cssVar: string, opacity: number) {
  const alphaPct = (Math.round(opacity * 255) / 255) * 100
  return `color-mix(in srgb, ${cssVar} ${alphaPct}%, transparent)`
}

const LIFECYCLE: ColorMap = {
  enrolled:  { bg: tint(VAR.cyan, 0.12),  color: VAR.cyan },
  active:    { bg: tint(VAR.teal, 0.12),  color: VAR.teal },
  suspended: { bg: tint(VAR.amber, 0.12), color: VAR.amber },
  revoked:   { bg: tint(VAR.error, 0.12), color: VAR.error },
}

const RISK: ColorMap = {
  minimal_risk:      { bg: tint(VAR.teal, 0.12),   color: VAR.teal },
  limited_risk:      { bg: tint(VAR.teal, 0.12),   color: VAR.teal },
  high_risk:         { bg: tint(VAR.amber, 0.12),  color: VAR.amber },
  unacceptable_risk: { bg: tint(VAR.error, 0.12),  color: VAR.error },
  gpai:              { bg: tint(VAR.violet, 0.12), color: VAR.violet },
}

const PRIVILEGE: ColorMap = {
  standard:         { bg: tint(VAR.slateGray, 0.15), color: VAR.muted },
  elevated:         { bg: tint(VAR.amber, 0.12),     color: VAR.amber },
  // No theme variable carries this orange, so it stays literal; changing it to
  // --amber would alter the Dark theme's rendered output.
  domain_admin:     { bg: tint(VAR.amber, 0.18),     color: '#f97316' },
  enterprise_admin: { bg: tint(VAR.error, 0.12),     color: VAR.error },
}

const VIOLATION: ColorMap = {
  new:          { bg: tint(VAR.error, 0.12), color: VAR.error },
  acknowledged: { bg: tint(VAR.amber, 0.12), color: VAR.amber },
  resolved:     { bg: tint(VAR.teal, 0.12),  color: VAR.teal },
}

const COMPLIANCE: ColorMap = {
  pass:                   { bg: tint(VAR.teal, 0.12),      color: VAR.teal },
  fail:                   { bg: tint(VAR.error, 0.12),     color: VAR.error },
  pending:                { bg: tint(VAR.slateGray, 0.15), color: VAR.muted },
  reassessment_requested: { bg: tint(VAR.amber, 0.12),     color: VAR.amber },
}

const NHI: ColorMap = {
  discovered:           { bg: tint(VAR.violet, 0.12),     color: VAR.violet },
  enrollment_requested: { bg: tint(VAR.amber, 0.12),      color: VAR.amber },
  dismissed:            { bg: tint(VAR.slateGray, 0.15),  color: VAR.muted },
}

const ALL_MAPS: Record<string, ColorMap> = {
  lifecycle: LIFECYCLE,
  risk: RISK,
  privilege: PRIVILEGE,
  violation: VIOLATION,
  compliance: COMPLIANCE,
  nhi: NHI,
}

// Unmapped statuses land here — including the compliance pills (`compliant`,
// `non_compliant`), which no map defines. That made them muted-on-slate, which
// is the pairing that went illegible on a light background.
export function getStatusColor(status: string, variant?: string): { bg: string; color: string } {
  if (variant && ALL_MAPS[variant]?.[status]) return ALL_MAPS[variant][status]
  for (const m of Object.values(ALL_MAPS)) {
    if (m[status]) return m[status]
  }
  return { bg: tint(VAR.slateGray, 0.15), color: VAR.muted }
}

export default function StatusBadge({ status, variant }: Props) {
  const { bg, color } = getStatusColor(status, variant)
  return (
    <span className="tag" style={{ background: bg, color }}>
      {status.replace(/_/g, ' ')}
    </span>
  )
}
