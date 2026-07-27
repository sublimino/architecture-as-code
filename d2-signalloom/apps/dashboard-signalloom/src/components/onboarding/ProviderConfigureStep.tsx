import { useState, type FormEvent } from 'react'
import type { ConnectorProvider } from '../../types/connectors'
import WizardFieldRenderer from './WizardFieldRenderer'

interface Props {
  provider: ConnectorProvider
  submitting: boolean
  error?: string
  onSubmit: (credentials: Record<string, string>) => void
  onBack: () => void
  onSkipProvider: () => void
}

export default function ProviderConfigureStep({
  provider,
  submitting,
  error,
  onSubmit,
  onBack,
  onSkipProvider,
}: Props) {
  const [values, setValues] = useState<Record<string, string>>({})

  const missingRequired = provider.wizard_config.fields
    .filter((f) => f.required)
    .some((f) => !values[f.name]?.trim())

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (missingRequired || submitting) return
    onSubmit(values)
  }

  return (
    <div style={{ maxWidth: 560 }}>
      <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', marginBottom: 6 }}>
        Set up {provider.display_name}
      </h1>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 20 }}>
        {provider.wizard_config.help_text}{' '}
        <a href={provider.wizard_config.docs_link} target="_blank" rel="noreferrer">
          View setup docs
        </a>
      </p>

      {provider.wizard_config.permissions.length > 0 && (
        <div className="card" style={{ marginBottom: 20, padding: 14 }}>
          <p style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}>
            Required permissions
          </p>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {provider.wizard_config.permissions.map((perm) => (
              <span key={perm} className="tag" style={{ background: 'var(--surface2)', color: 'var(--muted)' }}>
                {perm}
              </span>
            ))}
          </div>
        </div>
      )}

      <form onSubmit={handleSubmit} noValidate>
        <WizardFieldRenderer
          fields={provider.wizard_config.fields}
          values={values}
          onChange={(key, value) => setValues((v) => ({ ...v, [key]: value }))}
          disabled={submitting}
        />

        {error && (
          <div
            style={{
              marginTop: 16,
              padding: '10px 14px',
              background: 'rgba(220,38,38,0.1)',
              border: '1px solid rgba(220,38,38,0.4)',
              borderRadius: 6,
              color: '#ff6b6b',
              fontSize: 13,
            }}
          >
            {error}
          </div>
        )}

        <div style={{ display: 'flex', gap: 10, marginTop: 24 }}>
          <button type="button" className="btn btn-secondary" onClick={onBack} disabled={submitting}>
            Back
          </button>
          <button type="submit" className="btn btn-primary" disabled={missingRequired || submitting}>
            {submitting ? 'Connecting…' : 'Connect'}
          </button>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={onSkipProvider}
            disabled={submitting}
            style={{ marginLeft: 'auto' }}
          >
            Skip this provider
          </button>
        </div>
      </form>
    </div>
  )
}
