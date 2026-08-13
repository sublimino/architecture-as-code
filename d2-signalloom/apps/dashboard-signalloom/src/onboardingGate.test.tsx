import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { installMemoryStorage } from './test-utils/memoryStorage'
import App, { ONBOARDING_SKIP_STORAGE_KEY, ONBOARDING_SKIP_TTL_MS } from './App'

const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  getAccessTokenSilently: vi.fn<() => Promise<string>>().mockResolvedValue('test-token'),
  loginWithRedirect: vi.fn(),
}))

const connectors = vi.hoisted(() => ({
  listProviders: vi.fn<() => Promise<Array<{ provider_id: string }>>>().mockResolvedValue([]),
  listConnectors: vi.fn<() => Promise<Array<{ status: string }>>>().mockResolvedValue([]),
}))

const onboarding = vi.hoisted(() => ({
  getStatus: vi.fn<() => Promise<{ skipped_at: string | null }>>().mockResolvedValue({ skipped_at: null }),
}))

vi.mock('./auth/oidc', () => ({ useAuth0: () => auth }))
vi.mock('./auth/superadmin', () => ({
  useSuperadmin: () => [false, () => undefined] as const,
}))
vi.mock('./api/connectorsClient', () => ({
  connectorsApi: connectors,
}))
vi.mock('./api/onboardingClient', () => ({
  onboardingApi: onboarding,
}))

vi.mock('./components/Sidebar', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./components/Sidebar')>()),
  default: () => <nav data-testid="sidebar" />,
}))
vi.mock('./components/DemoToggle', () => ({ default: () => null }))
vi.mock('./components/ThemeToggle', () => ({ default: () => null }))
vi.mock('./components/KeyboardShortcutsOverlay', () => ({ default: () => null }))
vi.mock('./components/onboarding/SetupBanner', () => ({
  default: ({ connectedCount, totalCount }: { connectedCount: number; totalCount: number }) => (
    <div data-testid="setup-banner">{connectedCount}/{totalCount}</div>
  ),
}))

vi.mock('./pages/AgentsPage', async () => {
  const { useAppContext } = await import('./App')
  return {
    default: function AgentsPageProbe() {
      const { needsOnboarding } = useAppContext()
      return (
        <div data-testid="agents-page">
          Agents page
          <span data-testid="needs-onboarding">{String(needsOnboarding)}</span>
        </div>
      )
    },
  }
})

vi.mock('./pages/OnboardingWizard', async () => {
  const { useAppContext } = await import('./App')
  return {
    default: function OnboardingWizardProbe() {
      const { needsOnboarding } = useAppContext()
      return (
        <div data-testid="onboarding-page">
          Onboarding wizard
          <span data-testid="needs-onboarding">{String(needsOnboarding)}</span>
        </div>
      )
    },
  }
})

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  // Fresh, empty localStorage per test — see test-utils/memoryStorage.ts for why
  // the jsdom default is not usable here. This suite turns entirely on what the
  // skip key holds, so a store that silently drops writes would make every
  // assertion below meaningless.
  installMemoryStorage()
  auth.isAuthenticated = true
  auth.isLoading = false
  auth.getAccessTokenSilently.mockReset()
  auth.getAccessTokenSilently.mockResolvedValue('test-token')
  auth.loginWithRedirect.mockReset()

  connectors.listProviders.mockReset()
  connectors.listProviders.mockResolvedValue([])
  connectors.listConnectors.mockReset()
  connectors.listConnectors.mockResolvedValue([])

  onboarding.getStatus.mockReset()
  onboarding.getStatus.mockResolvedValue({ skipped_at: null })
})

describe('App onboarding gate computation', () => {
  // jsdom does no layout or clipping, so a "button is visible" assertion would
  // be theatre here. The regression was routing, not CSS: /agents vanished
  // because App computed needsOnboarding=true and ProtectedRoute redirected.
  it('suppresses onboarding from a fresh localStorage skip without a server round trip', async () => {
    localStorage.setItem(
      ONBOARDING_SKIP_STORAGE_KEY,
      JSON.stringify({ skippedAt: Date.now() - 1_000 }),
    )

    renderAt('/agents')

    await waitFor(() => expect(screen.getByTestId('needs-onboarding')).toHaveTextContent('false'))
    expect(screen.getByTestId('agents-page')).toBeInTheDocument()
    expect(auth.getAccessTokenSilently).not.toHaveBeenCalled()
    expect(connectors.listProviders).not.toHaveBeenCalled()
    expect(connectors.listConnectors).not.toHaveBeenCalled()
    expect(onboarding.getStatus).not.toHaveBeenCalled()
  })

  it('drops an expired skip, consults the server, and leaves the key removed', async () => {
    localStorage.setItem(
      ONBOARDING_SKIP_STORAGE_KEY,
      JSON.stringify({ skippedAt: Date.now() - ONBOARDING_SKIP_TTL_MS - 1 }),
    )
    onboarding.getStatus.mockResolvedValue({ skipped_at: '2026-08-13T09:00:00Z' })

    renderAt('/agents')

    await waitFor(() => expect(onboarding.getStatus).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(localStorage.getItem(ONBOARDING_SKIP_STORAGE_KEY)).toBeNull())
    await waitFor(() => expect(screen.getByTestId('needs-onboarding')).toHaveTextContent('false'))
    expect(auth.getAccessTokenSilently).toHaveBeenCalledTimes(1)
  })

  it('turns the gate on when nothing is skipped and the backend reports skipped_at null', async () => {
    onboarding.getStatus.mockResolvedValue({ skipped_at: null })

    renderAt('/agents')

    await waitFor(() => expect(screen.getByTestId('onboarding-page')).toBeInTheDocument())
    expect(screen.getByTestId('needs-onboarding')).toHaveTextContent('true')
    expect(screen.queryByTestId('agents-page')).toBeNull()
  })

  it('leaves the gate off when the backend already persisted skipped_at', async () => {
    onboarding.getStatus.mockResolvedValue({ skipped_at: '2026-08-13T09:00:00Z' })

    renderAt('/agents')

    await waitFor(() => expect(screen.getByTestId('agents-page')).toBeInTheDocument())
    expect(screen.getByTestId('needs-onboarding')).toHaveTextContent('false')
    expect(screen.queryByTestId('onboarding-page')).toBeNull()
  })
})
