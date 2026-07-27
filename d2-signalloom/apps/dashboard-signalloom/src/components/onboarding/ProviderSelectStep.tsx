import type { ConnectorProvider } from '../../types/connectors'

interface Props {
  providers: ConnectorProvider[]
  selectedProviderIds: string[]
  connectedProviderIds: Set<string>
  onToggle: (providerId: string) => void
}

// Renders every provider returned by GET /connectors/providers — no
// per-provider branching. New providers (e.g. a 6th identity source) show up
// automatically once Stream A's plugin registers itself.
export default function ProviderSelectStep({
  providers,
  selectedProviderIds,
  connectedProviderIds,
  onToggle,
}: Props) {
  return (
    <div>
      <h1 style={{ fontSize: 26, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>
        Connect your identity providers
      </h1>
      <p style={{ color: 'var(--muted)', fontSize: 14, marginBottom: 28, maxWidth: 560 }}>
        Signal Loom scans each connected provider for non-human identities (service
        accounts, API keys, bots) so we can surface stale credentials and privilege
        risk. Pick as many as apply — you can add more later from Settings.
      </p>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, maxWidth: 560 }}>
        {providers.map((provider) => {
          const isConnected = connectedProviderIds.has(provider.provider_id)
          const isSelected = selectedProviderIds.includes(provider.provider_id) || isConnected
          return (
            <label
              key={provider.provider_id}
              className="card"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 14,
                cursor: isConnected ? 'default' : 'pointer',
                borderColor: isSelected ? 'var(--cyan)' : undefined,
                opacity: isConnected ? 0.75 : 1,
              }}
            >
              <input
                type="checkbox"
                checked={isSelected}
                disabled={isConnected}
                onChange={() => onToggle(provider.provider_id)}
                aria-label={`Select ${provider.display_name}`}
                style={{ width: 16, height: 16, accentColor: 'var(--cyan)', flexShrink: 0 }}
              />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
                  {provider.display_name}
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
                  {provider.wizard_config.help_text}
                </div>
              </div>
              {isConnected && (
                <span className="tag" style={{ background: 'rgba(16,185,129,0.12)', color: 'var(--teal)', flexShrink: 0 }}>
                  Connected
                </span>
              )}
            </label>
          )
        })}
      </div>
    </div>
  )
}
