import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockGetStoreStats = vi.fn()
const mockGetObservations = vi.fn()
const mockSeedFixtures = vi.fn()
vi.mock('../api/weaveApi', () => ({
  weaveApi: {
    getStoreStats: (...a: unknown[]) => mockGetStoreStats(...a),
    getObservations: (...a: unknown[]) => mockGetObservations(...a),
    seedFixtures: (...a: unknown[]) => mockSeedFixtures(...a),
    runCorrelation: vi.fn(),
    createObservationsStream: () => ({ disconnect: () => undefined }),
  },
}))

import FeedsExplorerPage from './FeedsExplorerPage'

const STATS = {
  total_observations: 8,
  observations_by_layer: { network_egress: 8 },
  observations_by_fidelity: { strong: 8 },
  actor_count: 0,
  actors_by_status: {},
  last_ingestion: '2026-10-06T15:00:00Z',
  store_type: '*policy.Store',
}

/** What axios rejects with when nginx/fe-signalloom answer 502 (ingest OOM-killed, 2026-10-06). */
function axiosError(status: number, data?: unknown) {
  return Object.assign(new Error(`Request failed with status code ${status}`), {
    isAxiosError: true,
    response: { status, data },
  })
}

function renderPage() {
  return render(
    <MemoryRouter>
      <FeedsExplorerPage />
    </MemoryRouter>,
  )
}

describe('FeedsExplorerPage seed and ingest errors', () => {
  let alertSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    vi.clearAllMocks()
    mockGetStoreStats.mockResolvedValue(STATS)
    mockGetObservations.mockResolvedValue([])
    mockSeedFixtures.mockResolvedValue({ seeded: 64 })
    alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => undefined)
  })
  afterEach(() => alertSpy.mockRestore())

  it('Seed Fixtures calls the seed endpoint with the token, reports success and refreshes stats', async () => {
    renderPage()
    await waitFor(() => expect(mockGetStoreStats).toHaveBeenCalledTimes(1))
    await userEvent.click(screen.getByRole('button', { name: 'Seed Fixtures' }))
    await waitFor(() => expect(mockSeedFixtures).toHaveBeenCalledWith('test-token'))
    await waitFor(() => expect(alertSpy).toHaveBeenCalledWith(expect.stringMatching(/seeded/i)))
    await waitFor(() => expect(mockGetStoreStats).toHaveBeenCalledTimes(2))
  })

  it('a 502 on seed says the ingest service is unavailable, not "status code 502"', async () => {
    mockSeedFixtures.mockRejectedValue(axiosError(502, { error: { code: 'upstream_unavailable' } }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Seed Fixtures' }))
    await waitFor(() => expect(alertSpy).toHaveBeenCalled())
    const msg = String(alertSpy.mock.calls[0][0])
    expect(msg).toMatch(/signal ingest service is unavailable/i)
    expect(msg).not.toMatch(/status code/i)
  })

  it('a seed 500 shows the server reason', async () => {
    mockSeedFixtures.mockRejectedValue(axiosError(500, { error: 'failed to seed fixtures' }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Seed Fixtures' }))
    await waitFor(() => expect(alertSpy).toHaveBeenCalled())
    const msg = String(alertSpy.mock.calls[0][0])
    expect(msg).toMatch(/failed to seed fixtures/i)
    expect(msg).not.toMatch(/status code/i)
  })

  it('a 502 loading stats shows a readable unavailable/restarting message', async () => {
    mockGetStoreStats.mockRejectedValue(axiosError(502))
    renderPage()
    expect(await screen.findByText(/signal ingest service is unavailable/i)).toBeInTheDocument()
    expect(screen.queryByText(/status code 502/i)).toBeNull()
  })
})

const TEST_OBS = [
  {
    id: 'obs-001',
    timestamp: '2026-10-06T10:15:00Z',
    layer: 'endpoint_host',
    fidelity: 'definitive' as const,
    source: 'tetragon',
    actor_hint: 'agent-nono',
    confidence: 0.98,
    raw_evidence_ref: 'sha256:1111222233334444',
    description: 'Kernel tracepoint sys_enter_execve',
  },
  {
    id: 'obs-002',
    timestamp: '2026-10-06T14:30:00Z',
    layer: 'network_egress',
    fidelity: 'strong' as const,
    source: 'envoy-mtls',
    actor_hint: 'openbao-agent',
    confidence: 0.85,
    raw_evidence_ref: 'sha256:5555666677778888',
    description: 'Outbound mTLS connection to auth.internal',
  },
]

describe('FeedsExplorerPage Super-Table', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockGetStoreStats.mockResolvedValue(STATS)
    mockGetObservations.mockResolvedValue(TEST_OBS)
  })

  it('renders Super-Table with toolbar search, layer facets, fidelity select, and count', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('feeds-stream-search')).toBeInTheDocument()
    })
    expect(screen.getByTestId('feeds-stream-layer-all')).toBeInTheDocument()
    expect(screen.getByTestId('feeds-stream-layer-endpoint_host')).toBeInTheDocument()
    expect(screen.getByTestId('feeds-stream-fidelity')).toBeInTheDocument()
    expect(screen.getByTestId('feeds-stream-count')).toHaveTextContent('2 of 2 observations shown')

    // Both observations rendered
    expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
    expect(screen.getByText('Outbound mTLS connection to auth.internal')).toBeInTheDocument()
  })

  it('filters by search input and clears via ToolbarClear', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
    })

    const searchInput = screen.getByTestId('feeds-stream-search')
    await userEvent.type(searchInput, 'Kernel')

    await waitFor(() => {
      expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
      expect(screen.queryByText('Outbound mTLS connection to auth.internal')).toBeNull()
      expect(screen.getByTestId('feeds-stream-count')).toHaveTextContent('1 of 2 observations shown')
    })

    // Click Clear filters
    const clearBtn = screen.getByTestId('feeds-stream-clear')
    await userEvent.click(clearBtn)

    await waitFor(() => {
      expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
      expect(screen.getByText('Outbound mTLS connection to auth.internal')).toBeInTheDocument()
      expect(screen.getByTestId('feeds-stream-count')).toHaveTextContent('2 of 2 observations shown')
    })
  })

  it('filters by layer facet chip', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
    })

    // Click L2 chip (network_egress)
    const l2Chip = screen.getByTestId('feeds-stream-layer-network_egress')
    await userEvent.click(l2Chip)

    await waitFor(() => {
      expect(screen.queryByText('Kernel tracepoint sys_enter_execve')).toBeNull()
      expect(screen.getByText('Outbound mTLS connection to auth.internal')).toBeInTheDocument()
      expect(screen.getByTestId('feeds-stream-count')).toHaveTextContent('1 of 2 observations shown')
    })
  })

  it('clicking a row opens the evidence drawer', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByText('Kernel tracepoint sys_enter_execve')).toBeInTheDocument()
    })

    await userEvent.click(screen.getByText('Kernel tracepoint sys_enter_execve'))

    await waitFor(() => {
      expect(screen.getByText('Observation Evidence')).toBeInTheDocument()
      expect(screen.getByText('Decoded Evidence Payload (JSON)')).toBeInTheDocument()
    })
  })
})

