/**
 * Tests for WeavePage — the Signal Weave dashboard.
 *
 * Validates rendering of the three main panels: signal threads, actors, and
 * coverage honesty. Uses mocked weaveApi to avoid network calls.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import WeavePage from './WeavePage'

// fakeWeaveData is imported AFTER the vi.mock calls (which are hoisted), so
// we cannot reference it inside a vi.mock factory. Instead we use vi.hoisted
// to create the mock functions and wire them up in beforeEach.
import { fakeWeaveData } from '../api/fakeWeaveData'

// ── Mocks ──────────────────────────────────────────────────────────────────
// vi.mock is hoisted above imports, so variables it references must be
// created with vi.hoisted() to exist at that point.

const { getAccessTokenSilently, mockWeaveApi } = vi.hoisted(() => ({
  getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  mockWeaveApi: {
    getObservations: vi.fn(),
    getActors: vi.fn(),
    getCoverage: vi.fn(),
    promoteActor: vi.fn(),
    runCorrelation: vi.fn(),
  },
}))

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: mockWeaveApi,
}))

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/weave']}>
      <WeavePage />
    </MemoryRouter>,
  )
}

describe('WeavePage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    mockWeaveApi.getCoverage.mockResolvedValue(fakeWeaveData.coverage)
  })

  it('renders the page title', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('The Weave')).toBeInTheDocument()
    })
  })

  it('renders the signal threads panel', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('signal-threads')).toBeInTheDocument()
    })
  })

  it('renders actor cards', async () => {
    renderPage()
    await waitFor(() => {
      const cards = screen.getAllByTestId('actor-card')
      expect(cards.length).toBe(fakeWeaveData.actors.length)
    })
  })

  it('renders the coverage honesty panel', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('coverage-panel')).toBeInTheDocument()
    })
  })

  it('shows Coverage Honesty heading', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Coverage Honesty')).toBeInTheDocument()
    })
  })

  it('shows active layer statuses', async () => {
    renderPage()
    await waitFor(() => {
      const activeStatuses = screen.getAllByTestId('layer-status-active')
      expect(activeStatuses.length).toBe(fakeWeaveData.coverage.covered_layers.length)
    })
  })

  it('shows inactive layer statuses', async () => {
    renderPage()
    await waitFor(() => {
      const inactiveStatuses = screen.getAllByTestId('layer-status-inactive')
      // 7 total layers - 5 active = 2 inactive
      expect(inactiveStatuses.length).toBe(2)
    })
  })

  it('shows the closeable-by-issuance callout', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('closeable-callout')).toBeInTheDocument()
    })
  })

  it('renders View Evidence button for each actor', async () => {
    renderPage()
    await waitFor(() => {
      const buttons = screen.getAllByTestId('view-evidence-btn')
      expect(buttons.length).toBe(fakeWeaveData.actors.length)
    })
  })

  it('opens evidence drawer when View Evidence is clicked', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getAllByTestId('view-evidence-btn').length).toBeGreaterThan(0)
    })
    await userEvent.click(screen.getAllByTestId('view-evidence-btn')[0])
    expect(screen.getByTestId('evidence-drawer')).toBeInTheDocument()
  })

  it('shows promote button only for actionable actors', async () => {
    renderPage()
    await waitFor(() => {
      const promoteButtons = screen.getAllByTestId('promote-actor-btn')
      const actionableCount = fakeWeaveData.actors.filter((a) => a.status === 'actionable').length
      expect(promoteButtons.length).toBe(actionableCount)
    })
  })

  it('shows stat cards with correct values', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText(String(fakeWeaveData.observations.length))).toBeInTheDocument()
      expect(screen.getByText(String(fakeWeaveData.actors.length))).toBeInTheDocument()
    })
  })
})
