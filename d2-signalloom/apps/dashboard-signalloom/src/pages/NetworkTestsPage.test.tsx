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

import NetworkTestsPage, {
  isPollExhausted,
  isScanActive,
  netAssertProofs,
  verdictClass,
  verdictNarrative,
} from './NetworkTestsPage'

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

  // ── Filters ───────────────────────────────────────────────────────────────
  //
  // One vocabulary, three tables: a search box, one chip group with counts, a
  // clear control that appears only while something is narrowing, and an
  // "n of m shown" tally — all handed to DataTable's `toolbar` slot so the
  // controls outlive the table when a filter empties it.
  describe('every table narrows through the same toolbar', () => {
    it('puts each toolbar inside DataTable\'s own slot rather than stacking it above by hand', async () => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      // The whole point of the slot: a hand-rolled strip above a
      // `rows.length ? table : empty` ternary disappears with the table.
      expect(within(screen.getByTestId('netserts-toolbar')).getByTestId('netassert-search')).toBeTruthy()
      expect(within(screen.getByTestId('ci-results-toolbar')).getByTestId('ci-search')).toBeTruthy()
      expect(within(screen.getByTestId('agent-tests-toolbar')).getByTestId('agent-search')).toBeTruthy()
    })

    it('narrows the NetAssert table by search text', async () => {
      renderPage()
      await screen.findByText('agents-to-postgresql-denied')

      await userEvent.type(screen.getByTestId('netassert-search'), 'postgresql')
      expect(screen.queryByText('dashboard-to-api-allowed')).toBeNull()
      expect(screen.getByText('agents-to-postgresql-denied')).toBeTruthy()
      expect(screen.getByTestId('netassert-count').textContent).toBe('1 of 2 shown')
    })

    it('narrows the NetAssert table by verdict class, which no chip offers', async () => {
      // The chips filter by direction, so without this the rows that observed
      // nothing would be the one state on the page with no way to isolate it.
      listMock.mockResolvedValue({
        tests: [
          test_({ name: 'observed-pass' }),
          test_({ name: 'probe-never-reported', result: 'error', evidence: 'job not found in namespace' }),
        ],
        scanStatus: 'complete',
      })
      renderPage()
      await screen.findByText('probe-never-reported')

      await userEvent.type(screen.getByTestId('netassert-search'), 'no verdict')
      expect(screen.getByText('probe-never-reported')).toBeTruthy()
      expect(screen.queryByText('observed-pass')).toBeNull()
    })

    it('narrows the CI table by its outcome chips', async () => {
      renderPage()
      expect(screen.getAllByText('bats-static-contracts').length).toBe(8)

      await userEvent.click(screen.getByTestId('ci-filter-fail'))
      expect(screen.queryByText('bats-static-contracts')).toBeNull()
      expect(screen.getByTestId('ci-count').textContent).toBe('0 of 8 shown')
    })

    it('narrows the agent table by status chip and by search', async () => {
      renderPage()
      expect(screen.getByText('fake-integration-proxy')).toBeTruthy()

      await userEvent.click(screen.getByTestId('agent-filter-pending'))
      expect(screen.getByText('fake-integration-proxy')).toBeTruthy()
      expect(screen.queryByText('cardvault-agent')).toBeNull()

      await userEvent.click(screen.getByTestId('agent-filter-all'))
      await userEvent.type(screen.getByTestId('agent-search'), 'policy-eval')
      expect(screen.getByText('policy-engine')).toBeTruthy()
      expect(screen.queryByText('cardvault-agent')).toBeNull()
    })

    it('offers the outcomes a CI run can have, not only the ones these rows happen to carry', async () => {
      // Every loaded row passed, while the run behind them recorded 14 failures
      // and an error. Chips derived from the array would quietly agree the
      // pipeline is green; a `fail 0` chip is what makes the sample visible.
      renderPage()
      expect(screen.getByTestId('ci-filter-fail').textContent).toContain('0')
      expect(screen.getByTestId('ci-filter-pass').textContent).toContain('8')
      expect(screen.getByTestId('ci-filter-error')).toBeTruthy()
      expect(screen.getByTestId('ci-filter-skip')).toBeTruthy()
    })

    it('announces which chip is in force and tints the selected one from a token', async () => {
      renderPage()
      const all = screen.getByTestId('agent-filter-all')
      const pending = screen.getByTestId('agent-filter-pending')
      expect(all.getAttribute('aria-pressed')).toBe('true')
      expect(pending.getAttribute('aria-pressed')).toBe('false')
      expect(all.style.background).toContain('var(--cyan)')
      expect(all.style.background).not.toMatch(/rgba?\(/)

      await userEvent.click(pending)
      expect(pending.getAttribute('aria-pressed')).toBe('true')
      expect(all.getAttribute('aria-pressed')).toBe('false')
    })
  })

  // ── The empty branch ──────────────────────────────────────────────────────
  describe('a filter that matches nothing can always be undone', () => {
    it.each([
      ['netassert', 'netserts', 'dashboard-to-api-allowed'],
      ['ci', 'ci-results', 'bats-static-contracts'],
      ['agent', 'agent-tests', 'policy-engine'],
    ])('%s: shows an empty state and keeps the controls that caused it', async (prefix, tableId, sampleRow) => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')

      await userEvent.type(screen.getByTestId(`${prefix}-search`), 'zzzz-no-such-row')
      const empty = screen.getByTestId(`${tableId}-empty`)
      expect(empty.textContent).toContain('Nothing matches this filter')
      // The bug the `toolbar` prop exists to prevent: a hand-rolled ternary
      // unmounts the search box along with the table, leaving no way back
      // short of a reload.
      expect(screen.getByTestId(`${prefix}-search`)).toBeTruthy()

      const clear = screen.getByRole('button', { name: 'Clear filters' })
      expect(within(screen.getByTestId(`${tableId}-toolbar`)).getByTestId(`${prefix}-clear`)).toBe(clear)
      await userEvent.click(clear)

      expect(screen.queryByTestId(`${tableId}-empty`)).toBeNull()
      expect(screen.getAllByText(sampleRow).length).toBeGreaterThan(0)
    })

    it('offers no clear control while nothing is being narrowed', async () => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      expect(screen.queryByRole('button', { name: 'Clear filters' })).toBeNull()
    })

    it('says an empty suite is an absence of evidence, not a filter that matched nothing', async () => {
      listMock.mockResolvedValue({ tests: [], scanStatus: 'never-run' })
      renderPage()
      await screen.findByText('No scan has been run yet')

      const empty = screen.getByTestId('netserts-empty')
      // Blaming an untouched filter for an empty suite would send the reader
      // to clear a control they never used.
      expect(empty.textContent).toContain('No assertions were returned')
      expect(empty.textContent).toContain('nothing on this page has been observed')
      expect(empty.textContent).not.toContain('Nothing matches this filter')
    })
  })

  // ── Tooltips ──────────────────────────────────────────────────────────────
  describe('every explanation is reachable by its accessible name', () => {
    it.each([
      ['netserts-help-description', 'What Direction means', /arrow is an assertion that the connection must succeed/i],
      ['netserts-help-targetPort', 'What Port means', /TCP port on the destination/i],
      ['netserts-help-expectedExit', 'What Expected means', /only an allow assertion against the same destination/i],
      ['netserts-help-result', 'What Result means', /Only pass and fail are observations/i],
      ['netserts-help-lastRun', 'What Last Run means', /verdict predates it/i],
      ['ci-results-help-result', 'What Result means', /sample of 259 results/i],
      ['agent-tests-help-status', 'What Status means', /has not reported this cycle/i],
      ['agent-tests-help-testsRun', 'What Tests means', /absent from both figures/i],
    ])('%s is named %s and opens on focus', async (testId, name, body) => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      const hint = screen.getByTestId(testId)
      expect(hint).toHaveAccessibleName(name)
      await userEvent.click(hint) // focus opens it, as does hover
      expect(screen.getByRole('tooltip').textContent).toMatch(body)
    })

    // KNOWN LIMITATION, pinned rather than tolerated silently. DataTable
    // derives a column hint's accessible name from the column label
    // (`What ${col.label} means`) with no way to override it, and two tables
    // on this page each have a column honestly labelled "Result". A sighted
    // reader disambiguates by position; someone navigating a button list or
    // driving by voice hears the same name twice. The fix belongs in
    // DataTable — a `helpLabel` beside `help` — not in a renamed column that
    // says something other than what the field is.
    it('has two hints sharing a name, which only DataTable can fix', async () => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      expect(screen.getAllByRole('button', { name: 'What Result means' })).toHaveLength(2)
    })

    it('names the row hint after the test it explains, so it can be spoken', async () => {
      renderPage()
      await screen.findByText('agents-to-postgresql-denied')
      // WCAG 2.5.3: the accessible name contains the label a reader can see.
      const hint = screen.getByRole('button', { name: 'What the agents-to-postgresql-denied result means' })
      expect(hint).toBe(screen.getByTestId('netassert-verdict-hint-agents-to-postgresql-denied'))
    })

    it('discloses on the CI table that eight green rows are a sample of a run that was not green', async () => {
      renderPage()
      await userEvent.click(screen.getByRole('button', { name: 'What the CI result counts cover' }))
      const tip = screen.getByRole('tooltip').textContent ?? ''
      expect(tip).toContain('only the 8 rows loaded here')
      expect(tip).toContain('14 fail')
    })

    it('discloses that the suite badge counts unobserved rows as not-passing', async () => {
      renderPage()
      await screen.findByText('dashboard-to-api-allowed')
      await userEvent.click(screen.getByRole('button', { name: 'What the suite badge means' }))
      expect(screen.getByRole('tooltip').textContent).toMatch(/produced no verdict at all/i)
    })

  })

  // ── The distinction this page exists to keep ──────────────────────────────
  //
  // `nc` exits non-zero for a dropped packet, an unresolvable host, a missing
  // binary and a dead container alike; NetworkPolicy is not enforced at pod
  // start; and a denial with no positive control cannot tell "correctly
  // blocked" from "nothing was listening". The server is careful about this —
  // it emits pass/fail only where netassert printed a TAP line — so the page
  // must not flatten what it was handed.
  describe('a probe that never reported is not a failure', () => {
    it('classifies the five result values into verdicts and silences', () => {
      expect(verdictClass('pass')).toBe('observed')
      expect(verdictClass('fail')).toBe('observed')
      expect(verdictClass('running')).toBe('in-flight')
      expect(verdictClass('pending')).toBe('not-observed')
      expect(verdictClass('error')).toBe('unavailable')
    })

    it('renders an unavailable result differently from a negative one', async () => {
      listMock.mockResolvedValue({
        tests: [
          test_({
            name: 'policy-breached',
            expectedExit: 1,
            result: 'fail',
            evidence: 'netassert TAP: not ok - policy-breached',
          }),
          test_({
            name: 'probe-never-reported',
            expectedExit: 1,
            result: 'error',
            evidence: 'scan finished but produced no result for this test — check Job logs',
          }),
        ],
        scanStatus: 'complete',
      })
      renderPage()
      await screen.findByText('probe-never-reported')

      // Words: one is a verdict, the other is the absence of one.
      expect(screen.getByTestId('netassert-verdict-class-policy-breached').textContent).toBe('observed')
      expect(screen.getByTestId('netassert-verdict-class-probe-never-reported').textContent).toBe('no verdict')

      // Colour: DashKit's Pill painted `error` and `fail` the same red, so a
      // probe that could not run looked exactly like a policy that had been
      // breached. StatusBadge maps `fail` to the error token and has no
      // `error` key, so the silence takes the neutral fallback.
      const failed = screen.getByTestId('netassert-result-policy-breached')
      const unavailable = screen.getByTestId('netassert-result-probe-never-reported')
      expect(failed.style.color).toBe('var(--error)')
      expect(unavailable.style.color).toBe('var(--muted)')
      expect(unavailable.style.color).not.toBe(failed.style.color)
    })

    it('separates a scan still running from one that produced nothing', async () => {
      listMock.mockResolvedValue({
        tests: [
          test_({ name: 'still-going', result: 'running', evidence: 'scan in progress' }),
          test_({ name: 'never-scanned', result: 'pending', evidence: 'no scan has been run yet' }),
        ],
        scanStatus: 'running',
      })
      renderPage()
      await screen.findByText('never-scanned')
      expect(screen.getByTestId('netassert-verdict-class-still-going').textContent).toBe('in flight')
      expect(screen.getByTestId('netassert-verdict-class-never-scanned').textContent).toBe('not observed')
    })

    it('tells a reader what an unavailable row does and does not say', () => {
      const narrative = verdictNarrative(
        test_({ result: 'error', evidence: 'pod netassert-run-xyz: ImagePullBackOff' }),
      )
      expect(narrative).toContain('No verdict')
      expect(narrative).toContain('ImagePullBackOff')
      expect(narrative).toContain('not a denial and not a pass')
    })

    it('refuses to let a passing deny assertion read as proof the path was ever open', () => {
      const narrative = verdictNarrative(test_({ expectedExit: 1, result: 'pass' }))
      // The three ways this project has been burned, named where they apply.
      expect(narrative).toContain('a dead listener')
      expect(narrative).toContain('policy not yet programmed on a just-started pod')
      expect(narrative).toContain('only an allow assertion against the same destination')
    })

    it('calls a breached deny assertion what it is: the one verdict needing no corroboration', () => {
      const narrative = verdictNarrative(test_({ expectedExit: 1, result: 'fail' }))
      expect(narrative).toContain('completed connection is positive evidence')
    })

    it('does not colour an intent as though it were an outcome', async () => {
      renderPage()
      await screen.findByText('agents-to-postgresql-denied')
      // `blocked` was red, which painted a deny rule working exactly as
      // designed in the colour of an alarm.
      const deny = screen.getByTestId('netassert-expected-agents-to-postgresql-denied')
      const allow = screen.getByTestId('netassert-expected-dashboard-to-api-allowed')
      expect(deny.textContent).toBe('deny')
      expect(allow.textContent).toBe('allow')
      expect(deny.style.color).toBe('var(--muted)')
      expect(allow.style.color).toBe('var(--muted)')
    })

    it('quotes the row\'s own evidence rather than paraphrasing it', () => {
      const narrative = verdictNarrative(
        test_({ result: 'pass', evidence: 'netassert TAP: ok - dashboard-to-api-allowed' }),
      )
      expect(narrative).toContain('netassert TAP: ok - dashboard-to-api-allowed')
    })

    it('says so plainly when a row carries no evidence at all', () => {
      expect(verdictNarrative(test_({ result: 'error', evidence: '' }))).toContain('no evidence was recorded')
    })
  })
})
