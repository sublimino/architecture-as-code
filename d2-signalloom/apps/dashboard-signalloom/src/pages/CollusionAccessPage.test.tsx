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
 *
 * Since the design-system migration, three more:
 *
 *  7. every one of the four tables narrows — by search box and by facet chip —
 *     and the figure beside the chips reports the narrowing honestly;
 *  8. a filter that matches nothing leaves a visible way back. This is the
 *     defect DataTable's `toolbar` + `emptyState` pair exists to prevent: a
 *     hand-rolled `rows.length ? table : empty` ternary unmounts the control
 *     that caused the empty result. Asserted by finding the search box AND a
 *     Clear filters button on the empty branch, and by pressing the latter;
 *  9. every explanatory "?" is reachable by its accessible name, section by
 *     section. Several tables carry a "Risk" column, so these queries are
 *     scoped to a section rather than to the page — an unscoped one would
 *     match three buttons and pass or fail for the wrong reason.
 *
 * A note on scoping generally, because it cost this project seven vacuous CI
 * assertions: every sidebar nav label is also a page heading, so
 * `getByText(...).first()` finds the nav link and passes against a page that
 * rendered nothing. Everything below goes through a role-scoped heading, or a
 * testid, or a section resolved from one of those.
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

/**
 * A live analysis with several single-subject escalations at different risks.
 *
 * The demo fixtures declare none at all — both runs are pure collusion — so
 * the Privilege Escalation Paths table cannot be filtered in demo mode at any
 * size of test. This is the smallest fixture that lets that table be exercised
 * the same way the other three are: three subjects, three escalation types,
 * three risk levels, one of each.
 */
