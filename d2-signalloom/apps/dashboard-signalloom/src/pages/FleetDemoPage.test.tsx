import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import FleetDemoPage from './FleetDemoPage'
import type { FleetTopology } from '../api/fleetApi'

// ── Mocks ───────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockSuperadmin = { value: true }

vi.mock('../App', () => ({
  useAppContext: () => ({
    superadmin: mockSuperadmin.value,
    setSuperadmin: vi.fn(),
    failingControls: 0,
    setFailingControls: vi.fn(),
    helpOpen: false,
    setHelpOpen: vi.fn(),
  }),
}))

const mockFetchFleetTopology = vi.fn()
const mockDeployFleet = vi.fn()
const mockScanFleet = vi.fn()
const mockStunFleetAgent = vi.fn()
const mockRecoverFleet = vi.fn()
const mockResetFleet = vi.fn()

vi.mock('../api/fleetApi', () => ({
  fetchFleetTopology: (...args: unknown[]) => mockFetchFleetTopology(...args),
  deployFleet: (...args: unknown[]) => mockDeployFleet(...args),
  scanFleet: (...args: unknown[]) => mockScanFleet(...args),
  stunFleetAgent: (...args: unknown[]) => mockStunFleetAgent(...args),
  recoverFleet: (...args: unknown[]) => mockRecoverFleet(...args),
  resetFleet: (...args: unknown[]) => mockResetFleet(...args),
}))

// ── Fixtures ────────────────────────────────────────────────────────────────

