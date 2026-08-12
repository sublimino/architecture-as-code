import { createContext, useContext, useState, useEffect, useCallback, lazy, Suspense } from 'react'
import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import { useAuth0 } from './auth/oidc'
import { useSuperadmin } from './auth/superadmin'
import Sidebar from './components/Sidebar'
import ProtectedRoute from './auth/ProtectedRoute'
import DemoToggle from './components/DemoToggle'
import ThemeToggle from './components/ThemeToggle'
import KeyboardShortcutsOverlay from './components/KeyboardShortcutsOverlay'
import SetupBanner from './components/onboarding/SetupBanner'
import { api } from './api/client'
import { connectorsApi } from './api/connectorsClient'
import { onboardingApi } from './api/onboardingClient'
import type { CookiePreferences } from './types/api'

const CONSENT_ENABLED = import.meta.env.VITE_CONSENT_MODAL_ENABLED === 'true'

/** localStorage key shared with OnboardingWizard — skip TTL (30 min). */
const ONBOARDING_SKIP_STORAGE_KEY = 'sl_onboarding_skipped'
const ONBOARDING_SKIP_TTL_MS = 30 * 60 * 1000

const ConsentModal    = CONSENT_ENABLED ? lazy(() => import('./components/ConsentModal'))    : null
const CookieSettingsModal = lazy(() => import('./components/CookieSettingsModal'))

const AgentsPage = lazy(() => import('./pages/AgentsPage'))
const AgentDetailPage = lazy(() => import('./pages/AgentDetailPage'))
const DiscoveryPage = lazy(() => import('./pages/DiscoveryPage'))
const DiscoveryAccountDetailPage = lazy(() => import('./pages/DiscoveryAccountDetailPage'))
const CompliancePage = lazy(() => import('./pages/CompliancePage'))
const FrameworkDetailPage = lazy(() => import('./pages/FrameworkDetailPage'))
const AuditTrailPage = lazy(() => import('./pages/AuditTrailPage'))
const CryptographyPage = lazy(() => import('./pages/CryptographyPage'))
const CredentialInventoryPage = lazy(() => import('./pages/CredentialInventoryPage'))
const FederatedServicesPage = lazy(() => import('./pages/FederatedServicesPage'))
const CollusionAccessPage = lazy(() => import('./pages/CollusionAccessPage'))
const RbacAnalysisPage = lazy(() => import('./pages/RbacAnalysisPage'))
const RbacExplorerPage = lazy(() => import('./pages/RbacExplorerPage'))
const SettingsPage = lazy(() => import('./pages/SettingsPage'))
const RedeemInvitePage = lazy(() => import('./pages/RedeemInvite'))
const OnboardingWizardPage = lazy(() => import('./pages/OnboardingWizard'))
const ConnectorHelpPage = lazy(() => import('./pages/ConnectorHelpPage'))
const SuperCredPage = lazy(() => import('./pages/SuperCredPage'))
const CompliancePolicyPage = lazy(() => import('./pages/CompliancePolicyPage'))
const AgentPosturePage = lazy(() => import('./pages/AgentPosturePage'))
const RiskExposurePage = lazy(() => import('./pages/RiskExposurePage'))
const NetworkTestsPage = lazy(() => import('./pages/NetworkTestsPage'))
const AgentTrustTopologyPage = lazy(() => import('./pages/AgentTrustTopologyPage'))
const FleetDemoPage = lazy(() => import('./pages/FleetDemoPage'))

export interface ApiKeyRevealData {
  key: string
  prefix_hint: string
}

export interface AppCtx {
  failingControls: number
  setFailingControls: (n: number) => void
  helpOpen: boolean
  setHelpOpen: (v: boolean) => void
  apiKeyReveal: ApiKeyRevealData | null
  setApiKeyReveal: (v: ApiKeyRevealData | null) => void
  cookieSettingsOpen: boolean
  setCookieSettingsOpen: (v: boolean) => void
  superadmin: boolean
  setSuperadmin: (v: boolean) => void
  connectedProviderCount: number
  totalProviderCount: number
  needsOnboarding: boolean | null
  refreshOnboardingState: () => Promise<void>
}

