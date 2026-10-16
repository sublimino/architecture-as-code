import { useState, type FormEvent } from 'react'
import type { ConnectorCreateRequest, ConnectorProvider, TenantConnector } from '../types/connectors'
import { useAuth0 } from '../auth/oidc'
import ProviderLogo from './onboarding/ProviderLogo'
import WizardFieldRenderer from './onboarding/WizardFieldRenderer'
import {
  typedCredentials,
  verifyConnectorCredentials,
  type VerificationOutcome,
} from './onboarding/connectorVerification'

interface Props {
  provider: ConnectorProvider
  // The tenant's existing connector for this provider, when there is one: its
  // credentials are held by the server and are never sent back to the browser.
  connector?: TenantConnector | null
  isOpen: boolean
  onClose: () => void
  onSave: (payload: ConnectorCreateRequest) => Promise<void>
  // Prefill for the provider's wizard_config fields.
  initialValues?: Record<string, string>
  // Replaces the server credential test for a provider whose check is not a
  // connector test (in-cluster Dex: the portal session probe).
  verify?: (credentials: Record<string, string>) => Promise<VerificationOutcome>
  onTested?: (outcome: VerificationOutcome) => void
}

const RESULT_TESTID: Record<VerificationOutcome['status'], string> = {
  verified: 'test-connection-success',
  failed: 'test-connection-error',
  unchecked: 'test-connection-unchecked',
}

const RESULT_COLOUR: Record<VerificationOutcome['status'], string> = {
  verified: 'var(--teal)',
  failed: 'var(--error)',
  unchecked: 'var(--amber)',
}

export default function ConnectorConfigureModal({
  provider,
  connector,
  isOpen,
  onClose,
  onSave,
  initialValues,
  verify,
  onTested,
}: Props) {
  const { getAccessTokenSilently } = useAuth0()
  const [values, setValues] = useState<Record<string, string>>(() => ({ ...initialValues }))
  const [testing, setTesting] = useState(false)
  const [testResult, setTestResult] = useState<VerificationOutcome | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!isOpen) return null

  const fields = provider.wizard_config.fields
  // A disconnected row's credentials are gone; any other row still has them.
  const serverHoldsCredentials = Boolean(connector && connector.status !== 'disconnected')

  const handleTest = async () => {
    setTesting(true)
    setTestResult(null)
    setError(null)
    let outcome: VerificationOutcome
    try {
      outcome = verify
        ? await verify(typedCredentials(values))
        : await verifyConnectorCredentials({
            token: await getAccessTokenSilently(),
            providerId: provider.provider_id,
            credentials: values,
            connectorId: serverHoldsCredentials ? connector?.connector_id : undefined,
          })
    } catch (err) {
      outcome = { status: 'failed', message: err instanceof Error ? err.message : 'Connection test failed.' }
    }
    setTestResult(outcome)
    setTesting(false)
    onTested?.(outcome)
  }

  const handleFormSubmit = async (e: FormEvent) => {
    e.preventDefault()
    setError(null)

    const credentials = typedCredentials(values)
    // The server replaces a stored credential set wholesale, so "keep what is
    // stored" is only possible when nothing at all is typed. A test result
    // never stands in for a credential.
    const keepStored = serverHoldsCredentials && Object.keys(credentials).length === 0
    if (!keepStored) {
      const missing = fields.find((f) => f.required && !credentials[f.name])
      if (missing) {
        setError(`${missing.label} is required.`)
        return
      }
    }

    setSaving(true)
    try {
      await onSave({
        provider_id: provider.provider_id,
        // An existing connector keeps its (possibly custom) name.
        ...(connector ? {} : { display_name: provider.display_name }),
        credentials,
      })
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save connector configuration.')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'color-mix(in srgb, var(--bg) 70%, transparent)',
        backdropFilter: 'blur(6px)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 2000,
        padding: 16,
      }}
    >
      <div
        className="card slide-up"
        style={{
          width: 580,
          maxWidth: '100%',
          maxHeight: '90vh',
          overflowY: 'auto',
          padding: 24,
          background: 'var(--surface)',
          borderRadius: 'var(--radius)',
          border: '1px solid var(--border-subtle)',
        }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="configure-connector-title"
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <ProviderLogo providerId={provider.provider_id} displayName={provider.display_name} size={36} />
            <div>
              <h2 id="configure-connector-title" style={{ fontSize: 17, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                Configure {provider.display_name}
              </h2>
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                {serverHoldsCredentials ? `Configured, status: ${connector?.status}` : 'Read-only Connector Setup'}
              </span>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="btn btn-secondary"
            aria-label="Close"
            style={{ padding: '4px 10px', fontSize: 12, lineHeight: 1 }}
          >
            ✕
          </button>
        </div>

        {provider.wizard_config.help_text && (
          <p style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5, marginBottom: 14 }}>
            {provider.wizard_config.help_text}
          </p>
        )}

        {serverHoldsCredentials && (
          <div
            data-testid="connector-stored-credentials-note"
            style={{
              padding: '10px 12px',
              background: 'var(--cyan-focus)',
              border: '1px solid var(--cyan-border)',
              borderRadius: 'var(--radius-sm)',
              fontSize: 12,
              color: 'var(--text)',
              lineHeight: 1.5,
              marginBottom: 14,
            }}
          >
            The server already holds credentials for this connector. Leave every field blank to keep them, or
            enter a complete new set to replace them.
          </div>
        )}

        <form onSubmit={handleFormSubmit} noValidate>
          <WizardFieldRenderer
            fields={fields}
            values={values}
            onChange={(key, val) => setValues((prev) => ({ ...prev, [key]: val }))}
            disabled={saving}
          />

          <div style={{ marginTop: 18, paddingTop: 14, borderTop: '1px solid var(--border)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="btn-modal-test-connection"
                onClick={() => void handleTest()}
                disabled={testing || saving}
                style={{ fontSize: 12 }}
              >
                {testing ? 'Testing Connection…' : 'Test Connection'}
              </button>

              {testResult && (
                <span
                  data-testid={RESULT_TESTID[testResult.status]}
                  role="status"
                  style={{ fontSize: 12, color: RESULT_COLOUR[testResult.status], lineHeight: 1.4 }}
                >
                  {testResult.message}
                </span>
              )}
            </div>
          </div>

          {error && (
            <div
              data-testid="connector-save-error"
              role="alert"
              style={{
                marginTop: 14,
                padding: '8px 12px',
                background: 'var(--red-focus)',
                border: '1px solid var(--red-border)',
                borderRadius: 'var(--radius-sm)',
                color: 'var(--error)',
                fontSize: 12,
              }}
            >
              {error}
            </div>
          )}

          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, marginTop: 22 }}>
            <button type="button" className="btn btn-secondary" onClick={onClose} disabled={saving}>
              Cancel
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              data-testid="btn-modal-save-connector"
              disabled={saving}
            >
              {saving ? 'Saving…' : 'Save & Enable Connector'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
