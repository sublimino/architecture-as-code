import type { ConnectorProvider } from '../../types/connectors'
import type { ProviderRunState } from '../../hooks/useOnboardingWizard'

interface Props {
  providers: ConnectorProvider[]
  selectedProviderIds: string[]
  providerRunState: Record<string, ProviderRunState>
  stepNumber: number
  totalSteps: number
  onSkip: () => void
}

const STATUS_COLOR: Record<ProviderRunState['status'], string> = {
  idle: 'var(--muted)',
  submitting: 'var(--cyan)',
  connected: 'var(--teal)',
  error: 'var(--error)',
}

const STATUS_LABEL: Record<ProviderRunState['status'], string> = {
  idle: 'Not started',
  submitting: 'Connecting…',
  connected: 'Connected',
  error: 'Error',
}

export default function ProgressBanner({
  providers,
  selectedProviderIds,
  providerRunState,
  stepNumber,
  totalSteps,
  onSkip,
}: Props) {
  const displayName = (id: string) => providers.find((p) => p.provider_id === id)?.display_name ?? id

  const progressPct = totalSteps > 0 ? Math.round((stepNumber / totalSteps) * 100) : 0

  return (
    <div style={{ borderBottom: '1px solid var(--border)' }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 16,
          padding: '14px 32px 10px',
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
            Step {stepNumber} of {totalSteps}
          </span>

          {selectedProviderIds.length > 0 && (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {selectedProviderIds.map((id) => {
                const status = providerRunState[id]?.status ?? 'idle'
                return (
                  <span
                    key={id}
                    className="tag"
                    style={{
                      background: `${STATUS_COLOR[status]}1f`,
                      color: STATUS_COLOR[status],
                    }}
                    title={`${displayName(id)} — ${STATUS_LABEL[status]}`}
                  >
                    {displayName(id)}: {STATUS_LABEL[status]}
                  </span>
                )
              })}
            </div>
          )}
        </div>

        <button className="btn btn-secondary" onClick={onSkip}>
          Skip for now
        </button>
      </div>

      {/* Visual progress bar + step dots — the old version was text-only
          ("Step X of Y"), which read as flat/utilitarian rather than
          showing at-a-glance where you are in the flow. */}
      <div style={{ padding: '0 32px 14px', display: 'flex', alignItems: 'center', gap: 6 }}>
        <div
          role="progressbar"
          aria-valuenow={progressPct}
          aria-valuemin={0}
          aria-valuemax={100}
          style={{
            flex: 1, height: 6, borderRadius: 3, background: 'var(--border)',
            overflow: 'hidden',
          }}
        >
          <div
            style={{
              width: `${progressPct}%`, height: '100%',
              background: 'linear-gradient(90deg, var(--cyan), var(--violet, #8B5CF6))',
              borderRadius: 3, transition: 'width 0.3s ease',
            }}
          />
        </div>
        {Array.from({ length: totalSteps }, (_, i) => (
          <span
            key={i}
            aria-hidden="true"
            style={{
              width: 6, height: 6, borderRadius: '50%', flexShrink: 0,
              background: i < stepNumber ? 'var(--cyan)' : 'var(--border)',
            }}
          />
        ))}
      </div>
    </div>
  )
}
