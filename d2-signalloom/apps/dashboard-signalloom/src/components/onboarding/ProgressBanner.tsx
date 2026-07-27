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

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        gap: 16,
        padding: '14px 32px',
        borderBottom: '1px solid var(--border)',
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
  )
}
