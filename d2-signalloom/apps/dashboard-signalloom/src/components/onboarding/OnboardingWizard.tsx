/**
 * The onboarding wizard, in the order a new tenant operator needs things:
 *
 *   welcome (not a persisted step)
 *   0 Organization & Identity   TenantIdentityStep        saved in wizard state
 *   1 Identity Provider          IdpLinkageStep            Test Connection -> GET /api/v1/me
 *   2 Scan preferences           PreferencesStep           PATCH /api/tenant/settings/preferences
 *   3 API key (opt-in reveal)    ApiKeyStep                POST /api/tenants/{id}/api-keys/initial
 *   4 Containment & Consent      ContainmentPolicyConsentStep  POST /api/onboarding/complete
 *
 * Step progress and the selected provider persist through PUT /api/onboarding/state
 * (tenant_onboarding.wizard_state), so a user resumes where they left off on
 * another device. Preferences persist through the tenant settings API, which is
 * the same row the Settings page edits, so what the wizard saves is what
 * Settings shows.
 *
 * Not rendered here: ProviderSelectStep, ProviderConfigureStep and SummaryStep.
 * They drive the connectors API and live on the Connectors page, which already
 * owns create, test, toggle and delete; a second copy of that flow inside the
 * wizard would be a second place for it to drift.
 */
import React, { useCallback, useEffect, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth0 } from '../../auth/oidc'
import { getTenantIdFromToken } from '../../auth/tenant'
import { onboardingApi, OnboardingApiError } from '../../api/onboardingClient'
import { api } from '../../api/client'
import { useAppContext } from '../../App'
import OnboardingProgressHeader, { type StepDefinition } from './OnboardingProgressHeader'
import WelcomeStep from './WelcomeStep'
import TenantIdentityStep, { type TenantProfileData } from './TenantIdentityStep'
import IdpLinkageStep, { type IdpConfigData, type ConnectionTestResult } from './IdpLinkageStep'
import PreferencesStep, { type PreferencesValues } from './PreferencesStep'
import ApiKeyStep, { type RevealedKey } from './ApiKeyStep'
import ContainmentPolicyConsentStep, { type ContainmentPolicyData } from './ContainmentPolicyConsentStep'
import CompletionCelebration from './CompletionCelebration'
import ValidationErrorBanner from './ValidationErrorBanner'
import LoadingState from '../LoadingState'

export const WIZARD_STEPS: StepDefinition[] = [
  { id: 'tenant-identity', title: 'Organization & Identity', subtitle: 'Set up tenant and workspace profile' },
  { id: 'idp-linkage', title: 'Identity Provider', subtitle: 'Link OIDC/OAuth2 authentication' },
  { id: 'preferences', title: 'Scan preferences', subtitle: 'Cadence and alerting' },
  { id: 'api-key', title: 'API key', subtitle: 'Optional one-time reveal' },
  { id: 'containment-policy', title: 'Containment & Consent', subtitle: 'Configure zero-trust policy rules' },
]

const STEP_TENANT = 0
const STEP_IDP = 1
const STEP_PREFERENCES = 2
const STEP_API_KEY = 3
const STEP_CONTAINMENT = 4

const DEFAULT_PREFERENCES: PreferencesValues = {
  preferred_scan_cadence_hours: 24,
  alert_email: '',
  alert_threshold: 5,
}

export interface OnboardingWizardProps {
  onCompleted?: () => void
  onSkipped?: () => void
}

function errorMessage(err: unknown, fallback: string): string {
  if (err instanceof OnboardingApiError) return err.message
  if (err && typeof err === 'object' && 'message' in err && typeof (err as { message: unknown }).message === 'string') {
    return (err as { message: string }).message
  }
  return fallback
}