const RICH_ANALYSIS = {
  schema_version: '3.4.0',
  metadata: { subjects: ['sa:prod/api', 'sa:prod/worker', 'sa:prod/backup'] },
  single_escalations: [
    {
      subject: 'sa:prod/api',
      escalation_type: 'admin_via_impersonation',
      scope: 'cluster-wide',
      gained_permission: { verb: '*', resource: 'all', namespace: 'cluster' },
      risk: { level: 'critical', score: 90 },
      evidence: { shell: [], documents: [] },
      trace: {},
    },
    {
      subject: 'sa:prod/worker',
      escalation_type: 'bind_via_escalate',
      scope: 'namespace/apps',
      gained_permission: { verb: 'create', resource: 'rolebindings', namespace: 'apps' },
      risk: { level: 'high', score: 70 },
      evidence: { shell: [], documents: [] },
      trace: {},
    },
    {
      subject: 'sa:prod/backup',
      escalation_type: 'secret_read',
      scope: 'namespace/kube-system',
      gained_permission: { verb: 'get', resource: 'secrets', namespace: 'kube-system' },
      risk: { level: 'medium', score: 40 },
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

/**
 * The `<section>` a named table lives in.
 *
 * Resolved from the section's own H2 rather than from a text match. Three of
 * the four tables carry a "Risk" column and every one carries a page-size
 * select, so nearly every query below has to be scoped to one table or it is
 * asking the page a question the page cannot answer unambiguously.
 */
function sectionFor(heading: string): HTMLElement {
  const h2 = screen.getByRole('heading', { level: 2, name: heading })
  const section = h2.closest('section')
  if (!section) throw new Error(`Heading "${heading}" is not inside a <section>.`)
  return section as HTMLElement
}

/** Body rows of a table, header row dropped. No proof console is open in these tests. */
function bodyRows(heading: string): HTMLElement[] {
  return within(sectionFor(heading)).queryAllByRole('row').slice(1)
}

/** The first cell of every body row — enough to identify which findings survived a filter. */
function firstCells(heading: string): string[] {
  return bodyRows(heading).map(row => within(row).getAllByRole('cell')[0]?.textContent ?? '')
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

describe('CollusionAccessPage — table filters', () => {
  it('narrows Collusion Pairs by risk chip, and the chip counts describe the whole run', async () => {
    renderPage()

    // The counts on the chips are computed against every row, not against
    // whatever the search box left — a chip that reported the effect of its
    // neighbour would be unusable for deciding whether to press it.
    expect(screen.getByTestId('group-escalations-filter-all')).toHaveTextContent('all 4')
    expect(screen.getByTestId('group-escalations-filter-critical')).toHaveTextContent('critical 1')
    expect(screen.getByTestId('group-escalations-filter-high')).toHaveTextContent('high 2')
    expect(screen.getByTestId('group-escalations-filter-medium')).toHaveTextContent('medium 1')

    await userEvent.click(screen.getByTestId('group-escalations-filter-critical'))

    expect(bodyRows('Collusion Pairs')).toHaveLength(1)
    expect(firstCells('Collusion Pairs')).toEqual(['group:dev-eu, sa:ci/runner'])
    expect(screen.getByTestId('group-escalations-count')).toHaveTextContent('1 of 4 shown')
    // The stat card counts the run, not the filter. Filtering is a view over
    // the findings; it must never look like findings went away.
    expect(statCardValue('Collusion pairs')).toBe('4')
  })

  it('narrows Collusion Pairs by search across members, actor and permission', async () => {
    renderPage()

    await userEvent.type(screen.getByTestId('group-escalations-search'), 'analysts')

    expect(firstCells('Collusion Pairs')).toEqual(['group:analysts, sa:data/etl'])
    expect(screen.getByTestId('group-escalations-count')).toHaveTextContent('1 of 4 shown')
  })

  it('narrows Shared-Role Pivot Points by its derived risk chip', async () => {
    renderPage()

    // "low" here is the page's own derivation — a pivot nobody privileged
    // shares — and the chip has to agree with the Pill in the row.
    await userEvent.click(screen.getByTestId('shared-roles-filter-low'))

    expect(firstCells('Shared-Role Pivot Points')).toEqual(['role:pv-manager'])
    expect(screen.getByTestId('shared-roles-count')).toHaveTextContent('1 of 3 shown')
  })

  it('narrows Shared-Role Pivot Points by role and by privileged subject', async () => {
    renderPage()

    const search = screen.getByTestId('shared-roles-search')
    await userEvent.type(search, 'secret')
    expect(firstCells('Shared-Role Pivot Points')).toEqual(['role:secret-reader'])

    await userEvent.clear(search)
    // A subject name, not a role name — the privileged-subjects column is
    // searchable too, which is how you answer "where can this identity pivot".
    await userEvent.type(search, 'sa:ci/runner')
    expect(firstCells('Shared-Role Pivot Points')).toEqual(['role:flux-reconciler'])
  })

  it('narrows Remediation Priorities by search, and offers a kind chip per kind present', async () => {
    renderPage()

    expect(screen.getByTestId('guards-filter-all')).toHaveTextContent('all 4')
    expect(screen.getByTestId('guards-filter-group')).toHaveTextContent('group 4')
    // Every demo guard is a group guard, so no "single" chip is offered. A chip
    // that always reads zero is a control that cannot do anything.
    expect(screen.queryByTestId('guards-filter-single')).not.toBeInTheDocument()

    await userEvent.type(screen.getByTestId('guards-search'), 'secret-reader')

    expect(firstCells('Remediation Priorities')).toEqual(['Split role:secret-reader per namespace'])
    expect(screen.getByTestId('guards-count')).toHaveTextContent('1 of 4 shown')
  })

  it('leaves a way back when a filter matches nothing — the toolbar survives the empty branch', async () => {
    renderPage()

    await userEvent.type(screen.getByTestId('group-escalations-search'), 'no-such-subject')

    expect(screen.getByTestId('group-escalations-filtered-empty')).toBeInTheDocument()
    expect(bodyRows('Collusion Pairs')).toHaveLength(0)
    // The whole point of passing `toolbar` and `emptyState` together: the
    // control that emptied the table is still on screen to undo it.
    expect(screen.getByTestId('group-escalations-search')).toBeInTheDocument()

    await userEvent.click(screen.getByTestId('group-escalations-clear-filters'))

    expect(screen.queryByTestId('group-escalations-filtered-empty')).not.toBeInTheDocument()
    expect(bodyRows('Collusion Pairs')).toHaveLength(4)
    expect(screen.getByTestId('group-escalations-search')).toHaveValue('')
  })

  it('clearing from the empty panel resets the chip as well as the search box', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('shared-roles-filter-low'))
    await userEvent.type(screen.getByTestId('shared-roles-search'), 'flux')
    // low + "flux" is empty: the flux pivot is high, the low pivot is pv-manager.
    expect(screen.getByTestId('shared-roles-filtered-empty')).toBeInTheDocument()

    await userEvent.click(screen.getByTestId('shared-roles-clear-filters'))

    expect(bodyRows('Shared-Role Pivot Points')).toHaveLength(3)
    expect(screen.getByTestId('shared-roles-filter-all')).toHaveAttribute('aria-pressed', 'true')
  })

  it('distinguishes an honest zero from a filter that matched nothing', async () => {
    renderPage()

    // The aggregate has no single-subject findings at all. That panel says so
    // in its own words and offers no Clear filters button, because there is no
    // filter to clear and offering one would suggest the rows are hidden.
    expect(screen.getByTestId('single-escalations-empty')).toBeInTheDocument()
    expect(screen.queryByTestId('single-escalations-filtered-empty')).not.toBeInTheDocument()
    expect(screen.queryByTestId('single-escalations-search')).not.toBeInTheDocument()

    await userEvent.type(screen.getByTestId('guards-search'), 'no-such-fix')
    expect(screen.getByTestId('guards-filtered-empty')).toBeInTheDocument()
    expect(screen.queryByTestId('guards-empty')).not.toBeInTheDocument()
  })

  it('drops the filters on a run change, so a stale chip cannot blank the new run', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('group-escalations-filter-medium'))
    expect(bodyRows('Collusion Pairs')).toHaveLength(1)

    // The prod run has no medium finding; carrying the chip over would show
    // four empty tables with no visible cause.
    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'demo-run-prod-eu-1')

    expect(screen.getByTestId('group-escalations-filter-all')).toHaveAttribute('aria-pressed', 'true')
    expect(bodyRows('Collusion Pairs')).toHaveLength(2)
  })

  it('names the strip and the box inside it differently, so one utterance selects one control', () => {
    renderPage()

    const section = within(sectionFor('Collusion Pairs'))
    expect(section.getByRole('group', { name: 'Filter collusion pairs' })).toBeInTheDocument()
    expect(section.getByRole('searchbox', { name: 'Search collusion pairs' })).toBeInTheDocument()
  })

  it('sorts a column on demand — the capability the hand-rolled table never had', async () => {
    renderPage()

    const risk = within(sectionFor('Collusion Pairs')).getByRole('columnheader', { name: /Risk/ })
    // Ascending is alphabetical and happens to match the arrival order, so the
    // assertion is on the second click, where the order genuinely differs.
    await userEvent.click(risk)
    await userEvent.click(risk)

    expect(firstCells('Collusion Pairs')[0]).toBe('group:analysts, sa:data/etl')
    expect(risk).toHaveAttribute('aria-sort', 'descending')
  })
})

