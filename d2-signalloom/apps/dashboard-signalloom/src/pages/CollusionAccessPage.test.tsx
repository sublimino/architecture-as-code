/**
 * Tests for the Collusion & Access page.
 *
 * The page used to render four tables of hardcoded content with no fetch call
 * at all — demo and live were visually identical by construction. It now has
 * a run selector (aggregate + per-run drill-down) backed by two different data
 * sources: fixed offline fixtures in demo mode, and the real KubeSec-AFM API
 * in live mode. The load-bearing assertions here are:
 *
 *  1. demo mode renders deterministically with no network calls;
 *  2. the run selector lists real runs and drilling into one changes content;
 *  3. live mode issues real HTTP calls and the data it renders is
 *     *empirically different* from the demo fixture — the concrete proof that
 *     the "demo and live return identical data" bug is fixed;
 *  4. a live-mode failure renders a visible error and never falls back to
 *     demo content, per the non-negotiable in WORKTREE-INTEGRATION.md;
 *  5. the selector offers a CLUSTER entry per cluster, not only job history —
 *     the gap that made a cluster visible on the KubeSec-AFM dashboard and
 *     RBAC Explorer unreachable from this page;
 *  6. every claim on the page can be traced to a command, and the demo path
 *     says plainly that nothing was measured rather than dressing a fixture
 *     up as a probe.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import CollusionAccessPage from './CollusionAccessPage'
import { DEMO_RUNS } from '../api/afmDemoFixtures'

const isDemoMode = vi.fn(() => true)
const fetchMock = vi.fn()

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
  subscribeDemoMode: () => () => {},
}))

function renderPage() {
  return render(
    <MemoryRouter>
      <CollusionAccessPage />
    </MemoryRouter>,
  )
}

function response(ok: boolean, body?: unknown): Response {
  return { ok, json: vi.fn().mockResolvedValue(body) } as unknown as Response
}

// ── Live fixtures — deliberately different from the demo fixtures ─────────
// (different cluster name, different subject names, different escalation
// counts) so a passing "divergence" test is not an accident of overlap.

const LIVE_CLUSTERS = [{ id: 'prod', name: 'Prod Live Cluster' }]

const LIVE_JOB = {
  id: 'job-live-1',
  cluster_id: 'prod',
  facts_sha256: 'x',
  params_sha256: 'y',
  status: 'done',
  trigger_source: 'manual',
  created_at: '2026-08-01T10:00:00Z',
  finished_at: '2026-08-01T10:00:05Z',
}

const LIVE_STATUS = {
  has_running: false,
  running_job_id: null,
  last_completed_job_id: 'job-live-1',
  latest_done_at: '2026-08-01T10:00:05Z',
  latest_failed_at: null,
}

const LIVE_ANALYSIS = {
  schema_version: '3.4.0',
  metadata: { subjects: ['sa:prod/api'] },
  single_escalations: [
    {
      subject: 'sa:prod/api',
      escalation_type: 'admin_via_impersonation',
      scope: 'cluster-wide',
      gained_permission: { verb: '*', resource: 'all', namespace: 'cluster' },
      risk: { level: 'high', score: 70 },
      evidence: { shell: [], documents: [] },
      trace: {},
    },
  ],
  group_escalations: [],
}

const LIVE_SHARED_ROLES = {
  cluster: { id: 'prod', name: 'Prod Live Cluster' },
  results: [
    { role: 'ClusterRole/admin', bindings: [], all_subjects: ['sa:prod/api', 'sa:prod/worker'], privileged_subjects: ['sa:prod/api'] },
  ],
}

const LIVE_GUARDS = {
  job_id: 'job-live-1',
  count: 1,
  guards: [
    { name: 'traceguard-prod-single-0', kind: 'single', escalation_index: 0, participants: ['sa:prod/api'], deny_step_indices: [1], would_block: true, yaml: '...' },
  ],
}

interface RouteOverrides {
  clusters?: () => Promise<Response>
  jobs?: () => Promise<Response>
  status?: () => Promise<Response>
  latest?: () => Promise<Response>
  jobResult?: () => Promise<Response>
  sharedRoles?: () => Promise<Response>
  guards?: () => Promise<Response>
}

function routeLiveFetch(overrides: RouteOverrides = {}) {
  fetchMock.mockImplementation((input: RequestInfo | URL) => {
    const url = String(input)
    if (url === '/afm/clusters') {
      return overrides.clusters ? overrides.clusters() : Promise.resolve(response(true, LIVE_CLUSTERS))
    }
    if (url === '/afm/clusters/prod/jobs?limit=10') {
      return overrides.jobs ? overrides.jobs() : Promise.resolve(response(true, [LIVE_JOB]))
    }
    if (url === '/afm/clusters/prod/analysis/status') {
      return overrides.status ? overrides.status() : Promise.resolve(response(true, LIVE_STATUS))
    }
    if (url === '/afm/clusters/prod/analysis/latest') {
      return overrides.latest ? overrides.latest() : Promise.resolve(response(true, LIVE_ANALYSIS))
    }
    if (url === '/afm/jobs/job-live-1/result') {
      return overrides.jobResult ? overrides.jobResult() : Promise.resolve(response(true, LIVE_ANALYSIS))
    }
    if (url === '/afm/clusters/prod/analysis/shared_roles') {
      return overrides.sharedRoles ? overrides.sharedRoles() : Promise.resolve(response(true, LIVE_SHARED_ROLES))
    }
    if (url === '/afm/clusters/prod/analysis/guards') {
      return overrides.guards ? overrides.guards() : Promise.resolve(response(true, LIVE_GUARDS))
    }
    return Promise.reject(new Error(`unexpected fetch: ${url}`))
  })
}

function requestedUrls(): string[] {
  return fetchMock.mock.calls.map(([input]) => String(input))
}

function optionValues(select: HTMLElement): (string | null)[] {
  return within(select).getAllByRole('option').map(o => o.getAttribute('value'))
}

/** Reads a StatCard's numeric value by its label — several stat cards can share a value, so text queries alone are ambiguous. */
function statCardValue(label: string): string {
  const labelNode = screen.getByText(label)
  const card = labelNode.closest('.card')
  if (!card) throw new Error(`StatCard "${label}" is not inside a .card element.`)
  const value = within(card as HTMLElement).getByText(/^\d+$/)
  return value.textContent ?? ''
}

