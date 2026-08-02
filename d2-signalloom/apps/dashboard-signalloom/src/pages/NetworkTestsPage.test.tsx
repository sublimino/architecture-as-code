import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import type { NetworkTestListResponse, NetworkTestResult } from '../types/api'

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: true,
    getAccessTokenSilently: () => Promise.resolve('fake-token'),
    user: { name: 'Test', email: 'test@example.com' },
  }),
}))

const listMock = vi.fn()
const scanMock = vi.fn()

vi.mock('../api/client', () => ({
  api: {
    networkTests: {
      list: (...args: unknown[]) => listMock(...args),
      scan: (...args: unknown[]) => scanMock(...args),
    },
  },
}))

import NetworkTestsPage from './NetworkTestsPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <NetworkTestsPage />
    </MemoryRouter>,
  )
}

function test_(overrides: Partial<NetworkTestResult>): NetworkTestResult {
  return {
    name: 'dashboard-to-api-allowed',
    expectedExit: 0,
    targetPort: 8000,
    src: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    dst: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    description: 'Dashboard to API backend (nginx /api proxy)',
    result: 'pass',
    evidence: 'netassert TAP: ok - dashboard-to-api-allowed',
    lastRun: '2026-08-01T10:20:52Z',
    ...overrides,
  }
}

const LIVE_TESTS: NetworkTestListResponse = {
  tests: [
    test_({ name: 'dashboard-to-api-allowed', expectedExit: 0, result: 'pass' }),
    test_({
      name: 'agents-to-postgresql-denied',
      expectedExit: 1,
      targetPort: 5432,
      src: { namespace: 'fe-signalloom-agents', name: 'agent-patsy' },
      dst: { namespace: 'inf-signalloom', name: 'postgresql' },
      description: 'Agent pods MUST NOT reach PostgreSQL directly',
      result: 'fail',
      evidence: 'netassert TAP: not ok - agents-to-postgresql-denied',
    }),
  ],
  scanStatus: 'complete',
}

