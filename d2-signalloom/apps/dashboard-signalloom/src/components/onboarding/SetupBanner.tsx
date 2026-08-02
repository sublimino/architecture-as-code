import { useNavigate } from 'react-router-dom'

interface Props {
  connectedCount: number
  totalCount: number
}

// Persistent dashboard-wide "Complete setup" nudge (US-ENHC-011 closeout).
// Distinct from ProgressBanner.tsx, which lives inside the wizard itself and
// tracks per-provider connect status within the wizard's step machine — this
// one is coarser (just "setup incomplete, click to resume") and renders on
// every page except the wizard and its help pages (see App.tsx).
export default function SetupBanner({ connectedCount, totalCount }: Props) {
  const navigate = useNavigate()
  const progressPct = totalCount > 0 ? Math.round((connectedCount / totalCount) * 100) : 0

  return (
    <div
      role="status"
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 16,
        padding: '12px 32px',
        background: 'var(--surface2)',
        borderBottom: '1px solid var(--border)',
        flexWrap: 'wrap',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
          Complete setup to start discovering non-human identities
        </span>
        <div
          style={{
            width: 120,
            height: 6,
            borderRadius: 3,
            background: 'var(--border)',
            overflow: 'hidden',
          }}
          aria-hidden="true"
        >
          <div
            style={{
              width: `${progressPct}%`,
              height: '100%',
              background: 'var(--cyan)',
              transition: 'width 0.3s ease',
            }}
          />
        </div>
        <span style={{ fontSize: 12, color: 'var(--muted)' }}>
          {connectedCount} of {totalCount} providers connected
        </span>
      </div>

      <button className="btn btn-primary" onClick={() => navigate('/onboarding')}>
        Complete setup
      </button>
    </div>
  )
}
