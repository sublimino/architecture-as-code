// Purpose-built preview illustrations for the wizard's Welcome-step tour.
// Not real screenshots — the browser tooling available in this session can't
// export a captured screenshot to a file (only display it inline), so these
// are hand-built mockups instead, styled to match the real pages (same dark
// surfaces, same cyan/violet/teal/amber/red accent palette, same card/table
// conventions) and populated with representative — not necessarily literal —
// data, per an explicit call to make these "more exciting" than a sparse
// live capture would be. Swap for real screenshots later if desired; the
// call site (WelcomeStep.tsx) just takes an image src, so no structural
// change would be needed.

const BG = 'var(--surface)'
const SURFACE = 'var(--surface2)'
const BORDER = 'var(--border-subtle)'
// CYAN/TEAL stay literal: both are string-concatenated with hex alpha
// suffixes below (`${CYAN}22`, `${c.color}33`), which var() cannot express.
const CYAN = '#06B6D4'
const VIOLET = '#8B5CF6'
const TEAL = '#10B981'
const AMBER = '#D97706'
const RED = '#DC2626'
const MUTED = '#64748B'
const TEXT = '#F1F5F9'

const previewStyle = {
  width: 160, height: 100, borderRadius: 8, border: `1px solid ${BORDER}`,
  flexShrink: 0, display: 'block' as const,
}

export function DiscoveryPreview() {
  return (
    <svg viewBox="0 0 320 200" style={previewStyle} xmlns="http://www.w3.org/2000/svg">
      <rect width="320" height="200" fill={BG} />
      <rect x="10" y="10" width="300" height="26" rx="5" fill={`${RED}22`} stroke={`${RED}55`} />
      <circle cx="24" cy="23" r="4" fill={RED} />
      <rect x="36" y="18" width="90" height="10" rx="2" fill={RED} opacity="0.85" />
      <rect x="10" y="46" width="300" height="34" rx="5" fill={SURFACE} stroke={BORDER} />
      <rect x="20" y="55" width="60" height="8" rx="2" fill={MUTED} />
      <rect x="20" y="66" width="40" height="10" rx="2" fill={TEXT} />
      <rect x="140" y="55" width="60" height="8" rx="2" fill={MUTED} />
      <rect x="140" y="66" width="90" height="10" rx="2" fill={CYAN} />
      {[0, 1, 2, 3].map((i) => (
        <g key={i}>
          <rect x="10" y={90 + i * 26} width="300" height="22" rx="4" fill={SURFACE} opacity={0.6} />
          <rect x="18" y={97 + i * 26} width="80" height="8" rx="2" fill={TEXT} opacity="0.9" />
          <rect x="150" y={97 + i * 26} width="46" height="8" rx="2" fill={i % 2 === 0 ? RED : MUTED} />
          <rect x="210" y={97 + i * 26} width="40" height="8" rx="2" fill={AMBER} opacity={i % 3 === 0 ? 1 : 0.3} />
          <rect x="264" y={97 + i * 26} width="36" height="8" rx="2" fill={VIOLET} opacity="0.7" />
        </g>
      ))}
    </svg>
  )
}

export function AgentsPreview() {
  const cards = [
    { color: TEAL, label: 'Active' },
    { color: CYAN, label: 'Enrolled' },
    { color: AMBER, label: 'Suspended' },
  ]
  return (
    <svg viewBox="0 0 320 200" style={previewStyle} xmlns="http://www.w3.org/2000/svg">
      <rect width="320" height="200" fill={BG} />
      {cards.map((c, i) => (
        <g key={i} transform={`translate(${10 + i * 106}, 14)`}>
          <rect width="96" height="172" rx="8" fill={SURFACE} stroke={BORDER} />
          <circle cx="20" cy="24" r="5" fill={c.color} />
          <rect x="14" y="42" width="68" height="9" rx="2" fill={TEXT} />
          <rect x="14" y="58" width="50" height="7" rx="2" fill={MUTED} />
          <rect x="14" y="80" width="68" height="6" rx="2" fill={BORDER} />
          <rect x="14" y="80" width={i === 0 ? 60 : i === 1 ? 34 : 18} height="6" rx="2" fill={c.color} />
          <rect x="14" y="96" width="34" height="14" rx="3" fill={`${c.color}33`} />
          <rect x="20" y="100" width="22" height="6" rx="1.5" fill={c.color} />
        </g>
      ))}
    </svg>
  )
}

