import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import OnboardAgentHelpPage from './OnboardAgentHelpPage'

describe('OnboardAgentHelpPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    Object.defineProperty(navigator, 'clipboard', {
      value: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
      configurable: true,
      writable: true,
    })
  })

  function renderPage() {
    return render(
      <MemoryRouter initialEntries={['/settings/help/onboard-agent']}>
        <OnboardAgentHelpPage />
      </MemoryRouter>
    )
  }

  it('renders heading and the 3 onboarding steps', () => {
    renderPage()

    expect(screen.getByRole('heading', { name: /Help to Onboard an Agent/i })).toBeInTheDocument()
    expect(screen.getByTestId('step-1-section')).toBeInTheDocument()
    expect(screen.getByText(/Workload Manifest Labels & Annotations/i)).toBeInTheDocument()
    expect(screen.getByTestId('step-2-section')).toBeInTheDocument()
    expect(screen.getByText(/SPIFFE ID Registration & OpenBao Access Policy/i)).toBeInTheDocument()
    expect(screen.getByTestId('step-3-section')).toBeInTheDocument()
    expect(screen.getByText(/Minting Enrollment Tokens & Claiming Discovered Agents/i)).toBeInTheDocument()
    expect(screen.getByTestId('doc-links-section')).toBeInTheDocument()
  })

  it('renders required label keys and descriptions in Step 1', () => {
    renderPage()

    expect(screen.getByText('signalloom.ai/agent')).toBeInTheDocument()
    expect(screen.getByText('signalloom.ai/framework')).toBeInTheDocument()
    expect(screen.getByText('signalloom.ai/model')).toBeInTheDocument()
    expect(screen.getByText('signalloom.ai/tenant')).toBeInTheDocument()
    expect(screen.getByText('signalloom.io/workload-profile')).toBeInTheDocument()
    expect(screen.getByTestId('step1-yaml-snippet')).toBeInTheDocument()
  })

  it('renders SPIFFE and OpenBao snippets in Step 2', () => {
    renderPage()

    expect(screen.getByTestId('step2-spire-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('step2-openbao-policy-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('step2-openbao-role-snippet')).toBeInTheDocument()
  })

  it('renders claiming and enrollment token curl examples in Step 3', () => {
    renderPage()

    expect(screen.getByTestId('step3-claim-id-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('step3-claim-pod-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('step3-mint-token-snippet')).toBeInTheDocument()
  })

  it('handles snippet copy interaction with feedback', async () => {
    renderPage()

    const spireSnippet = screen.getByTestId('step2-spire-snippet')
    const copyBtn = spireSnippet.querySelector('button')!
    expect(copyBtn).toHaveTextContent('Copy')

    fireEvent.click(copyBtn)

    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
        expect.stringContaining('spire-server entry create')
      )
      expect(copyBtn).toHaveTextContent('✓ Copied')
    })
  })

  it('renders links to external documentation portal routes', () => {
    renderPage()

    const firstAgentLink = screen.getByTestId('doc-link-first-agent')
    expect(firstAgentLink).toHaveAttribute('href', '/docs/start/first-agent/')

    const dualAgentLink = screen.getByTestId('doc-link-dual-agent')
    expect(dualAgentLink).toHaveAttribute('href', '/docs/agents/dual-agent-onboarding/')

    const quickStartLink = screen.getByTestId('doc-link-quick-start')
    expect(quickStartLink).toHaveAttribute('href', '/docs/start/quick-start/')
  })

  it('provides navigation back to settings', () => {
    renderPage()

    const backLink = screen.getByTestId('back-to-settings-link')
    expect(backLink).toHaveAttribute('href', '/settings')
  })
})
