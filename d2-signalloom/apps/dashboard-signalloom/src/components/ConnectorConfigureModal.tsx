import { useEffect, useRef, useState, type FormEvent } from 'react'
import type { ConnectorCreateRequest, ConnectorProvider, TenantConnector } from '../types/connectors'
import { useAuth0 } from '../auth/oidc'
import ProviderLogo from './onboarding/ProviderLogo'
import WizardFieldRenderer from './onboarding/WizardFieldRenderer'
import { tint } from './StatusBadge'
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

// Design-system audit rule 11: only failed/unchecked need the dot-carries-the-
// colour treatment (teal/verified already passes AA as direct text colour).
const RESULT_DOT: Partial<Record<VerificationOutcome['status'], string>> = {
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
  const dialogRef = useRef<HTMLDivElement>(null)

  // A1 (design-system audit): Escape closes, matching SyncLogsModal's
  // existing behaviour on the same Settings row.
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    if (isOpen) window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [isOpen, onClose])

  // A1 (design-system audit): initial focus moves into the dialog, and is
  // restored to whatever was focused before opening. Scoped to the `isOpen`
  // transition only (not every render) so the restore doesn't fire just
  // because a parent re-creates `onClose` on re-render.
  useEffect(() => {
    if (!isOpen) return
    const previouslyFocused = document.activeElement as HTMLElement | null
    const panel = dialogRef.current
    // Prefer the first real form field over the Close button, which is the
    // first focusable element in DOM order but not where a keyboard user
    // typing credentials wants to land.
    const firstField = panel?.querySelector<HTMLElement>('input, select, textarea')
    ;(firstField ?? panel)?.focus()
    return () => {
      previouslyFocused?.focus()
    }
  }, [isOpen])

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
    <div className="modal-overlay">
      <div
        ref={dialogRef}
        className="card slide-up"
        style={{
          width: 580,
          maxWidth: '100%',
          maxHeight: '90vh',
          overflowY: 'auto',
          padding: 24,
        }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="configure-connector-title"
        tabIndex={-1}
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
              // Themed tint(), not the unthemed --cyan-focus/-border alpha
              // ramp (design-system audit, rule 2 / finding C6): those are
              // fixed dark-palette hex values and show the wrong hue under
              // the light theme.
              background: tint('var(--cyan)', 0.1),
              border: `1px solid ${tint('var(--cyan)', 0.33)}`,
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
                  style={{
                    fontSize: 12,
                    // Design-system audit rule 11 / finding C5: `--error` and
                    // `--amber` measured 3.02-3.39:1 as text, under the 4.5:1
                    // AA floor. `--teal` (verified) doesn't have that problem
                    // and keeps its direct colour; failed/unchecked move the
                    // body to `--text` and carry the colour on a dot instead.
                    color: RESULT_DOT[testResult.status] ? 'var(--text)' : RESULT_COLOUR[testResult.status],
                    lineHeight: 1.4,
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 6,
                  }}
                >
                  {RESULT_DOT[testResult.status] && (
                    <span
                      aria-hidden="true"
                      data-testid="test-connection-result-dot"
                      style={{ width: 6, height: 6, borderRadius: '50%', background: RESULT_DOT[testResult.status], flexShrink: 0 }}
                    />
                  )}
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
                // Themed tint(), not the unthemed --red-focus/-border alpha
                // ramp — see the comment on the stored-credentials note above.
                background: tint('var(--error)', 0.1),
                border: `1px solid ${tint('var(--error)', 0.3)}`,
                borderRadius: 'var(--radius-sm)',
                // Design-system audit rule 11 / finding C4: `--error` as body
                // text measured 3.39:1 in dark, under the 4.5:1 AA floor for
                // 12px text. The red rule (the border above) carries the
                // colour; the message itself reads in `--text`.
                color: 'var(--text)',
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
