import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act, within } from '@testing-library/react'
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
const isDemoMode = vi.fn(() => false)

vi.mock('../api/client', () => ({
  api: {
    networkTests: {
      list: (...args: unknown[]) => listMock(...args),
      scan: (...args: unknown[]) => scanMock(...args),
    },
  },
}))

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
}))

import NetworkTestsPage, { isPollExhausted, isScanActive, netAssertProofs } from './NetworkTestsPage'

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
    isDemoMode.mockReturnValue(false)
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
    // The shared in-button wait, not a bespoke word. A static "Scanning…"
    // reads identically at second two and second ninety; ButtonWait carries
    // the elapsed figure that tells a slow scan from a hung one.
    expect(within(btn).getByTestId('network-tests-scan-wait')).toBeTruthy()
    expect(screen.queryByText('Scanning…')).toBeNull()

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

  // The scan control is the page's one destructive-ish action and the one
  // Andy called out as ignoring the design system.
  describe('the scan control is built out of the shared design system', () => {
    it('carries the shared button classes rather than a bespoke inline button', async () => {
      renderPage()
      const btn = await screen.findByRole('button', { name: /Scan Now/i })
      expect(btn.className.split(/\s+/)).toEqual(expect.arrayContaining(['btn', 'btn-primary']))
    })

    it('reserves a width so the control does not resize when the label becomes a loader', async () => {
      renderPage()
      const btn = await screen.findByRole('button', { name: /Scan Now/i })
      // A toolbar button that jumps mid-scan reads to a room as a fault. The
      // reserved width is the specimen's actual claim on the Design System
      // page, so it is asserted rather than eyeballed.
      expect(btn.style.minWidth).toBe('152px')
    })

    it('keeps an accessible name while its own text is a loader', async () => {
      let resolveScan: (() => void) | undefined
      scanMock.mockImplementation(() => new Promise<void>((resolve) => { resolveScan = resolve }))
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')

      const btn = screen.getByRole('button', { name: /Scan Now/i })
      await userEvent.click(btn)
      // Replacing a button's text with a grid of squares removes the only
      // thing that named the control; the busy name has to say what is running.
      await waitFor(() => expect(btn).toHaveAccessibleName('Network test scan in progress'))

      await act(async () => { resolveScan?.(); await Promise.resolve() })
    })

    it('gives the filter chips the sanctioned selected treatment and announces which is in force', async () => {
      renderPage()
      const all = await screen.findByTestId('netassert-filter-all')
      const denied = screen.getByTestId('netassert-filter-denied')

      expect(all.getAttribute('type')).toBe('button')
      expect(all.getAttribute('aria-pressed')).toBe('true')
      expect(denied.getAttribute('aria-pressed')).toBe('false')

      await userEvent.click(denied)
      expect(denied.getAttribute('aria-pressed')).toBe('true')
      expect(all.getAttribute('aria-pressed')).toBe('false')
    })

    it('tints the selected chip from a theme token, never a literal colour', async () => {
      renderPage()
      const all = await screen.findByTestId('netassert-filter-all')
      // The literal `rgba(6,182,212,0.10)` this replaced is correct in exactly
      // one of Dark, Light and Andy and wrong in the other two.
      expect(all.style.background).toContain('var(--cyan)')
      expect(all.style.background).not.toMatch(/rgba?\(/)
    })
  })

  // Every NetAssert row asserts something about the cluster. This page has a
  // documented history of probes reporting a verdict they had not earned, so a
  // reader has to be able to re-run the thing that decided it.
  describe('how do we know a reachability verdict is real', () => {
    it('opens a proof console showing the command and the raw evidence for that row', async () => {
      renderPage()
      await screen.findByText('agents-to-postgresql-denied')

      await userEvent.click(screen.getByTestId('netassert-disclose-agents-to-postgresql-denied'))

      const panel = screen.getByTestId('netassert-console-agents-to-postgresql-denied-panel')
      expect(panel.textContent).toContain('/network-tests')
      expect(panel.textContent).toContain('select(.name == "agents-to-postgresql-denied")')
      // The literal TAP line the server read out of the netassert Job's pod
      // log — the thing that actually decided the verdict.
      expect(panel.textContent).toContain('netassert TAP: not ok - agents-to-postgresql-denied')
      expect(panel.textContent).toContain('"result": "fail"')
    })

    it('closes again, and the row control is the only thing that decides it', async () => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')

      const toggle = screen.getByTestId('netassert-disclose-dashboard-to-api-allowed')
      await userEvent.click(toggle)
      expect(screen.getByTestId('netassert-console-dashboard-to-api-allowed')).toBeTruthy()
      expect(toggle.textContent).toBe('Hide proof')

      await userEvent.click(toggle)
      expect(screen.queryByTestId('netassert-console-dashboard-to-api-allowed')).toBeNull()
      expect(toggle.textContent).toBe('How do we know?')
    })

    it('projects only fields the response carried, with nulls where jq prints null', () => {
      const test = test_({ name: 'x', lastRun: null })
      const [proof] = netAssertProofs(test, [test], false)
      expect(proof.command).toBe(
        `curl -s -H "Authorization: Bearer $TOKEN" /network-tests | jq '.tests[] | select(.name == "x") | {name, description, src, dst, targetPort, expectedExit, result, evidence, lastRun}'`,
      )
      expect(proof.detail).toContain('"lastRun": null')
      expect(proof.detail).toContain('"namespace": "fe-signalloom"')
    })

    it('prints every match, because select is a stream', () => {
      const a = test_({ name: 'dup', evidence: 'first' })
      const b = test_({ name: 'dup', evidence: 'second' })
      const [proof] = netAssertProofs(a, [a, b], false)
      expect(proof.detail).toContain('"evidence": "first"')
      expect(proof.detail).toContain('"evidence": "second"')
    })

    it('refuses to invent a command in demo mode, where no request was ever issued', async () => {
      // With the toggle on, api.networkTests.list short-circuits to a fixture
      // before any HTTP happens. A curl line here would be exactly the
      // fabricated probe this product exists to make impossible.
      isDemoMode.mockReturnValue(true)
      expect(netAssertProofs(test_({}), [test_({})], true)).toEqual([])

      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      await userEvent.click(screen.getByTestId('netassert-disclose-dashboard-to-api-allowed'))

      const console_ = screen.getByTestId('netassert-console-dashboard-to-api-allowed')
      expect(console_.textContent).toContain('no proof was recorded')
      expect(console_.textContent).not.toContain('curl')
    })
  })
})
