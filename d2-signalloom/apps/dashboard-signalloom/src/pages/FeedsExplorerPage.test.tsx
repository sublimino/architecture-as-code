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
