import { colors } from '../styles/tokens'

interface Props {
  status: string
  variant?: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'
}

type ColorMap = Record<string, { bg: string; color: string }>

function hex(c: string, opacity: number) {
  return c + Math.round(opacity * 255).toString(16).padStart(2, '0')
}

const LIFECYCLE: ColorMap = {
  enrolled:  { bg: hex(colors.cyanLoom, 0.12),  color: colors.cyanLoom },
  active:    { bg: hex(colors.tealLoom, 0.12),  color: colors.tealLoom },
  suspended: { bg: hex(colors.amber, 0.12),     color: colors.amber },
  revoked:   { bg: hex(colors.red, 0.12),       color: colors.red },
}

const RISK: ColorMap = {
  minimal_risk:      { bg: hex(colors.tealLoom, 0.12), color: colors.tealLoom },
  limited_risk:      { bg: hex(colors.tealLoom, 0.12), color: colors.tealLoom },
  high_risk:         { bg: hex(colors.amber, 0.12),    color: colors.amber },
  unacceptable_risk: { bg: hex(colors.red, 0.12),      color: colors.red },
  gpai:              { bg: hex(colors.irisViolet, 0.12), color: colors.irisViolet },
}

const PRIVILEGE: ColorMap = {
  standard:         { bg: hex(colors.slateGray, 0.15), color: colors.muted },
  elevated:         { bg: hex(colors.amber, 0.12),     color: colors.amber },
  domain_admin:     { bg: hex(colors.amber, 0.18),     color: '#f97316' },
  enterprise_admin: { bg: hex(colors.red, 0.12),       color: colors.red },
}

const VIOLATION: ColorMap = {
  new:          { bg: hex(colors.red, 0.12),   color: colors.red },
  acknowledged: { bg: hex(colors.amber, 0.12), color: colors.amber },
  resolved:     { bg: hex(colors.tealLoom, 0.12), color: colors.tealLoom },
}

const COMPLIANCE: ColorMap = {
  pass:                   { bg: hex(colors.tealLoom, 0.12),  color: colors.tealLoom },
  fail:                   { bg: hex(colors.red, 0.12),       color: colors.red },
  pending:                { bg: hex(colors.slateGray, 0.15), color: colors.muted },
  reassessment_requested: { bg: hex(colors.amber, 0.12),     color: colors.amber },
}

const NHI: ColorMap = {
  discovered:           { bg: hex(colors.irisViolet, 0.12), color: colors.irisViolet },
  enrollment_requested: { bg: hex(colors.amber, 0.12),      color: colors.amber },
  dismissed:            { bg: hex(colors.slateGray, 0.15),  color: colors.muted },
}

const ALL_MAPS: Record<string, ColorMap> = {
  lifecycle: LIFECYCLE,
  risk: RISK,
  privilege: PRIVILEGE,
  violation: VIOLATION,
  compliance: COMPLIANCE,
  nhi: NHI,
}

function getColor(status: string, variant?: string): { bg: string; color: string } {
  if (variant && ALL_MAPS[variant]?.[status]) return ALL_MAPS[variant][status]
  for (const m of Object.values(ALL_MAPS)) {
    if (m[status]) return m[status]
  }
  return { bg: hex(colors.slateGray, 0.15), color: colors.muted }
}

export default function StatusBadge({ status, variant }: Props) {
  const { bg, color } = getColor(status, variant)
  return (
    <span className="tag" style={{ background: bg, color }}>
      {status.replace(/_/g, ' ')}
    </span>
  )
}
