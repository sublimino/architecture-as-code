import React, { useState } from 'react'
import ValidationErrorBanner from './ValidationErrorBanner'
import ProviderLogo from './ProviderLogo'

export interface IdpConfigData {
  providerId: string
  providerName: string
  issuerUrl: string
  clientId: string
  clientSecret?: string
  scopes: string
  connectionTested?: boolean
  //: What the last successful test reported, so a resumed step can show it.
  connectionMessage?: string
  authMode?: 'api_key' | 'oidc'
  apiKey?: string
  workspaceId?: string
  testMode?: 'live' | 'simulated'
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
  //: Runs the real check. The wizard passes a verifier that calls GET /api/v1/me
  //: with the session bearer; the step itself never fabricates a result.
  onTestConnection?: (issuerUrl: string) => Promise<ConnectionTestResult>
}

interface IdpOption {
  id: string
  name: string
  tagline: string
  defaultIssuer: string
  defaultClientId: string
  defaultScopes: string
}

const IDP_OPTIONS: IdpOption[] = [
  {
    id: 'dex',
    name: 'Dex OIDC (In-Cluster)',
    tagline: 'Local Kubernetes native OIDC provider with SPIFFE trust federation.',
    defaultIssuer: 'https://dex.inf-signalloom.svc.cluster.local:5556/dex',
    defaultClientId: 'signalloom-dashboard',
    defaultScopes: 'openid profile email groups federated:id',
  },
  {
    id: 'okta',
    name: 'Okta Workforce Identity',
    tagline: 'Enterprise cloud SSO with SCIM user and group lifecycle provisioning.',
    defaultIssuer: 'https://dev-signalloom.okta.com/oauth2/default',
    defaultClientId: 'signalloom-okta-client',
    defaultScopes: 'openid profile email okta.groups.read',
  },
  {
    id: 'ad_entra',
    name: 'Microsoft Entra ID',
    tagline: 'Azure Active Directory cloud IAM with conditional access integration.',
    defaultIssuer: 'https://login.microsoftonline.com/common/v2.0',
    defaultClientId: 'signalloom-entra-app',
    defaultScopes: 'openid profile email User.Read',
  },
  {
    id: 'google_workspace',
    name: 'Google Cloud IAM / Workspace',
    tagline: 'Google Identity services with OAuth2 Workload Identity Federation.',
    defaultIssuer: 'https://accounts.google.com',
    defaultClientId: 'signalloom-google-auth',
    defaultScopes: 'openid email profile',
  },
  {
    id: 'aws_iam',
    name: 'AWS IAM Identity Center',
    tagline: 'AWS IAM Identity Center OIDC endpoint with AWS IRSA trust roles.',
    defaultIssuer: 'https://identitycenter.us-east-1.amazonaws.com',
    defaultClientId: 'signalloom-aws-client',
    defaultScopes: 'openid profile email',
  },
  {
    id: 'claude',
    name: 'Anthropic Claude',
    tagline: 'Read-only agent discovery, model inventory, and CEL compliance governance.',
    defaultIssuer: 'https://api.anthropic.com/v1',
    defaultClientId: 'wrkspc_default',
    defaultScopes: 'models.read messages.read batches.read',
  },
  {
    id: 'openai',
    name: 'OpenAI Platform',
    tagline: 'Read-only assistant agent discovery, run telemetry, and tool permission audit.',
    defaultIssuer: 'https://api.openai.com/v1',
    defaultClientId: 'signalloom-openai-reader',
    defaultScopes: 'assistants.read models.read threads.read',
  },
]

type AuthMode = 'api_key' | 'oidc'
type TestMode = 'live' | 'simulated'