beforeEach(() => {
  vi.clearAllMocks()
  isDemoMode.mockReturnValue(true)
  fetchMock.mockReset()
  Object.defineProperty(globalThis, 'fetch', { configurable: true, writable: true, value: fetchMock })
})

describe('CollusionAccessPage — demo mode', () => {
  it('renders the heading and every section with no network calls', () => {
    renderPage()

    expect(screen.getByRole('heading', { level: 1, name: /Collusion & Access/ })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Privilege Escalation Paths' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Collusion Pairs' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Shared-Role Pivot Points' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Remediation Priorities' })).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('defaults to "All runs (aggregate)" and shows the union of both demo runs', () => {
    renderPage()

    expect(screen.getByTestId('collusion-run-select')).toHaveValue('aggregate')
    // Aggregate = both demo runs' collusion pairs combined (2 + 2 = 4).
    expect(statCardValue('Collusion pairs')).toBe('4')
    expect(screen.getAllByText(/role:flux-reconciler/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/role:secret-reader/).length).toBeGreaterThan(0)
  })

  it('lists both demo runs in the selector, distinguishable by cluster, timestamp and outcome', () => {
    renderPage()

    const select = screen.getByTestId('collusion-run-select')
    const options = within(select).getAllByRole('option').map(o => o.textContent)
    expect(options).toEqual([
      'All runs (aggregate)',
      'Prod GitOps Cluster (EU) · latest analysis',
      'Staging Cluster · latest analysis',
      'Prod GitOps Cluster (EU) · 2026-07-28 09:12 · 2 collusion pairs',
      'Staging Cluster · 2026-07-30 14:47 · 2 collusion pairs',
    ])
  })

  it('drilling into one run narrows the content to that run only', async () => {
    renderPage()

    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'demo-run-prod-eu-1')

    // The staging run's escalation is no longer shown.
    expect(screen.queryByText(/role:secret-reader/)).not.toBeInTheDocument()
    // The prod run's escalation still is.
    expect(screen.getAllByText(/role:flux-reconciler/).length).toBeGreaterThan(0)
    // Collusion-pairs count drops from the aggregate's 4 to this run's 2.
    expect(statCardValue('Collusion pairs')).toBe('2')
  })
})

