/**
 * Tests for SignalsPage: the realtime signals and decisions review surface.
 *
 * The page's reason to exist is that a human can look at a decision and form
 * an objective judgement about it, so the tests that matter most are the ones
 * about the review control: that a verdict reaches the API, that it is shown
 * back with its reviewer and time, and that a 409 or a 403 is reported without
 * taking the rest of the page down with it.
 *
 * recharts is mocked, as it is on every other charting page here: jsdom has no
 * layout engine, so ResponsiveContainer measures zero and renders nothing. The
 * mock keeps the series elements in the DOM so "one series per layer" is
 * actually assertable.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, act, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import type { SignalObservation } from '../api/weaveApi'
import type { PolicyDecision, PolicyFinding, IngestRateBucket } from '../api/policyApi'

const { getAccessTokenSilently, mockPolicyApi, mockWeaveApi, mockIsDemoMode, streamHandles } =
  vi.hoisted(() => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
    mockPolicyApi: {
      getFindings: vi.fn(),
      getDecisions: vi.fn(),
      getRates: vi.fn(),
      reviewDecision: vi.fn(),
    },
    mockWeaveApi: {
      getObservations: vi.fn(),
      createObservationsStream: vi.fn(),
    },
    mockIsDemoMode: vi.fn().mockReturnValue(false),
    streamHandles: [] as Array<{
      disconnect: ReturnType<typeof vi.fn>
      push: (o: SignalObservation) => void
    }>,
  }))

vi.mock('../auth/oidc', () => ({ useAuth0: () => ({ getAccessTokenSilently }) }))
vi.mock('../api/demoMode', () => ({ isDemoMode: mockIsDemoMode }))
vi.mock('../api/weaveApi', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/weaveApi')>()
  return { ...actual, weaveApi: mockWeaveApi }
})
vi.mock('../api/policyApi', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/policyApi')>()
  return { ...actual, policyApi: mockPolicyApi }
})
vi.mock('recharts', () => {
  const Pass = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>
  return {
    ResponsiveContainer: Pass,
    BarChart: ({ children }: { children?: React.ReactNode }) => (
      <div data-testid="bar-chart">{children}</div>
    ),
    Bar: ({ dataKey }: { dataKey: string }) => <div data-testid={`rate-series-${dataKey}`} />,
    XAxis: () => null,
    YAxis: () => null,
    CartesianGrid: () => null,
    Tooltip: () => null,
    Legend: () => null,
  }
})

import SignalsPage from './SignalsPage'

// ── Fixtures ───────────────────────────────────────────────────────────────

const RAW_PAYLOAD_MARKER = 'SECRET-PAYLOAD-SHOULD-NEVER-RENDER'

/**
 * An observation carrying a `raw` field alongside the projected description.
 *
 * The page is only ever allowed to show the projection. The field is typed as
 * an extra because the real wire body may carry more than the client's type
 * describes, which is exactly the situation this guard exists for.
 */
const observations: Array<SignalObservation & { raw?: string }> = [
  {
    id: 'obs-1',
    timestamp: '2026-10-05T09:04:00Z',
    layer: 'network_egress',
    fidelity: 'strong',
    source: 'sentinel.ebpf.socket_trace',
    confidence: 0.82,
    actor_hint: 'actor-7f3a',
    raw_evidence_ref: 'blob://evidence/obs-1',
    description: 'Egress to an unapproved destination was denied',
    labels: { destination: 'api.unknown-llm.example', raw_body: RAW_PAYLOAD_MARKER },
    raw: RAW_PAYLOAD_MARKER,
  },
  {
    id: 'obs-2',
    timestamp: '2026-10-05T09:02:00Z',
    layer: 'endpoint_host',
    fidelity: 'definitive',
    source: 'stun-sentinel',
    confidence: 0.95,
    actor_hint: 'actor-2c91',
    raw_evidence_ref: 'blob://evidence/obs-2',
    description: 'Read of a sensitive path under /etc was blocked',
    labels: { path_prefix: '/etc' },
  },
]