export default function OnboardingWizard({ onCompleted, onSkipped }: OnboardingWizardProps) {
  const { getAccessTokenSilently, isAuthenticated } = useAuth0()
  const navigate = useNavigate()
  const location = useLocation()
  const { refreshOnboardingState } = useAppContext()

  const returnTo = (location.state as { returnTo?: string } | null)?.returnTo || '/overview'

  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [tenantId, setTenantId] = useState<string | null>(null)

  const [showWelcome, setShowWelcome] = useState<boolean>(true)
  const [stepIndex, setStepIndex] = useState<number>(STEP_TENANT)
  const [isCompleted, setIsCompleted] = useState<boolean>(false)
  const [submittingComplete, setSubmittingComplete] = useState<boolean>(false)
  const [apiError, setApiError] = useState<string | null>(null)

  const [tenantProfile, setTenantProfile] = useState<TenantProfileData>({
    organizationName: 'Acme Corporation',
    workspaceId: 'acme-primary',
    adminEmail: 'operator@acme.corp',
    environment: 'production',
    description: 'Enterprise autonomous agent governance, runtime confinement, and tamper-evident audit.',
  })

  const [idpConfig, setIdpConfig] = useState<IdpConfigData>({
    providerId: 'dex',
    providerName: 'Dex OIDC (In-Cluster)',
    issuerUrl: 'https://dex.inf-signalloom.svc.cluster.local:5556/dex',
    clientId: 'signalloom-dashboard',
    clientSecret: '••••••••••••••••',
    scopes: 'openid profile email groups federated:id',
    // Nothing has been verified until Test Connection has asked the server.
    connectionTested: false,
  })

  const [preferences, setPreferences] = useState<PreferencesValues>(DEFAULT_PREFERENCES)
  const [savingPreferences, setSavingPreferences] = useState(false)
  const [preferencesError, setPreferencesError] = useState<string | undefined>(undefined)

  const [revealedKey, setRevealedKey] = useState<RevealedKey | null>(null)
  const [revealingKey, setRevealingKey] = useState(false)
  const [revealError, setRevealError] = useState<string | undefined>(undefined)

  const [containmentPolicy, setContainmentPolicy] = useState<ContainmentPolicyData>({
    policyTier: 'strict-sandboxed',
    zeroTrustIdentity: true,
    autonomousContainment: true,
    auditTrailRetention: true,
  })

  const loadInitialState = useCallback(async () => {
    if (!isAuthenticated) return
    setLoading(true)
    setLoadError(null)
    try {
      const token = await getAccessTokenSilently()
      const tid = getTenantIdFromToken(token)
      setTenantId(tid)

      const [status, state, settings] = await Promise.all([
        onboardingApi.getStatus(token).catch(() => null),
        onboardingApi.getState(token).catch(() => null),
        api.settings(token).catch(() => null),
      ])

      if (settings) {
        setPreferences({
          preferred_scan_cadence_hours: settings.preferred_scan_cadence_hours,
          alert_email: settings.alert_email ?? '',
          alert_threshold: settings.alert_threshold,
        })
      }

      if (status?.status === 'completed' || Boolean(status?.completed_at)) {
        setIsCompleted(true)
      } else if (state) {
        const resumed = typeof state.step_index === 'number' && state.step_index >= 0 && state.step_index < WIZARD_STEPS.length
          ? state.step_index
          : STEP_TENANT
        setStepIndex(resumed)
        // Someone who has already moved past the first step does not need the
        // welcome again; a fresh tenant does.
        const hasProgress = resumed > STEP_TENANT || (state.selected_provider_ids?.length ?? 0) > 0
        setShowWelcome(!hasProgress)
        if (state.selected_provider_ids && state.selected_provider_ids.length > 0) {
          const pid = state.selected_provider_ids[0]
          setIdpConfig((prev) => ({ ...prev, providerId: pid }))
        }
        const stored = state.provider_run_state?.[state.selected_provider_ids?.[0] ?? 'dex']
        if (stored?.status === 'connected') {
          setIdpConfig((prev) => ({ ...prev, connectionTested: true }))
        }
      }
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : 'Failed to load onboarding status from server.')
    } finally {
      setLoading(false)
    }
  }, [isAuthenticated, getAccessTokenSilently])

  useEffect(() => {
    void loadInitialState()
  }, [loadInitialState])

  const persistState = useCallback(
    async (nextStepIndex: number, currentProviderId: string, connectionTested: boolean) => {
      try {
        const token = await getAccessTokenSilently()
        await onboardingApi.putState(token, {
          selected_provider_ids: [currentProviderId],
          step_index: nextStepIndex,
          provider_run_state: {
            [currentProviderId]: { status: connectionTested ? 'connected' : 'idle' },
          },
        })
      } catch (err) {
        // Best effort background sync: losing the resume point is not worth
        // blocking the person in front of the form.
        console.warn('Failed to persist wizard step progress:', err)
      }
    },
    [getAccessTokenSilently],
  )

  const goTo = useCallback(
    (index: number, provider: string = idpConfig.providerId, tested: boolean = Boolean(idpConfig.connectionTested)) => {
      setApiError(null)
      setStepIndex(index)
      void persistState(index, provider, tested)
    },
    [idpConfig.providerId, idpConfig.connectionTested, persistState],
  )

  // Test Connection: prove the session this browser holds is one the portal
  // accepts. GET /api/v1/me validates the bearer against the configured
  // issuer and reports the tenant decision; that is exactly the thing a wrong
  // issuer would break. It does not probe the issuer URL typed above, and the
  // message says so rather than implying it.
  const testConnection = useCallback(
    async (issuerUrl: string): Promise<ConnectionTestResult> => {
      const token = await getAccessTokenSilently()
      try {
        const me = await api.me(token)
        const who = me.email ?? me.subject
        return {
          ok: true,
          message: `Portal session verified: ${who} in tenant ${me.tenant} (GET /api/v1/me). The issuer ${issuerUrl} is saved, not probed.`,
        }
      } catch (err) {
        const status = (err as { response?: { status?: number } })?.response?.status
        return {
          ok: false,
          message: status
            ? `The portal refused this session (HTTP ${status} from GET /api/v1/me).`
            : `The portal could not be reached: ${errorMessage(err, 'network error')}.`,
        }
      }
    },
    [getAccessTokenSilently],
  )

  const handleTenantIdentityNext = (data: TenantProfileData) => {
    setTenantProfile(data)
    goTo(STEP_IDP)
  }

  const handleIdpNext = (data: IdpConfigData) => {
    setIdpConfig(data)
    goTo(STEP_PREFERENCES, data.providerId, Boolean(data.connectionTested))
  }

  const handlePreferencesSubmit = async (values: PreferencesValues) => {
    setSavingPreferences(true)
    setPreferencesError(undefined)
    try {
      const token = await getAccessTokenSilently()
      const saved = await api.patchPreferences(token, {
        preferred_scan_cadence_hours: values.preferred_scan_cadence_hours,
        alert_email: values.alert_email.trim() ? values.alert_email.trim() : null,
        alert_threshold: values.alert_threshold,
      })
      setPreferences({
        preferred_scan_cadence_hours: saved.preferred_scan_cadence_hours,
        alert_email: saved.alert_email ?? '',
        alert_threshold: saved.alert_threshold,
      })
      goTo(STEP_API_KEY)
    } catch (err) {
      setPreferencesError(errorMessage(err, 'Failed to save scan preferences. Please try again.'))
    } finally {
      setSavingPreferences(false)
    }
  }

  const handleRevealKey = async () => {
    if (!tenantId) {
      setRevealError('No tenant id in the session token, so there is no key to reveal.')
      return
    }
    setRevealingKey(true)
    setRevealError(undefined)
    try {
      const token = await getAccessTokenSilently()
      const resp = await api.apiKeys.revealInitial(token, tenantId)
      setRevealedKey({ key: resp.key, prefix_hint: resp.prefix_hint })
    } catch (err) {
      setRevealError(errorMessage(err, 'The key could not be revealed. It may already have been shown once; use Settings to rotate it.'))
    } finally {
      setRevealingKey(false)
    }
  }

  const handleComplete = async (policy: ContainmentPolicyData) => {
    setContainmentPolicy(policy)
    setSubmittingComplete(true)
    setApiError(null)

    try {
      const token = await getAccessTokenSilently()
      await onboardingApi.putState(token, {
        selected_provider_ids: [idpConfig.providerId],
        step_index: STEP_CONTAINMENT,
        provider_run_state: {
          [idpConfig.providerId]: { status: idpConfig.connectionTested ? 'connected' : 'idle' },
        },
      })
      await onboardingApi.complete(token)
      await refreshOnboardingState()
      setIsCompleted(true)
      if (onCompleted) onCompleted()
    } catch (err) {
      setApiError(errorMessage(err, 'Failed to complete onboarding. Please try again.'))
    } finally {
      setSubmittingComplete(false)
    }
  }

  const handleSkip = async () => {
    setApiError(null)
    try {
      const token = await getAccessTokenSilently()
      await onboardingApi.skip(token)
      await refreshOnboardingState()
      if (onSkipped) {
        onSkipped()
      } else {
        navigate(returnTo, { replace: true })
      }
    } catch (err) {
      console.error('Failed to skip onboarding:', err)
      navigate(returnTo, { replace: true })
    }
  }

  const handleFinishAndGoToDashboard = () => {
    navigate(returnTo, { replace: true })
  }

  if (loading) {
    return (
      <div style={{ padding: '60px 20px', textAlign: 'center' }}>
        <LoadingState status="loading" label="setup" testId="onboarding-load-state" />
      </div>
    )
  }

  if (loadError) {
    return (
      <div style={{ maxWidth: 640, margin: '60px auto', padding: '0 20px' }}>
        <LoadingState
          status="error"
          label="setup"
          error={loadError}
          onRetry={() => void loadInitialState()}
          testId="onboarding-load-state"
        />
      </div>
    )
  }

  if (isCompleted) {
    return (
      <div className="fade-in" style={{ padding: '40px 20px' }}>
        <CompletionCelebration
          tenantProfile={tenantProfile}
          idpConfig={idpConfig}
          containmentPolicy={containmentPolicy}
          onContinue={handleFinishAndGoToDashboard}
        />
      </div>
    )
  }

  if (showWelcome) {
    return (
      <div data-testid="onboarding-welcome" className="fade-in" style={{ maxWidth: 760, margin: '0 auto', padding: '40px 20px' }}>
        <WelcomeStep
          onContinue={() => setShowWelcome(false)}
          onOpenHelp={() => navigate('/help/connectors')}
        />
      </div>
    )
  }

  return (
    <div data-testid="onboarding-wizard-container" className="fade-in" style={{ paddingBottom: 60 }}>
      <OnboardingProgressHeader
        currentStepIndex={stepIndex}
        totalSteps={WIZARD_STEPS.length}
        steps={WIZARD_STEPS}
        onStepClick={(idx) => {
          if (idx < stepIndex) goTo(idx)
        }}
        onSkip={handleSkip}
      />

      {apiError && (
        <div style={{ maxWidth: 760, margin: '0 auto 20px', padding: '0 20px' }}>
          <ValidationErrorBanner errors={[apiError]} onDismiss={() => setApiError(null)} />
        </div>
      )}

      <div style={{ padding: '0 20px' }}>
        {stepIndex === STEP_TENANT && (
          <TenantIdentityStep
            initialValues={tenantProfile}
            onNext={handleTenantIdentityNext}
            onSkip={handleSkip}
          />
        )}

        {stepIndex === STEP_IDP && (
          <IdpLinkageStep
            initialValues={idpConfig}
            onNext={handleIdpNext}
            onBack={() => goTo(STEP_TENANT)}
            onSkip={handleSkip}
            onTestConnection={testConnection}
          />
        )}

        {stepIndex === STEP_PREFERENCES && (
          <div style={{ maxWidth: 760, margin: '0 auto' }} data-testid="preferences-step">
            <PreferencesStep
              initialValues={preferences}
              submitting={savingPreferences}
              error={preferencesError}
              onSubmit={(values) => void handlePreferencesSubmit(values)}
              onBack={() => goTo(STEP_IDP)}
            />
          </div>
        )}

        {stepIndex === STEP_API_KEY && (
          <div style={{ maxWidth: 760, margin: '0 auto' }} data-testid="api-key-step">
            <ApiKeyStep
              revealed={revealedKey}
              revealing={revealingKey}
              error={revealError}
              onReveal={() => void handleRevealKey()}
              onContinue={() => goTo(STEP_CONTAINMENT)}
              onBack={() => goTo(STEP_PREFERENCES)}
            />
          </div>
        )}

        {stepIndex === STEP_CONTAINMENT && (
          <ContainmentPolicyConsentStep
            tenantProfile={tenantProfile}
            idpConfig={idpConfig}
            initialValues={containmentPolicy}
            submitting={submittingComplete}
            onSubmit={handleComplete}
            onBack={() => goTo(STEP_API_KEY)}
            onSkip={handleSkip}
          />
        )}
      </div>
    </div>
  )
}
