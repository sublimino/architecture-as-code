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
  // Every one of these three buttons changes a shared cluster and none of them
  // asks for confirmation. The label says the verb; only the hint says the
  // blast radius, which is what an instructor needs before pressing it live.
  describe('the mutating controls say what they will do', () => {
    it('warns that Stun cascades to dependent agents and is reversible', async () => {
      renderPage()
      await waitFor(() => expect(screen.getByTestId('fleet-controls')).toBeInTheDocument())

      const hint = screen.getByTestId('fleet-stun-help')
      expect(hint).toHaveAccessibleName('What Stun does to the fleet')
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

      for (const name of ['reset', 'recover']) {
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
    expect(screen.getByRole('button', { name: /deploy fleet/i })).toBeEnabled()
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
