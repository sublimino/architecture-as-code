import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import HelpModal from './HelpModal'
import { AppContext } from '../App'

vi.mock('../auth/oidc', () => {
  const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
  return { useAuth0: () => ({ getAccessTokenSilently }) }
})

function renderModal(setHelpOpen = vi.fn()) {
  const appCtxValue = {
    failingControls: 0,
    setFailingControls: () => undefined,
    helpOpen: true,
    setHelpOpen,
    apiKeyReveal: null,
    setApiKeyReveal: () => undefined,
    cookieSettingsOpen: false,
    setCookieSettingsOpen: () => undefined,
    connectedProviderCount: 0,
    totalProviderCount: 0,
    needsOnboarding: null,
    refreshOnboardingState: () => Promise.resolve(),
    superadmin: false,
    setSuperadmin: () => undefined,
  }
  return render(
    <MemoryRouter initialEntries={['/agents']}>
      <AppContext.Provider value={appCtxValue}>
        <Routes>
          <Route path="/agents" element={<HelpModal />} />
          <Route path="/help/connectors/:provider" element={<div>CONNECTOR HELP PAGE</div>} />
        </Routes>
      </AppContext.Provider>
    </MemoryRouter>
  )
}

describe('HelpModal NHI Discovery FAQ', () => {
  it('links "How do I connect my Entra directory?" to the Entra help route and closes the modal on click', () => {
    const setHelpOpen = vi.fn()
    renderModal(setHelpOpen)

    fireEvent.click(screen.getByText('How do I connect my Entra directory?'))
    const link = screen.getByRole('link', { name: /Entra\/Azure AD connector setup guide/i })
    expect(link).toHaveAttribute('href', '/help/connectors/entra')

    fireEvent.click(link)
    expect(setHelpOpen).toHaveBeenCalledWith(false)
  })
})