const TOPOLOGY: FleetTopology = {
  agents: [
    { id: 'agent-cardvault', name: 'Card Vault', type: 'data-vault', team: 'data', trustProfile: 'high', state: 'active' },
    { id: 'agent-pipeline', name: 'Data Pipeline', type: 'data-pipeline', team: 'data', trustProfile: 'medium', state: 'active' },
    { id: 'agent-llm', name: 'LLM Inference', type: 'llm-inference', team: 'ai', trustProfile: 'medium', state: 'active' },
    { id: 'agent-gateway', name: 'API Gateway', type: 'api-gateway', team: 'platform', trustProfile: 'low', state: 'active' },
    { id: 'agent-monitor', name: 'Monitor', type: 'observability', team: 'sre', trustProfile: 'high', state: 'active' },
  ],
  edges: [
    { from: 'agent-cardvault', to: 'agent-pipeline' },
    { from: 'agent-pipeline', to: 'agent-llm' },
    { from: 'agent-llm', to: 'agent-gateway' },
    { from: 'agent-gateway', to: 'agent-monitor' },
  ],
  aggregateRisk: { ale: 847000, var95: 1200000, trend: 'up', previousAle: 650000 },
  cascadeHistory: [],
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function renderPage(audience = false) {
  return render(
    <MemoryRouter>
      <FleetDemoPage audience={audience} />
    </MemoryRouter>
  )
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe('FleetDemoPage', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = true
    mockFetchFleetTopology.mockResolvedValue(TOPOLOGY)
    mockDeployFleet.mockResolvedValue(undefined)
    mockScanFleet.mockResolvedValue(undefined)
    mockStunFleetAgent.mockResolvedValue({
      triggerId: 'agent-cardvault',
      affectedIds: ['agent-cardvault', 'agent-pipeline'],
      timestamp: '2026-08-04T00:00:00Z',
      durationMs: 500,
      riskBefore: 650000,
      riskAfter: 847000,
    })
    mockRecoverFleet.mockResolvedValue(undefined)
    mockResetFleet.mockResolvedValue(undefined)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders the page title', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument()
    })
    expect(screen.getByText('Fleet Demo')).toBeInTheDocument()
  })

  it('superadmin sees controls', async () => {
    mockSuperadmin.value = true
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-controls')).toBeInTheDocument()
    })
    expect(screen.getByTestId('fleet-deploy-btn')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-scan-btn')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-stun-btn')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-recover-btn')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-reset-btn')).toBeInTheDocument()
  })

  it('non-superadmin does not see controls', async () => {
    mockSuperadmin.value = false
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('fleet-controls')).not.toBeInTheDocument()
  })

  it('deploy button calls the API', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-deploy-btn')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('fleet-deploy-btn'))
    await waitFor(() => {
      expect(mockDeployFleet).toHaveBeenCalledWith('test-token')
    })
  })

  it('scan button calls the API', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-scan-btn')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('fleet-scan-btn'))
    await waitFor(() => {
      expect(mockScanFleet).toHaveBeenCalledWith('test-token')
    })
  })

  it('stun dropdown lists all non-observability agents', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-stun-select')).toBeInTheDocument()
    })
    const select = screen.getByTestId('fleet-stun-select') as HTMLSelectElement
    const options = Array.from(select.options).map(o => o.value)
    // Monitor is observability, should not be in the list.
    expect(options).toContain('agent-cardvault')
    expect(options).toContain('agent-pipeline')
    expect(options).toContain('agent-llm')
    expect(options).toContain('agent-gateway')
    expect(options).not.toContain('agent-monitor')
  })

  it('stun button calls the API with selected agent', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-stun-btn')).toBeInTheDocument()
    })
    // Default target is agent-cardvault.
    await user.click(screen.getByTestId('fleet-stun-btn'))
    await waitFor(() => {
      expect(mockStunFleetAgent).toHaveBeenCalledWith('agent-cardvault', 'test-token')
    })
  })

  it('recover button calls the API', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-recover-btn')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('fleet-recover-btn'))
    await waitFor(() => {
      expect(mockRecoverFleet).toHaveBeenCalledWith('test-token')
    })
  })

  it('reset button calls the API', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-reset-btn')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('fleet-reset-btn'))
    await waitFor(() => {
      expect(mockResetFleet).toHaveBeenCalledWith('test-token')
    })
  })

  it('the topology and gauge render together', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
    })
    expect(screen.getByTestId('fleet-risk-gauge')).toBeInTheDocument()
  })

  it('shows fleet summary with counts', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-summary')).toBeInTheDocument()
    })
    const summary = screen.getByTestId('fleet-summary')
    expect(summary.textContent).toContain('5')
    expect(summary.textContent).toContain('deployed')
    expect(summary.textContent).toContain('active')
  })

  it('shows loading states for operations', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-topology-status')).toBeInTheDocument()
    })
    expect(screen.getByTestId('fleet-deploy-status')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-scan-status')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-stun-status')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-recover-status')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-reset-status')).toBeInTheDocument()
  })

  it('audience mode hides controls', async () => {
    renderPage(true)
    await waitFor(() => {
      expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('fleet-controls')).not.toBeInTheDocument()
  })

  it('audience mode still shows topology and gauge', async () => {
    renderPage(true)
    await waitFor(() => {
      expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
    })
    expect(screen.getByTestId('fleet-risk-gauge')).toBeInTheDocument()
  })

  it('polls for topology data on mount', async () => {
    renderPage()
    await waitFor(() => {
      expect(mockFetchFleetTopology).toHaveBeenCalled()
    })
  })

  it('handles topology fetch error gracefully', async () => {
    mockFetchFleetTopology.mockRejectedValue(new Error('Network error'))
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument()
    })
    // Should not crash; page still renders.
    expect(screen.getByTestId('fleet-topology-status')).toBeInTheDocument()
  })

  // ── Introduction ──────────────────────────────────────────────────────────
  //
  // This page is presented from, live, to an audience. One sentence saying
  // "topology and cascade visualisation" told the instructor nothing they
  // could say out loud and told the audience nothing at all.

  describe('the introduction explains the demo', () => {
    /** Every hint on this page, keyed by the control or term it explains. */
    const HINTS = [
      'fleet-intro-help',
      'fleet-deploy-help',
      'fleet-scan-help',
      'fleet-stun-help',
      'fleet-recover-help',
      'fleet-reset-help',
      'fleet-risk-help',
      'fleet-summary-help',
      'fleet-roster-help',
      // Generated by DataTable from each column's `help` string, so the label
      // voice ("What X means") is enforced by the shared component rather than
      // by this page remembering to match it.
      'fleet-roster-help-id',
      'fleet-roster-help-type',
      'fleet-roster-help-team',
      'fleet-roster-help-trustProfile',
      'fleet-roster-help-state',
    ]

    /** Focus a hint and return the tooltip it points `aria-describedby` at. */
    function openHint(testId: string): HTMLElement {
      const hint = screen.getByTestId(testId)
      act(() => { hint.focus() })
      const id = hint.getAttribute('aria-describedby')
      expect(id, `${testId} should describe its tooltip`).toBeTruthy()
      return document.getElementById(id!)!
    }

    it('says what the diagram is, not just that there is one', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-intro')).toBeInTheDocument())
      const intro = screen.getByTestId('fleet-intro').textContent ?? ''

      expect(intro).toMatch(/dependency graph/i)
      // A line is a blast radius, which is the whole reason the page exists.
      expect(intro).toMatch(/blast radius/i)
      // The FAIR figure needs naming or the big number on the right is decoration.
      expect(intro).toMatch(/annual loss expectancy|\bALE\b/i)
      expect(intro).toMatch(/VaR95/)
      expect(intro).toMatch(/FAIR/)
      // And the controls are live against a real cluster.
      expect(intro).toMatch(/superadmin/i)
      expect(intro).toMatch(/no confirmation|without confirmation/i)
      expect(intro.length).toBeGreaterThan(400)
    })

    it('uses no em dashes, in the introduction or in any hint', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      const emDash = /—/
      expect(screen.getByTestId('fleet-intro').textContent).not.toMatch(emDash)
      for (const testId of HINTS) {
        expect(openHint(testId).textContent, testId).not.toMatch(emDash)
      }
    })

    it('is written in American English', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      const british = /\b\w+isation\b|\bmodelled\b|\bbehaviour\b|\bcolour\b|\bprioritise\b/i
      expect(screen.getByTestId('fleet-intro').textContent).not.toMatch(british)
      for (const testId of HINTS) {
        expect(openHint(testId).textContent, testId).not.toMatch(british)
      }
    })

    it('explains every instructor control, including Deploy and Scan', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      expect(openHint('fleet-deploy-help').textContent).toMatch(/SPIFFE|OpenBao/i)
      expect(openHint('fleet-scan-help').textContent).toMatch(/nothing is revoked|only reads/i)
      // The running order is presenter guidance, not control documentation, so
      // it belongs in a hint rather than on screen with everything else.
      expect(openHint('fleet-intro-help').textContent).toMatch(/deploy/i)
      expect(openHint('fleet-intro-help').textContent).toMatch(/reset/i)
    })

    it('hides the introduction hint from a non-superadmin along with the controls', async () => {
      mockSuperadmin.value = false
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-intro')).toBeInTheDocument())
      expect(screen.queryByTestId('fleet-intro-help')).not.toBeInTheDocument()
      expect(screen.queryByTestId('fleet-deploy-help')).not.toBeInTheDocument()
      expect(screen.queryByTestId('fleet-scan-help')).not.toBeInTheDocument()
    })
  })

  // ── Control chrome ────────────────────────────────────────────────────────

  describe('the instructor controls look like the rest of the product', () => {
    const BUTTONS = [
      'fleet-deploy-btn',
      'fleet-scan-btn',
      'fleet-stun-btn',
      'fleet-recover-btn',
      'fleet-reset-btn',
    ]

    it('uses the shared button classes rather than a private outlined box', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      for (const testId of BUTTONS) {
        const button = screen.getByTestId(testId)
        expect(button.className.split(/\s+/), testId).toContain('btn')
        expect(button.className, testId).toMatch(/\bbtn-(primary|secondary|danger)\b/)
      }
    })

    it('leaves fill and border to the stylesheet, so the themes still reach them', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      for (const testId of BUTTONS) {
        const button = screen.getByTestId(testId)
        expect(button.style.background, testId).toBe('')
        expect(button.style.border, testId).toBe('')
        expect(button.style.color, testId).toBe('')
      }
    })

    it('marks the destructive controls as destructive', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())
      expect(screen.getByTestId('fleet-stun-btn').className).toMatch(/btn-danger/)
      expect(screen.getByTestId('fleet-reset-btn').className).toMatch(/btn-danger/)
      expect(screen.getByTestId('fleet-deploy-btn').className).toMatch(/btn-primary/)
    })

    it('lets the global form styling reach the stun target select', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-stun-select')).toBeInTheDocument())
      const select = screen.getByTestId('fleet-stun-select')
      // global.css already themes `input, select, textarea`. The inline
      // overrides here used --surface/--border against the stylesheet's
      // --surface2/--border-subtle, so this one control did not match any
      // other select in the product.
      expect(select.style.background).toBe('')
      expect(select.style.border).toBe('')
      expect(select.style.color).toBe('')
    })
  })
  // Every one of these three buttons changes a shared cluster and none of them
  // asks for confirmation. The label says the verb; only the hint says the
  // blast radius, which is what an instructor needs before pressing it live.
  describe('the mutating controls say what they will do', () => {
    it('warns that Stun cascades to dependent agents and is reversible', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      const hint = screen.getByTestId('fleet-stun-help')
      expect(hint).toHaveAccessibleName('What the Stun control does')
      act(() => { hint.focus() })
      expect(document.activeElement).toBe(hint)

      const tooltip = screen.getByRole('tooltip')
      // The cascade is the whole demo: stunning one agent takes down what
      // depends on it. A hint that stopped at "revokes credentials" would
      // understate the blast radius.
      expect(tooltip.textContent).toMatch(/depends on it/i)
      expect(tooltip.textContent).toMatch(/cascade/i)
      expect(tooltip.textContent).toMatch(/Recover fleet/i)
    })

    it('says Reset fleet destroys everything, not just the stunned agents', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      act(() => { screen.getByTestId('fleet-reset-help').focus() })
      const tooltip = screen.getByRole('tooltip')
      expect(tooltip.textContent).toMatch(/stunned or not/i)
      expect(tooltip.textContent).toMatch(/Deploy fleet/i)
    })

    it('says Recover only undoes a stun, so it is not confused with redeploying', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      act(() => { screen.getByTestId('fleet-recover-help').focus() })
      expect(screen.getByRole('tooltip').textContent).toMatch(/does not redeploy/i)
    })

    it('keeps each hint beside its button rather than stacked under it', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      for (const name of ['deploy', 'scan', 'reset', 'recover']) {
        const button = screen.getByTestId(`fleet-${name}-btn`)
        const hint = screen.getByTestId(`fleet-${name}-help`)
        // The controls column is vertical; a hint that is a sibling of the
        // button lands on its own row, detached from what it explains.
        expect(button.parentElement).toBe(hint.closest('span[style]')?.parentElement)
        expect(button.parentElement).not.toBe(screen.getByTestId('fleet-controls'))
      }
    })

    it('hides every hint from a non-superadmin, along with the controls', async () => {
      mockSuperadmin.value = false
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument())

      expect(screen.queryByTestId('fleet-controls')).not.toBeInTheDocument()
      expect(screen.queryByTestId('fleet-stun-help')).not.toBeInTheDocument()
      expect(screen.queryByTestId('fleet-reset-help')).not.toBeInTheDocument()
      expect(screen.queryByTestId('fleet-recover-help')).not.toBeInTheDocument()
    })
  })
})

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// Every control here already had a LoadingState beside it saying THAT it is
// running. None of them said for HOW LONG, which is the only thing anyone
// actually wants to know sixty seconds into a fleet deploy. The in-button
// loader supplies the elapsed figure and is deliberately aria-hidden: the
// sibling LoadingState is already a polite live region for this operation, and
// two regions announcing one operation is worse than one.