describe('CollusionAccessPage — page chrome', () => {
  it('renders no decorative page background, so the chrome matches every sibling page', () => {
    const { container } = renderPage()

    // The radial cluster-graph placeholder this page alone used to carry.
    expect(screen.queryByTestId('ktp-graph-bg')).not.toBeInTheDocument()
    expect(container.querySelector('[data-bg]')).toBeNull()
    // No element paints a backgroundImage behind the page.
    const painted = Array.from(container.querySelectorAll<HTMLElement>('[style]'))
      .filter(el => el.style.backgroundImage !== '')
    expect(painted).toHaveLength(0)
  })
})

describe('CollusionAccessPage — run selector covers the same selections as the AFM/RBAC surfaces', () => {
  it('offers every cluster as well as every run, derived from the fixtures rather than hardcoded', () => {
    renderPage()

    // Derived from the same source the page reads, so the assertion cannot
    // drift into agreeing with a stale copy of the option list.
    const expectedClusters = Array.from(new Set(DEMO_RUNS.map(r => `cluster:${r.clusterId}`)))
    const expectedRuns = DEMO_RUNS.map(r => r.id)

    expect(optionValues(screen.getByTestId('collusion-run-select')))
      .toEqual(['aggregate', ...expectedClusters, ...expectedRuns])
  })

  it('groups the selector so a cluster reads as a different altitude from a run', () => {
    renderPage()

    const groups = Array.from(screen.getByTestId('collusion-run-select').querySelectorAll('optgroup'))
      .map(g => g.getAttribute('label'))
    expect(groups).toEqual(['Cluster (latest analysis)', 'Run history'])
  })

  it("selecting a cluster shows that cluster's analysis and nothing from the other cluster", async () => {
    renderPage()

    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'cluster:staging-1')

    expect(screen.getAllByText(/role:secret-reader/).length).toBeGreaterThan(0)
    expect(screen.queryByText(/role:flux-reconciler/)).not.toBeInTheDocument()
    expect(statCardValue('Collusion pairs')).toBe('2')
  })
})