describe('NetworkTestsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    listMock.mockResolvedValue(LIVE_TESTS)
    scanMock.mockResolvedValue({ job: 'netassert-run', status: 'started' })
  })

  it('renders the page heading', async () => {
    renderPage()
    expect(screen.getByText('Network Tests')).toBeTruthy()
    await waitFor(() => expect(listMock).toHaveBeenCalled())
  })

  it('renders the NetSerts section', async () => {
    renderPage()
    expect(screen.getByText('NetSerts — Network Policy Assertions')).toBeTruthy()
    await waitFor(() => expect(listMock).toHaveBeenCalled())
  })

  it('renders live allowed and denied test entries from the API, not hardcoded data', async () => {
    renderPage()
    expect(await screen.findByText('dashboard-to-api-allowed')).toBeTruthy()
    expect(await screen.findByText('agents-to-postgresql-denied')).toBeTruthy()
    expect(listMock).toHaveBeenCalledWith('fake-token')
  })

  it('renders the CI Pipeline Results section', () => {
    renderPage()
    expect(screen.getByText('CI Pipeline Results')).toBeTruthy()
  })

  it('renders CI summary stats', () => {
    renderPage()
    expect(screen.getByText('176')).toBeTruthy() // pass count
  })

  it('renders agent test results section', () => {
    renderPage()
    expect(screen.getByText('Agent Test Infrastructure')).toBeTruthy()
  })

  it('renders the fe-signalloom-agents namespace reference', () => {
    renderPage()
    expect(screen.getAllByText('fe-signalloom-agents').length).toBeGreaterThan(0)
  })

  it('shows a never-run prompt when no scan has happened yet', async () => {
    listMock.mockResolvedValue({ tests: [], scanStatus: 'never-run' })
    renderPage()
    expect(await screen.findByText('No scan has been run yet')).toBeTruthy()
  })

  it('surfaces a visible error when loading results fails', async () => {
    listMock.mockRejectedValue(new Error('backend unreachable'))
    renderPage()
    expect(await screen.findByText('backend unreachable')).toBeTruthy()
  })

  it('renders an accessible, real Scan Now button', async () => {
    renderPage()
    const btn = await screen.findByRole('button', { name: /Scan Now/i })
    expect(btn.tagName).toBe('BUTTON')
    expect(btn).not.toBeDisabled()
  })

  it('triggers a scan and reloads results on click', async () => {
    renderPage()
    await screen.findByText('dashboard-to-api-allowed')
    listMock.mockClear()
    await userEvent.click(screen.getByRole('button', { name: /Scan Now/i }))
    await waitFor(() => expect(scanMock).toHaveBeenCalledWith('fake-token'))
    await waitFor(() => expect(listMock).toHaveBeenCalled())
  })

  it('disables the button and marks it busy while a scan is in flight', async () => {
    let resolveScan: (() => void) | undefined
    scanMock.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          resolveScan = resolve
        }),
    )
    renderPage()
    await screen.findByText('dashboard-to-api-allowed')

    const user = userEvent.setup()
    const btn = screen.getByRole('button', { name: /Scan Now/i })
    await user.click(btn)

    await waitFor(() => expect(btn).toBeDisabled())
    expect(btn.getAttribute('aria-busy')).toBe('true')
    expect(screen.getByText('Scanning…')).toBeTruthy()

    resolveScan?.()
    await waitFor(() => expect(btn).not.toBeDisabled())
  })

  it('does not allow a second scan to be triggered while one is in flight (no double-submit)', async () => {
    let resolveScan: (() => void) | undefined
    scanMock.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          resolveScan = resolve
        }),
    )
    renderPage()
    await screen.findByText('dashboard-to-api-allowed')

    const user = userEvent.setup()
    const btn = screen.getByRole('button', { name: /Scan Now/i })
    await user.click(btn)
    await user.click(btn) // second click while disabled must be a no-op

    expect(scanMock).toHaveBeenCalledTimes(1)
    await act(async () => {
      resolveScan?.()
      await Promise.resolve()
    })
  })

  it('shows the real error message when a scan fails', async () => {
    scanMock.mockRejectedValue(new Error('a network test scan is already running'))
    renderPage()
    await screen.findByText('dashboard-to-api-allowed')
    await userEvent.click(screen.getByRole('button', { name: /Scan Now/i }))
    expect(await screen.findByText(/a network test scan is already running/)).toBeTruthy()
  })

  it('polls while the backend reports the scan as running, and stops once complete', async () => {
    vi.useFakeTimers()
    try {
      const running = { tests: LIVE_TESTS.tests.map((t) => ({ ...t, result: 'running' as const })), scanStatus: 'running' as const }
      // Enough 'running' responses to cover mount plus a couple of poll ticks,
      // however many renders the environment triggers along the way — the
      // behavior under test is "stops polling once status flips to complete",
      // not an exact call count.
      listMock.mockResolvedValueOnce(running).mockResolvedValueOnce(running).mockResolvedValue(running)

      renderPage()
      await act(async () => {
        await Promise.resolve()
        await Promise.resolve()
      })
      const callsWhileRunning = listMock.mock.calls.length
      expect(callsWhileRunning).toBeGreaterThanOrEqual(1)

      await act(async () => {
        await vi.advanceTimersByTimeAsync(2500)
      })
      // Still running (mock keeps returning 'running'), so polling continued.
      expect(listMock.mock.calls.length).toBeGreaterThan(callsWhileRunning)

      // Now let the backend report completion and confirm polling stops.
      listMock.mockResolvedValue(LIVE_TESTS)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2500)
      })
      const callsOnceComplete = listMock.mock.calls.length

      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000)
      })
      expect(listMock.mock.calls.length).toBe(callsOnceComplete)
    } finally {
      vi.useRealTimers()
    }
  })
})
