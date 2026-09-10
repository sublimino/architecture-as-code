import React, { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth0 } from '../../auth/oidc'
import { getTenantIdFromToken } from '../../auth/tenant'
import { onboardingApi, OnboardingApiError } from '../../api/onboardingClient'
import { useAppContext } from '../../App'
import OnboardingProgressHeader, { type StepDefinition } from './OnboardingProgressHeader'
import TenantIdentityStep, { type TenantProfileData } from './TenantIdentityStep'
import IdpLinkageStep, { type IdpConfigData } from './IdpLinkageStep'
import ContainmentPolicyConsentStep, { type ContainmentPolicyData } from './ContainmentPolicyConsentStep'
import CompletionCelebration from './CompletionCelebration'
import ValidationErrorBanner from './ValidationErrorBanner'
import LoadingState from '../LoadingState'

const WIZARD_STEPS: StepDefinition[] = [
  { id: 'tenant-identity', title: 'Organization & Identity', subtitle: 'Set up tenant and workspace profile' },
  { id: 'idp-linkage', title: 'Identity Provider', subtitle: 'Link OIDC/OAuth2 authentication' },
  { id: 'containment-policy', title: 'Containment & Consent', subtitle: 'Configure zero-trust policy rules' },
]

export interface OnboardingWizardProps {
  onCompleted?: () => void
  onSkipped?: () => void
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

  const [stepIndex, setStepIndex] = useState<number>(0)
  const [isCompleted, setIsCompleted] = useState<boolean>(false)
  const [submittingComplete, setSubmittingComplete] = useState<boolean>(false)
  const [apiError, setApiError] = useState<string | null>(null)

  // Step Data Form States
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
    connectionTested: true,
  })

  const [containmentPolicy, setContainmentPolicy] = useState<ContainmentPolicyData>({
    policyTier: 'strict-sandboxed',
    zeroTrustIdentity: true,
    autonomousContainment: true,
    auditTrailRetention: true,
  })

  // Load Initial Server State
  const loadInitialState = useCallback(async () => {
    if (!isAuthenticated) return
    setLoading(true)
    setLoadError(null)
    try {
      const token = await getAccessTokenSilently()
      const tid = getTenantIdFromToken(token)
      setTenantId(tid)

      const [status, state] = await Promise.all([
        onboardingApi.getStatus(token).catch(() => null),
        onboardingApi.getState(token).catch(() => null),
      ])

      if (status?.status === 'completed' || Boolean(status?.completed_at)) {
        setIsCompleted(true)
      } else if (state) {
        if (typeof state.step_index === 'number' && state.step_index >= 0 && state.step_index < WIZARD_STEPS.length) {
          setStepIndex(state.step_index)
        }
        if (state.selected_provider_ids && state.selected_provider_ids.length > 0) {
          const pid = state.selected_provider_ids[0]
          setIdpConfig((prev) => ({ ...prev, providerId: pid }))
        }
        if (state.provider_run_state) {
          // If we had stored state inside provider_run_state
          const storedDex = state.provider_run_state.dex
          if (storedDex?.status === 'connected') {
            setIdpConfig((prev) => ({ ...prev, connectionTested: true }))
          }
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

  // Persist State to Server on Step Transitions
  const persistState = useCallback(
    async (nextStepIndex: number, currentProviderId: string) => {
      try {
        const token = await getAccessTokenSilently()
        await onboardingApi.putState(token, {
          selected_provider_ids: [currentProviderId],
          step_index: nextStepIndex,
          provider_run_state: {
            [currentProviderId]: {
              status: idpConfig.connectionTested ? 'connected' : 'idle',
            },
          },
        })
      } catch (err) {
        // Best effort background sync - non-blocking
        console.warn('Failed to persist wizard step progress:', err)
      }
    },
    [getAccessTokenSilently, idpConfig.connectionTested],
  )

  // Step 1 Handlers
  const handleTenantIdentityNext = (data: TenantProfileData) => {
    setTenantProfile(data)
    setApiError(null)
    const nextIdx = 1
    setStepIndex(nextIdx)
    void persistState(nextIdx, idpConfig.providerId)
  }

  // Step 2 Handlers
  const handleIdpNext = (data: IdpConfigData) => {
    setIdpConfig(data)
    setApiError(null)
    const nextIdx = 2
    setStepIndex(nextIdx)
    void persistState(nextIdx, data.providerId)
  }

  const handleBackToStep1 = () => {
    setApiError(null)
    const prevIdx = 0
    setStepIndex(prevIdx)
    void persistState(prevIdx, idpConfig.providerId)
  }

  // Step 3 Handlers
  const handleBackToStep2 = () => {
    setApiError(null)
    const prevIdx = 1
    setStepIndex(prevIdx)
    void persistState(prevIdx, idpConfig.providerId)
  }

  const handleComplete = async (policy: ContainmentPolicyData) => {
    setContainmentPolicy(policy)
    setSubmittingComplete(true)
    setApiError(null)

    try {
      const token = await getAccessTokenSilently()
      // Persist final step state
      await onboardingApi.putState(token, {
        selected_provider_ids: [idpConfig.providerId],
        step_index: 2,
        provider_run_state: {
          [idpConfig.providerId]: { status: 'connected' },
        },
      })

      // Send terminal complete mutation
      await onboardingApi.complete(token)

      // Refresh app-level status
      await refreshOnboardingState()

      setIsCompleted(true)
      if (onCompleted) {
        onCompleted()
      }
    } catch (err) {
      const msg = err instanceof OnboardingApiError ? err.message : 'Failed to complete onboarding. Please try again.'
      setApiError(msg)
    } finally {
      setSubmittingComplete(false)
    }
  }

  // Skip Handler
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
      // Even if server skip fails, navigate away gracefully
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

  return (
    <div data-testid="onboarding-wizard-container" className="fade-in" style={{ paddingBottom: 60 }}>
      <OnboardingProgressHeader
        currentStepIndex={stepIndex}
        totalSteps={WIZARD_STEPS.length}
        steps={WIZARD_STEPS}
        onStepClick={(idx) => {
          if (idx < stepIndex) {
            setStepIndex(idx)
            void persistState(idx, idpConfig.providerId)
          }
        }}
        onSkip={handleSkip}
      />

      {apiError && (
        <div style={{ maxWidth: 760, margin: '0 auto 20px', padding: '0 20px' }}>
          <ValidationErrorBanner errors={[apiError]} onDismiss={() => setApiError(null)} />
        </div>
      )}

      <div style={{ padding: '0 20px' }}>
        {stepIndex === 0 && (
          <TenantIdentityStep
            initialValues={tenantProfile}
            onNext={handleTenantIdentityNext}
            onSkip={handleSkip}
          />
        )}

        {stepIndex === 1 && (
          <IdpLinkageStep
            initialValues={idpConfig}
            onNext={handleIdpNext}
            onBack={handleBackToStep1}
            onSkip={handleSkip}
          />
        )}

        {stepIndex === 2 && (
          <ContainmentPolicyConsentStep
            tenantProfile={tenantProfile}
            idpConfig={idpConfig}
            initialValues={containmentPolicy}
            submitting={submittingComplete}
            onSubmit={handleComplete}
            onBack={handleBackToStep2}
            onSkip={handleSkip}
          />
        )}
      </div>
    </div>
  )
}