// ── The two regions that present rows and columns and are still not tables ──
//
// Re-swept the page for row-and-column regions rendered outside DataTable,
// since a grep for `<table>` misses DashKit and div-based ones. Every array
// this page renders into layout is now a DataTable except three: the run
// selector's <option> list (a select, not a table), the StatCard strip, and
// the Analysis Phases grid. The last two are card grids that could be read as
// three-column tables, and both stay as they are.
//
// The reasons are pinned as tests rather than comments because in both cases
// the intuitive conclusion is the wrong one, and a later reader "finishing the
// migration" would break something specific.

describe('CollusionAccessPage — Analysis Phases is the method, not the findings', () => {
  it('offers no filter, because a filter here would let the analysis under-report itself', () => {
    renderPage()

    const phases = within(sectionFor('Analysis Phases'))

    // Phase 2 IS the collusion check. A run with zero collusion pairs already
    // looks, to a non-expert, like collusion was never examined — and the only
    // thing on the page that says otherwise is this card. A control that can
    // hide it lets "we checked and found nothing" render identically to "we
    // never checked", on a page whose entire contract is that every claim
    // carries its source. That is the same defect class as a filter under a
    // warning banner, and it is worse here: it hides the method, not a row.
    expect(phases.queryByRole('searchbox')).not.toBeInTheDocument()
    expect(phases.queryByRole('group')).not.toBeInTheDocument()
    expect(phases.getByText('Collusion escalation')).toBeInTheDocument()
  })

  it('says the same thing for every run, because it describes the engine and not the data', async () => {
    renderPage()

    const titles = () => within(sectionFor('Analysis Phases'))
      .getAllByText(/Admin & self-escalation removal|Impersonation check|Collusion escalation/)
      .map(node => node.textContent)
    const before = titles()
    expect(before).toHaveLength(3)

    // PHASES is a module constant. Not fetched, not per-cluster, not switched
    // by demo mode — so drilling from the aggregate into a single run must not
    // move it. If this ever fails, the phases became data and the verdict above
    // has to be revisited.
    await userEvent.selectOptions(screen.getByTestId('collusion-run-select'), 'demo-run-staging-1')

    expect(titles()).toEqual(before)
  })
})

