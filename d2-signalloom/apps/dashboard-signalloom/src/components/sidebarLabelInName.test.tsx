import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Sidebar, { SIDEBAR_COLLAPSED_STORAGE_KEY } from './Sidebar'
import { AppContext } from '../App'
import { api } from '../api/client'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import type { TenantSettingsResponse } from '../types/api'

// WCAG 2.5.3 "Label in Name" guard for the sidebar's controls.
//
// The bug this exists to catch: the Help & Support button carried
// `aria-label="Open help and support"` while rendering the visible text
// "Help & Support". An explicit aria-label REPLACES the element's content as
// its accessible name, so the name a speech-input user must utter ("open help
// and support") was not the label they can see ("Help & Support") — and no
// substring of it, because "and" is not "&". A user saying "click Help and
// Support" got nothing, and a screen reader announced words that are on no
// part of the screen.
//
// It cost a CI lane 30 seconds to find, because the only thing asserting it
// was a Playwright `getByRole('button', { name: /help & support/i })` that sat
// there timing out against a live cluster. This suite asserts the same
// invariant against every labelled control in the rail in about a second, and
// it fails the whole class rather than the one control that happened to have a
// browser test pointed at it.
//
// The invariant: if a control has an explicit aria-label AND renders visible
// text, the aria-label must contain that text (case-insensitively). Icon-only
// controls are exempt — they have no visible label to contain, which is the
// entire reason they need an aria-label in the first place.

const DEFAULT_USER = { name: 'Test User', email: 'test@acme.com' }
const authMock = vi.hoisted(() => ({
  user: { name: 'Test User', email: 'test@acme.com' } as Record<string, unknown>,
}))

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    user: authMock.user,
    logout: vi.fn(),
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  }),
}))

vi.mock('../api/client', () => ({
  api: {
    settings: vi.fn(),
    nhi: {
      discovered: vi.fn().mockResolvedValue({
        accounts: [],
        total: 0,
        summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 },
      }),
    },
  },
}))

function makeSettings(): TenantSettingsResponse {
  return {
    tenant_id: 'tenant-1',
    org_name: 'Acme Insurance',
    plan_tier: 'growth',
    agent_count: 12,
    billing_tier: null,
    api_key_status: 'active',
    selected_frameworks: [],
    consent_required: false,
    cookie_preferences: null,
    preferred_scan_cadence_hours: 24,
    alert_email: null,
    alert_threshold: 1,
  }
}

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
  totalProviderCount: 0,
  needsOnboarding: null,
  refreshOnboardingState: () => Promise.resolve(),
  superadmin: false,
  setSuperadmin: () => undefined,
}

function renderSidebar(ctx: Partial<typeof appCtxValue> = {}) {
  return render(
    <MemoryRouter>
      <AppContext.Provider value={{ ...appCtxValue, ...ctx }}>
        <Sidebar />
      </AppContext.Provider>
    </MemoryRouter>
  )
}

/**
 * The text a sighted user can actually read on this control.
 *
 * Subtrees marked `aria-hidden="true"` are excluded, which mirrors the real
 * accessible-name computation: decorative glyphs and state badges that merely
 * restate `aria-pressed`/`aria-expanded` are not part of the label a user
 * would speak. Everything else counts, at any depth — `<button
 * aria-label="X"><span>Save</span></button>` is the same defect as a bare text
 * child and must fail the same way.
 */
function visibleText(el: Element): string {
  let out = ''
  for (const node of Array.from(el.childNodes)) {
    if (node.nodeType === Node.TEXT_NODE) {
      out += node.textContent ?? ''
    } else if (node.nodeType === Node.ELEMENT_NODE) {
      const child = node as Element
      if (child.getAttribute('aria-hidden') === 'true') continue
      out += visibleText(child)
    }
  }
  return out.replace(/\s+/g, ' ').trim()
}

/**
 * Glyph-only content ("×", "↪", "/") is an icon that happens to be a
 * character rather than an SVG. WCAG 2.5.3 governs "labels that include text
 * or images of text"; a lone symbol is neither, and there is no word for a
 * speech-input user to say. Requiring an aria-label to contain "↪" would be
 * nonsense, so a control only enters the check once it renders a word.
 */
const hasWord = (text: string) => /[A-Za-z0-9]/.test(text)

/** Every interactive control in the rail that overrides its own name. */
function labelledControls(root: HTMLElement): Element[] {
  return Array.from(root.querySelectorAll('button[aria-label], a[aria-label], [role="button"][aria-label]'))
}

function violations(root: HTMLElement): string[] {
  return labelledControls(root).flatMap((el) => {
    const label = el.getAttribute('aria-label') ?? ''
    const text = visibleText(el)
    if (!hasWord(text)) return []
    if (label.toLowerCase().includes(text.toLowerCase())) return []
    return [`<${el.tagName.toLowerCase()}> shows "${text}" but is named "${label}"`]
  })
}

describe('Sidebar — WCAG 2.5.3 label in name', () => {
  beforeEach(() => {
    installMemoryStorage()
    vi.mocked(api.settings).mockResolvedValue(makeSettings())
    // demo-user is the superadmin-eligible identity, so the superadmin toggle
    // renders and is covered rather than silently skipped.
    authMock.user = { name: 'demo-user', email: 'demo-user@signalloom.local' }
  })

  afterEach(() => {
    authMock.user = { ...DEFAULT_USER }
  })

  it('every labelled control in the expanded rail is named by what it shows', async () => {
    const { container } = renderSidebar({ superadmin: true })
    await screen.findByRole('link', { name: /Agents/ })

    expect(violations(container)).toEqual([])
  })

  it('every labelled control in the collapsed rail is named by what it shows', async () => {
    localStorage.setItem(SIDEBAR_COLLAPSED_STORAGE_KEY, 'true')
    const { container } = renderSidebar({ superadmin: true })
    await waitFor(() => expect(labelledControls(container).length).toBeGreaterThan(0))

    expect(violations(container)).toEqual([])
  })

  it('covers the search-clear button, which only exists while the query is non-empty', async () => {
    const user = userEvent.setup()
    const { container } = renderSidebar({ superadmin: true })
    const search = await screen.findByRole('textbox', { name: 'Quick search navigation' })

    await user.type(search, 'aud')
    expect(screen.getByTestId('sidebar-search-clear')).toBeInTheDocument()

    expect(violations(container)).toEqual([])
  })

  // The regression itself, named. The suite above would catch it, but this
  // states the contract the Playwright smoke test depends on: the name a user
  // reads off the screen is the name that resolves the control.
  it('the help control answers to the label printed on it', async () => {
    renderSidebar()

    expect(await screen.findByRole('button', { name: /help & support/i })).toBeInTheDocument()
  })
})
