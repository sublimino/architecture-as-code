import { createContext, useContext, useState, useEffect, useCallback, lazy, Suspense } from 'react'
import { Routes, Route, Navigate, useLocation, matchPath } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useAuth0 } from './auth/oidc'
import { useSuperadmin, isSuperadminEligible, useServerSuperadmin } from './auth/superadmin'
import Sidebar, { NAV } from './components/Sidebar'
import PixelLoader from './components/PixelLoader'
import ProtectedRoute from './auth/ProtectedRoute'
import FloatingConfigControls from './components/FloatingConfigControls'
import KeyboardShortcutsOverlay from './components/KeyboardShortcutsOverlay'
import SetupBanner from './components/onboarding/SetupBanner'
import { CurrencyProvider } from './money/CurrencyContext'
import { api } from './api/client'
import { connectorsApi } from './api/connectorsClient'
import { onboardingApi } from './api/onboardingClient'
import FeatureGate from './components/common/FeatureGate'
import { PageLoader as AppLoader } from './components/common/PagePattern'
import NotFoundPage from './pages/NotFoundPage'
import type { CookiePreferences } from './types/api'

const appQueryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      retry: 1,
    },
  },
})

// The server decides, with the client-side name match as the pre-flight answer
// for the first render only (useServerSuperadmin). A non-eligible user is still
// redirected immediately, as before; an eligible one is redirected as soon as
// /api/v1/me says the allow-lists do not name them. Before this the browser's
// name match was the only answer, so the dashboard and the API could disagree
// the moment API_SUPERADMIN_EMAILS named anyone other than the demo user.
export function SuperadminRoute({ children }: { children: React.ReactNode }) {
  const { user, getAccessTokenSilently } = useAuth0()
  const { superadmin } = useServerSuperadmin(user, getAccessTokenSilently)
  if (!superadmin) {
    return <Navigate to="/agents" replace />
  }
  return <>{children}</>
}

export function AdminRoute({ children }: { children: React.ReactNode }) {
  const { user, getAccessTokenSilently } = useAuth0()
  const { superadmin } = useServerSuperadmin(user, getAccessTokenSilently)
  if (!superadmin) {
    return <Navigate to="/agents" replace />
  }
  return <>{children}</>
}

const CONSENT_ENABLED = import.meta.env.VITE_CONSENT_MODAL_ENABLED === 'true'