const findings: PolicyFinding[] = [
  {
    id: 'fnd-1',
    timestamp: '2026-10-05T09:04:01Z',
    tenant_id: 'tenant-demo',
    actor: 'actor-7f3a',
    layer: 'network_egress',
    source_observation_id: 'obs-1',
    rule_id: 'egress.unapproved_destination',
    bundle_id: 'slaws-baseline',
    bundle_version: '0.4.2',
    severity: 'high',
    mode: 'enforce',
    labels: { verdict: 'deny' },
  },
  {
    id: 'fnd-2',
    timestamp: '2026-10-05T09:02:01Z',
    tenant_id: 'tenant-demo',
    actor: 'actor-2c91',
    layer: 'endpoint_host',
    source_observation_id: 'obs-2',
    rule_id: 'host.sensitive_file_access',
    bundle_id: 'slaws-baseline',
    bundle_version: '0.4.2',
    severity: 'critical',
    mode: 'enforce',
    labels: null,
  },
]

const decisions: PolicyDecision[] = [
  {
    id: 'dec-1',
    timestamp: '2026-10-05T09:04:02Z',
    tenant_id: 'tenant-demo',
    actor: 'actor-7f3a',
    window_id: 'win-5m-0',
    rule_id: 'egress.unapproved_destination',
    bundle_id: 'slaws-baseline',
    bundle_version: '0.4.2',
    severity: 'high',
    mode: 'enforce',
    count: 3,
    finding_ids: ['fnd-1'],
    review: null,
  },
  {
    id: 'dec-2',
    timestamp: '2026-10-05T09:02:02Z',
    tenant_id: 'tenant-demo',
    actor: 'actor-2c91',
    window_id: 'win-5m-1',
    rule_id: 'host.sensitive_file_access',
    bundle_id: 'slaws-baseline',
    bundle_version: '0.4.2',
    severity: 'critical',
    mode: 'enforce',
    count: 1,
    finding_ids: ['fnd-2'],
    review: {
      id: 'rev-9',
      decision_id: 'dec-2',
      verdict: 'true_positive',
      note: 'Confirmed by the host owner, container was compromised.',
      reviewer: 'operator@signalloom.local',
      reviewed_at: '2026-10-05T09:03:00Z',
    },
  },
]

const rates: IngestRateBucket[] = [
  { bucket_start: '2026-10-05T09:00:00Z', layer: 'network_egress', source: 'sentinel.ebpf.socket_trace', count: 4 },
  { bucket_start: '2026-10-05T09:00:00Z', layer: 'endpoint_host', source: 'stun-sentinel', count: 2 },
  { bucket_start: '2026-10-05T09:01:00Z', layer: 'network_egress', source: 'sentinel.ebpf.socket_trace', count: 6 },
  { bucket_start: '2026-10-05T09:01:00Z', layer: 'cloud_control_plane', source: 'aws-cloudtrail', count: 1 },
]

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/signals']}>
      <SignalsPage />
    </MemoryRouter>,
  )
}

/** Wait for the first load to settle. */
async function renderLoaded() {
  const r = renderPage()
  await waitFor(() => expect(screen.getByTestId('signals-page')).toBeInTheDocument())
  return r
}

async function openDecisions(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByTestId('signals-tab-decisions'))
  await waitFor(() => expect(screen.getAllByTestId('decision-card').length).toBeGreaterThan(0))
}

