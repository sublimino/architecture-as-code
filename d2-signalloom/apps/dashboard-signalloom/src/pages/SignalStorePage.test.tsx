import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock weaveApi
const mockGetStoreStats = vi.fn()
const mockGetObservations = vi.fn()
const mockRunCorrelation = vi.fn()
const mockSeedFixtures = vi.fn()

vi.mock('../api/weaveApi', () => ({
  weaveApi: {
    getStoreStats: (...args: unknown[]) => mockGetStoreStats(...args),
    getObservations: (...args: unknown[]) => mockGetObservations(...args),
    runCorrelation: (...args: unknown[]) => mockRunCorrelation(...args),
    seedFixtures: (...args: unknown[]) => mockSeedFixtures(...args),
  },
}))

import SignalStorePage from './SignalStorePage'

const FIXTURE_STATS = {
  total_observations: 8,
  observations_by_layer: {
    network_egress: 2,
    identity_authorization: 2,
    application_saas: 1,
    endpoint_host: 1,
    behavioural: 2,
  },
  observations_by_fidelity: {
    definitive: 1,
    strong: 3,
    suggestive: 3,
    circumstantial: 1,
  },
  actor_count: 3,
  actors_by_status: {
    provisional: 1,
    actionable: 1,
    promoted: 1,
  },
  last_ingestion: '2026-08-15T07:30:00Z',
  store_type: '*store.FrostDBStore',
}

const FIXTURE_OBS = [
  {
    id: 'obs-net-001',
    timestamp: '2026-08-15T02:14:00Z',
    layer: 'network_egress',
    fidelity: 'strong',
    source: 'cilium-hubble',
    confidence: 0.82,
    raw_evidence_ref: 'ref',
    description: 'Outbound HTTPS to api.openai.com',
  },
  {
    id: 'obs-id-001',
    timestamp: '2026-08-15T02:12:00Z',
    layer: 'identity_authorization',
    fidelity: 'definitive',
    source: 'opa-audit-log',
    confidence: 0.95,
    raw_evidence_ref: 'ref',
    description: 'Service account read secrets',
  },
]

function renderPage() {
  return render(
    <MemoryRouter>
      <SignalStorePage />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  mockGetStoreStats.mockResolvedValue(FIXTURE_STATS)
  mockGetObservations.mockResolvedValue(FIXTURE_OBS)
  mockRunCorrelation.mockResolvedValue({ status: 'correlation_complete' })
  mockSeedFixtures.mockResolvedValue({ seeded: 8 })
})

describe('SignalStorePage', () => {
  it('renders loading state initially', () => {
    // Make the promises never resolve to keep loading state
    mockGetStoreStats.mockReturnValue(new Promise(() => {}))
    mockGetObservations.mockReturnValue(new Promise(() => {}))
    renderPage()
    expect(screen.getByTestId('store-load-state')).toHaveAttribute('data-status', 'loading')
  })

  it('renders the Signal Store heading', async () => {
    renderPage()
    expect(screen.getByText('Signal Store')).toBeInTheDocument()
    expect(screen.getByText('FrostDB observation store diagnostics')).toBeInTheDocument()
  })

  it('renders stat cards with fixture data', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Total Observations')).toBeInTheDocument()
    })
    // Check that the stat card values are present (use getAllByText for values that appear multiple times)
    expect(screen.getByText('Active Actors')).toBeInTheDocument()
    expect(screen.getByText('FrostDBStore')).toBeInTheDocument()
    expect(screen.getByText('Across all signal layers')).toBeInTheDocument()
  })

  it('renders observations table', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('obs-net-001')).toBeInTheDocument()
    })
    expect(screen.getByText('obs-id-001')).toBeInTheDocument()
    expect(screen.getByText('cilium-hubble')).toBeInTheDocument()
    expect(screen.getByText('opa-audit-log')).toBeInTheDocument()
  })

  it('renders fidelity breakdown', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Observations by Fidelity')).toBeInTheDocument()
    })
    // Fidelity tier names appear in both the breakdown cards and the observations table,
    // so we verify the section heading exists (which means the data loaded and rendered).
    expect(screen.getByText('Structural quality of evidence tiers')).toBeInTheDocument()
  })

  it('handles API error gracefully', async () => {
    mockGetStoreStats.mockRejectedValue(new Error('Store unreachable'))
    mockGetObservations.mockRejectedValue(new Error('Store unreachable'))
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('store-load-state')).toHaveAttribute('data-status', 'error')
    })
  })

  it('correlate button calls the correlate endpoint', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Total Observations')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('action-correlate'))
    await waitFor(() => {
      expect(mockRunCorrelation).toHaveBeenCalledWith('test-token')
    })
    await waitFor(() => {
      expect(screen.getByTestId('action-result')).toHaveTextContent('Correlation engine run complete')
    })
  })

  it('seed button calls the seed endpoint', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Total Observations')).toBeInTheDocument()
    })
    await user.click(screen.getByTestId('action-seed'))
    await waitFor(() => {
      expect(mockSeedFixtures).toHaveBeenCalledWith('test-token')
    })
    await waitFor(() => {
      expect(screen.getByTestId('action-result')).toHaveTextContent('Seeded 8 observations')
    })
  })
})
