import { syncModeLabel, useRemoteAgents } from '../../hooks/useConnectorStream'
import SyncStatusPill, { type SyncTone } from './SyncStatusPill'

// Compact remote sync state for an AI provider's connector row in Settings,
// fed by the same shared store as the remote environment page. "Live" is only
// claimed when the upstream streams or pushes AND this tab's stream is open.
//
// A2 (design-system audit): renders through the shared SyncStatusPill rather
// than a hand-rolled pill with its own tone map.

export default function RemoteSyncBadge({ providerId }: { providerId: string }) {
  const { view, connection } = useRemoteAgents(providerId)
  if (view.status === 'not_configured') return null

  let text = 'Checking sync…'
  let tone: SyncTone = 'muted'
  let title: string | undefined
  const sync = view.syncState
  if (view.status === 'error') {
    text = 'Sync state unavailable'
    title = view.error ?? undefined
  } else if (sync?.last_error) {
    text = `Sync error: ${sync.last_error}`
    tone = 'red'
    title = sync.last_error
  } else if (connection.status === 'reconnecting') {
    text = 'Reconnecting'
    tone = 'amber'
    title = connection.error ?? undefined
  } else if (sync) {
    const label = syncModeLabel(sync)
    const streamUp = connection.status === 'open' || connection.status === 'demo'
    if (!label.startsWith('Live')) {
      text = label
      tone = 'cyan'
    } else if (streamUp) {
      text = 'Live'
      tone = 'teal'
    } else {
      text = 'Connecting'
    }
  }

  return (
    <SyncStatusPill
      tone={tone}
      label={text}
      testId={`remote-sync-${providerId}`}
      title={title}
      ariaLive="polite"
      style={{ maxWidth: 260, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
    />
  )
}
