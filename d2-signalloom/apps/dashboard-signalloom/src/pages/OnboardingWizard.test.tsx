import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import OnboardingWizard from './OnboardingWizard'

// The wizard used to keep a private copy of App's rotating ring for its own
// initial load — a second bespoke spinner in a product that has one brand
// loader. Its error branch already rendered LoadingState; the loading branch
// now does too, so both phases of the same wait are drawn the same way.

// `getAccessTokenSilently` has to keep ONE identity across renders. The
// wizard's `load` is a useCallback keyed on it and an effect is keyed on
// `load`, so handing back a fresh function each render re-runs the fetch on
// every render — which on the failure path is an endless loading→error→render
// loop that never settles, and reads in the test output as "the error state
// never arrived". The behaviour under test is fine; only the double is wrong.
const auth = vi.hoisted(() => {
  const state = { token: (): Promise<string> => new Promise<string>(() => {}) }
  return { state, getAccessTokenSilently: () => state.token() }
})

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: true,
    isLoading: false,
    getAccessTokenSilently: auth.getAccessTokenSilently,
  }),
}))

function ringMarkup(): string[] {
  return ['rotate(360deg)', 'onboarding-spin', '@keyframes spin'].filter((m) =>
    document.body.innerHTML.includes(m),
  )
}

function liveRegions(): Element[] {
  return Array.from(document.querySelectorAll('[aria-live], [role="status"], [role="alert"]'))
}

function renderWizard() {
  return render(
    <MemoryRouter initialEntries={['/onboarding']}>
      <OnboardingWizard />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  // Default: the token never arrives, so the wizard stays in `loading`.
  auth.state.token = () => new Promise<string>(() => {})
})

describe('OnboardingWizard loading state', () => {
  it('draws the Signal Loom mark, not a rotating ring', () => {
    renderWizard()

    const loader = screen.getByTestId('onboarding-load-state-loader')
    expect(loader.querySelector('[data-loom-weave]')).not.toBeNull()
    expect(ringMarkup()).toEqual([])
  })

  it('says what is loading', () => {
    renderWizard()
    expect(screen.getByTestId('onboarding-load-state-message')).toHaveTextContent('Loading setup')
  })

  it('owns exactly one live region', () => {
    renderWizard()
    expect(liveRegions()).toHaveLength(1)
  })
})

describe('OnboardingWizard load failure', () => {
  it('reports the reason in place of the loader', async () => {
    auth.state.token = () => Promise.reject(new Error('token endpoint unreachable'))
    renderWizard()

    await waitFor(() =>
      expect(screen.getByTestId('onboarding-load-state')).toHaveAttribute('data-status', 'error'),
    )
    expect(screen.getByText('token endpoint unreachable')).toBeInTheDocument()
    expect(screen.queryByTestId('onboarding-load-state-loader')).toBeNull()
    expect(ringMarkup()).toEqual([])
  })
})