/** localStorage key shared with OnboardingWizard: skip TTL (30 min). */
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
const UsersPage = lazy(() => import('./pages/UsersPage'))
const SettingsPage = lazy(() => import('./pages/SettingsPage'))
const RedeemInvitePage = lazy(() => import('./pages/RedeemInvite'))
const OnboardingWizardPage = lazy(() => import('./pages/OnboardingWizard'))
const ConnectorHelpPage = lazy(() => import('./pages/ConnectorHelpPage'))
const DeploySensorHelpPage = lazy(() => import('./pages/DeploySensorHelpPage'))
const OnboardAgentHelpPage = lazy(() => import('./pages/OnboardAgentHelpPage'))
const SuperCredPage = lazy(() => import('./pages/SuperCredPage'))
const CompliancePolicyPage = lazy(() => import('./pages/CompliancePolicyPage'))
const AgentPosturePage = lazy(() => import('./pages/AgentPosturePage'))
const RiskExposurePage = lazy(() => import('./pages/RiskExposurePage'))
const NetworkTestsPage = lazy(() => import('./pages/NetworkTestsPage'))
const AgentTrustTopologyPage = lazy(() => import('./pages/AgentTrustTopologyPage'))
const WeavePage = lazy(() => import('./pages/WeavePage'))
const SignalsPage = lazy(() => import('./pages/SignalsPage'))
const SignalFusionPage = lazy(() => import('./pages/SignalFusionPage'))
const DistanceLatencyPage = lazy(() => import('./pages/DistanceLatencyPage'))
const FleetDemoPage = lazy(() => import('./pages/FleetDemoPage'))
const FleetAudiencePage = lazy(() => import('./pages/FleetAudiencePage'))
const AgentMaxxingDemoPage = lazy(() => import('./pages/AgentMaxxingDemoPage'))
const SignalStorePage = lazy(() => import('./pages/SignalStorePage'))
const FeedsExplorerPage = lazy(() => import('./pages/FeedsExplorerPage'))
const DesignSystemPage = lazy(() => import('./pages/DesignSystemPage'))
const DesignSystemHeadersPage = lazy(() => import('./pages/DesignSystemHeadersPage'))
const DesignSystemCssLabPage = lazy(() => import('./pages/DesignSystemCssLabPage'))
const LoginPage = lazy(() => import('./pages/LoginPage'))
const CallbackPage = lazy(() => import('./pages/CallbackPage'))
const AdminUsersPage = lazy(() => import('./pages/admin/UsersPage'))
const AdminFeaturesPage = lazy(() => import('./pages/admin/FeaturesPage'))
const PolicyEvaluationPage = lazy(() => import('./pages/PolicyEvaluationPage'))

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
// 12s ago" line that go with them. Neither of these two surfaces has phases:
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
  '/overview': 'Overview',
  '/agents/:id': 'Agent',
  '/discovery': 'Discovery',
  '/discovery/accounts/:accountId': 'Account',
  '/topology': 'Topology',
  '/activity': 'The Weave',
  '/risk': 'FAIR Risk',
  '/policies': 'Policies',
  '/containment': 'Containment',
  '/approvals': 'Approvals',
  '/workspaces': 'Workspaces',
  '/connectors': 'Connectors',
  '/compliance': 'Compliance',
  '/compliance/policies': 'Policy Compliance',
  '/compliance/posture': 'Agent Posture',
  '/compliance/risk': 'Risk Exposure',
  '/compliance/:frameworkId': 'Framework',
  '/agent-trust-topology': 'Agent Trust Topology',
  '/weave': 'The Weave',
  '/federated-services': 'Federated Services',
  '/collusion-access': 'Collusion & Access',
  '/fleet/audience': 'Fleet Demo Audience',
  '/demos/fleet/audience': 'Fleet Demo Audience',
  '/onboarding': 'Setup',
  '/help/connectors/:provider': 'Connector Help',
  '/settings/help/deploy-sensor': 'Deploy Sensor Help',
  '/settings/help/onboard-agent': 'Onboard Agent Help',
  '/settings/deploy-sensor': 'Deploy Sensor Help',
  '/settings/onboard-agent': 'Onboard Agent Help',
  '/redeem-invite': 'Invite',
  '/login': 'Login',
  '/callback': 'Sign In',
  '/admin/users': 'User Administration',
  '/admin/features': 'Feature Flags',
  '/design-system/css': 'CSS Lab',
  '/evaluations': 'Policy Evaluation',
  '/compliance/evaluation': 'Policy Evaluation',
  '/supercred': 'SuperCred Demo',
  '/fleet': 'Fleet Demo',
  '/demos/fleet': 'Fleet Demo',
  '/demos/agentmaxxing': 'AgentMaxxing Console',
  '/demos/agentmaxxing/*': 'AgentMaxxing Console',
  '/network-tests': 'Network Tests',
  '/signal-fusion': 'Signal Fusion',
  '/distance-latency': 'Distance & Latency',
  '/signal-store': 'Signal Store',
  '/feeds': 'Feeds Explorer',
  '/design-system': 'Design System',
  '/design-system/headers': 'Design System Headers',
  '/settings': 'Settings',
  '/users': 'Users',
}

/**
 * What to call the page whose chunk is being fetched.
 *
 * The Suspense fallback sits above the Routes and so is not told which route
 * it is covering, but App already holds the pathname (it keys the fade on it),
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
 * Route-level wrapper for feature-flag gated pages.
 * While feature flags are resolving, renders AppLoader with the route-specific
 * label and PixelLoader (honoring the operator's loadTimes settings) so that
 * the user never experiences a flash of 404. If the flag evaluates to false,
 * renders NotFoundPage as terminal fallback.
 */
