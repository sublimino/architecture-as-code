import { createContext, useContext, useState, useEffect, useCallback, lazy, Suspense } from 'react'
import { Routes, Route, Navigate, useLocation, matchPath } from 'react-router-dom'
import { useAuth0 } from './auth/oidc'
import { useSuperadmin } from './auth/superadmin'
import Sidebar, { NAV } from './components/Sidebar'
import PixelLoader from './components/PixelLoader'
import ProtectedRoute from './auth/ProtectedRoute'
import DemoToggle from './components/DemoToggle'
import ThemeToggle from './components/ThemeToggle'
import KeyboardShortcutsOverlay from './components/KeyboardShortcutsOverlay'
import SetupBanner from './components/onboarding/SetupBanner'
import { CurrencyProvider } from './money/CurrencyContext'
import { api } from './api/client'
import { connectorsApi } from './api/connectorsClient'
import { onboardingApi } from './api/onboardingClient'
import type { CookiePreferences } from './types/api'

const CONSENT_ENABLED = import.meta.env.VITE_CONSENT_MODAL_ENABLED === 'true'

/** localStorage key shared with OnboardingWizard — skip TTL (30 min). */
export const ONBOARDING_SKIP_STORAGE_KEY = 'sl_onboarding_skipped'
export const ONBOARDING_SKIP_TTL_MS = 30 * 60 * 1000

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
const DesignSystemPage = lazy(() => import('./pages/DesignSystemPage'))

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

// ─── Waiting ─────────────────────────────────────────────────────────────────
//
// App has two waits, and until now each drew a rotating ring of its own. That
// is what produced the double-loader users saw on every navigation: the ring
// while the route chunk downloaded, then the Signal Loom mark once the page
// mounted and rendered its own LoadingState. Two idioms, back to back, for one
// continuous wait.
//
// Both waits now draw the brand mark, so a navigation shows one loader that is
// simply relabelled as the page takes over.
//
// PixelLoader directly, not LoadingState. LoadingState is a *phase* component:
// idle / loading / success / error, with the stamps and the "last refreshed
// 12s ago" line that go with them. Neither of these two surfaces has phases —
// a chunk that fails to load throws to an error boundary rather than settling
// into an error state, and the auth gate resolves by rendering the app or
// redirecting away. Feeding a four-phase machine a constant `status="loading"`
// to get at the loader inside it would be using the wrapper for a side effect.
// OnboardingWizard is the other way round and uses LoadingState, correctly:
// its initial load really can fail in place, and already rendered LoadingState
// for that.

/**
 * Destinations that are not in the Sidebar's NAV: detail pages, and the flows
 * only ever arrived at by redirect. NAV supplies the rest, so a new nav entry
 * gets a loading label for free and the label the user reads while waiting is
 * the same word they just clicked.
 */
const EXTRA_ROUTE_LABELS: Record<string, string> = {
  '/agents/:id': 'Agent',
  '/discovery/accounts/:accountId': 'Account',
  '/compliance/:frameworkId': 'Framework',
  '/fleet/audience': 'Fleet Demo',
  '/onboarding': 'Setup',
  '/help/connectors/:provider': 'Connector Help',
  '/redeem-invite': 'Invite',
}

/**
 * What to call the page whose chunk is being fetched.
 *
 * The Suspense fallback sits above the Routes and so is not told which route
 * it is covering — but App already holds the pathname (it keys the fade on it),
 * and that is enough to name the destination. Worth doing: "Loading" is the
 * one label PixelLoader's own docs tell callers not to use, and the fallback
 * is on screen for precisely the moment the user is wondering whether their
 * click registered.
 */
export function routeLoadingLabel(pathname: string): string {
  const patterns: [string, string][] = [
    ...NAV.map((item): [string, string] => [item.to, item.label]),
    ...Object.entries(EXTRA_ROUTE_LABELS),
  ]
  // Exact patterns before parameterised ones. `/compliance/:frameworkId`
  // matches `/compliance/policies` perfectly well, so a plain first-match walk
  // in declaration order would label the Policy Compliance page "Framework".
  // Within each group order is irrelevant: matchPath is a whole-path match, so
  // no two distinct exact patterns can both hit the same pathname.
  const ordered = [
    ...patterns.filter(([pattern]) => !pattern.includes(':')),
    ...patterns.filter(([pattern]) => pattern.includes(':')),
  ]
  for (const [pattern, label] of ordered) {
    if (matchPath(pattern, pathname)) return `Loading ${label}`
  }
  return 'Loading'
}

/**
 * The brand mark, centred, for a surface that is doing nothing else yet.
 *
 * One live region, and it is PixelLoader's own (`announce` defaults true) —
 * this wrapper adds none. Announcing on navigation is the deliberate choice
 * rather than an accident of the default: a client-side route change is
 * otherwise completely silent to a screen reader, so "Loading Compliance" is
 * the only confirmation that the click did anything. It is polite, so it
 * queues rather than interrupts, and it only ever fires when the chunk is not
 * already cached — which is exactly when there is something worth saying.
 *
 * `minHeight` rather than a height: the box must never be taller than the
 * space it sits in, or the scrollbar appears while loading and vanishes when
 * the page swaps in, and the whole column shifts sideways twice. The ring this
 * replaces asked for `height: 100vh` inside a container already carrying 28px
 * of padding, and did exactly that.
 */
function AppLoader({ label, minHeight, testId }: { label: string; minHeight: string; testId: string }) {
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        minHeight,
        background: 'var(--bg)',
      }}
    >
      <PixelLoader label={label} testId={testId} />
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

  // "Signing in", not "Loading": this wait is the OIDC library resolving an
  // existing session or completing a redirect callback, and that is a thing
  // worth naming.
  if (isLoading) return <AppLoader label="Signing in" minHeight="100vh" testId="auth-loading" />

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
      {/* Wraps the whole tree, not just the risk pages. Every surface that
          shows money must resolve the same user preference — a figure in one
          currency beside a figure in another, both unlabelled, is worse than
          either alone. */}
      <CurrencyProvider>
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
            {/* 60vh, not the full height: the container this sits in is at
                most one viewport tall and already spends 56px of it on
                padding, so a taller box would toggle a scrollbar for the
                duration of the chunk fetch. */}
            <Suspense fallback={<AppLoader label={routeLoadingLabel(location.pathname)} minHeight="60vh" testId="route-loading" />}>
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
                {/* Superadmin is a VISIBILITY control (see auth/superadmin.ts):
                    the Sidebar decides whether to render the link, the route
                    stays registered and reachable by URL like every other one. */}
                <Route path="/design-system" element={<ProtectedRoute><DesignSystemPage /></ProtectedRoute>} />
                <Route path="*" element={<Navigate to="/agents" replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>
      </div>
      </CurrencyProvider>
    </AppContext.Provider>
  )
}
