export const colors = {
  deepMidnight: 'var(--bg)',
  slateDark: 'var(--surface)',
  elevatedSlate: 'var(--surface2)',
  cyanLoom: 'var(--cyan)',
  irisViolet: 'var(--violet)',
  tealLoom: 'var(--teal)',
  amber: 'var(--amber)',
  red: 'var(--error)',
  electricWhite: 'var(--text)',
  muted: 'var(--muted)',
  dim: 'var(--dim)',
  slateGray: 'var(--slate-gray)',
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