describe('fleet waits say how long they have been waiting', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = true
    mockFetchFleetTopology.mockResolvedValue(TOPOLOGY)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  /** A promise held open until the test decides the request has finished. */
  function gate() {
    let release!: () => void
    const promise = new Promise<void>(resolve => { release = () => resolve() })
    return { promise, release }
  }

  it('counts up inside Deploy Fleet and stops when the deploy returns', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    const held = gate()
    mockDeployFleet.mockReturnValue(held.promise)

    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-deploy-btn')).toBeInTheDocument())
    await user.click(screen.getByTestId('fleet-deploy-btn'))

    const loader = await screen.findByTestId('fleet-deploy-loader')
    expect(within(loader).getByTestId('fleet-deploy-loader-elapsed')).toHaveTextContent(/s$/)
    // The control keeps a meaningful name even though the loader is hidden
    // from assistive technology.
    expect(screen.getByRole('button', { name: /deploying/i })).toBeDisabled()

    held.release()
    await waitFor(() => expect(screen.queryByTestId('fleet-deploy-loader')).not.toBeInTheDocument())
    // Anchored, because the hint beside this button is deliberately named after
    // it — "What the Deploy Fleet control does" — so a substring match now finds
    // two buttons. That is the hint doing its job: a speech-input user asking
    // for the explanation of a control should be able to say the control's name.
    expect(screen.getByRole('button', { name: /^deploy fleet$/i })).toBeEnabled()
  })

  it('does not add a second live region beside the one already announcing', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    const held = gate()
    mockScanFleet.mockReturnValue(held.promise)

    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-scan-btn')).toBeInTheDocument())
    await user.click(screen.getByTestId('fleet-scan-btn'))

    const loader = await screen.findByTestId('fleet-scan-loader')
    // PixelLoader is role=status by construction; hiding the subtree is what
    // keeps the announcement single. fleet-scan-status stays the announcer.
    expect(loader.closest('[aria-hidden="true"]')).not.toBeNull()
    expect(screen.getByTestId('fleet-scan-status')).toHaveAttribute('aria-live', 'polite')

    held.release()
    await waitFor(() => expect(screen.queryByTestId('fleet-scan-loader')).not.toBeInTheDocument())
  })

  it('counts up inside the narrow Stun button without letting it change size', async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    const held = gate()
    mockStunFleetAgent.mockReturnValue(held.promise)

    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-stun-btn')).toBeInTheDocument())
    const idleWidth = screen.getByTestId('fleet-stun-btn').style.minWidth
    await user.click(screen.getByTestId('fleet-stun-btn'))

    expect(await screen.findByTestId('fleet-stun-loader')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /stunning/i })).toBeDisabled()
    // Reserved, not measured: the button is the same box idle and busy, so
    // neither the swap nor a tick can nudge the row.
    expect(screen.getByTestId('fleet-stun-btn').style.minWidth).toBe(idleWidth)
    expect(idleWidth).not.toBe('')

    held.release()
    await waitFor(() => expect(screen.queryByTestId('fleet-stun-loader')).not.toBeInTheDocument())
  })

  it('leaves the two-second topology poll alone', async () => {
    // topologyLoading flips true on EVERY poll. A loader there would flash
    // twice a second forever, which is noise, not information — the existing
    // LoadingState already carries "Refreshing… · last refreshed 3s ago".
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-topology-status')).toBeInTheDocument())
    expect(screen.queryByTestId('fleet-topology-loader')).not.toBeInTheDocument()
  })
})