export function GatedRoute({ flag, children }: { flag: string; children: React.ReactNode }) {
  const location = useLocation()
  return (
    <FeatureGate
      flag={flag}
      fallback={<NotFoundPage />}
      loadingFallback={
        <AppLoader
          label={routeLoadingLabel(location.pathname)}
          minHeight="60vh"
          testId="route-loading"
        />
      }
    >
      {children}
    </FeatureGate>
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

    // Client-side TTL: if the user recently skipped, suppress the gate
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
        // Expired: clean up
        localStorage.removeItem(ONBOARDING_SKIP_STORAGE_KEY)
      }
    } catch {
      // Corrupt or unavailable localStorage: fall through to server check.
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
      const isCompleted = onboardingStatus.status === 'completed' || Boolean(onboardingStatus.completed_at)
      const isSkipped = onboardingStatus.status === 'skipped' || Boolean(onboardingStatus.skipped_at)
      setNeedsOnboarding(connectedCount === 0 && !isCompleted && !isSkipped)
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
    location.pathname === '/onboarding' ||
    location.pathname.startsWith('/help/connectors') ||
    location.pathname.startsWith('/settings/help') ||
    location.pathname === '/settings/deploy-sensor' ||
    location.pathname === '/settings/onboard-agent'

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
      <QueryClientProvider client={appQueryClient}>
      {/* Wraps the whole tree, not just the risk pages. Every surface that
          shows money must resolve the same user preference: a figure in one
          currency beside a figure in another, both unlabelled, is worse than
          either alone. */}
      <CurrencyProvider>
      <FloatingConfigControls />

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
        {/* `position: relative` is load-bearing, and the reason is not obvious.
            `overflow: auto` makes this the app's scroll container, but it does
            NOT make it the containing block. An absolutely-positioned
            descendant with no positioned ancestor resolves against the initial
            containing block instead (which is OUTSIDE this clip), so the clip
            does not apply to it and its box extends the DOCUMENT's scroll area.
            The shell above is `height: 100vh; overflow: hidden`, so that
            document scroll shows up as a SECOND scrollbar which drags the whole
            UI (sidebar, page and sticky rail alike) off the top of the screen.

            Nothing has to be positioned on purpose for this to bite. The two
            elements that triggered it are visually-hidden live regions,
            ProofConsole's `.sr-only` span and ButtonWait's inline twin, and the
            standard `position: absolute; width: 1px` recipe is the whole cause.
            They are on other pages too and were harmless there only because
            those pages are short enough that the span's static position still
            lands inside the viewport; /design-system is 12620px tall and put
            one at y=9573, which was the document height to the pixel. So this
            was a latent shell defect that a long page revealed rather than
            something that page introduced, and pinning the containing block
            here closes it for every abspos descendant rather than for the two
            that happened to surface it.

            `position: fixed` descendants are unaffected (only transform/filter/
            contain capture those), so the toggles still anchor to the viewport;
            they carry `zIndex: 4000` and stay above this now-positioned box.

            smoke.spec.ts "has exactly one scroll context" is the guard, and it
            samples over a window rather than reading once: the live regions
            mount a beat after the page, so a single measurement taken when the
            <h1> appears reports the broken page as clean. */}
        <main style={{ flex: 1, overflow: 'auto', background: 'var(--bg)', position: 'relative' }}>
          {isAuthenticated && needsOnboarding === true && !onboardingGateExempt && (
            <SetupBanner
              connectedCount={connectedProviderCount}
              totalCount={totalProviderCount}
            />
          )}
          <div key={location.pathname} className="fade-in" style={{ padding: '28px 32px', maxWidth: 'var(--content-max-width, 1600px)', width: '100%', margin: '0 auto', minHeight: '100%' }}>
            {/* 60vh, not the full height: the container this sits in is at
                most one viewport tall and already spends 56px of it on
                padding, so a taller box would toggle a scrollbar for the
                duration of the chunk fetch. */}
            <Suspense fallback={<AppLoader label={routeLoadingLabel(location.pathname)} minHeight="60vh" testId="route-loading" />}>
              <Routes>
                <Route path="/login" element={<LoginPage />} />
                <Route path="/callback" element={<CallbackPage />} />
                <Route path="/redeem-invite" element={<ProtectedRoute><RedeemInvitePage /></ProtectedRoute>} />
                <Route path="/signup" element={<Navigate to="/redeem-invite" replace />} />

                <Route path="/" element={<Navigate to="/agents" replace />} />
                <Route path="/overview" element={<Navigate to="/discovery" replace />} />
                <Route path="/discovery" element={<ProtectedRoute><GatedRoute flag="page_discovery"><DiscoveryPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/discovery/accounts/:accountId" element={<ProtectedRoute><GatedRoute flag="page_discovery"><DiscoveryAccountDetailPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/agents" element={<ProtectedRoute><GatedRoute flag="page_agents"><AgentsPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/agents/:id" element={<ProtectedRoute><GatedRoute flag="page_agents"><AgentDetailPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/topology" element={<ProtectedRoute><GatedRoute flag="page_topology"><AgentTrustTopologyPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/agent-trust-topology" element={<ProtectedRoute><GatedRoute flag="page_topology"><AgentTrustTopologyPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/activity" element={<Navigate to="/weave" replace />} />
                <Route path="/weave" element={<ProtectedRoute><GatedRoute flag="page_weave"><WeavePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/signals" element={<ProtectedRoute><GatedRoute flag="page_signals"><SignalsPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/risk" element={<ProtectedRoute><GatedRoute flag="page_risk"><RiskExposurePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/compliance/risk" element={<ProtectedRoute><GatedRoute flag="page_risk"><RiskExposurePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/policies" element={<ProtectedRoute><GatedRoute flag="page_policies"><CompliancePolicyPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/compliance/policies" element={<ProtectedRoute><GatedRoute flag="page_policies"><CompliancePolicyPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/containment" element={<Navigate to="/compliance" replace />} />
                <Route path="/compliance" element={<ProtectedRoute><GatedRoute flag="page_compliance"><CompliancePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/compliance/posture" element={<ProtectedRoute><GatedRoute flag="page_compliance"><AgentPosturePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/compliance/:frameworkId" element={<ProtectedRoute><GatedRoute flag="page_compliance"><FrameworkDetailPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/evaluations" element={<ProtectedRoute><GatedRoute flag="page_compliance"><PolicyEvaluationPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/compliance/evaluation" element={<ProtectedRoute><GatedRoute flag="page_compliance"><PolicyEvaluationPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/eval" element={<Navigate to="/evaluations" replace />} />
                <Route path="/approvals" element={<Navigate to="/collusion-access" replace />} />
                <Route path="/collusion-access" element={<ProtectedRoute><GatedRoute flag="collusion_access"><CollusionAccessPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/users" element={<ProtectedRoute><UsersPage /></ProtectedRoute>} />
                <Route path="/audit" element={<ProtectedRoute><GatedRoute flag="page_audit"><AuditTrailPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/workspaces" element={<Navigate to="/discovery" replace />} />
                <Route path="/connectors" element={<Navigate to="/federated-services" replace />} />
                <Route path="/federated-services" element={<ProtectedRoute><GatedRoute flag="page_federated_services"><FederatedServicesPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/cryptography" element={<ProtectedRoute><GatedRoute flag="page_cryptography"><CryptographyPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/credential-inventory" element={<ProtectedRoute><GatedRoute flag="page_credential_inventory"><CredentialInventoryPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/rbac-analysis" element={<ProtectedRoute><GatedRoute flag="rbac_analysis"><RbacAnalysisPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/rbac-explorer" element={<ProtectedRoute><GatedRoute flag="rbac_analysis"><RbacExplorerPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/signal-fusion" element={<ProtectedRoute><SuperadminRoute><SignalFusionPage /></SuperadminRoute></ProtectedRoute>} />
                <Route path="/distance-latency" element={<ProtectedRoute><SuperadminRoute><DistanceLatencyPage /></SuperadminRoute></ProtectedRoute>} />
                <Route path="/signal-store" element={<ProtectedRoute><GatedRoute flag="page_signal_store"><SignalStorePage /></GatedRoute></ProtectedRoute>} />
                <Route path="/feeds" element={<ProtectedRoute><GatedRoute flag="page_feeds"><FeedsExplorerPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/settings" element={<ProtectedRoute><SettingsPage /></ProtectedRoute>} />
                <Route path="/settings/help/deploy-sensor" element={<ProtectedRoute exemptFromOnboardingGate><DeploySensorHelpPage /></ProtectedRoute>} />
                <Route path="/settings/help/onboard-agent" element={<ProtectedRoute exemptFromOnboardingGate><OnboardAgentHelpPage /></ProtectedRoute>} />
                <Route path="/settings/deploy-sensor" element={<Navigate to="/settings/help/deploy-sensor" replace />} />
                <Route path="/settings/onboard-agent" element={<Navigate to="/settings/help/onboard-agent" replace />} />
                <Route path="/onboarding" element={<ProtectedRoute exemptFromOnboardingGate><OnboardingWizardPage /></ProtectedRoute>} />
                <Route path="/help/connectors/:provider" element={<ProtectedRoute exemptFromOnboardingGate><ConnectorHelpPage /></ProtectedRoute>} />
                <Route path="/network-tests" element={<ProtectedRoute><GatedRoute flag="page_network_tests"><NetworkTestsPage /></GatedRoute></ProtectedRoute>} />
                <Route path="/supercred" element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="supercred"><SuperCredPage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path="/fleet" element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="demos_fleet"><FleetDemoPage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path="/demos/fleet" element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="demos_fleet"><FleetDemoPage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path="/fleet/audience" element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="demos_fleet"><FleetAudiencePage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path="/demos/fleet/audience" element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="demos_fleet"><FleetAudiencePage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path={'/demos/agentmaxxing'} element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="page_agentmaxxing"><AgentMaxxingDemoPage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />
                <Route path={'/demos/agentmaxxing/*'} element={<ProtectedRoute><SuperadminRoute><GatedRoute flag="page_agentmaxxing"><AgentMaxxingDemoPage /></GatedRoute></SuperadminRoute></ProtectedRoute>} />

                <Route path="/design-system" element={<ProtectedRoute><SuperadminRoute><DesignSystemPage /></SuperadminRoute></ProtectedRoute>} />
                <Route path="/design-system/headers" element={<ProtectedRoute><SuperadminRoute><DesignSystemHeadersPage /></SuperadminRoute></ProtectedRoute>} />
                <Route path="/design-system/css" element={<ProtectedRoute><SuperadminRoute><DesignSystemCssLabPage /></SuperadminRoute></ProtectedRoute>} />
                <Route path="/design-system/css-lab" element={<Navigate to="/design-system/css" replace />} />
                <Route path="/admin/users" element={<ProtectedRoute><AdminRoute><AdminUsersPage /></AdminRoute></ProtectedRoute>} />
                <Route path="/admin/features" element={<ProtectedRoute><AdminRoute><AdminFeaturesPage /></AdminRoute></ProtectedRoute>} />
                <Route path="*" element={<Navigate to="/agents" replace />} />
              </Routes>
            </Suspense>
          </div>
        </main>
      </div>
      </CurrencyProvider>
      </QueryClientProvider>
    </AppContext.Provider>
  )
}