describe('CollusionAccessPage — how do we know', () => {
  it('discloses the demo data path and says outright that nothing was measured', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('collusion-proof-provenance'))

    const console_ = screen.getByTestId('collusion-console-provenance')
    expect(console_).toHaveTextContent('localStorage.getItem("demoMode")')
    expect(console_).toHaveTextContent('afmDemoFixtures.ts')
    expect(console_).toHaveTextContent(/nothing here was measured/i)
  })

  it('sources each collusion pair to the fixture that declares it, carrying AFM\'s own reason', async () => {
    renderPage()

    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'demo-run-prod-eu-1')
    await userEvent.click(screen.getByTestId('collusion-proof-group-0'))

    const console_ = screen.getByTestId('collusion-console-group-0')
    expect(console_).toHaveTextContent('afmDemoFixtures.ts')
    // The claim's own substance, not a restatement of the row: AFM's reason.
    expect(console_).toHaveTextContent('pivots through role:flux-reconciler, 4-step joint trace')
    expect(console_).toHaveTextContent('group:dev-eu, sa:ci/runner')
    // A fixture must never read as a probe result.
    expect(console_).toHaveTextContent(/not a measurement/i)
  })

  it('sources the shared-role and remediation tables too', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('collusion-proof-shared-roles'))
    expect(screen.getByTestId('collusion-console-shared-roles'))
      .toHaveTextContent('role:flux-reconciler — shared by 4, privileged: sa:ci/runner')

    await userEvent.click(screen.getByTestId('collusion-proof-guards'))
    expect(screen.getByTestId('collusion-console-guards'))
      .toHaveTextContent('Remove escalate verb from role:flux-reconciler')
  })

  it('closes the console again, and does not leave it open across a run change', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('collusion-proof-provenance'))
    expect(screen.getByTestId('collusion-console-provenance')).toBeInTheDocument()

    await userEvent.click(screen.getByTestId('collusion-proof-provenance'))
    expect(screen.queryByTestId('collusion-console-provenance')).not.toBeInTheDocument()

    await userEvent.click(screen.getByTestId('collusion-proof-group-0'))
    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'demo-run-staging-1')
    expect(screen.queryByTestId('collusion-console-group-0')).not.toBeInTheDocument()
  })
})