describe('CollusionAccessPage — the stat strip counts the run, never the filter', () => {
  it('holds every figure steady while all four tables are filtered to nothing', async () => {
    renderPage()

    const figures = () => ({
      subjects: statCardValue('Subjects analysed'),
      escalations: statCardValue('Escalation paths'),
      pairs: statCardValue('Collusion pairs'),
      pivots: statCardValue('Pivot roles'),
      fixes: statCardValue('Priority fixes'),
    })
    const before = figures()
    expect(before).toEqual({ subjects: '8', escalations: '0', pairs: '4', pivots: '3', fixes: '4' })

    await userEvent.type(screen.getByTestId('group-escalations-search'), 'zzz')
    await userEvent.type(screen.getByTestId('shared-roles-search'), 'zzz')
    await userEvent.type(screen.getByTestId('guards-search'), 'zzz')

    // Three tables now say nothing matched. The strip is a claim about the
    // run — "this cluster has 4 collusion pairs" — and a filter is a view over
    // that claim, never a revision of it. A strip that tracked the filters
    // would report findings as having gone away because someone typed in a box.
    expect(screen.getByTestId('group-escalations-filtered-empty')).toBeInTheDocument()
    expect(screen.getByTestId('shared-roles-filtered-empty')).toBeInTheDocument()
    expect(screen.getByTestId('guards-filtered-empty')).toBeInTheDocument()
    expect(figures()).toEqual(before)
  })
})

describe('CollusionAccessPage — Privilege Escalation Paths filters', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch({ latest: () => Promise.resolve(response(true, RICH_ANALYSIS)) })
  })

  it('narrows by risk chip', async () => {
    renderPage()

    expect(await screen.findByTestId('single-escalations-filter-all')).toHaveTextContent('all 3')

    await userEvent.click(screen.getByTestId('single-escalations-filter-medium'))

    expect(firstCells('Privilege Escalation Paths')).toEqual(['sa:prod/backup'])
    expect(screen.getByTestId('single-escalations-count')).toHaveTextContent('1 of 3 shown')
  })

  it('narrows by search over subject, escalation type, scope and gained permission', async () => {
    renderPage()

    const search = await screen.findByTestId('single-escalations-search')

    await userEvent.type(search, 'impersonation')
    expect(firstCells('Privilege Escalation Paths')).toEqual(['sa:prod/api'])

    await userEvent.clear(search)
    await userEvent.type(search, 'kube-system')
    expect(firstCells('Privilege Escalation Paths')).toEqual(['sa:prod/backup'])
  })

  it('keeps a row\'s proof addressed to that row after a filter reorders the table', async () => {
    renderPage()

    // sa:prod/backup is index 2 in the unfiltered array. Filtering it to the
    // only visible row must not turn it into "single-0" — the proof key is the
    // finding's identity, not its position on screen.
    await userEvent.click(await screen.findByTestId('single-escalations-filter-medium'))
    await userEvent.click(screen.getByTestId('collusion-proof-single-2'))

    expect(screen.getByTestId('collusion-console-single-2')).toHaveTextContent('subject: sa:prod/backup')
  })
})

describe('CollusionAccessPage — explanations', () => {
  it('names the two concepts the page assumes its reader already has', async () => {
    renderPage()

    expect(screen.getByRole('button', { name: 'What collusion means' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'What bounded model checking means' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'What the Run selector offers' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'What showing the proof does' })).toBeInTheDocument()

    // Reachable is not enough — it has to say something. HelpHint opens on focus.
    await userEvent.click(screen.getByRole('button', { name: 'What collusion means' }))
    expect(screen.getByRole('tooltip')).toHaveTextContent(/cannot reach a privileged role on their own/i)
  })

  it('explains every column whose header does not already say it', () => {
    renderPage()

    const expected: [string, string[]][] = [
      ['Collusion Pairs', ['Group', 'Primary actor', 'Primary gain', 'Collaborator gains', 'Risk', 'Proof']],
      ['Shared-Role Pivot Points', ['Role', 'Shared by', 'Privileged subjects', 'Risk']],
      ['Remediation Priorities', ['Fix', 'Kind', 'Participants', 'Would block']],
    ]

    for (const [heading, columns] of expected) {
      const section = within(sectionFor(heading))
      for (const column of columns) {
        expect(
          section.getByRole('button', { name: `What ${column} means` }),
          `${heading} › ${column}`,
        ).toBeInTheDocument()
      }
    }
  })

  it('explains the two facet rows whose chip labels are not self-describing', () => {
    renderPage()

    // "high"/"low" on the pivot table is this page's own derivation, and
    // "single"/"group" on the guards table is a distinction the word alone
    // does not carry. The two risk rows whose levels come straight from AFM
    // get no hint — the column header's "?" already covers them.
    expect(within(sectionFor('Shared-Role Pivot Points')).getByTestId('shared-roles-facet-help'))
      .toHaveAttribute('aria-label', 'What risk means')
    expect(within(sectionFor('Remediation Priorities')).getByTestId('guards-facet-help'))
      .toHaveAttribute('aria-label', 'What kind means')
  })
})