export const AppContext = createContext<AppCtx>({
  failingControls: 0,
  setFailingControls: () => undefined,
  helpOpen: false,
  setHelpOpen: () => undefined,
  apiKeyReveal: null,
  setApiKeyReveal: () => undefined,
  cookieSettingsOpen: false,
  setCookieSettingsOpen: () => undefined,
  superadmin: false,
  setSuperadmin: () => undefined,
  connectedProviderCount: 0,
  totalProviderCount: 0,
  needsOnboarding: null,
  refreshOnboardingState: () => Promise.resolve(),
})

export function useAppContext() {
  return useContext(AppContext)
}

function Spinner() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', background: 'var(--bg)' }}>
      <div style={{ width: 36, height: 36, border: '3px solid var(--border)', borderTopColor: 'var(--cyan)', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
      <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
    </div>
  )
}

export default function App() {
  const { isAuthenticated, isLoading, getAccessTokenSilently } = useAuth0()
  const location = useLocation()
  const [failingControls, setFailingControls] = useState(0)
  const [helpOpen, setHelpOpen] = useState(false)
  const [apiKeyReveal, setApiKeyReveal] = useState<ApiKeyRevealData | null>(null)
  const [cookieSettingsOpen, setCookieSettingsOpen] = useState(false)
  const [superadmin, setSuperadmin] = useSuperadmin()
  const [consentRequired, setConsentRequired] = useState<boolean | null>(null)
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null)
  const [connectedProviderCount, setConnectedProviderCount] = useState(0)
  const [totalProviderCount, setTotalProviderCount] = useState(0)

  const refreshOnboardingState = useCallback(async () => {
    if (!isAuthenticated) {
      setNeedsOnboarding(null)
      return
    }

    // Client-side TTL — if the user recently skipped, suppress the gate
    // for ~30 minutes without hitting the server. The localStorage entry
    // is written by OnboardingWizard.handleSkip().
    try {
      const raw = localStorage.getItem(ONBOARDING_SKIP_STORAGE_KEY)
      if (raw) {
        const { skippedAt } = JSON.parse(raw) as { skippedAt: number }
        if (Date.now() - skippedAt < ONBOARDING_SKIP_TTL_MS) {
          setNeedsOnboarding(false)
          return
        }
        // Expired — clean up
        localStorage.removeItem(ONBOARDING_SKIP_STORAGE_KEY)
      }
    } catch {
      // Corrupt or unavailable localStorage — fall through to server check.
    }

    try {
      const token = await getAccessTokenSilently()
      const [providers, connectors, onboardingStatus] = await Promise.all([
        connectorsApi.listProviders(token),
        connectorsApi.listConnectors(token),
        onboardingApi.getStatus(token),
      ])
      const connectedCount = connectors.filter((c) => c.status === 'connected').length
      setTotalProviderCount(providers.length)
      setConnectedProviderCount(connectedCount)
      setNeedsOnboarding(connectedCount === 0 && !onboardingStatus.skipped_at)
    } catch {
      setNeedsOnboarding(false)
    }
  }, [isAuthenticated, getAccessTokenSilently])

  useEffect(() => {
    void refreshOnboardingState()
  }, [refreshOnboardingState])

  useEffect(() => {
    if (!isAuthenticated || !CONSENT_ENABLED) {
      setConsentRequired(false)
      return
    }
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const status = await api.consent.status(token)
        setConsentRequired(status.consent_required)
      } catch {
        setConsentRequired(false)
      }
    })()
  }, [isAuthenticated]) // eslint-disable-line react-hooks/exhaustive-deps

  async function handleConsentAccept(cookiePrefs: CookiePreferences) {
    const token = await getAccessTokenSilently()
    await api.consent.accept(token, {
      document_versions: { terms: '1.2', eula: '1.2', privacy: '1.2' },
      cookie_preferences: cookiePrefs,
      b2b_warranty_accepted: true,
    })
    setConsentRequired(false)
  }

  if (isLoading) return <Spinner />

  const onboardingGateExempt =
    location.pathname === '/onboarding' || location.pathname.startsWith('/help/connectors')

  return (
    <AppContext.Provider value={{
      failingControls, setFailingControls,
      helpOpen, setHelpOpen,
      apiKeyReveal, setApiKeyReveal,
      cookieSettingsOpen, setCookieSettingsOpen,
      superadmin, setSuperadmin,
      connectedProviderCount, totalProviderCount,
      needsOnboarding, refreshOnboardingState,
    }}>
      <DemoToggle />
      <ThemeToggle />

      {CONSENT_ENABLED && ConsentModal && isAuthenticated && consentRequired === true && (
        <Suspense fallback={null}>
          <ConsentModal onAccept={handleConsentAccept} />
        </Suspense>
      )}

      {cookieSettingsOpen && isAuthenticated && (
        <Suspense fallback={null}>
          <CookieSettingsModal onClose={() => setCookieSettingsOpen(false)} />
        </Suspense>
      )}

      {/* Every shortcut it documents is bound by the Sidebar, so it only
          makes sense once the Sidebar is on screen. */}
      {isAuthenticated && <KeyboardShortcutsOverlay />}

      <div style={{ display: 'flex', height: '100vh', overflow: 'hidden' }}>
        {isAuthenticated && <Sidebar />}
        <main style={{ flex: 1, overflow: 'auto', background: 'var(--bg)' }}>
          {isAuthenticated && needsOnboarding === true && !onboardingGateExempt && (
            <SetupBanner
              connectedCount={connectedProviderCount}
              totalCount={totalProviderCount}
            />
          )}
          <div key={location.pathname} className="fade-in" style={{ padding: '28px 32px', maxWidth: 1172, margin: '0 auto', minHeight: '100%' }}>
            <Suspense fallback={<Spinner />}>
              <Routes>
                <Route path="/redeem-invite" element={<RedeemInvitePage />} />
                <Route path="/signup" element={<Navigate to="/redeem-invite" replace />} />

                <Route path="/" element={<Navigate to="/agents" replace />} />
                <Route path="/agents" element={<ProtectedRoute><AgentsPage /></ProtectedRoute>} />
                <Route path="/agents/:id" element={<ProtectedRoute><AgentDetailPage /></ProtectedRoute>} />
                <Route path="/discovery" element={<ProtectedRoute><DiscoveryPage /></ProtectedRoute>} />
                <Route path="/discovery/accounts/:accountId" element={<ProtectedRoute><DiscoveryAccountDetailPage /></ProtectedRoute>} />
                <Route path="/compliance" element={<ProtectedRoute><CompliancePage /></ProtectedRoute>} />
                <Route path="/compliance/policies" element={<ProtectedRoute><CompliancePolicyPage /></ProtectedRoute>} />
                <Route path="/compliance/posture" element={<ProtectedRoute><AgentPosturePage /></ProtectedRoute>} />
                <Route path="/compliance/risk" element={<ProtectedRoute><RiskExposurePage /></ProtectedRoute>} />
                <Route path="/compliance/:frameworkId" element={<ProtectedRoute><FrameworkDetailPage /></ProtectedRoute>} />
                <Route path="/audit" element={<ProtectedRoute><AuditTrailPage /></ProtectedRoute>} />
                <Route path="/cryptography" element={<ProtectedRoute><CryptographyPage /></ProtectedRoute>} />
                <Route path="/credential-inventory" element={<ProtectedRoute><CredentialInventoryPage /></ProtectedRoute>} />
                <Route path="/federated-services" element={<ProtectedRoute><FederatedServicesPage /></ProtectedRoute>} />
                <Route path="/collusion-access" element={<ProtectedRoute><CollusionAccessPage /></ProtectedRoute>} />
                <Route path="/rbac-analysis" element={<ProtectedRoute><RbacAnalysisPage /></ProtectedRoute>} />
                <Route path="/rbac-explorer" element={<ProtectedRoute><RbacExplorerPage /></ProtectedRoute>} />
                <Route path="/agent-trust-topology" element={<ProtectedRoute><AgentTrustTopologyPage /></ProtectedRoute>} />
                <Route path="/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
                <Route path="/onboarding" element={<ProtectedRoute exemptFromOnboardingGate><OnboardingWizardPage /></ProtectedRoute>} />
                <Route path="/help/connectors/:provider" element={<ProtectedRoute exemptFromOnboardingGate><ConnectorHelpPage /></ProtectedRoute>} />
                <Route path="/network-tests" element={<ProtectedRoute><NetworkTestsPage /></ProtectedRoute>} />
                <Route path="/supercred" element={<ProtectedRoute><SuperCredPage /></ProtectedRoute>} />
                <Route path="/fleet" element={<ProtectedRoute><FleetDemoPage /></ProtectedRoute>} />
                <Route path="/fleet/audience" element={<ProtectedRoute><FleetDemoPage audience /></ProtectedRoute>} />
                <Route path="*" element={<Navigate to="/agents" replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>
      </div>
    </AppContext.Provider>
  )
}