export function CompliancePreview() {
  return (
    <svg viewBox="0 0 320 200" style={previewStyle} xmlns="http://www.w3.org/2000/svg">
      <rect width="320" height="200" fill={BG} />
      <g transform="translate(70,100)">
        <circle r="52" fill="none" stroke={BORDER} strokeWidth="16" />
        <circle r="52" fill="none" stroke={TEAL} strokeWidth="16" strokeDasharray="245 327" strokeLinecap="round" transform="rotate(-90)" />
        <text x="0" y="8" textAnchor="middle" fontSize="28" fontWeight="700" fill={TEXT} fontFamily="sans-serif">75%</text>
      </g>
      {[
        { label: 'SOC 2 Type II', color: TEAL, w: 70 },
        { label: 'EU AI Act', color: CYAN, w: 50 },
        { label: 'ISO 42001', color: AMBER, w: 34 },
      ].map((row, i) => (
        <g key={row.label} transform={`translate(150, ${44 + i * 42})`}>
          <rect width="150" height="9" rx="2" fill={TEXT} opacity="0.85" />
          <rect y="18" width="150" height="8" rx="4" fill={BORDER} />
          <rect y="18" width={row.w} height="8" rx="4" fill={row.color} />
        </g>
      ))}
    </svg>
  )
}

export function AuditTrailPreview() {
  return (
    <svg viewBox="0 0 320 200" style={previewStyle} xmlns="http://www.w3.org/2000/svg">
      <rect width="320" height="200" fill={BG} />
      <line x1="30" y1="16" x2="30" y2="184" stroke={BORDER} strokeWidth="2" />
      {[
        { color: TEAL, w: 200 },
        { color: CYAN, w: 160 },
        { color: VIOLET, w: 220 },
        { color: AMBER, w: 140 },
        { color: TEAL, w: 180 },
      ].map((row, i) => (
        <g key={i} transform={`translate(0, ${20 + i * 34})`}>
          <circle cx="30" cy="8" r="6" fill={row.color} />
          <rect x="48" y="0" width={row.w} height="9" rx="2" fill={TEXT} opacity="0.9" />
          <rect x="48" y="14" width={row.w * 0.5} height="6" rx="2" fill={MUTED} />
        </g>
      ))}
    </svg>
  )
}

export function SettingsPreview() {
  return (
    <svg viewBox="0 0 320 200" style={previewStyle} xmlns="http://www.w3.org/2000/svg">
      <rect width="320" height="200" fill={BG} />
      {[
        { on: true, label: 84 },
        { on: true, label: 60 },
        { on: false, label: 72 },
      ].map((row, i) => (
        <g key={i} transform={`translate(16, ${20 + i * 56})`}>
          <rect width="288" height="42" rx="7" fill={SURFACE} stroke={BORDER} />
          <circle cx="22" cy="21" r="10" fill={`${CYAN}22`} />
          <rect x="42" y="12" width={row.label} height="8" rx="2" fill={TEXT} />
          <rect x="42" y="24" width={row.label * 0.6} height="6" rx="2" fill={MUTED} />
          <rect x="240" y="12" width="32" height="18" rx="9" fill={row.on ? CYAN : BORDER} />
          <circle cx={row.on ? 262 : 250} cy="21" r="7" fill="var(--on-accent)" />
        </g>
      ))}
    </svg>
  )
}