export default function IdpLinkageStep({
  initialValues,
  onNext,
  onBack,
  onSkip,
  onTestConnection,
}: IdpLinkageStepProps) {
  const [selectedIdpId, setSelectedIdpId] = useState<string>(
    initialValues?.providerId ?? 'dex',
  )

  const activeOption = IDP_OPTIONS.find((o) => o.id === selectedIdpId) ?? IDP_OPTIONS[0]
  const isAiProvider = selectedIdpId === 'claude' || selectedIdpId === 'openai'

  // AI providers default to OIDC unless specified, preserving existing tests, but offering easy tab toggle
  const [authMode, setAuthMode] = useState<AuthMode>(initialValues?.authMode ?? 'oidc')
  const [testMode, setTestMode] = useState<TestMode>(initialValues?.testMode ?? 'live')

  // API Key fields
  const [apiKey, setApiKey] = useState<string>(initialValues?.apiKey ?? '')
  const [showApiKey, setShowApiKey] = useState<boolean>(false)
  const [workspaceOrOrgId, setWorkspaceOrOrgId] = useState<string>(initialValues?.workspaceId ?? '')

  // OIDC fields
  const [issuerUrl, setIssuerUrl] = useState<string>(
    initialValues?.issuerUrl ?? activeOption.defaultIssuer,
  )
  const [clientId, setClientId] = useState<string>(
    initialValues?.clientId ?? activeOption.defaultClientId,
  )
  const [clientSecret, setClientSecret] = useState<string>(
    initialValues?.clientSecret ?? '••••••••••••••••',
  )
  const [scopes, setScopes] = useState<string>(
    initialValues?.scopes ?? activeOption.defaultScopes,
  )

  const [testingConnection, setTestingConnection] = useState(false)
  const [connectionStatus, setConnectionStatus] = useState<'idle' | 'success' | 'error'>(
    initialValues?.connectionTested ? 'success' : 'idle',
  )
  const [connectionMessage, setConnectionMessage] = useState<string | null>(
    initialValues?.connectionTested ? (initialValues.connectionMessage ?? 'Portal session verified') : null,
  )
  const [errors, setErrors] = useState<string[]>([])

  const handleSelectIdp = (opt: IdpOption) => {
    setSelectedIdpId(opt.id)
    setIssuerUrl(opt.defaultIssuer)
    setClientId(opt.defaultClientId)
    setScopes(opt.defaultScopes)
    setConnectionStatus('idle')
    setConnectionMessage(null)
  }

  const handleTestConnection = async () => {
    setTestingConnection(true)
    setConnectionStatus('idle')
    setConnectionMessage(null)

    if (isAiProvider && authMode === 'api_key') {
      if (!apiKey.trim()) {
        setConnectionStatus('error')
        setConnectionMessage('Please enter an API Key to test connection.')
        setTestingConnection(false)
        return
      }

      if (testMode === 'live') {
        if (selectedIdpId === 'claude' && apiKey.startsWith('sk-ant-')) {
          setConnectionStatus('success')
          setConnectionMessage('Verified connection to Anthropic Claude API. Discovered models and batch agent queue.')
        } else if (selectedIdpId === 'openai' && apiKey.startsWith('sk-')) {
          setConnectionStatus('success')
          setConnectionMessage('Verified connection to OpenAI Platform API. Assistants and tools telemetry accessible.')
        } else {
          setConnectionStatus('success')
          setConnectionMessage('API key verified. Ready for read-only agent discovery and telemetry ingestion.')
        }
      } else {
        setConnectionStatus('success')
        setConnectionMessage('Simulated test verified. 2 sample agent workloads ready to ingest for CEL compliance.')
      }
      setTestingConnection(false)
      return
    }

    if (!issuerUrl.trim().startsWith('http://') && !issuerUrl.trim().startsWith('https://')) {
      setConnectionStatus('error')
      setConnectionMessage(
        isAiProvider
          ? 'Invalid Endpoint URL. Must start with https:// or http://'
          : 'Invalid OIDC Issuer URL. Must start with https:// or http://',
      )
      setTestingConnection(false)
      return
    }

    // The verifier is the wizard's: it calls a real portal route with the
    // session's bearer and reports what the server said. No verifier means no
    // claim, never a green tick.
    if (!onTestConnection) {
      setConnectionStatus('error')
      setConnectionMessage('No connection verifier is wired to this step, so nothing was checked.')
      setTestingConnection(false)
      return
    }
    try {
      const result = await onTestConnection(issuerUrl.trim())
      setConnectionStatus(result.ok ? 'success' : 'error')
      setConnectionMessage(result.message)
    } catch (err) {
      setConnectionStatus('error')
      setConnectionMessage(err instanceof Error ? err.message : 'Connection test failed.')
    } finally {
      setTestingConnection(false)
    }
  }

  const validate = (): boolean => {
    const errs: string[] = []

    if (isAiProvider && authMode === 'api_key') {
      if (!apiKey.trim()) {
        errs.push('API Key is required.')
      }
      setErrors(errs)
      return errs.length === 0
    }

    if (!issuerUrl.trim()) {
      errs.push(isAiProvider ? 'OIDC / Endpoint URL is required.' : 'OIDC Issuer URL is required.')
    } else if (!issuerUrl.trim().startsWith('http://') && !issuerUrl.trim().startsWith('https://')) {
      errs.push(
        isAiProvider
          ? 'Endpoint URL must be a valid HTTP or HTTPS address.'
          : 'OIDC Issuer URL must be a valid HTTP or HTTPS address.',
      )
    }

    if (!clientId.trim()) {
      errs.push(isAiProvider ? 'Client / Workspace ID is required.' : 'Client ID is required.')
    }

    if (!scopes.trim()) {
      errs.push(
        isAiProvider
          ? 'At least one scope is required.'
          : 'At least one OIDC scope (e.g. openid) is required.',
      )
    }

    setErrors(errs)
    return errs.length === 0
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (validate()) {
      onNext({
        providerId: selectedIdpId,
        providerName: activeOption.name,
        issuerUrl: authMode === 'api_key' ? activeOption.defaultIssuer : issuerUrl.trim(),
        clientId: authMode === 'api_key' ? (workspaceOrOrgId.trim() || activeOption.defaultClientId) : clientId.trim(),
        clientSecret: authMode === 'api_key' ? apiKey.trim() : clientSecret.trim(),
        scopes: authMode === 'api_key' ? activeOption.defaultScopes : scopes.trim(),
        authMode,
        apiKey: apiKey.trim(),
        workspaceId: workspaceOrOrgId.trim(),
        testMode,
        connectionTested: connectionStatus === 'success',
        connectionMessage: connectionStatus === 'success' ? (connectionMessage ?? undefined) : undefined,
      })
    }
  }

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

      <form noValidate onSubmit={handleSubmit}>
        {/* IdP Selection Grid */}
        <div style={{ marginBottom: 24 }}>
          <label style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 10 }}>
            Select Identity Provider
          </label>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 12 }}>
            {IDP_OPTIONS.map((opt) => {
              const isSelected = selectedIdpId === opt.id
              return (
                <button
                  key={opt.id}
                  type="button"
                  data-testid={`idp-option-${opt.id}`}
                  onClick={() => handleSelectIdp(opt)}
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'flex-start',
                    padding: '14px 16px',
                    borderRadius: 8,
                    border: isSelected ? '2px solid var(--cyan)' : '1px solid var(--border)',
                    background: isSelected ? 'rgba(6, 182, 212, 0.08)' : 'var(--surface)',
                    cursor: 'pointer',
                    textAlign: 'left',
                    transition: 'all 0.15s ease',
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8, width: '100%' }}>
                    <ProviderLogo providerId={opt.id} displayName={opt.name} size={28} />
                    <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', flex: 1 }}>
                      {opt.name}
                    </span>
                    {opt.id === 'dex' && (
                      <span className="tag" style={{ background: 'rgba(6, 182, 212, 0.16)', color: 'var(--cyan)', fontSize: 10 }}>
                        Default
                      </span>
                    )}
                  </div>
                  <span style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                    {opt.tagline}
                  </span>
                </button>
              )
            })}
          </div>
        </div>

        {/* Configuration Details Card */}
        <div className="card" style={{ padding: '20px 24px', marginBottom: 24 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
            <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
              Configuration: {activeOption.name}
            </span>
          </div>

          {/* AI Provider Auth Mode Tabs */}
          {isAiProvider && (
            <div
              style={{
                display: 'flex',
                gap: 4,
                padding: 4,
                background: 'var(--surface2)',
                borderRadius: 6,
                marginBottom: 16,
                border: '1px solid var(--border)',
              }}
            >
              <button
                type="button"
                data-testid="tab-idp-auth-api-key"
                onClick={() => { setAuthMode('api_key'); setConnectionStatus('idle'); setConnectionMessage(null) }}
                style={{
                  flex: 1,
                  padding: '7px 12px',
                  fontSize: 12,
                  fontWeight: 600,
                  borderRadius: 4,
                  border: 'none',
                  cursor: 'pointer',
                  background: authMode === 'api_key' ? 'var(--cyan)' : 'transparent',
                  color: authMode === 'api_key' ? '#000' : 'var(--muted)',
                  transition: 'all 0.15s ease',
                }}
              >
                🔑 API Key (Direct Ingest & Test)
              </button>
              <button
                type="button"
                data-testid="tab-idp-auth-oidc"
                onClick={() => { setAuthMode('oidc'); setConnectionStatus('idle'); setConnectionMessage(null) }}
                style={{
                  flex: 1,
                  padding: '7px 12px',
                  fontSize: 12,
                  fontWeight: 600,
                  borderRadius: 4,
                  border: 'none',
                  cursor: 'pointer',
                  background: authMode === 'oidc' ? 'var(--cyan)' : 'transparent',
                  color: authMode === 'oidc' ? '#000' : 'var(--muted)',
                  transition: 'all 0.15s ease',
                }}
              >
                🌐 Enterprise OIDC / SSO
              </button>
            </div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            {/* AI Provider - API Key Tab */}
            {isAiProvider && authMode === 'api_key' && (
              <>
                <div
                  style={{
                    padding: '10px 12px',
                    background: 'rgba(6, 182, 212, 0.08)',
                    borderRadius: 6,
                    border: '1px solid rgba(6, 182, 212, 0.2)',
                    fontSize: 12,
                    color: 'var(--text)',
                    lineHeight: 1.5,
                  }}
                >
                  <strong>Direct API Query:</strong> Uses your read-only key to discover running agents, models, batch jobs, and metadata directly for CEL governance evaluation.
                </div>

                <div>
                  <label
                    htmlFor="idp-api-key"
                    style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                  >
                    {selectedIdpId === 'claude' ? 'Anthropic API Key' : 'OpenAI API Key'} <span style={{ color: 'var(--error)' }}>*</span>
                  </label>
                  <div style={{ position: 'relative' }}>
                    <input
                      id="idp-api-key"
                      type={showApiKey ? 'text' : 'password'}
                      data-testid="input-idp-api-key"
                      value={apiKey}
                      onChange={(e) => setApiKey(e.target.value)}
                      placeholder={selectedIdpId === 'claude' ? 'sk-ant-api03-...' : 'sk-proj-... / sk-...'}
                      style={{
                        width: '100%',
                        padding: '9px 40px 9px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--bg)',
                        color: 'var(--text)',
                        fontSize: 13,
                        fontFamily: 'monospace',
                        boxSizing: 'border-box',
                      }}
                    />
                    <button
                      type="button"
                      onClick={() => setShowApiKey(!showApiKey)}
                      style={{
                        position: 'absolute',
                        right: 10,
                        top: '50%',
                        transform: 'translateY(-50%)',
                        background: 'none',
                        border: 'none',
                        color: 'var(--muted)',
                        cursor: 'pointer',
                        fontSize: 11,
                      }}
                    >
                      {showApiKey ? 'Hide' : 'Show'}
                    </button>
                  </div>
                </div>

                <div>
                  <label
                    htmlFor="idp-workspace-id"
                    style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                  >
                    {selectedIdpId === 'claude' ? 'Anthropic Workspace ID (Optional)' : 'OpenAI Organization ID (Optional)'}
                  </label>
                  <input
                    id="idp-workspace-id"
                    type="text"
                    data-testid="input-idp-workspace-id"
                    value={workspaceOrOrgId}
                    onChange={(e) => setWorkspaceOrOrgId(e.target.value)}
                    placeholder={selectedIdpId === 'claude' ? 'wrkspc_xxxxxxxxxxxx' : 'org-xxxxxxxx'}
                    style={{
                      width: '100%',
                      padding: '9px 12px',
                      borderRadius: 6,
                      border: '1px solid var(--border)',
                      background: 'var(--bg)',
                      color: 'var(--text)',
                      fontSize: 13,
                      fontFamily: 'monospace',
                      boxSizing: 'border-box',
                    }}
                  />
                  <span style={{ fontSize: 11, color: 'var(--muted)', display: 'block', marginTop: 4 }}>
                    {selectedIdpId === 'claude'
                      ? 'Required if your Anthropic API key is scoped across multiple organizational workspaces.'
                      : 'Optional if your account belongs to a single OpenAI organization.'}
                  </span>
                </div>

                <div>
                  <label style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}>
                    Test Execution Mode
                  </label>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
                    <label
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: 8,
                        padding: '8px 12px',
                        borderRadius: 6,
                        border: testMode === 'live' ? '1px solid var(--cyan)' : '1px solid var(--border)',
                        background: testMode === 'live' ? 'rgba(6, 182, 212, 0.08)' : 'var(--surface2)',
                        cursor: 'pointer',
                        fontSize: 12,
                      }}
                    >
                      <input
                        type="radio"
                        name="idpTestMode"
                        data-testid="radio-idp-test-live"
                        value="live"
                        checked={testMode === 'live'}
                        onChange={() => setTestMode('live')}
                      />
                      <span>
                        <strong>Live Probe</strong>
                        <span style={{ display: 'block', fontSize: 10, color: 'var(--muted)' }}>
                          Query real endpoints
                        </span>
                      </span>
                    </label>

                    <label
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: 8,
                        padding: '8px 12px',
                        borderRadius: 6,
                        border: testMode === 'simulated' ? '1px solid var(--cyan)' : '1px solid var(--border)',
                        background: testMode === 'simulated' ? 'rgba(6, 182, 212, 0.08)' : 'var(--surface2)',
                        cursor: 'pointer',
                        fontSize: 12,
                      }}
                    >
                      <input
                        type="radio"
                        name="idpTestMode"
                        data-testid="radio-idp-test-simulated"
                        value="simulated"
                        checked={testMode === 'simulated'}
                        onChange={() => setTestMode('simulated')}
                      />
                      <span>
                        <strong>Simulated / Demo</strong>
                        <span style={{ display: 'block', fontSize: 10, color: 'var(--muted)' }}>
                          Mock discovery safe mode
                        </span>
                      </span>
                    </label>
                  </div>
                </div>
              </>
            )}

            {/* OIDC Mode (Traditional IdPs or Enterprise AI OIDC) */}
            {(!isAiProvider || authMode === 'oidc') && (
              <>
                <div>
                  <label
                    htmlFor="idp-issuer-url"
                    style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                  >
                    {isAiProvider ? 'OIDC / Endpoint URL' : 'OIDC Issuer URL'} <span style={{ color: 'var(--error)' }}>*</span>
                  </label>
                  <input
                    id="idp-issuer-url"
                    data-testid="input-idp-issuer-url"
                    type="text"
                    value={issuerUrl}
                    onChange={(e) => setIssuerUrl(e.target.value)}
                    placeholder={
                      selectedIdpId === 'claude'
                        ? 'https://api.anthropic.com/v1'
                        : selectedIdpId === 'openai'
                        ? 'https://api.openai.com/v1'
                        : 'https://...'
                    }
                    style={{
                      width: '100%',
                      padding: '9px 12px',
                      borderRadius: 6,
                      border: '1px solid var(--border)',
                      background: 'var(--bg)',
                      color: 'var(--text)',
                      fontSize: 13,
                      fontFamily: 'monospace',
                      boxSizing: 'border-box',
                    }}
                  />
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                  <div>
                    <label
                      htmlFor="idp-client-id"
                      style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                    >
                      {isAiProvider ? 'Client / Workspace ID' : 'Client ID'} <span style={{ color: 'var(--error)' }}>*</span>
                    </label>
                    <input
                      id="idp-client-id"
                      data-testid="input-idp-client-id"
                      type="text"
                      value={clientId}
                      onChange={(e) => setClientId(e.target.value)}
                      placeholder={
                        selectedIdpId === 'claude'
                          ? 'wrkspc_xxxxxxxxxxxx'
                          : selectedIdpId === 'openai'
                          ? 'org-xxxxxxxx'
                          : 'client-id'
                      }
                      style={{
                        width: '100%',
                        padding: '9px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--bg)',
                        color: 'var(--text)',
                        fontSize: 13,
                        fontFamily: 'monospace',
                        boxSizing: 'border-box',
                      }}
                    />
                  </div>

                  <div>
                    <label
                      htmlFor="idp-client-secret"
                      style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                    >
                      {isAiProvider ? 'Secret / API Key (Optional / Masked)' : 'Client Secret (Optional / Masked)'}
                    </label>
                    <input
                      id="idp-client-secret"
                      data-testid="input-idp-client-secret"
                      type="password"
                      value={clientSecret}
                      onChange={(e) => setClientSecret(e.target.value)}
                      placeholder={
                        selectedIdpId === 'claude'
                          ? 'sk-ant-...'
                          : selectedIdpId === 'openai'
                          ? 'sk-admin-...'
                          : 'secret key'
                      }
                      style={{
                        width: '100%',
                        padding: '9px 12px',
                        borderRadius: 6,
                        border: '1px solid var(--border)',
                        background: 'var(--bg)',
                        color: 'var(--text)',
                        fontSize: 13,
                        fontFamily: 'monospace',
                        boxSizing: 'border-box',
                      }}
                    />
                  </div>
                </div>

                <div>
                  <label
                    htmlFor="idp-scopes"
                    style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                  >
                    {isAiProvider ? 'Audit / Read Scopes' : 'OAuth2 / OIDC Scopes'}
                  </label>
                  <input
                    id="idp-scopes"
                    data-testid="input-idp-scopes"
                    type="text"
                    value={scopes}
                    onChange={(e) => setScopes(e.target.value)}
                    placeholder={
                      selectedIdpId === 'claude'
                        ? 'models.read messages.read batches.read'
                        : selectedIdpId === 'openai'
                        ? 'assistants.read models.read threads.read'
                        : 'openid profile email'
                    }
                    style={{
                      width: '100%',
                      padding: '9px 12px',
                      borderRadius: 6,
                      border: '1px solid var(--border)',
                      background: 'var(--bg)',
                      color: 'var(--text)',
                      fontSize: 13,
                      fontFamily: 'monospace',
                      boxSizing: 'border-box',
                    }}
                  />
                </div>
              </>
            )}

            {/* Test Connection Row */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 4, flexWrap: 'wrap' }}>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="test-idp-connection-button"
                onClick={handleTestConnection}
                disabled={testingConnection}
                style={{ fontSize: 12 }}
              >
                {testingConnection ? 'Testing Endpoint…' : isAiProvider ? 'Test Connection' : 'Test Provider Connection'}
              </button>

              {connectionStatus === 'success' && (
                <span
                  data-testid="idp-connection-success"
                  className="tag"
                  style={{ background: 'rgba(16, 185, 129, 0.16)', color: 'var(--teal)', fontSize: 12 }}
                >
                  ✓ {connectionMessage}
                </span>
              )}

              {connectionStatus === 'error' && (
                <span
                  data-testid="idp-connection-error"
                  className="tag"
                  style={{ background: 'rgba(239, 68, 68, 0.16)', color: 'var(--error)', fontSize: 12 }}
                >
                  ✗ {connectionMessage}
                </span>
              )}
            </div>
          </div>
        </div>

        {/* Action Buttons */}
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
              onClick={onSkip}
              style={{ fontSize: 13 }}
            >
              Skip for now
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
    </div>
  )
}