describe('SignalsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    streamHandles.length = 0
    mockIsDemoMode.mockReturnValue(false)
    mockWeaveApi.getObservations.mockResolvedValue(observations)
    mockWeaveApi.createObservationsStream.mockImplementation(
      (_token: string, _params: unknown, onMessage?: (o: SignalObservation) => void) => {
        const handle = {
          disconnect: vi.fn(),
          push: (o: SignalObservation) => onMessage?.(o),
        }
        streamHandles.push(handle)
        return handle
      },
    )
    mockPolicyApi.getFindings.mockResolvedValue(findings)
    mockPolicyApi.getDecisions.mockResolvedValue(decisions)
    mockPolicyApi.getRates.mockResolvedValue(rates)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // ── Shell ────────────────────────────────────────────────────────────────

  it('renders the page with both tabs and the Live tab selected', async () => {
    await renderLoaded()
    expect(screen.getByTestId('signals-tab-live')).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByTestId('signals-tab-decisions')).toHaveAttribute('aria-selected', 'false')
  })

  it('shows a loading state before the first load settles', async () => {
    let release: (v: PolicyFinding[]) => void = () => undefined
    mockPolicyApi.getFindings.mockReturnValue(new Promise((res) => { release = res }))
    renderPage()
    expect(await screen.findByTestId('signals-load-state')).toBeInTheDocument()
    act(() => release(findings))
    await waitFor(() => expect(screen.getByTestId('signals-page')).toBeInTheDocument())
  })

  it('defaults to the 10m window', async () => {
    await renderLoaded()
    expect(screen.getByTestId('window-btn-10m')).toHaveAttribute('aria-pressed', 'true')
    expect(mockPolicyApi.getFindings).toHaveBeenCalledWith('test-token', expect.objectContaining({ window: '10m' }))
  })

  // ── Window selector ──────────────────────────────────────────────────────

  it('changes every query when the window changes', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    mockPolicyApi.getFindings.mockClear()
    mockPolicyApi.getDecisions.mockClear()
    mockPolicyApi.getRates.mockClear()

    await user.click(screen.getByTestId('window-btn-90m'))

    await waitFor(() => {
      expect(mockPolicyApi.getFindings).toHaveBeenCalledWith('test-token', expect.objectContaining({ window: '90m' }))
      expect(mockPolicyApi.getDecisions).toHaveBeenCalledWith('test-token', expect.objectContaining({ window: '90m' }))
      expect(mockPolicyApi.getRates).toHaveBeenCalledWith('test-token', expect.objectContaining({ window: '90m' }))
    })
    expect(screen.getByTestId('window-btn-90m')).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByTestId('window-btn-10m')).toHaveAttribute('aria-pressed', 'false')
  })

  it('uses a one minute bucket for short windows and five for long ones', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    expect(mockPolicyApi.getRates).toHaveBeenCalledWith('test-token', { window: '10m', bucket: '1m' })
    await user.click(screen.getByTestId('window-btn-90m'))
    await waitFor(() =>
      expect(mockPolicyApi.getRates).toHaveBeenCalledWith('test-token', { window: '90m', bucket: '5m' }),
    )
  })

  it('shares the window across both tabs', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await user.click(screen.getByTestId('window-btn-30m'))
    await openDecisions(user)
    expect(screen.getByTestId('window-btn-30m')).toHaveAttribute('aria-pressed', 'true')
  })

  // ── Live tab ─────────────────────────────────────────────────────────────

  it('renders one chart series per layer present in the rates', async () => {
    await renderLoaded()
    expect(screen.getByTestId('rate-series-network_egress')).toBeInTheDocument()
    expect(screen.getByTestId('rate-series-endpoint_host')).toBeInTheDocument()
    expect(screen.getByTestId('rate-series-cloud_control_plane')).toBeInTheDocument()
    expect(screen.getAllByTestId(/^rate-series-/)).toHaveLength(3)
  })

  it('renders a per-source table with a count and a last-seen time', async () => {
    await renderLoaded()
    const row = screen.getByTestId('source-row-sentinel.ebpf.socket_trace')
    expect(within(row).getByTestId('source-count')).toHaveTextContent('10')
    expect(within(row).getByTestId('source-last-seen')).not.toBeEmptyDOMElement()
  })

  it('renders the live observation feed with layer, source, actor and labels', async () => {
    await renderLoaded()
    const items = screen.getAllByTestId('observation-item')
    expect(items).toHaveLength(2)
    expect(within(items[0]).getByTestId('observation-layer')).toHaveTextContent('Network/Egress')
    expect(within(items[0]).getByTestId('observation-source')).toHaveTextContent('sentinel.ebpf.socket_trace')
    expect(within(items[0]).getByTestId('observation-actor')).toHaveTextContent('actor-7f3a')
    expect(
      within(items[0]).getByText('Egress to an unapproved destination was denied'),
    ).toBeInTheDocument()
    expect(within(items[0]).getByTestId('label-chip-destination')).toHaveTextContent(
      'api.unknown-llm.example',
    )
  })

  it('never renders a raw payload field or a raw evidence reference', async () => {
    await renderLoaded()
    expect(screen.queryByText(new RegExp(RAW_PAYLOAD_MARKER))).not.toBeInTheDocument()
    expect(document.body.textContent).not.toContain(RAW_PAYLOAD_MARKER)
    expect(document.body.textContent).not.toContain('blob://evidence/obs-1')
    expect(screen.queryByTestId('label-chip-raw_body')).not.toBeInTheDocument()
  })

  it('lists findings with rule, severity, bundle version and a link to the observation', async () => {
    await renderLoaded()
    const rows = screen.getAllByTestId('finding-row')
    expect(rows).toHaveLength(2)
    expect(within(rows[0]).getByTestId('finding-rule')).toHaveTextContent('egress.unapproved_destination')
    expect(within(rows[0]).getByTestId('finding-severity')).toHaveTextContent('high')
    expect(within(rows[0]).getByTestId('finding-bundle')).toHaveTextContent('0.4.2')
    expect(within(rows[0]).getByTestId('finding-observation-link')).toHaveAttribute(
      'href',
      '#observation-obs-1',
    )
  })

  // ── Stream ───────────────────────────────────────────────────────────────

  it('opens exactly one stream and prepends a live arrival', async () => {
    await renderLoaded()
    expect(streamHandles).toHaveLength(1)
    act(() => {
      streamHandles[0].push({
        ...observations[1],
        id: 'obs-live',
        description: 'A brand new arrival over the stream',
      })
    })
    await waitFor(() => {
      const items = screen.getAllByTestId('observation-item')
      expect(items).toHaveLength(3)
      expect(within(items[0]).getByText('A brand new arrival over the stream')).toBeInTheDocument()
    })
  })

  it('never holds more than one open stream across a window change', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await user.click(screen.getByTestId('window-btn-30m'))
    await waitFor(() => expect(streamHandles.length).toBeGreaterThan(1))
    const open = streamHandles.filter((h) => h.disconnect.mock.calls.length === 0)
    expect(open).toHaveLength(1)
  })

  it('pause disconnects the stream and stops updates; resume reopens it', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    const first = streamHandles[0]

    await user.click(screen.getByTestId('stream-toggle'))
    await waitFor(() => expect(first.disconnect).toHaveBeenCalled())
    expect(screen.getByTestId('stream-status')).toHaveTextContent('Paused')

    act(() => {
      first.push({ ...observations[1], id: 'obs-while-paused', description: 'Arrived while paused' })
    })
    expect(screen.queryByText('Arrived while paused')).not.toBeInTheDocument()
    expect(screen.getAllByTestId('observation-item')).toHaveLength(2)

    await user.click(screen.getByTestId('stream-toggle'))
    await waitFor(() => expect(screen.getByTestId('stream-status')).toHaveTextContent('Live'))
    const open = streamHandles.filter((h) => h.disconnect.mock.calls.length === 0)
    expect(open).toHaveLength(1)
  })

  it('refetches on the ten second interval', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('signals-page')).toBeInTheDocument())
    const before = mockPolicyApi.getDecisions.mock.calls.length
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000)
    })
    expect(mockPolicyApi.getDecisions.mock.calls.length).toBeGreaterThan(before)
  })

  it('stops refetching while paused', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('signals-page')).toBeInTheDocument())
    await act(async () => {
      screen.getByTestId('stream-toggle').click()
    })
    const before = mockPolicyApi.getDecisions.mock.calls.length
    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000)
    })
    expect(mockPolicyApi.getDecisions.mock.calls.length).toBe(before)
  })

  // ── Decisions tab ────────────────────────────────────────────────────────

  it('renders a decision card with rule, window, count, actor, severity and mode', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    expect(within(card).getByTestId('decision-rule')).toHaveTextContent('egress.unapproved_destination')
    expect(within(card).getByTestId('decision-window')).toHaveTextContent('win-5m-0')
    expect(within(card).getByTestId('decision-count')).toHaveTextContent('3')
    expect(within(card).getByTestId('decision-actor')).toHaveTextContent('actor-7f3a')
    expect(within(card).getByTestId('decision-severity')).toHaveTextContent('high')
    expect(within(card).getByTestId('decision-mode')).toHaveTextContent('enforce')
  })

  it('expands the contributing findings on demand only', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    expect(within(card).queryByTestId('decision-findings')).not.toBeInTheDocument()
    await user.click(within(card).getByTestId('decision-findings-toggle'))
    const expanded = within(card).getByTestId('decision-findings')
    expect(within(expanded).getByText('egress.unapproved_destination')).toBeInTheDocument()
  })

  it('shows the stored verdict with its reviewer and time for a reviewed decision', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-2')
    expect(within(card).getByTestId('decision-verdict-badge')).toHaveTextContent('True positive')
    expect(within(card).getByTestId('decision-reviewer')).toHaveTextContent('operator@signalloom.local')
    expect(within(card).queryByTestId('review-submit')).not.toBeInTheDocument()
  })

  it('requires a note of at least ten characters before it will submit', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    await user.click(within(card).getByTestId('verdict-btn-true_positive'))
    const submit = within(card).getByTestId('review-submit')
    expect(submit).toBeDisabled()
    await user.type(within(card).getByTestId('review-note'), 'too short')
    expect(submit).toBeDisabled()
    await user.type(within(card).getByTestId('review-note'), ' now it is long enough')
    expect(submit).toBeEnabled()
  })

  it('requires a verdict before it will submit', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    await user.type(within(card).getByTestId('review-note'), 'a perfectly long enough note')
    expect(within(card).getByTestId('review-submit')).toBeDisabled()
  })

  it('posts the review, shows the badge optimistically, then the persisted record', async () => {
    const user = userEvent.setup()
    let release: (v: unknown) => void = () => undefined
    mockPolicyApi.reviewDecision.mockReturnValue(new Promise((res) => { release = res }))
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')

    await user.click(within(card).getByTestId('verdict-btn-false_positive'))
    await user.type(within(card).getByTestId('review-note'), 'Known backup job, owner confirmed.')
    await user.click(within(card).getByTestId('review-submit'))

    // Optimistic: the badge is there before the POST resolves.
    await waitFor(() =>
      expect(within(card).getByTestId('decision-verdict-badge')).toHaveTextContent('False positive'),
    )
    expect(within(card).getByTestId('decision-verdict-badge')).toHaveAttribute('data-pending', 'true')
    expect(mockPolicyApi.reviewDecision).toHaveBeenCalledWith('test-token', 'dec-1', {
      verdict: 'false_positive',
      note: 'Known backup job, owner confirmed.',
    })

    act(() =>
      release({
        id: 'rev-new',
        decision_id: 'dec-1',
        verdict: 'false_positive',
        note: 'Known backup job, owner confirmed.',
        reviewer: 'operator@signalloom.local',
        reviewed_at: '2026-10-05T09:10:00Z',
      }),
    )

    await waitFor(() =>
      expect(within(card).getByTestId('decision-verdict-badge')).toHaveAttribute('data-pending', 'false'),
    )
    expect(within(card).getByTestId('decision-reviewer')).toHaveTextContent('operator@signalloom.local')
  })

  it('reports a 409 as already recorded and rolls the optimistic badge back', async () => {
    const user = userEvent.setup()
    mockPolicyApi.reviewDecision.mockRejectedValue({ response: { status: 409 } })
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    await user.click(within(card).getByTestId('verdict-btn-needs_info'))
    await user.type(within(card).getByTestId('review-note'), 'Need the host owner to confirm.')
    await user.click(within(card).getByTestId('review-submit'))

    await waitFor(() =>
      expect(within(card).getByTestId('review-error')).toHaveTextContent('already recorded'),
    )
    expect(within(card).queryByTestId('decision-verdict-badge')).not.toBeInTheDocument()
    // The rest of the page is untouched by one failed review.
    expect(screen.getByTestId('decision-card-dec-2')).toBeInTheDocument()
    expect(screen.getByTestId('signals-tab-live')).toBeInTheDocument()
  })

  it('reports a 403 as a key that cannot review', async () => {
    const user = userEvent.setup()
    mockPolicyApi.reviewDecision.mockRejectedValue({ response: { status: 403 } })
    await renderLoaded()
    await openDecisions(user)
    const card = screen.getByTestId('decision-card-dec-1')
    await user.click(within(card).getByTestId('verdict-btn-true_positive'))
    await user.type(within(card).getByTestId('review-note'), 'This one is a genuine hit.')
    await user.click(within(card).getByTestId('review-submit'))

    await waitFor(() =>
      expect(within(card).getByTestId('review-error')).toHaveTextContent('cannot review'),
    )
    expect(screen.getByTestId('decision-card-dec-2')).toBeInTheDocument()
  })

  it('filters to unreviewed decisions only', async () => {
    const user = userEvent.setup()
    await renderLoaded()
    await openDecisions(user)
    expect(screen.getAllByTestId('decision-card')).toHaveLength(2)
    await user.click(screen.getByTestId('unreviewed-only-toggle'))
    await waitFor(() => expect(screen.getAllByTestId('decision-card')).toHaveLength(1))
    expect(screen.getByTestId('decision-card-dec-1')).toBeInTheDocument()
    expect(screen.queryByTestId('decision-card-dec-2')).not.toBeInTheDocument()
  })

  // ── Empty, error and demo states ─────────────────────────────────────────

  it('shows an empty state when the window holds nothing', async () => {
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockPolicyApi.getFindings.mockResolvedValue([])
    mockPolicyApi.getDecisions.mockResolvedValue([])
    mockPolicyApi.getRates.mockResolvedValue([])
    await renderLoaded()
    expect(screen.getByTestId('signals-empty')).toBeInTheDocument()
  })

  it('shows an empty state on the Decisions tab when nothing is to be judged', async () => {
    const user = userEvent.setup()
    mockPolicyApi.getDecisions.mockResolvedValue([])
    await renderLoaded()
    await user.click(screen.getByTestId('signals-tab-decisions'))
    await waitFor(() => expect(screen.getByTestId('decisions-empty')).toBeInTheDocument())
  })

  it('names the gateway when it is unreachable', async () => {
    mockPolicyApi.getFindings.mockRejectedValue(new Error('Network Error'))
    renderPage()
    await waitFor(() => expect(screen.getByTestId('signals-unreachable')).toBeInTheDocument())
    expect(screen.getByTestId('signals-unreachable')).toHaveTextContent('policy engine')
  })

  it('shows an ordinary error state for a failure that is not a connection failure', async () => {
    mockPolicyApi.getFindings.mockRejectedValue(new Error('Request failed with status code 422'))
    renderPage()
    await waitFor(() => expect(screen.getByTestId('signals-load-state')).toHaveAttribute('data-status', 'error'))
    expect(screen.queryByTestId('signals-unreachable')).not.toBeInTheDocument()
  })

  it('does not claim the service is down while in demo mode', async () => {
    mockIsDemoMode.mockReturnValue(true)
    mockPolicyApi.getFindings.mockRejectedValue(new Error('Network Error'))
    renderPage()
    await waitFor(() => expect(screen.getByTestId('signals-load-state')).toBeInTheDocument())
    expect(screen.queryByTestId('signals-unreachable')).not.toBeInTheDocument()
  })

  it('marks the data as fixture data in demo mode', async () => {
    mockIsDemoMode.mockReturnValue(true)
    await renderLoaded()
    expect(screen.getByTestId('signals-demo-notice')).toBeInTheDocument()
  })

  it('does not open a stream in demo mode', async () => {
    mockIsDemoMode.mockReturnValue(true)
    await renderLoaded()
    expect(mockWeaveApi.createObservationsStream).not.toHaveBeenCalled()
    expect(screen.getByTestId('stream-status')).toHaveTextContent('Fixtures')
  })

  it('filters live signal feed when clicking a layer in the ingest rate chart and resets on clear', async () => {
    const user = userEvent.setup()
    await renderLoaded()

    // Click network_egress layer chip on chart
    const layerChip = screen.getByTestId('rate-layer-chip-network_egress')
    await user.click(layerChip)

    // Indicator renders
    await waitFor(() => {
      expect(screen.getByTestId('selected-layer-indicator')).toBeInTheDocument()
      expect(screen.getByTestId('selected-layer-indicator')).toHaveTextContent('Network/Egress')
    })

    // Fetch was called with layer parameter
    expect(mockWeaveApi.getObservations).toHaveBeenCalledWith(
      'test-token',
      expect.objectContaining({ layer: 'network_egress' })
    )

    // Reset filter
    const clearBtn = screen.getByTestId('clear-layer-filter-btn')
    await user.click(clearBtn)
    await waitFor(() => {
      expect(screen.queryByTestId('selected-layer-indicator')).not.toBeInTheDocument()
    })
  })

  it('filters live signal feed using Super DataTable controls and sentinel noise toggle', async () => {
    const user = userEvent.setup()
    await renderLoaded()

    // Initially both observations shown
    expect(screen.getAllByTestId('observation-item')).toHaveLength(2)

    // Toggle exclude sentinel noise (both obs-1 socket_trace and obs-2 stun-sentinel are filtered out)
    const sentinelToggle = screen.getByTestId('feed-exclude-sentinel-toggle')
    await user.click(sentinelToggle)

    // Both sentinel events (including stun-sentinel) are filtered out of the feed
    await waitFor(() => {
      expect(screen.queryAllByTestId('observation-item')).toHaveLength(0)
    })

    // Toggle off to restore observations
    await user.click(sentinelToggle)
    await waitFor(() => {
      expect(screen.getAllByTestId('observation-item')).toHaveLength(2)
    })

    // Search input
    const searchInput = screen.getByTestId('feed-toolbar-search')
    await user.clear(searchInput)
    await user.type(searchInput, 'stun-sentinel')
    expect(screen.getAllByTestId('observation-item')).toHaveLength(1)

    // Clear filters
    const clearBtn = screen.getByTestId('feed-toolbar-clear')
    await user.click(clearBtn)
    await waitFor(() => {
      expect(screen.getAllByTestId('observation-item')).toHaveLength(2)
    })
  })

  it('initializes filters and window from URL deep-link search parameters', async () => {
    render(
      <MemoryRouter initialEntries={['/signals?layer=endpoint_host&window=30m&excludeSentinel=true']}>
        <SignalsPage />
      </MemoryRouter>
    )

    await waitFor(() => expect(screen.getByTestId('signals-page')).toBeInTheDocument())

    expect(screen.getByTestId('selected-layer-indicator')).toBeInTheDocument()
    expect(screen.getByTestId('selected-layer-indicator')).toHaveTextContent('Endpoint/Host')
    expect(screen.getByTestId('feed-exclude-sentinel-toggle')).toHaveAttribute('aria-pressed', 'true')
  })
})