describe('CollusionAccessPage — live mode', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch()
  })

  it('fetches clusters, jobs and the aggregate analysis on mount', async () => {
    renderPage()

    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/clusters')
    })
    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/clusters/prod/jobs?limit=10')
    })
    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/clusters/prod/analysis/latest')
    })
  })

  it('renders data that is empirically different from the demo fixture — the core bug this fixes', async () => {
    renderPage()

    // Real subject and escalation type from the live fixture, not the demo one.
    expect(await screen.findAllByText('sa:prod/api')).not.toHaveLength(0)
    expect(screen.getByText('admin_via_impersonation')).toBeInTheDocument()

    // None of the demo-only narrative content is present.
    expect(screen.queryByText(/group:dev-eu/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Prod GitOps Cluster \(EU\)/)).not.toBeInTheDocument()

    // Live cluster has zero group escalations (the real 'local'-cluster
    // finding this fixture is modelled on) — an honest empty state, not a
    // fabricated collusion pair.
    expect(screen.getByTestId('group-escalations-empty')).toBeInTheDocument()
  })

  it('lists the live run in the selector by cluster name, timestamp and job status', async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    await waitFor(() => {
      expect(within(select).getAllByRole('option')).toHaveLength(3)
    })
    expect(within(select).getAllByRole('option')[2]).toHaveTextContent('Prod Live Cluster · 2026-08-01 10:00 · done')
  })

  it('offers every AFM cluster as a selection, so the results the AFM dashboard shows are reachable here', async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    // One entry per cluster from /afm/clusters — the same list the RBAC
    // Analysis embed and RBAC Explorer enumerate — plus the run history.
    await waitFor(() => {
      expect(optionValues(select)).toEqual(['aggregate', 'cluster:prod', 'job-live-1'])
    })
  })

  it("selecting a cluster fetches that cluster's latest analysis rather than a job result", async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    await waitFor(() => expect(within(select).getAllByRole('option')).toHaveLength(3))
    fetchMock.mockClear()

    await userEvent.selectOptions(select, 'cluster:prod')

    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/clusters/prod/analysis/latest')
    })
    expect(requestedUrls()).not.toContain('/afm/jobs/job-live-1/result')
    expect(await screen.findAllByText('sa:prod/api')).not.toHaveLength(0)
  })

  it('names the endpoint and the exact row behind a live finding', async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    await waitFor(() => expect(within(select).getAllByRole('option')).toHaveLength(3))
    await userEvent.selectOptions(select, 'job-live-1')

    await userEvent.click(await screen.findByTestId('collusion-proof-single-0'))

    const console_ = screen.getByTestId('collusion-console-single-0')
    // The command returns exactly the object this row was rendered from.
    expect(console_).toHaveTextContent("curl -s /afm/jobs/job-live-1/result | jq '.single_escalations[0]'")
    // toHaveTextContent collapses runs of whitespace, so the console's column
    // alignment is not asserted here — only the field/value pairs.
    expect(console_).toHaveTextContent('escalation_type: admin_via_impersonation')
    expect(console_).toHaveTextContent('risk.level: high')
    // AFM sent no reason for this finding; the console says so rather than
    // inventing one.
    expect(console_).toHaveTextContent('risk.reason: (none reported by AFM)')
  })

  it('attributes an aggregate row to its own cluster endpoint, not to whichever cluster came first', async () => {
    renderPage()

    await userEvent.click(await screen.findByTestId('collusion-proof-single-0'))

    expect(screen.getByTestId('collusion-console-single-0'))
      .toHaveTextContent("curl -s /afm/clusters/prod/analysis/latest | jq '.single_escalations[0]'")
  })

  it('discloses the aggregate data path, including how many clusters were rolled up', async () => {
    renderPage()

    await userEvent.click(await screen.findByTestId('collusion-proof-provenance'))

    const console_ = screen.getByTestId('collusion-console-provenance')
    expect(console_).toHaveTextContent('curl -s /afm/clusters | jq -r ".[].id"')
    expect(console_).toHaveTextContent('1 cluster(s) returned: prod')
    expect(console_).toHaveTextContent('1 of them have a completed analysis run')
  })

  it('drilling into the live run fetches /jobs/{id}/result and its guards', async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    await waitFor(() => expect(within(select).getAllByRole('option')).toHaveLength(3))

    await userEvent.selectOptions(select, 'job-live-1')

    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/jobs/job-live-1/result')
    })
    expect(await screen.findByText('traceguard-prod-single-0')).toBeInTheDocument()
  })

  it('shows a visible fatal error and renders no data when AFM is unreachable — never falls back to demo', async () => {
    routeLiveFetch({ clusters: () => Promise.reject(new Error('connect ECONNREFUSED')) })

    renderPage()

    expect(await screen.findByTestId('collusion-fatal-error')).toHaveTextContent(/ECONNREFUSED/)
    // No demo content anywhere as a silent fallback.
    expect(screen.queryByText(/group:dev-eu/)).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Collusion Pairs' })).not.toBeInTheDocument()
  })

  it('shows a visible fatal error when AFM returns a non-OK status', async () => {
    routeLiveFetch({ clusters: () => Promise.resolve(response(false)) })

    renderPage()

    expect(await screen.findByTestId('collusion-fatal-error')).toBeInTheDocument()
    expect(screen.queryByText(/group:dev-eu/)).not.toBeInTheDocument()
  })

  it('surfaces a non-fatal run error when a specific run fails to load, without touching demo data', async () => {
    renderPage()

    const select = await screen.findByTestId('collusion-run-select')
    await waitFor(() => expect(within(select).getAllByRole('option')).toHaveLength(3))

    routeLiveFetch({ jobResult: () => Promise.reject(new Error('job result unavailable')) })
    await userEvent.selectOptions(select, 'job-live-1')

    expect(await screen.findByTestId('collusion-run-error')).toHaveTextContent(/job result unavailable/)
    expect(screen.queryByText(/group:dev-eu/)).not.toBeInTheDocument()
  })

  it('retries the connection when "Retry connection" is clicked', async () => {
    let reachable = false
    routeLiveFetch({ clusters: () => reachable ? Promise.resolve(response(true, LIVE_CLUSTERS)) : Promise.reject(new Error('down')) })

    renderPage()

    expect(await screen.findByTestId('collusion-fatal-error')).toBeInTheDocument()

    reachable = true
    await userEvent.click(screen.getByRole('button', { name: /retry connection/i }))

    await waitFor(() => {
      expect(screen.queryByTestId('collusion-fatal-error')).not.toBeInTheDocument()
    })
    expect(await screen.findAllByText('sa:prod/api')).not.toHaveLength(0)
  })
})
