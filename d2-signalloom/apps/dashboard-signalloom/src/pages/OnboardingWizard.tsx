import { useCallback, useEffect, useState, type CSSProperties } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { getTenantIdFromToken } from '../auth/tenant'
import { connectorsApi } from '../api/connectorsClient'
import { useOnboardingWizard } from '../hooks/useOnboardingWizard'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'
import ProgressBanner from '../components/onboarding/ProgressBanner'
import ProviderSelectStep from '../components/onboarding/ProviderSelectStep'
import ProviderConfigureStep from '../components/onboarding/ProviderConfigureStep'
import SummaryStep from '../components/onboarding/SummaryStep'
import ErrorState from '../components/ErrorState'

function Spinner() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 1 }}>
      <div
        style={{
          width: 32, height: 32, border: '3px solid var(--border)',
          borderTopColor: 'var(--cyan)', borderRadius: '50%',
          animation: 'onboarding-spin 0.8s linear infinite',
        }}
      />
      <style>{`@keyframes onboarding-spin { to { transform: rotate(360deg) } }`}</style>
    </div>
  )
}

export default function OnboardingWizard() {
  const { getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()

  const [tenantId, setTenantId] = useState<string | null>(null)
  const [providers, setProviders] = useState<ConnectorProvider[]>([])
  const [connectors, setConnectors] = useState<TenantConnector[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [disconnectingId, setDisconnectingId] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(null)
    try {
      const token = await getAccessTokenSilently()
      setTenantId(getTenantIdFromToken(token))
      const [providerList, connectorList] = await Promise.all([
        connectorsApi.listProviders(token),
        connectorsApi.listConnectors(token),
      ])
      setProviders(providerList)
      setConnectors(connectorList)
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Failed to load connector providers.')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  const wizard = useOnboardingWizard(tenantId, connectors)

  const connectedProviderIds = new Set(
    connectors.filter((c) => c.status === 'connected').map((c) => c.provider_id),
  )

  async function handleConfigureSubmit(providerId: string, credentials: Record<string, string>) {
    wizard.setProviderStatus(providerId, { status: 'submitting' })
    try {
      const token = await getAccessTokenSilently()
      const created = await connectorsApi.createConnector(token, { provider_id: providerId, credentials })
      setConnectors((prev) => [...prev.filter((c) => c.provider_id !== providerId), created])
      // Surface expiry / rotation status immediately (ADR-ENHC-012 §7).
      const testResult = await connectorsApi.testConnector(token, created.connector_id).catch(() => null)
      if (testResult) {
        setConnectors((prev) =>
          prev.map((c) =>
            c.connector_id === created.connector_id
              ? { ...c, credential_expires_at: testResult.credential_expires_at }
              : c,
          ),
        )
      }
      wizard.setProviderStatus(providerId, { status: 'connected' })
    } catch (e) {
      wizard.setProviderStatus(providerId, {
        status: 'error',
        error: e instanceof Error ? e.message : 'Could not connect — check your credentials and try again.',
      })
    }
  }

  async function handleDisconnect(connector: TenantConnector) {
    setDisconnectingId(connector.connector_id)
    try {
      const token = await getAccessTokenSilently()
      await connectorsApi.deleteConnector(token, connector.connector_id)
      setConnectors((prev) =>
        prev.map((c) =>
          c.connector_id === connector.connector_id ? { ...c, status: 'disconnected' as const } : c,
        ),
      )
    } finally {
      setDisconnectingId(null)
    }
  }

  function handleFinish() {
    wizard.reset()
    navigate('/agents')
  }

  function handleSkip() {
    // Progress is already persisted — the user can return to /onboarding later.
    navigate('/agents')
  }

  if (loading) {
    return (
      <div style={fullPageStyle}>
        <Spinner />
      </div>
    )
  }

  if (loadError) {
    return (
      <div style={fullPageStyle}>
        <ErrorState message={loadError} onRetry={load} />
      </div>
    )
  }

  const step = wizard.currentStep

  return (
    <div style={fullPageStyle}>
      <ProgressBanner
        providers={providers}
        selectedProviderIds={wizard.selectedProviderIds}
        providerRunState={wizard.providerRunState}
        stepNumber={wizard.stepIndex + 1}
        totalSteps={wizard.steps.length}
        onSkip={handleSkip}
      />

      <div style={{ flex: 1, overflow: 'auto', padding: '48px 32px', display: 'flex', justifyContent: 'center' }}>
        <div style={{ width: '100%' }}>
          {step.kind === 'select-providers' && (
            <>
              <ProviderSelectStep
                providers={providers}
                selectedProviderIds={wizard.selectedProviderIds}
                connectedProviderIds={connectedProviderIds}
                onToggle={wizard.toggleProvider}
              />
              <div style={{ display: 'flex', marginTop: 24, maxWidth: 560 }}>
                <button
                  className="btn btn-primary"
                  onClick={wizard.goNext}
                  disabled={wizard.selectedProviderIds.length === 0}
                >
                  Continue
                </button>
              </div>
            </>
          )}

          {step.kind === 'configure' && (
            <ProviderConfigureStep
              provider={providers.find((p) => p.provider_id === step.providerId)!}
              submitting={wizard.providerRunState[step.providerId]?.status === 'submitting'}
              error={wizard.providerRunState[step.providerId]?.error}
              onSubmit={(credentials) => handleConfigureSubmit(step.providerId, credentials)}
              onBack={wizard.goBack}
              onSkipProvider={wizard.goNext}
            />
          )}

          {step.kind === 'summary' && (
            <SummaryStep
              connectors={connectors}
              disconnectingId={disconnectingId}
              onDisconnect={handleDisconnect}
              onFinish={handleFinish}
              onBack={wizard.goBack}
            />
          )}
        </div>
      </div>
    </div>
  )
}

const fullPageStyle: CSSProperties = {
  position: 'fixed',
  inset: 0,
  zIndex: 7000,
  background: 'var(--bg)',
  display: 'flex',
  flexDirection: 'column',
}
