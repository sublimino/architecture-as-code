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

import NetworkTestsPage, { isPollExhausted, isScanActive } from './NetworkTestsPage'

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

  it('renders the NetAssert section', async () => {
    renderPage()
    expect(screen.getByText('NetAssert — Network Policy Assertions')).toBeTruthy()
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
    expect(screen.getByText('unavailable')).toBeTruthy()
    expect(screen.queryByText('loading…')).toBeNull()
  })

  it('shows an explicit loading status while the initial results request is pending', () => {
    listMock.mockImplementation(() => new Promise(() => {}))
    renderPage()
    expect(screen.getByRole('status').textContent).toMatch(/Loading network test results/)
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

  it('polls through pending and running responses, then stops after completion', async () => {
    vi.useFakeTimers()
    try {
      const pending = { tests: LIVE_TESTS.tests.map((t) => ({ ...t, result: 'pending' as const })), scanStatus: 'pending' as const }
      const running = { tests: LIVE_TESTS.tests.map((t) => ({ ...t, result: 'running' as const })), scanStatus: 'running' as const }
      listMock
        .mockResolvedValueOnce({ ...pending, tests: [...pending.tests] })
        .mockResolvedValueOnce({ ...pending, tests: [...pending.tests] })
        .mockResolvedValueOnce({ ...running, tests: [...running.tests] })
        .mockResolvedValueOnce(LIVE_TESTS)

      renderPage()
      await Promise.resolve()
      await Promise.resolve()
      expect(listMock).toHaveBeenCalledTimes(1)
      for (let poll = 0; poll < 3; poll += 1) {
        await act(async () => {
          await vi.advanceTimersByTimeAsync(2500)
        })
      }
      expect(listMock.mock.calls.length).toBeGreaterThanOrEqual(4)
      const callsOnceComplete = listMock.mock.calls.length

      await act(async () => {
        await vi.advanceTimersByTimeAsync(10_000)
      })
      expect(listMock.mock.calls.length).toBe(callsOnceComplete)
    } finally {
      vi.useRealTimers()
    }
  })

  it('exhausts automatic polling after forty-eight attempts', () => {
    expect(isPollExhausted(47)).toBe(false)
    expect(isPollExhausted(48)).toBe(true)
    expect(isScanActive('pending')).toBe(true)
    expect(isScanActive('running')).toBe(true)
    expect(isScanActive('complete')).toBe(false)
  })

  it('shows the newest valid last-run timestamp in the NetAssert section hint', async () => {
    listMock.mockResolvedValue({
      tests: [
        test_({ lastRun: null }),
        test_({ name: 'newest-test', lastRun: '2026-08-02T10:20:52Z' }),
        test_({ name: 'invalid-date', lastRun: 'not-a-date' }),
      ],
      scanStatus: 'complete',
    })
    renderPage()
    expect(await screen.findByText(/last run 02 Aug 2026/)).toBeTruthy()
  })
})