describe('FeedsExplorerPage Ingestion Density Historical Time-Travel', () => {
  const HIST_OBS = [
    {
      id: 'hist-001',
      timestamp: '2026-10-01T08:00:00Z',
      layer: 'behavioural',
      fidelity: 'suggestive' as const,
      source: 'agent-nono',
      confidence: 0.77,
      description: 'Historical Landlock syscall restriction',
    },
  ]

  beforeEach(() => {
    vi.clearAllMocks()
    mockGetStoreStats.mockResolvedValue(STATS)
    mockGetObservations.mockResolvedValue(TEST_OBS)
  })

  it('clicking Prev Day queries observations with after and before for the previous day', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('feeds-density-prev-day')).toBeInTheDocument()
    })

    mockGetObservations.mockResolvedValueOnce(HIST_OBS)

    await userEvent.click(screen.getByTestId('feeds-density-prev-day'))

    await waitFor(() => {
      expect(mockGetObservations).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({
          after: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T00:00:00\.000Z$/),
          before: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T23:59:59\.999Z$/),
          limit: 500,
        }),
      )
    })

    // Now viewing historical archive
    await waitFor(() => {
      expect(screen.getByText(/Historical Archive/i)).toBeInTheDocument()
    })
  })

  it('Live / Today button returns to live mode', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('feeds-density-prev-day')).toBeInTheDocument()
    })

    mockGetObservations.mockResolvedValue(HIST_OBS)
    await userEvent.click(screen.getByTestId('feeds-density-prev-day'))

    await waitFor(() => {
      expect(screen.getByText(/Historical Archive/i)).toBeInTheDocument()
    })

    // Return to live
    await userEvent.click(screen.getByTestId('feeds-density-live-btn'))

    await waitFor(() => {
      expect(screen.getByText(/Live Stream Window/i)).toBeInTheDocument()
    })
  })
})

describe('FeedsExplorerPage Deep Linking and URL Sync', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mockGetStoreStats.mockResolvedValue(STATS)
    mockGetObservations.mockResolvedValue(TEST_OBS)
  })

  it('initializes filters from URL search parameters', async () => {
    render(
      <MemoryRouter initialEntries={['/feeds?layer=network_egress&fidelity=strong&q=auth.internal']}>
        <FeedsExplorerPage />
      </MemoryRouter>,
    )

    await waitFor(() => {
      expect(screen.getByText('Outbound mTLS connection to auth.internal')).toBeInTheDocument()
    })
    expect(screen.queryByText('Kernel tracepoint sys_enter_execve')).not.toBeInTheDocument()
    expect(screen.getByTestId('feeds-stream-count')).toHaveTextContent('1 of 2 observations shown')
  })
})
