export const colors = {
  deepMidnight: '#020617',
  slateDark: '#0F172A',
  elevatedSlate: '#1E293B',
  cyanLoom: '#06B6D4',
  irisViolet: '#8B5CF6',
  tealLoom: '#10B981',
  amber: '#D97706',
  red: '#DC2626',
  electricWhite: '#F8FAFC',
  muted: '#94A3B8',
  dim: '#64748B',
  slateGray: '#475569',
}

// Matches demo v5's donut rendering (measured live, 2026-07-30): sharp segment
// edges with no visible border, ~3deg gap between segments — Recharts' own
// defaults (a 1px white stroke, 0 paddingAngle) are what made ours read chunky.
export const donutDefaults = {
  paddingAngle: 3,
  cornerRadius: 0,
  stroke: 'none',
}

export const statusColors = {
  active: colors.tealLoom,
  compliant: colors.tealLoom,
  pass: colors.tealLoom,
  good: colors.tealLoom,
  resolved: colors.tealLoom,
  enrolled: colors.cyanLoom,
  pending: colors.cyanLoom,
  reassessmentRequested: colors.cyanLoom,
  suspended: colors.amber,
  warning: colors.amber,
  newViolation: colors.amber,
  revoked: colors.red,
  nonCompliant: colors.red,
  failed: colors.red,
  critical: colors.red,
  notClassified: colors.slateGray,
  acknowledged: colors.slateGray,
}
