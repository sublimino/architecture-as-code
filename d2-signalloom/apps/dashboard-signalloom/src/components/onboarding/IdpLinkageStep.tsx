import React, { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import ValidationErrorBanner from './ValidationErrorBanner'
import ProviderLogo from './ProviderLogo'
import { useAuth0 } from '../../auth/oidc'
import { connectorsApi } from '../../api/connectorsClient'
import ConnectorConfigureModal from '../ConnectorConfigureModal'
import type { VerificationOutcome } from './connectorVerification'
import type { ConnectorCreateRequest, ConnectorProvider, TenantConnector } from '../../types/connectors'

export interface IdpConfigData {
  providerId: string
  providerName: string
  // Only in-cluster Dex has an issuer the wizard knows; connector providers
  // are described by their own wizard_config fields, held by the server.
  issuerUrl?: string
  // True only when a check answered by the server said so in this setup.
  connectionTested?: boolean
  // What the last successful check reported, so a resumed step can show it.
  connectionMessage?: string
}

export interface ConnectionTestResult {
  ok: boolean
  message: string
}

interface IdpLinkageStepProps {
  initialValues?: Partial<IdpConfigData>
  onNext: (data: IdpConfigData) => void
  onBack: () => void
  onSkip: () => void
  skipLabel?: string
  // The Dex check. The wizard passes a verifier that calls GET /api/v1/me with
  // the session bearer; the step itself never fabricates a result.
  onTestConnection?: (issuerUrl: string) => Promise<ConnectionTestResult>
}

const DEX_ID = 'dex'
const DEX_ISSUER = 'https://dex.inf-signalloom.svc.cluster.local:5556/dex'

interface IdpOption {
  id: string
  name: string
  tagline: string
}

// Each id other than dex is a backend connector provider_id
// (fe-signalloom routers/connectors.py STANDARD_PROVIDERS). Dex is the
// portal's own login issuer: there is no connector to create for it.
const IDP_OPTIONS: IdpOption[] = [
  { id: DEX_ID, name: 'Dex OIDC (In-Cluster)', tagline: 'Local Kubernetes native OIDC provider with SPIFFE trust federation.' },
  { id: 'okta', name: 'Okta Workforce Identity', tagline: 'Enterprise cloud SSO with SCIM user and group lifecycle provisioning.' },
  { id: 'ad_entra', name: 'Microsoft Entra ID', tagline: 'Azure Active Directory cloud IAM with conditional access integration.' },
  { id: 'google_workspace', name: 'Google Cloud IAM / Workspace', tagline: 'Google Identity services with OAuth2 Workload Identity Federation.' },
  { id: 'aws_iam', name: 'AWS IAM Identity Center', tagline: 'AWS IAM Identity Center OIDC endpoint with AWS IRSA trust roles.' },
  { id: 'claude', name: 'Anthropic Claude', tagline: 'Read-only agent discovery, model inventory, and CEL compliance governance.' },
  { id: 'openai', name: 'OpenAI Platform', tagline: 'Read-only assistant agent discovery, run telemetry, and tool permission audit.' },
]

const DEX_PROVIDER: ConnectorProvider = {
  provider_id: DEX_ID,
  display_name: 'Dex OIDC (In-Cluster)',
  wizard_config: {
    fields: [],
    permissions: [],
    docs_link: '',
    help_text:
      `Dex (${DEX_ISSUER}) is the portal's own login issuer, so there is nothing to store. ` +
      'Test Connection checks that the portal accepts this browser session (GET /api/v1/me).',
  },
}

const STATUS_TESTID: Record<VerificationOutcome['status'], string> = {
  verified: 'idp-connection-success',
  failed: 'idp-connection-error',
  unchecked: 'idp-connection-unchecked',
}

const STATUS_COLOUR: Record<VerificationOutcome['status'], string> = {
  verified: 'var(--teal)',
  failed: 'var(--error)',
  unchecked: 'var(--amber)',
}

function useSafeSearchParams() {
  try {
    return useSearchParams()
  } catch {
    const search = typeof window !== 'undefined' ? window.location.search : ''
    return [new URLSearchParams(search), () => {}] as const
  }
}

const isLive = (c: TenantConnector) => c.status !== 'disconnected'

export default function IdpLinkageStep({
  initialValues,
  onNext,
  onBack,
  onSkip,
  skipLabel = 'Skip for now',
  onTestConnection,
}: IdpLinkageStepProps) {
  const { getAccessTokenSilently } = useAuth0()
  const [searchParams] = useSafeSearchParams()
  const deepLinkDoneRef = useRef(false)

  const [providers, setProviders] = useState<ConnectorProvider[] | null>(null)
  const [connectors, setConnectors] = useState<TenantConnector[]>([])
  const [loadError, setLoadError] = useState<string | null>(null)

  const [selectedId, setSelectedId] = useState<string>(initialValues?.providerId ?? DEX_ID)
  const [configuringId, setConfiguringId] = useState<string | null>(null)
  const [outcomes, setOutcomes] = useState<Record<string, VerificationOutcome>>(() =>
    initialValues?.connectionTested && initialValues.providerId
      ? {
          [initialValues.providerId]: {
            status: 'verified',
            message: initialValues.connectionMessage ?? 'Verified earlier in this setup.',
          },
        }
      : {},
  )
  const [errors, setErrors] = useState<string[]>([])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const [p, c] = await Promise.all([
          connectorsApi.listProviders(token),
          connectorsApi.listConnectors(token),
        ])
        if (cancelled) return
        setProviders(p)
        setConnectors(c)
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Could not load connector providers.')
      }
    })()
    return () => {
      cancelled = true
    }
    // Loaded once per mount: the step re-mounts each time the wizard shows it.
  }, [])

  useEffect(() => {
    if (deepLinkDoneRef.current) return
    const target = searchParams.get('provider') || searchParams.get('configure')
    if (target && IDP_OPTIONS.some((o) => o.id === target)) {
      deepLinkDoneRef.current = true
      setSelectedId(target)
      setConfiguringId(target)
    }
  }, [searchParams])

  const providerFor = (id: string): ConnectorProvider | undefined =>
    id === DEX_ID ? DEX_PROVIDER : providers?.find((p) => p.provider_id === id)
  const connectorFor = (id: string) => connectors.find((c) => c.provider_id === id && isLive(c))
  const isConfigured = (id: string) => (id === DEX_ID ? outcomes[id]?.status === 'verified' : Boolean(connectorFor(id)))

  const activeOption = IDP_OPTIONS.find((o) => o.id === selectedId) ?? IDP_OPTIONS[0]
  const selectedOutcome = outcomes[selectedId]

  const openConfigure = (opt: IdpOption) => {
    setSelectedId(opt.id)
    setErrors([])
    setConfiguringId(opt.id)
  }

  const verifyDex = async (): Promise<VerificationOutcome> => {
    if (!onTestConnection) {
      return { status: 'failed', message: 'No connection verifier is wired to this step, so nothing was checked.' }
    }
    const result = await onTestConnection(DEX_ISSUER)
    return { status: result.ok ? 'verified' : 'failed', message: result.message }
  }

  const saveFor = (id: string) => async (payload: ConnectorCreateRequest) => {
    if (id === DEX_ID) return
    // A rejection propagates to the modal, which shows it and stays open.
    const token = await getAccessTokenSilently()
    const created = await connectorsApi.createConnector(token, payload)
    setConnectors((prev) => [...prev.filter((c) => c.provider_id !== created.provider_id), created])
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (selectedId !== DEX_ID && !connectorFor(selectedId)) {
      setErrors([`Configure ${activeOption.name} before continuing, or skip this step.`])
      return
    }
    setErrors([])
    onNext({
      providerId: selectedId,
      providerName: activeOption.name,
      issuerUrl: selectedId === DEX_ID ? DEX_ISSUER : undefined,
      connectionTested: selectedOutcome?.status === 'verified',
      connectionMessage: selectedOutcome?.status === 'verified' ? selectedOutcome.message : undefined,
    })
  }

  const configuringProvider = configuringId ? providerFor(configuringId) : undefined

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>
          Identity Provider Linkage
        </h1>
        <p style={{ color: 'var(--muted)', fontSize: 14, lineHeight: 1.6 }}>
          Connect your organization's OpenID Connect (OIDC) identity provider. Signal Loom federates
          with your IdP to authenticate operators and establish SPIFFE trust chains for autonomous agents.
        </p>
      </div>

      <ValidationErrorBanner errors={errors} onDismiss={() => setErrors([])} />

      {loadError && (
        <div data-testid="idp-providers-error" role="alert" style={{ color: 'var(--error)', fontSize: 13, marginBottom: 16 }}>
          Connector providers could not be loaded: {loadError}. Only in-cluster Dex can be configured.
        </div>
      )}

      <form noValidate onSubmit={handleSubmit}>
        <div style={{ marginBottom: 24 }}>
          <label style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 10 }}>
            Select Identity Provider
          </label>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 12 }}>
            {IDP_OPTIONS.map((opt) => {
              const isSelected = selectedId === opt.id
              return (
                <div
                  key={opt.id}
                  data-testid={`idp-option-${opt.id}`}
                  onClick={() => openConfigure(opt)}
                  role="button"
                  tabIndex={0}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') openConfigure(opt)
                  }}
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'flex-start',
                    padding: '14px 16px',
                    borderRadius: 'var(--radius)',
                    border: isSelected ? '2px solid var(--cyan)' : '1px solid var(--border)',
                    background: isSelected ? 'var(--cyan-focus)' : 'var(--surface)',
                    cursor: 'pointer',
                    textAlign: 'left',
                    transition: 'all 0.15s ease',
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8, width: '100%' }}>
                    <ProviderLogo providerId={opt.id} displayName={opt.name} size={28} />
                    <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', flex: 1 }}>{opt.name}</span>
                    {opt.id === DEX_ID && (
                      <span className="tag" style={{ background: 'var(--cyan-bg)', color: 'var(--cyan)', fontSize: 10 }}>
                        Default
                      </span>
                    )}
                  </div>
                  <span style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4, flex: 1 }}>{opt.tagline}</span>
                  <div
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      width: '100%',
                      marginTop: 12,
                      paddingTop: 8,
                      borderTop: '1px solid var(--border)',
                    }}
                  >
                    <button
                      type="button"
                      className="btn btn-secondary btn-sm"
                      data-testid={`configure-idp-${opt.id}`}
                      onClick={(e) => {
                        e.stopPropagation()
                        openConfigure(opt)
                      }}
                      style={{ fontSize: 11, padding: '3px 10px' }}
                    >
                      Configure
                    </button>
                    {isConfigured(opt.id) && (
                      <span
                        className="tag"
                        data-testid={`configured-tag-${opt.id}`}
                        style={{ background: 'var(--teal-bg)', color: 'var(--teal)', fontSize: 10, padding: '2px 6px' }}
                      >
                        ✓ Configured
                      </span>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </div>

        {selectedOutcome && (
          <div
            data-testid={STATUS_TESTID[selectedOutcome.status]}
            style={{ fontSize: 13, color: STATUS_COLOUR[selectedOutcome.status], lineHeight: 1.5, marginBottom: 8 }}
          >
            {activeOption.name}: {selectedOutcome.message}
          </div>
        )}

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 24 }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={onBack}
            data-testid="back-step-button"
            style={{ fontSize: 13 }}
          >
            ← Back
          </button>
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <button
              type="button"
              className="btn btn-secondary"
              data-testid="step-skip-button"
              onClick={onSkip}
              style={{ fontSize: 13 }}
            >
              {skipLabel}
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              data-testid="next-step-button"
              style={{ fontSize: 14, padding: '8px 20px' }}
            >
              Next: Policy &amp; Consent →
            </button>
          </div>
        </div>
      </form>

      {configuringId && configuringProvider && (
        <ConnectorConfigureModal
          key={configuringId}
          isOpen
          provider={configuringProvider}
          connector={connectorFor(configuringId)}
          onClose={() => setConfiguringId(null)}
          onSave={saveFor(configuringId)}
          verify={configuringId === DEX_ID ? verifyDex : undefined}
          onTested={(outcome) => setOutcomes((prev) => ({ ...prev, [configuringId]: outcome }))}
        />
      )}
    </div>
  )
}
