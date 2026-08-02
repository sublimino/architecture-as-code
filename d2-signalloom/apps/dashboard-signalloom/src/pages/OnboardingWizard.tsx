import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { getTenantIdFromToken } from '../auth/tenant'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import { onboardingApi } from '../api/onboardingClient'
import { useOnboardingWizard, type WizardPersistedState, type WizardStep } from '../hooks/useOnboardingWizard'
import { useAppContext } from '../App'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'
import ProgressBanner from '../components/onboarding/ProgressBanner'
import WelcomeStep from '../components/onboarding/WelcomeStep'
import ProviderSelectStep from '../components/onboarding/ProviderSelectStep'
import ProviderConfigureStep from '../components/onboarding/ProviderConfigureStep'
import PreferencesStep, { type PreferencesValues } from '../components/onboarding/PreferencesStep'
import ApiKeyStep, { type RevealedKey } from '../components/onboarding/ApiKeyStep'
import SummaryStep from '../components/onboarding/SummaryStep'
import ErrorState from '../components/ErrorState'

const DEFAULT_PREFERENCES: PreferencesValues = {
  preferred_scan_cadence_hours: 24,
  alert_email: '',
  alert_threshold: 1,
}

// Per-step content width — a single fixed width forced short/simple steps
// (Preferences, API key) and content-heavy ones (the provider grid) into the
// same narrow column, so the provider grid scrolled unnecessarily on wide
// screens while everything else had room to spare. Content still centers
// via the flex parent either way (see the wrapper div below).
const STEP_MAX_WIDTH: Record<WizardStep['kind'], number> = {
  welcome: 760,
  'select-providers': 900,
  configure: 560,
  preferences: 560,
  'api-key': 560,
  summary: 680,
}

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

/** localStorage key for the 30-minute skip TTL (client-side only). */
const SKIP_STORAGE_KEY = 'sl_onboarding_skipped'

