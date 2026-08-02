import { createContext, useContext, useState, useEffect, lazy, Suspense } from 'react'
import { Routes, Route, Navigate } from 'react-router-dom'
import { useAuth0 } from './auth/oidc'
import { useSuperadmin } from './auth/superadmin'
import Sidebar from './components/Sidebar'
import ProtectedRoute from './auth/ProtectedRoute'
import DemoToggle from './components/DemoToggle'
import ThemeToggle from './components/ThemeToggle'
import { api } from './api/client'
import type { CookiePreferences } from './types/api'

// Feature flag — must be "true" explicitly; any other value (including absence) = off.
// Default false in prod for safe rollout; set to "true" in dev .env.
const CONSENT_ENABLED = import.meta.env.VITE_CONSENT_MODAL_ENABLED === 'true'

// Lazy-loaded to keep the main bundle lean; only fetched when flag is on.
const ConsentModal    = CONSENT_ENABLED ? lazy(() => import('./components/ConsentModal'))    : null
const CookieSettingsModal = lazy(() => import('./components/CookieSettingsModal'))

const AgentsPage = lazy(() => import('./pages/AgentsPage'))
const AgentDetailPage = lazy(() => import('./pages/AgentDetailPage'))
const CompliancePage = lazy(() => import('./pages/CompliancePage'))
const FrameworkDetailPage = lazy(() => import('./pages/FrameworkDetailPage'))
const AuditTrailPage = lazy(() => import('./pages/AuditTrailPage'))
const CryptographyPage = lazy(() => import('./pages/CryptographyPage'))
const FederatedServicesPage = lazy(() => import('./pages/FederatedServicesPage'))
const CollusionAccessPage = lazy(() => import('./pages/CollusionAccessPage'))
const RbacAnalysisPage = lazy(() => import('./pages/RbacAnalysisPage'))
const RbacExplorerPage = lazy(() => import('./pages/RbacExplorerPage'))
const SettingsPage = lazy(() => import('./pages/SettingsPage'))
const RedeemInvitePage = lazy(() => import('./pages/RedeemInvite'))
const OnboardingWizardPage = lazy(() => import('./pages/OnboardingWizard'))
const SuperCredPage = lazy(() => import('./pages/SuperCredPage'))
const CompliancePolicyPage = lazy(() => import('./pages/CompliancePolicyPage'))
const AgentPosturePage = lazy(() => import('./pages/AgentPosturePage'))
const RiskExposurePage = lazy(() => import('./pages/RiskExposurePage'))

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
  // Superadmin is a VISIBILITY flag only — it decides which nav links the
  // sidebar renders. It is NOT authorization: every route below stays
  // registered and reachable by direct URL regardless of this value.
  superadmin: boolean
  setSuperadmin: (v: boolean) => void
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
  const [failingControls, setFailingControls] = useState(0)
  const [helpOpen, setHelpOpen] = useState(false)
  const [apiKeyReveal, setApiKeyReveal] = useState<ApiKeyRevealData | null>(null)
  const [cookieSettingsOpen, setCookieSettingsOpen] = useState(false)
  const [superadmin, setSuperadmin] = useSuperadmin()
  // null = not yet checked, true = show modal, false = accepted or flag off
  const [consentRequired, setConsentRequired] = useState<boolean | null>(null)

  // Check consent status on first authentication (only when flag is on).
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
        // Fail open — a broken consent check must not lock users out.
        setConsentRequired(false)
      }
    })()
  }, [isAuthenticated]) // eslint-disable-line react-hooks/exhaustive-deps

  // On first authentication, attempt the one-time key reveal.
  // 410 Gone (already revealed) or any error → silently do nothing.
  useEffect(() => {
    if (!isAuthenticated) return
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const b64 = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
        const payload = JSON.parse(atob(b64)) as Record<string, unknown>
        const tenantId = payload['https://signalloom.ai/tenant_id'] as string | undefined
        if (!tenantId) return
        const result = await api.apiKeys.revealInitial(token, tenantId)
        setApiKeyReveal({ key: result.key, prefix_hint: result.prefix_hint })
      } catch {
        // 410 Gone = already revealed. Any other error = silently skip.
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

  return (
    <AppContext.Provider value={{
      failingControls, setFailingControls,
      helpOpen, setHelpOpen,
      apiKeyReveal, setApiKeyReveal,
      cookieSettingsOpen, setCookieSettingsOpen,
      superadmin, setSuperadmin,
    }}>
      {/* Demo-data toggle — corner widget; flips the api client to local fixtures */}
      <DemoToggle />

      {/* Theme picker — corner widget, sits to the left of DemoToggle */}
      <ThemeToggle />

      {/* Consent modal — fullscreen, gates entire dashboard (flag-gated) */}
      {CONSENT_ENABLED && ConsentModal && isAuthenticated && consentRequired === true && (
        <Suspense fallback={null}>
          <ConsentModal onAccept={handleConsentAccept} />
        </Suspense>
      )}

      {/* Cookie settings modal — opened from Account Settings footer link */}
      {cookieSettingsOpen && isAuthenticated && (
        <Suspense fallback={null}>
          <CookieSettingsModal onClose={() => setCookieSettingsOpen(false)} />
        </Suspense>
      )}

      <div style={{ display: 'flex', height: '100vh', overflow: 'hidden' }}>
        {isAuthenticated && <Sidebar />}
        <main style={{ flex: 1, overflow: 'auto', background: 'var(--bg)' }}>
          <div style={{ padding: '28px 32px', maxWidth: 1172, margin: '0 auto', minHeight: '100%' }}>
            <Suspense fallback={<Spinner />}>
              <Routes>
                {/* Public routes — no Auth0 guard */}
                <Route path="/redeem-invite" element={<RedeemInvitePage />} />
                <Route path="/signup" element={<Navigate to="/redeem-invite" replace />} />

                {/* Protected routes */}
                <Route path="/" element={<Navigate to="/agents" replace />} />
                <Route path="/agents" element={<ProtectedRoute><AgentsPage /></ProtectedRoute>} />
                <Route path="/agents/:id" element={<ProtectedRoute><AgentDetailPage /></ProtectedRoute>} />
                <Route path="/compliance" element={<ProtectedRoute><CompliancePage /></ProtectedRoute>} />
                <Route path="/compliance/policies" element={<ProtectedRoute><CompliancePolicyPage /></ProtectedRoute>} />
                <Route path="/compliance/posture" element={<ProtectedRoute><AgentPosturePage /></ProtectedRoute>} />
                <Route path="/compliance/risk" element={<ProtectedRoute><RiskExposurePage /></ProtectedRoute>} />
                <Route path="/compliance/:frameworkId" element={<ProtectedRoute><FrameworkDetailPage /></ProtectedRoute>} />
                <Route path="/audit" element={<ProtectedRoute><AuditTrailPage /></ProtectedRoute>} />
                <Route path="/cryptography" element={<ProtectedRoute><CryptographyPage /></ProtectedRoute>} />
                <Route path="/federated-services" element={<ProtectedRoute><FederatedServicesPage /></ProtectedRoute>} />
                <Route path="/collusion-access" element={<ProtectedRoute><CollusionAccessPage /></ProtectedRoute>} />
                <Route path="/rbac-analysis" element={<ProtectedRoute><RbacAnalysisPage /></ProtectedRoute>} />
                <Route path="/rbac-explorer" element={<ProtectedRoute><RbacExplorerPage /></ProtectedRoute>} />
                <Route path="/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
                <Route path="/onboarding" element={<ProtectedRoute><OnboardingWizardPage /></ProtectedRoute>} />
                <Route path="/supercred" element={<ProtectedRoute><SuperCredPage /></ProtectedRoute>} />
                <Route path="*" element={<Navigate to="/agents" replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>
      </div>
    </AppContext.Provider>
  )
}
