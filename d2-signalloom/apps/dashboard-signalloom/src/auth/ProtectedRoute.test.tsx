import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import ProtectedRoute from './ProtectedRoute'
import { AppContext } from '../App'

vi.mock('./oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: true,
    isLoading: false,
    loginWithRedirect: vi.fn(),
  }),
}))

function renderWithGate(needsOnboarding: boolean | null, initialPath: string, exempt?: boolean) {
  const appCtxValue = {
    failingControls: 0,
    setFailingControls: () => undefined,
    helpOpen: false,
    setHelpOpen: () => undefined,
    apiKeyReveal: null,
    setApiKeyReveal: () => undefined,
    cookieSettingsOpen: false,
    setCookieSettingsOpen: () => undefined,
    connectedProviderCount: 0,
    totalProviderCount: 5,
    needsOnboarding,
    refreshOnboardingState: () => Promise.resolve(),
    superadmin: false,
    setSuperadmin: () => undefined,
  }

  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <AppContext.Provider value={appCtxValue}>
        <Routes>
          <Route
            path="/agents"
            element={
              <ProtectedRoute exemptFromOnboardingGate={exempt}>
                <div>Agents page</div>
              </ProtectedRoute>
            }
          />
          <Route path="/onboarding" element={<div>Wizard page</div>} />
        </Routes>
      </AppContext.Provider>
    </MemoryRouter>,
  )
}

describe('ProtectedRoute onboarding gate', () => {
  it('redirects to /onboarding when needsOnboarding is true', () => {
    renderWithGate(true, '/agents')
    expect(screen.getByText('Wizard page')).toBeInTheDocument()
    expect(screen.queryByText('Agents page')).not.toBeInTheDocument()
  })

  it('renders the route when needsOnboarding is false', () => {
    renderWithGate(false, '/agents')
    expect(screen.getByText('Agents page')).toBeInTheDocument()
  })

  it('does not redirect while needsOnboarding is still null (not yet checked)', () => {
    renderWithGate(null, '/agents')
    expect(screen.getByText('Agents page')).toBeInTheDocument()
  })

  it('does not redirect an exempt route even when needsOnboarding is true', () => {
    renderWithGate(true, '/agents', true)
    expect(screen.getByText('Agents page')).toBeInTheDocument()
  })
})