// ─── Roster ─────────────────────────────────────────────────────────────────
//
// The agents were always on this page, drawn as cards. The diagram answers
// "what depends on what" and nothing else: it cannot be sorted, cannot be
// narrowed, and never showed `team` or the workload ID at all — the latter
// being the exact string the Stun control sends, which an instructor had to
// know by heart or read out of a dropdown.

/** A fleet in four different states and all three trust profiles. */
const MIXED_TOPOLOGY: FleetTopology = {
  ...TOPOLOGY,
  agents: [
    { id: 'agent-cardvault', name: 'Card Vault', type: 'data-vault', team: 'data', trustProfile: 'high', state: 'active' },
    { id: 'agent-pipeline', name: 'Data Pipeline', type: 'data-pipeline', team: 'data', trustProfile: 'medium', state: 'stunned' },
    { id: 'agent-llm', name: 'LLM Inference', type: 'llm-inference', team: 'ai', trustProfile: 'medium', state: 'non-compliant' },
    { id: 'agent-gateway', name: 'API Gateway', type: 'api-gateway', team: 'platform', trustProfile: 'low', state: 'active' },
    { id: 'agent-monitor', name: 'Monitor', type: 'observability', team: 'sre', trustProfile: 'high', state: 'active' },
  ],
}

describe('the fleet roster', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = true
    mockFetchFleetTopology.mockResolvedValue(MIXED_TOPOLOGY)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  /** The rendered roster rows, by workload ID, in document order. */
  function rosterIds(): string[] {
    return Array.from(document.querySelectorAll('[data-testid^="fleet-roster-row-"]'))
      .map(el => el.getAttribute('data-testid')!.replace('fleet-roster-row-', ''))
  }

  async function renderRoster() {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-search')).toBeInTheDocument())
    return user
  }

  it('puts every agent the fleet manager reported on the table', async () => {
    await renderRoster()
    expect(rosterIds()).toHaveLength(MIXED_TOPOLOGY.agents.length)
    expect(screen.getByTestId('fleet-roster-count')).toHaveTextContent('5 of 5 shown')
  })

  it('shows the workload ID and the owning team, which were on screen nowhere else', async () => {
    await renderRoster()
    const row = screen.getByTestId('fleet-roster-row-agent-llm')
    // The ID is what Stun takes; the team is who you call when it cascades.
    expect(row).toHaveTextContent('agent-llm')
    expect(row).toHaveTextContent('ai')
    expect(row).toHaveTextContent('LLM Inference')
  })

  it('narrows to a search across name, workload ID, type and team', async () => {
    const user = await renderRoster()
    const search = screen.getByTestId('fleet-roster-search')

    // `vault` is in the name, the ID and the type of exactly one agent.
    await user.type(search, 'vault')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-cardvault']))

    await user.clear(search)
    // `platform` appears only as a team.
    await user.type(search, 'platform')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-gateway']))

    await user.clear(search)
    // `agent-` is in every workload ID, so the search reaches the ID column.
    await user.type(search, 'agent-')
    await waitFor(() => expect(rosterIds()).toHaveLength(5))
  })

  it('narrows by state, and each chip carries its own count', async () => {
    const user = await renderRoster()

    expect(screen.getByTestId('fleet-roster-filter-active')).toHaveTextContent('3')
    expect(screen.getByTestId('fleet-roster-filter-stunned')).toHaveTextContent('1')

    await user.click(screen.getByTestId('fleet-roster-filter-stunned'))
    await waitFor(() => expect(rosterIds()).toEqual(['agent-pipeline']))
    expect(screen.getByTestId('fleet-roster-filter-stunned')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('fleet-roster-count')).toHaveTextContent('1 of 5 shown')

    await user.click(screen.getByTestId('fleet-roster-filter-all'))
    await waitFor(() => expect(rosterIds()).toHaveLength(5))
  })

  it('offers only the states the fleet is actually in', async () => {
    await renderRoster()
    // No agent is deploying or absent, so no chip claims a zero.
    expect(screen.queryByTestId('fleet-roster-filter-deploying')).not.toBeInTheDocument()
    expect(screen.queryByTestId('fleet-roster-filter-absent')).not.toBeInTheDocument()
    expect(screen.getByTestId('fleet-roster-filter-non-compliant')).toBeInTheDocument()
  })

  it('narrows by trust profile', async () => {
    const user = await renderRoster()
    await user.selectOptions(screen.getByTestId('fleet-roster-trust'), 'low')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-gateway']))

    await user.selectOptions(screen.getByTestId('fleet-roster-trust'), 'high')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-cardvault', 'agent-monitor']))
  })

  it('combines the filters rather than letting the last one win', async () => {
    const user = await renderRoster()
    await user.selectOptions(screen.getByTestId('fleet-roster-trust'), 'high')
    await user.click(screen.getByTestId('fleet-roster-filter-active'))
    // Both high-trust agents are active, so this is still two...
    await waitFor(() => expect(rosterIds()).toEqual(['agent-cardvault', 'agent-monitor']))
    // ...and the search narrows the intersection further rather than resetting it.
    await user.type(screen.getByTestId('fleet-roster-search'), 'sre')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-monitor']))
  })

  it('keeps the toolbar when the filters match nothing, so the filter can be undone', async () => {
    const user = await renderRoster()
    await user.type(screen.getByTestId('fleet-roster-search'), 'zzzz-no-such-agent')

    await waitFor(() => expect(screen.getByTestId('fleet-roster-empty')).toBeInTheDocument())
    expect(rosterIds()).toHaveLength(0)
    expect(screen.getByText('No agents match those filters')).toBeInTheDocument()
    // The whole point of DataTable owning `toolbar` rather than the page
    // stacking it by hand: the control that emptied the table is still there.
    expect(screen.getByTestId('fleet-roster-search')).toBeInTheDocument()
    expect(screen.getByTestId('fleet-roster-filter-all')).toBeInTheDocument()

    await user.clear(screen.getByTestId('fleet-roster-search'))
    await waitFor(() => expect(rosterIds()).toHaveLength(5))
  })

  it('clears every filter at once from the toolbar', async () => {
    const user = await renderRoster()
    // The control only appears once there is something to clear.
    expect(screen.queryByTestId('fleet-roster-clear')).not.toBeInTheDocument()

    await user.type(screen.getByTestId('fleet-roster-search'), 'vault')
    await user.click(screen.getByTestId('fleet-roster-filter-active'))
    await user.selectOptions(screen.getByTestId('fleet-roster-trust'), 'high')
    await waitFor(() => expect(rosterIds()).toEqual(['agent-cardvault']))

    await user.click(screen.getByTestId('fleet-roster-clear'))
    await waitFor(() => expect(rosterIds()).toHaveLength(5))
    expect(screen.getByTestId('fleet-roster-search')).toHaveValue('')
    expect(screen.getByTestId('fleet-roster-filter-all')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('fleet-roster-trust')).toHaveValue('all')
  })

  it('says an empty fleet is empty, not filtered', async () => {
    mockFetchFleetTopology.mockResolvedValue({ ...MIXED_TOPOLOGY, agents: [], edges: [] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-empty')).toBeInTheDocument())
    // A healthy zero. The fleet manager answered; there is simply nothing there.
    expect(screen.getByText('No agents deployed')).toBeInTheDocument()
    expect(screen.queryByText('No agents match those filters')).not.toBeInTheDocument()
    expect(screen.queryByTestId('fleet-roster-unreachable')).not.toBeInTheDocument()
  })

  it('shows a failure, not an empty fleet, when the fleet manager is unreachable', async () => {
    // The exact shape FleetUnreachableError exists for: nginx's SPA catch-all
    // answers an unproxied /fleet-api/ with 200 and index.html, so `res.ok` is
    // true for a reply that is not this API. An empty state here would tell a
    // room the estate is clean when the backend is simply not there.
    mockFetchFleetTopology.mockRejectedValue(
      new Error('Fleet Manager did not respond — the request was answered by the dashboard itself'),
    )
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-unreachable')).toBeInTheDocument())

    expect(screen.queryByTestId('fleet-roster-empty')).not.toBeInTheDocument()
    expect(screen.queryByText('No agents deployed')).not.toBeInTheDocument()
    expect(screen.getByText('Failed to load')).toBeInTheDocument()
    // Filters over an estate nobody has heard from would be theater.
    expect(screen.queryByTestId('fleet-roster-search')).not.toBeInTheDocument()
  })

  it('refuses to count a fleet nobody has heard from', async () => {
    // The four counts used to render 0/0/0/0 beside the error saying the fleet
    // manager never answered: one screen making two contradictory claims, and
    // the confident one was the false one. A count you do not have is not zero.
    mockFetchFleetTopology.mockRejectedValue(new Error('Fleet Manager did not respond'))
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-summary-unreachable')).toBeInTheDocument())

    const summary = screen.getByTestId('fleet-summary')
    // No digits at all, so no card can be read as a measured zero.
    expect(summary.textContent).not.toContain('0')
    expect(summary.textContent).toMatch(/did not answer/i)
  })

  it('still counts a genuinely empty fleet, because zero is then the truth', async () => {
    mockFetchFleetTopology.mockResolvedValue({ ...MIXED_TOPOLOGY, agents: [] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-empty')).toBeInTheDocument())
    expect(screen.queryByTestId('fleet-summary-unreachable')).not.toBeInTheDocument()
    expect(screen.getByTestId('fleet-summary').textContent).toContain('0')
  })

  it('keeps the last known roster on screen when a later poll fails', async () => {
    mockFetchFleetTopology.mockResolvedValueOnce(MIXED_TOPOLOGY)
    mockFetchFleetTopology.mockRejectedValue(new Error('Fleet API 502: upstream gone'))
    renderPage()
    await waitFor(() => expect(rosterIds()).toHaveLength(5))

    await act(async () => { await vi.advanceTimersByTimeAsync(2100) })

    // Blanking a live demo on one dropped request is its own failure. The
    // estate stays; the LoadingState beside it carries the error.
    await waitFor(() => expect(screen.getByTestId('fleet-topology-status')).toHaveTextContent(/502/))
    expect(rosterIds()).toHaveLength(5)
    expect(screen.queryByTestId('fleet-roster-unreachable')).not.toBeInTheDocument()
  })
})

// ─── Both routes ────────────────────────────────────────────────────────────
//
// This page is mounted twice: `/fleet` for the instructor and `/fleet/audience`
// for the projector. The audience variant is the one a room watches and the one
// easiest to forget, so everything below asserts it explicitly rather than
// assuming the shared code path covers it.

describe('both fleet routes', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = true
    mockFetchFleetTopology.mockResolvedValue(MIXED_TOPOLOGY)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('gives the instructor route the roster and the audience route the diagram alone', async () => {
    const instructor = renderPage(false)
    await waitFor(() => expect(screen.getByTestId('fleet-roster-search')).toBeInTheDocument())
    expect(screen.getByRole('heading', { name: 'Fleet roster' })).toBeInTheDocument()
    instructor.unmount()

    renderPage(true)
    await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument())
    // A table of filter chips projected behind a speaker is noise, and nobody
    // in the room can operate it.
    expect(screen.queryByTestId('fleet-roster-search')).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Fleet roster' })).not.toBeInTheDocument()
  })

  it('fails visibly on the audience route rather than projecting an empty fleet', async () => {
    mockFetchFleetTopology.mockRejectedValue(
      new Error('Fleet Manager did not respond — /fleet-api/ is not proxied'),
    )
    renderPage(true)
    await waitFor(() => expect(screen.getByTestId('fleet-audience-unreachable')).toBeInTheDocument())

    expect(screen.getByText('Failed to load')).toBeInTheDocument()
    // The two things that would otherwise draw a healthy, empty estate: a
    // diagram with no nodes, and a risk gauge confidently reading zero.
    expect(screen.queryByTestId('fleet-topology')).not.toBeInTheDocument()
    expect(screen.queryByTestId('fleet-risk-gauge')).not.toBeInTheDocument()
  })

  it('keeps the audience diagram up when the fleet manager is merely empty', async () => {
    // Empty is not unreachable on this route either: an estate that has been
    // reset really is zero, and the gauge reading zero is then the truth.
    mockFetchFleetTopology.mockResolvedValue({ ...MIXED_TOPOLOGY, agents: [], edges: [] })
    renderPage(true)
    await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument())
    expect(screen.getByTestId('fleet-risk-gauge')).toBeInTheDocument()
    expect(screen.queryByTestId('fleet-audience-unreachable')).not.toBeInTheDocument()
  })

  it('keeps the audience diagram up when a later poll fails, mid-demo', async () => {
    mockFetchFleetTopology.mockResolvedValueOnce(MIXED_TOPOLOGY)
    mockFetchFleetTopology.mockRejectedValue(new Error('Fleet API 502: upstream gone'))
    renderPage(true)
    await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument())

    await act(async () => { await vi.advanceTimersByTimeAsync(2100) })

    expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
    expect(screen.queryByTestId('fleet-audience-unreachable')).not.toBeInTheDocument()
  })
})

