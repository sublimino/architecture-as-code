/**
 * The onboarding wizard, in the order a new tenant operator needs things:
 *
 *   welcome (not a persisted step)
 *   0 Organization & Identity   TenantIdentityStep        PATCH /api/tenant/settings/risk-profile
 *                                                         (the declared risk half only -- see below)
 *   1 Identity Provider          IdpLinkageStep            Test Connection -> GET /api/v1/me
 *   2 Scan preferences           PreferencesStep           PATCH /api/tenant/settings/preferences
 *   3 API key (opt-in reveal)    ApiKeyStep                POST /api/tenants/{id}/api-keys/initial
 *   4 Containment & Consent      ContainmentPolicyConsentStep  POST /api/onboarding/complete
 *
 * Step progress and the selected provider persist through PUT /api/onboarding/state
 * (tenant_onboarding.wizard_state), so a user resumes where they left off on
 * another device. Preferences persist through the tenant settings API, which is
 * the same row the Settings page edits, so what the wizard saves is what
 * Settings shows. The declared risk profile (sector, jurisdiction, reporting
 * currency, risk appetite) now does too.
 *
 * STILL NOT PERSISTED, stated so it is not mistaken for done: the identity half
 * of step 0 -- organizationName, workspaceId, adminEmail, environment,
 * description. Those five have no column to land in and remain wizard-local, so
 * they are still lost on reload. Giving them one is a separate change; what was
 * fixed here is that the step no longer discards EVERYTHING it collects.
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
  allowReplay?: boolean
  initialStepIndex?: number
  mode?: 'standalone' | 'settings'
}

type StoredRiskProfile = {
  sector: string | null
  jurisdiction: string | null
  reporting_currency: string | null
  risk_appetite_tolerance: number | null
  risk_load: number | null
}

function errorMessage(err: unknown, fallback: string): string {
  if (err instanceof OnboardingApiError) return err.message
  if (err && typeof err === 'object' && 'message' in err && typeof (err as { message: unknown }).message === 'string') {
    return (err as { message: string }).message
  }
  return fallback
}

export default function OnboardingWizard({
  onCompleted,
  onSkipped,
  allowReplay = false,
  initialStepIndex,
  mode = 'standalone',
}: OnboardingWizardProps) {
  const { getAccessTokenSilently, isAuthenticated } = useAuth0()
  const navigate = useNavigate()
  const location = useLocation()
  const { refreshOnboardingState } = useAppContext()

  const returnTo = (location.state as { returnTo?: string } | null)?.returnTo || '/overview'

  const isReplayOrSettings = mode === 'settings' || Boolean(allowReplay)
  const skipLabel = isReplayOrSettings ? 'Exit setup' : undefined
  const initialIndex =
    typeof initialStepIndex === 'number' && initialStepIndex >= 0 && initialStepIndex < WIZARD_STEPS.length
      ? initialStepIndex
      : STEP_TENANT

  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [tenantId, setTenantId] = useState<string | null>(null)

  const [showWelcome, setShowWelcome] = useState<boolean>(!isReplayOrSettings)
  const [stepIndex, setStepIndex] = useState<number>(initialIndex)
  const [isCompleted, setIsCompleted] = useState<boolean>(false)
  const [previouslyCompleted, setPreviouslyCompleted] = useState<boolean>(false)
  const [settingsCompleted, setSettingsCompleted] = useState<boolean>(false)
  const [submittingComplete, setSubmittingComplete] = useState<boolean>(false)
  const [apiError, setApiError] = useState<string | null>(null)

  const [tenantProfile, setTenantProfile] = useState<TenantProfileData>({
    organizationName: 'Acme Corporation',
    workspaceId: 'acme-primary',
    adminEmail: 'operator@acme.corp',
    environment: 'production',
    description: 'Enterprise autonomous agent governance, runtime confinement, and tamper-evident audit.',
  })

  const [tenantProfileError, setTenantProfileError] = useState<string | undefined>(undefined)

  // The risk profile as the server holds it. null means it could not be read,
  // so there is no baseline to diff against or risk_load to carry forward.
  const [storedRiskProfile, setStoredRiskProfile] = useState<StoredRiskProfile | null>(null)

  const [idpConfig, setIdpConfig] = useState<IdpConfigData>({
    providerId: 'dex',
    providerName: 'Dex OIDC (In-Cluster)',
    issuerUrl: 'https://dex.inf-signalloom.svc.cluster.local:5556/dex',
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
        const stored: StoredRiskProfile = {
          sector: settings.sector ?? null,
          jurisdiction: settings.jurisdiction ?? null,
          reporting_currency: settings.reporting_currency ?? null,
          risk_appetite_tolerance: settings.risk_appetite_tolerance ?? null,
          risk_load: settings.risk_load ?? null,
        }
        setStoredRiskProfile(stored)
        // The step edits what is stored, not a blank form: replaying it and
        // pressing Next must not erase a declaration.
        setTenantProfile((prev) => ({
          ...prev,
          sector: stored.sector ?? undefined,
          jurisdiction: stored.jurisdiction ?? undefined,
          reportingCurrency: stored.reporting_currency ?? undefined,
          riskAppetiteTolerance: stored.risk_appetite_tolerance === null ? undefined : String(stored.risk_appetite_tolerance),
        }))
      }

      const wasCompleted = status?.status === 'completed' || Boolean(status?.completed_at)
      if (wasCompleted) {
        setPreviouslyCompleted(true)
        if (!isReplayOrSettings) {
          setIsCompleted(true)
          return
        }
      }

      const resumed =
        typeof initialStepIndex === 'number' && initialStepIndex >= 0 && initialStepIndex < WIZARD_STEPS.length
          ? initialStepIndex
          : typeof state?.step_index === 'number' && state.step_index >= 0 && state.step_index < WIZARD_STEPS.length
          ? state.step_index
          : STEP_TENANT
      setStepIndex(resumed)

      if (isReplayOrSettings) {
        setShowWelcome(false)
      } else {
        const hasProgress = resumed > STEP_TENANT || (state?.selected_provider_ids?.length ?? 0) > 0
        setShowWelcome(!hasProgress)
      }

      if (state?.selected_provider_ids && state.selected_provider_ids.length > 0) {
        const pid = state.selected_provider_ids[0]
        setIdpConfig((prev) => ({ ...prev, providerId: pid, issuerUrl: pid === 'dex' ? prev.issuerUrl : undefined }))
      }
      const stored = state?.provider_run_state?.[state?.selected_provider_ids?.[0] ?? 'dex']
      if (stored?.status === 'connected') {
        setIdpConfig((prev) => ({ ...prev, connectionTested: true }))
      }
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : 'Failed to load onboarding status from server.')
    } finally {
      setLoading(false)
    }
  }, [isAuthenticated, getAccessTokenSilently, isReplayOrSettings, initialStepIndex])

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

  const handleTenantIdentityNext = async (data: TenantProfileData) => {
    setTenantProfile(data)
    setTenantProfileError(undefined)

    // THE BUG THIS FIXES: tenantProfile was React state and nothing ever sent
    // it anywhere -- not to the risk profile columns, not even into
    // wizard_state. A tenant typed its organisation identity, clicked Next, and
    // the whole thing evaporated on reload.
    //
    // The declared risk half now persists. The identity half (organizationName,
    // workspaceId, adminEmail, environment, description) still does not have a
    // column to land in, and inventing one was out of scope here -- so it is
    // still wizard-local, and that is a KNOWN remaining gap rather than a fixed
    // one.
    //
    // A failure here does NOT block the step. The whole profile is optional and
    // the step is skippable, so refusing to advance because an optional
    // declaration did not save would be a worse product than advancing with a
    // visible warning. Silence would be worse than both, which is why the error
    // is surfaced rather than swallowed.
    const tolerance = data.riskAppetiteTolerance?.trim()
    const declared = {
      sector: data.sector ?? null,
      jurisdiction: data.jurisdiction ?? null,
      reporting_currency: data.reportingCurrency ?? null,
      risk_appetite_tolerance: tolerance ? Number(tolerance) : null,
    }
    const nothingDeclared = Object.values(declared).every((v) => v === null)

    // The PATCH replaces the whole profile (api_compat.py), so it is only safe
    // against a known baseline: unchanged means no request at all, and a
    // change carries the stored risk_load (not collected by this form, an
    // actuarial parameter) forward instead of nulling it.
    if (!storedRiskProfile) {
      if (!nothingDeclared) {
        setTenantProfileError(
          'The stored risk profile could not be loaded, so the risk profile was not saved (saving now would ' +
          'overwrite fields this form does not show). You can set it later in Settings.',
        )
      }
    } else {
      const unchanged = (Object.keys(declared) as (keyof typeof declared)[]).every(
        (k) => declared[k] === storedRiskProfile[k],
      )
      if (!unchanged) {
        const body: StoredRiskProfile = { ...declared, risk_load: storedRiskProfile.risk_load }
        try {
          const token = await getAccessTokenSilently()
          await api.patchRiskProfile(token, body)
          setStoredRiskProfile(body)
        } catch (err) {
          setTenantProfileError(
            errorMessage(err, 'Could not save the risk profile. You can set it later in Settings.'),
          )
        }
      }
    }

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
      setPreviouslyCompleted(true)
      if (mode === 'settings') {
        setSettingsCompleted(true)
        if (onCompleted) onCompleted()
      } else {
        setIsCompleted(true)
        if (onCompleted) onCompleted()
      }
    } catch (err) {
      setApiError(errorMessage(err, 'Failed to complete onboarding. Please try again.'))
    } finally {
      setSubmittingComplete(false)
    }
  }

  const handleSkip = async () => {
    setApiError(null)
    // Replaying a finished (or settings-driven) setup: leaving it is a local
    // exit. POST /onboarding/skip would flip a completed tenant to skipped.
    if (isReplayOrSettings) {
      if (onSkipped) onSkipped()
      else navigate(returnTo, { replace: true })
      return
    }
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
        allowReplay={isReplayOrSettings}
        onStepClick={(idx) => {
          if (isReplayOrSettings) {
            setSettingsCompleted(false)
            goTo(idx)
          } else if (idx < stepIndex) {
            goTo(idx)
          }
        }}
        onSkip={handleSkip}
        skipLabel={skipLabel}
      />

      {apiError && (
        <div style={{ maxWidth: 760, margin: '0 auto 20px', padding: '0 20px' }}>
          <ValidationErrorBanner errors={[apiError]} onDismiss={() => setApiError(null)} />
        </div>
      )}

      {/* The risk profile is optional, so a failed save warns and lets the user
          carry on -- but it must never fail silently, or they would believe a
          declaration landed when it did not. */}
      {tenantProfileError && (
        <div style={{ maxWidth: 760, margin: '0 auto 20px', padding: '0 20px' }}>
          <ValidationErrorBanner
            errors={[tenantProfileError]}
            onDismiss={() => setTenantProfileError(undefined)}
          />
        </div>
      )}

      {settingsCompleted ? (
        <div style={{ maxWidth: 760, margin: '0 auto 24px', padding: '0 20px' }}>
          <div
            data-testid="onboarding-settings-completed-banner"
            style={{
              padding: '20px 24px',
              borderRadius: 'var(--radius)',
              background: 'var(--surface)',
              border: '1px solid var(--border)',
            }}
          >
            <p
              style={{
                margin: 0,
                fontSize: '15px',
                lineHeight: 1.5,
                color: 'var(--text)',
                fontWeight: 500,
              }}
            >
              ✓ Onboarding configuration updated successfully: onboarding is marked complete and the steps you saved along the way (risk profile, connectors, scan preferences) are stored. The containment policy choices are not saved by the server yet, so they do not change how any agent is governed.
            </p>
            <div style={{ display: 'flex', gap: '12px', marginTop: '16px' }}>
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="modify-again-button"
                onClick={() => setSettingsCompleted(false)}
              >
                Modify Again
              </button>
              {onCompleted && (
                <button
                  type="button"
                  className="btn btn-primary"
                  data-testid="settings-done-button"
                  onClick={onCompleted}
                >
                  Done
                </button>
              )}
            </div>
          </div>
        </div>
      ) : (
        <>
          {previouslyCompleted && (
            <div style={{ maxWidth: 760, margin: '0 auto 20px', padding: '0 20px' }}>
              <div
                data-testid="onboarding-replay-banner"
                style={{
                  padding: '12px 16px',
                  borderRadius: 'var(--radius)',
                  background: 'var(--surface)',
                  border: '1px solid var(--border)',
                  color: 'var(--muted)',
                  fontSize: '0.875rem',
                  lineHeight: 1.5,
                }}
              >
                Onboarding previously completed. You can re-run any step, update your organization profile, change IdP connectors, update scan cadence, or modify containment policies at any time.
              </div>
            </div>
          )}

          <div style={{ padding: '0 20px' }}>
            {stepIndex === STEP_TENANT && (
              <TenantIdentityStep
                initialValues={tenantProfile}
                onNext={handleTenantIdentityNext}
                onSkip={handleSkip}
                skipLabel={skipLabel}
              />
            )}

            {stepIndex === STEP_IDP && (
              <IdpLinkageStep
                initialValues={idpConfig}
                onNext={handleIdpNext}
                onBack={() => goTo(STEP_TENANT)}
                onSkip={handleSkip}
                skipLabel={skipLabel}
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
                skipLabel={skipLabel}
              />
            )}
          </div>
        </>
      )}
    </div>
  )
}
