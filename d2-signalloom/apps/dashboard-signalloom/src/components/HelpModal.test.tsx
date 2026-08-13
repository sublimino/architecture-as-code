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

/**
 * Em-dash budget for the rendered modal.
 *
 * The help copy was rewritten to drop a 16-dash pile-up that read as generated
 * text. Nothing in this modal needs a dash that a full stop, colon, comma or
 * parenthesis cannot carry, so the budget is zero. Raise this ONLY for a dash
 * doing work no other mark can do, and say which one in the commit.
 */
const MAX_EM_DASHES = 0
const EM_DASH = '—'

function countEmDashes(text: string): number {
  return text.split(EM_DASH).length - 1
}

const FAQ_SECTION_TITLES = [
  'Getting started',
  'Managing agents',
  'Compliance & frameworks',
  'NHI Discovery',
  'Billing & plans',
  'Security & access',
]

const FAQ_QUESTIONS = [
  'What is Signal Loom?',
  'How do I register a new agent?',
  'What do the lifecycle states mean?',
  "How do I change an agent's lifecycle state?",
  'What is a violation?',
  'How do I acknowledge a violation?',
  'Which compliance frameworks are supported?',
  'What is a posture score?',
  'How does reassessment work?',
  'What is an NHI account?',
  'What does "Enroll" do?',
  'What does "Dismiss" do?',
  'How do I connect my Entra directory?',
  'What plans are available?',
  'How is billing calculated?',
  'How do I upgrade my plan?',
  'How is my data isolated from other tenants?',
  'Where are my auth tokens stored?',
  'How do I rotate my API key?',
]

describe('HelpModal content', () => {
  it('renders every FAQ section heading', () => {
    renderModal()
    for (const title of FAQ_SECTION_TITLES) {
      expect(screen.getByText(title)).toBeInTheDocument()
    }
  })

  it('renders every FAQ question', () => {
    renderModal()
    for (const question of FAQ_QUESTIONS) {
      expect(screen.getByText(question)).toBeInTheDocument()
    }
  })

  it('renders the Contact Support form with its urgency options', () => {
    renderModal()
    fireEvent.click(screen.getByRole('button', { name: 'Contact Support' }))

    expect(screen.getByText('Subject')).toBeInTheDocument()
    expect(screen.getByText('Urgency')).toBeInTheDocument()
    expect(screen.getByText('Message')).toBeInTheDocument()

    const options = screen.getAllByRole('option').map(o => o.textContent)
    expect(options).toHaveLength(4)
    for (const label of ['Low', 'Normal', 'High', 'Critical']) {
      expect(options.some(o => o?.startsWith(label))).toBe(true)
    }
  })
})

describe('HelpModal em-dash budget', () => {
  it(`keeps rendered em dashes at or below ${MAX_EM_DASHES} in every state`, () => {
    const { container } = renderModal()

    // Sample the collapsed FAQ, then every answer in turn. Each section tracks
    // its own open index, so expanding one item never hides another section's.
    const counts: { state: string; count: number }[] = [
      { state: 'FAQ tab, all collapsed', count: countEmDashes(container.textContent ?? '') },
    ]

    for (const question of FAQ_QUESTIONS) {
      fireEvent.click(screen.getByText(question))
      counts.push({ state: question, count: countEmDashes(container.textContent ?? '') })
    }

    fireEvent.click(screen.getByRole('button', { name: 'Contact Support' }))
    counts.push({ state: 'Contact Support tab', count: countEmDashes(container.textContent ?? '') })

    // Guard against a vacuous pass if the copy is ever deleted wholesale.
    expect(counts).toHaveLength(FAQ_QUESTIONS.length + 2)

    const offenders = counts.filter(c => c.count > MAX_EM_DASHES)
    expect(
      offenders,
      `em dashes over budget (max ${MAX_EM_DASHES}): ${offenders.map(o => `${o.state} = ${o.count}`).join('; ')}`
    ).toEqual([])
  })
})

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
