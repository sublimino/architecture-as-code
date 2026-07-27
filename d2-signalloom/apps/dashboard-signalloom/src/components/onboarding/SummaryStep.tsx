import type { TenantConnector } from '../../types/connectors'

interface Props {
  connectors: TenantConnector[]
  disconnectingId: string | null
  onDisconnect: (connector: TenantConnector) => void
  onFinish: () => void
  onBack: () => void
}

function daysUntil(iso: string | null): number | null {
  if (!iso) return null
  return Math.ceil((new Date(iso).getTime() - Date.now()) / (24 * 60 * 60 * 1000))
}

function expiryLabel(iso: string | null): { text: string; warn: boolean } | null {
  const days = daysUntil(iso)
  if (days === null) return null
  if (days <= 0) return { text: 'Credential expired', warn: true }
  if (days <= 30) return { text: `Expires in ${days} day${days === 1 ? '' : 's'}`, warn: true }
  return { text: `Expires in ${days} days`, warn: false }
}

export default function SummaryStep({ connectors, disconnectingId, onDisconnect, onFinish, onBack }: Props) {
  const active = connectors.filter((c) => c.status !== 'disconnected')

  return (
    <div style={{ maxWidth: 640 }}>
      <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', marginBottom: 6 }}>
        Review your connections
      </h1>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 24 }}>
        You can disconnect a provider at any time. Disconnecting stops future scans but
        keeps historical NHI findings from that provider — nothing is deleted.
      </p>

      {active.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: 32, color: 'var(--muted)' }}>
          No providers connected yet.
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {active.map((c) => {
            const expiry = expiryLabel(c.credential_expires_at)
            return (
              <div key={c.connector_id} className="card" style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
                    {c.display_name ?? c.provider_id}
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, display: 'flex', gap: 10, flexWrap: 'wrap' }}>
                    <span
                      className="tag"
                      style={{
                        background: c.status === 'connected' ? 'rgba(16,185,129,0.12)' : 'rgba(220,38,38,0.12)',
                        color: c.status === 'connected' ? 'var(--teal)' : 'var(--error)',
                      }}
                    >
                      {c.status}
                    </span>
                    {expiry && (
                      <span style={{ color: expiry.warn ? 'var(--amber)' : 'var(--muted)' }}>
                        {expiry.text}
                      </span>
                    )}
                  </div>
                </div>
                <button
                  className="btn btn-danger"
                  onClick={() => onDisconnect(c)}
                  disabled={disconnectingId === c.connector_id}
                >
                  {disconnectingId === c.connector_id ? 'Disconnecting…' : 'Disconnect'}
                </button>
              </div>
            )
          })}
        </div>
      )}

      <div style={{ display: 'flex', gap: 10, marginTop: 24 }}>
        <button className="btn btn-secondary" onClick={onBack}>
          Back
        </button>
        <button className="btn btn-primary" onClick={onFinish}>
          Finish
        </button>
      </div>
    </div>
  )
}
