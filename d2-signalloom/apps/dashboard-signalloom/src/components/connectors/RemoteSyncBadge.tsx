import { syncModeLabel, useRemoteAgents } from '../../hooks/useConnectorStream'

// Compact remote sync state for an AI provider's connector row in Settings,
// fed by the same shared store as the remote environment page. "Live" is only
// claimed when the upstream streams or pushes AND this tab's stream is open.

const TONES = {
  teal: { color: 'var(--teal)', background: 'var(--teal-bg)', border: '1px solid var(--teal-border)' },
  cyan: { color: 'var(--cyan)', background: 'var(--cyan-bg)', border: '1px solid var(--cyan-border)' },
  amber: { color: 'var(--warning)', background: 'var(--amber-bg)', border: '1px solid var(--amber-border)' },
  red: { color: 'var(--error)', background: 'var(--red-bg)', border: '1px solid var(--red-border)' },
  muted: { color: 'var(--muted)', background: 'var(--surface)', border: '1px solid var(--border-subtle)' },
}

export default function RemoteSyncBadge({ providerId }: { providerId: string }) {
  const { view, connection } = useRemoteAgents(providerId)
  if (view.status === 'not_configured') return null

  let text = 'Checking sync…'
  let tone = TONES.muted
  let title: string | undefined
  const sync = view.syncState
  if (view.status === 'error') {
    text = 'Sync state unavailable'
    title = view.error ?? undefined
  } else if (sync?.last_error) {
    text = `Sync error: ${sync.last_error}`
    tone = TONES.red
    title = sync.last_error
  } else if (connection.status === 'reconnecting') {
    text = 'Reconnecting'
    tone = TONES.amber
    title = connection.error ?? undefined
  } else if (sync) {
    const label = syncModeLabel(sync)
    const streamUp = connection.status === 'open' || connection.status === 'demo'
    if (!label.startsWith('Live')) {
      text = label
      tone = TONES.cyan
    } else if (streamUp) {
      text = 'Live'
      tone = TONES.teal
    } else {
      text = 'Connecting'
    }
  }

  return (
    <span
      data-testid={`remote-sync-${providerId}`}
      aria-live="polite"
      title={title}
      style={{
        fontSize: 11,
        fontWeight: 600,
        padding: '2px 8px',
        borderRadius: 10,
        letterSpacing: '0.02em',
        maxWidth: 260,
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
        ...tone,
      }}
    >
      {text}
    </span>
  )
}