// ─── Hints ──────────────────────────────────────────────────────────────────

describe('the hints read as one author', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.clearAllMocks()
    mockSuperadmin.value = true
    mockFetchFleetTopology.mockResolvedValue(MIXED_TOPOLOGY)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  /** Every instructor control, and the hint that sits beside it. */
  const CONTROLS = [
    ['fleet-deploy-btn', 'fleet-deploy-help'],
    ['fleet-scan-btn', 'fleet-scan-help'],
    ['fleet-stun-btn', 'fleet-stun-help'],
    ['fleet-recover-btn', 'fleet-recover-help'],
    ['fleet-reset-btn', 'fleet-reset-help'],
  ]

  it('names every control hint after the exact label on the control', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

    for (const [button, hint] of CONTROLS) {
      const label = screen.getByTestId(button).textContent?.trim()
      // One pattern, mechanically: a speech-input user who can see "Reset
      // Fleet" can ask for "what the Reset Fleet control does" and be
      // understood. The five used to be three different sentence shapes.
      expect(screen.getByTestId(hint), hint).toHaveAccessibleName(`What the ${label} control does`)
    }
  })

  it('lets the shared DataTable name the column hints, so the table voice cannot drift', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-search')).toBeInTheDocument())

    // DataTable builds these from the column label. The page supplies prose and
    // never a label, which is why every table in the product says it the same way.
    expect(screen.getByTestId('fleet-roster-help-state')).toHaveAccessibleName('What State means')
    expect(screen.getByTestId('fleet-roster-help-trustProfile')).toHaveAccessibleName('What Trust means')
    expect(screen.getByTestId('fleet-roster-help-id')).toHaveAccessibleName('What Workload ID means')
  })

  it('gives every hint a reachable tooltip', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId('fleet-roster-search')).toBeInTheDocument())

    const hints = Array.from(document.querySelectorAll('[data-testid$="-help"], [data-testid*="-help-"]'))
    // Seven before this migration, and the count is asserted so a new one is a
    // decision rather than an accident.
    expect(hints.length).toBe(14)

    for (const hint of hints) {
      const testId = hint.getAttribute('data-testid')
      act(() => { (hint as HTMLElement).focus() })
      const describedBy = hint.getAttribute('aria-describedby')
      expect(describedBy, `${testId} should describe a tooltip`).toBeTruthy()
      const tooltip = document.getElementById(describedBy!)
      expect(tooltip?.textContent?.length ?? 0, `${testId} tooltip should say something`).toBeGreaterThan(40)
    }
  })
})
