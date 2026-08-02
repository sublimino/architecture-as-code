import type { ConnectorProvider } from '../../types/connectors'
import ProviderLogo from './ProviderLogo'

interface Props {
  providers: ConnectorProvider[]
  selectedProviderIds: string[]
  connectedProviderIds: Set<string>
  onToggle: (providerId: string) => void
}

// Renders every provider returned by GET /connectors/providers — no
// per-provider branching. New providers (e.g. a 6th identity source) show up
// automatically once Stream A's plugin registers itself.
//
// Grid, not a stacked list — a vertical stack of 5 full-width rows forced
// unnecessary scrolling in a centered column; a responsive grid uses the
// available width and fits everything above the fold on most screens.
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
      <p style={{ color: 'var(--muted)', fontSize: 14, marginBottom: 28 }}>
        Signal Loom scans each connected provider for non-human identities (service
        accounts, API keys, bots) so we can surface stale credentials and privilege
        risk. Pick as many as apply — you can add more later from Settings.
      </p>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))', gap: 14 }}>
        {providers.map((provider) => {
          const isConnected = connectedProviderIds.has(provider.provider_id)
          const isSelected = selectedProviderIds.includes(provider.provider_id) || isConnected
          return (
            <label
              key={provider.provider_id}
              className="card"
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 10,
                cursor: isConnected ? 'default' : 'pointer',
                borderColor: isSelected ? 'var(--cyan)' : undefined,
                opacity: isConnected ? 0.75 : 1,
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <ProviderLogo providerId={provider.provider_id} displayName={provider.display_name} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
                    {provider.display_name}
                  </div>
                  {isConnected && (
                    <span className="tag" style={{ background: 'rgba(16,185,129,0.12)', color: 'var(--teal)', fontSize: 10 }}>
                      Connected
                    </span>
                  )}
                </div>
                <input
                  type="checkbox"
                  checked={isSelected}
                  disabled={isConnected}
                  onChange={() => onToggle(provider.provider_id)}
                  aria-label={`Select ${provider.display_name}`}
                  style={{ width: 16, height: 16, accentColor: 'var(--cyan)', flexShrink: 0 }}
                />
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                {provider.wizard_config.help_text}
              </div>
            </label>
          )
        })}
      </div>
    </div>
  )
}