export default function OnboardingWizard() {
  const { getAccessTokenSilently } = useAuth0()
  const navigate = useNavigate()
  const location = useLocation()
  const { refreshOnboardingState, setHelpOpen } = useAppContext()

  // Where to go after skip/finish — ProtectedRoute passes the page the user
  // was on before the onboarding gate redirected them here.
  const returnTo = (location.state as { returnTo?: string } | null)?.returnTo || '/agents'

  const [tenantId, setTenantId] = useState<string | null>(null)
  const [providers, setProviders] = useState<ConnectorProvider[]>([])
  const [connectors, setConnectors] = useState<TenantConnector[]>([])
  const [initialWizardState, setInitialWizardState] = useState<WizardPersistedState | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [disconnectingId, setDisconnectingId] = useState<string | null>(null)
  const [preferences, setPreferences] = useState<PreferencesValues>(DEFAULT_PREFERENCES)
  const [preferencesSubmitting, setPreferencesSubmitting] = useState(false)
  const [preferencesError, setPreferencesError] = useState<string | undefined>(undefined)
  const [apiKeyRevealed, setApiKeyRevealed] = useState<RevealedKey | null>(null)
  const [apiKeyRevealing, setApiKeyRevealing] = useState(false)
  const [apiKeyError, setApiKeyError] = useState<string | undefined>(undefined)

  const load = useCallback(async () => {
    setLoading(true)
    setLoadError(null)
    try {
      const token = await getAccessTokenSilently()
      setTenantId(getTenantIdFromToken(token))
      const [providerList, connectorList, wizardState, settings] = await Promise.all([
        connectorsApi.listProviders(token),
        connectorsApi.listConnectors(token),
        onboardingApi.getState(token).catch(() => null),
        api.settings(token).catch(() => null),
      ])
      setProviders(providerList)
      setConnectors(connectorList)
      setInitialWizardState(
        wizardState && {
          selectedProviderIds: wizardState.selected_provider_ids,
          stepIndex: wizardState.step_index,
          providerRunState: wizardState.provider_run_state,
        },
      )
      if (settings) {
        setPreferences({
          preferred_scan_cadence_hours: settings.preferred_scan_cadence_hours,
          alert_email: settings.alert_email ?? '',
          alert_threshold: settings.alert_threshold,
        })
      }
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Failed to load connector providers.')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
  }, [load])

  const wizard = useOnboardingWizard(tenantId, connectors, initialWizardState)

  // Debounced cross-device persistence (Slice 1a, 86cajpvar QA item g).
  // State updates are instant/optimistic via the hook's useState — this
  // effect just ships them to PUT /onboarding/state in the background so
  // navigation never waits on the network. Also flushes on unmount so a
  // quick navigate-away right after a change isn't lost.
  const latestWizardStateRef = useRef<WizardPersistedState>({
    selectedProviderIds: wizard.selectedProviderIds,
    stepIndex: wizard.stepIndex,
    providerRunState: wizard.providerRunState,
  })
  latestWizardStateRef.current = {
    selectedProviderIds: wizard.selectedProviderIds,
    stepIndex: wizard.stepIndex,
    providerRunState: wizard.providerRunState,
  }

  const persistWizardState = useCallback(async () => {
    if (!tenantId || loading) return
    try {
      const token = await getAccessTokenSilently()
      const s = latestWizardStateRef.current
      await onboardingApi.putState(token, {
        selected_provider_ids: s.selectedProviderIds,
        step_index: s.stepIndex,
        provider_run_state: s.providerRunState,
      })
    } catch {
      // Best-effort — a failed background save must not disrupt the wizard;
      // worst case this device's progress doesn't carry over to another one.
    }
  }, [tenantId, loading, getAccessTokenSilently])

  useEffect(() => {
    if (!tenantId || loading) return
    const timer = setTimeout(() => { void persistWizardState() }, 500)
    return () => clearTimeout(timer)
  }, [tenantId, loading, wizard.selectedProviderIds, wizard.stepIndex, wizard.providerRunState, persistWizardState])

  useEffect(() => {
    return () => { void persistWizardState() }
    // Flush-on-unmount only — deliberately not re-running per state change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const connectedProviderIds = new Set(
    connectors.filter((c) => c.status === 'connected').map((c) => c.provider_id),
  )

  async function handleConfigureSubmit(providerId: string, credentials: Record<string, string>) {
    wizard.setProviderStatus(providerId, { status: 'submitting' })
    try {
      const token = await getAccessTokenSilently()
      const created = await connectorsApi.createConnector(token, { provider_id: providerId, credentials })
      setConnectors((prev) => [...prev.filter((c) => c.provider_id !== providerId), created])

      // Validate credentials before declaring victory (ADR-ENHC-012 §7) — POST
      // /connectors saves and marks a connector 'connected' without checking
      // credentials at all; this /test call is the only thing that actually
      // verifies them. `.catch(() => null)` covers a *transient* test-call
      // failure (network blip) as inconclusive — we still show connected
      // rather than punish the user for our own flakiness. An explicit
      // `valid: false` response, though, is a definitive "these credentials
      // don't work" — that must NOT be reported as connected, or the wizard
      // lies about state the backend itself already recorded as status='error'.
      const testResult = await connectorsApi.testConnector(token, created.connector_id).catch(() => null)
      if (testResult) {
        setConnectors((prev) =>
          prev.map((c) =>
            c.connector_id === created.connector_id
              ? {
                  ...c,
                  credential_expires_at: testResult.credential_expires_at,
                  status: testResult.valid ? c.status : 'error',
                }
              : c,
          ),
        )
      }

      if (testResult && !testResult.valid) {
        wizard.setProviderStatus(providerId, {
          status: 'error',
          error: testResult.error_msg || 'Connected, but credential validation failed. Check your credentials and try again.',
        })
      } else {
        wizard.setProviderStatus(providerId, { status: 'connected' })
      }
      refreshOnboardingState() // a connection just landed — re-check the gate/banner
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

  async function handlePreferencesSubmit(values: PreferencesValues) {
    setPreferencesSubmitting(true)
    setPreferencesError(undefined)
    try {
      const token = await getAccessTokenSilently()
      const updated = await api.patchPreferences(token, {
        preferred_scan_cadence_hours: values.preferred_scan_cadence_hours,
        alert_email: values.alert_email || null,
        alert_threshold: values.alert_threshold,
      })
      setPreferences({
        preferred_scan_cadence_hours: updated.preferred_scan_cadence_hours,
        alert_email: updated.alert_email ?? '',
        alert_threshold: updated.alert_threshold,
      })
      wizard.goNext()
    } catch (e) {
      setPreferencesError(e instanceof Error ? e.message : 'Could not save preferences — please try again.')
    } finally {
      setPreferencesSubmitting(false)
    }
  }

  async function handleRevealApiKey() {
    if (!tenantId) return
    setApiKeyRevealing(true)
    setApiKeyError(undefined)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.apiKeys.revealInitial(token, tenantId)
      setApiKeyRevealed({ key: result.key, prefix_hint: result.prefix_hint })
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status
      if (status === 410) {
        setApiKeyError('This key was already revealed once — you can rotate it anytime from Settings → API Access.')
      } else {
        setApiKeyError('Could not reveal your API key right now. You can always try again later from Settings → API Access.')
      }
    } finally {
      setApiKeyRevealing(false)
    }
  }

  async function handleFinish() {
    wizard.reset()
    // Clear server-side progress too — otherwise a later re-entry into the
    // wizard (e.g. to add another provider) would resume mid-flow instead
    // of starting clean, since reset() only clears local hook state now.
    getAccessTokenSilently()
      .then((token) => onboardingApi.putState(token, { selected_provider_ids: [], step_index: 0, provider_run_state: {} }))
      .catch(() => undefined)
    // Must await before navigating — refreshOnboardingState() resolves
    // asynchronously, and ProtectedRoute reads needsOnboarding synchronously
    // on render. Navigating first would show it the stale value and bounce
    // back to /onboarding (see refreshOnboardingState's doc comment in App.tsx).
    await refreshOnboardingState()
    navigate(returnTo)
  }

  async function handleSkip() {
    // Client-side TTL — suppress the onboarding gate for ~30 minutes so the
    // user isn't immediately bounced back after skipping.
    try {
      localStorage.setItem(SKIP_STORAGE_KEY, JSON.stringify({ skippedAt: Date.now() }))
    } catch {
      // localStorage may be unavailable (private browsing, quota) — non-fatal.
    }

    // Server-side skip (cross-device auto-trigger gate) alongside the
    // existing client-side progress persistence — see
    // outputs/engineering-logs/2026-07-30-us-enhc-011-closeout-plan.md §2.
    try {
      const token = await getAccessTokenSilently()
      await onboardingApi.skip(token)
    } catch {
      // Fail open — a failed skip-call must not trap the user in the wizard;
      // worst case they see it again next login, which is the safe default.
    }
    await refreshOnboardingState()
    navigate(returnTo)
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
        {/* maxWidth here (not just on each step's own root div) is what
            actually centers content — without it this wrapper fills 100% of
            the flex container's width, so the parent's justifyContent:
            'center' has no space left to center anything into, and every
            step renders flush left instead. Width varies per step kind
            (STEP_MAX_WIDTH) so content-heavy steps get breathing room
            without forcing scroll, while short steps stay tight and centered. */}
        <div style={{ width: '100%', maxWidth: STEP_MAX_WIDTH[step.kind] }}>
          {step.kind === 'welcome' && (
            <WelcomeStep onContinue={wizard.goNext} onOpenHelp={() => setHelpOpen(true)} />
          )}

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

          {step.kind === 'preferences' && (
            <PreferencesStep
              initialValues={preferences}
              submitting={preferencesSubmitting}
              error={preferencesError}
              onSubmit={handlePreferencesSubmit}
              onBack={wizard.goBack}
            />
          )}

          {step.kind === 'api-key' && (
            <ApiKeyStep
              revealed={apiKeyRevealed}
              revealing={apiKeyRevealing}
              error={apiKeyError}
              onReveal={handleRevealApiKey}
              onContinue={wizard.goNext}
              onBack={wizard.goBack}
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
