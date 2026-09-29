/**
 * Tests for the Collusion & Access page.
 *
 * The page used to render four tables of hardcoded content with no fetch call
 * at all: demo and live were visually identical by construction. It now has
 * a run selector (aggregate + per-run drill-down) backed by two different data
 * sources: fixed offline fixtures in demo mode, and the real KubeSec-AFM API
 * in live mode. The load-bearing assertions here are:
 *
 *  1. demo mode renders deterministically with no network calls;
 *  2. the run selector lists real runs and drilling into one changes content;
 *  3. live mode issues real HTTP calls and the data it renders is
 *     *empirically different* from the demo fixture: the concrete proof that
 *     the "demo and live return identical data" bug is fixed;
 *  4. a live-mode failure renders a visible error and never falls back to
 *     demo content, per the non-negotiable in WORKTREE-INTEGRATION.md;
 *  5. the selector offers a CLUSTER entry per cluster, not only job history:
 *     the gap that made a cluster visible on the KubeSec-AFM dashboard and
 *     RBAC Explorer unreachable from this page;
 *  6. every claim on the page can be traced to a command, and the demo path
 *     says plainly that nothing was measured rather than dressing a fixture
 *     up as a probe.
 *  7. zero em-dashes ('—') and zero en-dashes ('–') across all UI text and source;
 *  8. interactive scan triggers ('Run Collusion Scan' & 'Scan RBAC') dispatch API calls;
 *  9. recency badges display humanized relative timestamps from cluster jobs.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import CollusionAccessPage, {
  SubjectAgentLink,
  GroupMembersLink,
  CollaboratorGainsLinks,
  humanizeRelativeTime,
} from './CollusionAccessPage'
import { DEMO_RUNS } from '../api/afmDemoFixtures'
import type { AgentResponse } from '../types/api'

const isDemoMode = vi.fn(() => true)
const fetchMock = vi.fn()
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-bearer-token')

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
  subscribeDemoMode: () => () => {},
}))

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
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

// ── Live fixtures ─────────────────────────────────────────────────────────

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
  collusionTrigger?: () => Promise<Response>
  rbacTrigger?: () => Promise<Response>
}

function routeLiveFetch(overrides: RouteOverrides = {}) {
  fetchMock.mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    const method = init?.method?.toUpperCase() ?? 'GET'

    if (method === 'POST' && url === '/afm/clusters/prod/jobs') {
      return overrides.collusionTrigger
        ? overrides.collusionTrigger()
        : Promise.resolve(response(true, {
            id: 'job-live-new',
            cluster_id: 'prod',
            status: 'queued',
            trigger_source: 'manual',
            created_at: '2026-08-01T11:00:00Z',
          }))
    }
    if (method === 'POST' && url === '/api/rbac/clusters/prod/scan') {
      return overrides.rbacTrigger
        ? overrides.rbacTrigger()
        : Promise.resolve(response(true, {
            jobId: 'rbac-job-1',
            status: 'queued',
            message: 'RBAC scan queued',
          }))
    }
    if (url === '/afm/clusters') {
      return overrides.clusters ? overrides.clusters() : Promise.resolve(response(true, LIVE_CLUSTERS))
    }
    if (url === '/afm/clusters/prod/jobs?limit=10' || url === '/afm/clusters/prod/jobs?limit=5') {
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
    if (url.startsWith('/agents') || url.includes('/agents')) {
      return Promise.resolve(response(true, { agents: [] }))
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

function statCardValue(label: string): string {
  const labelNode = screen.getByText(label)
  const card = labelNode.closest('.card')
  if (!card) throw new Error(`StatCard "${label}" is not inside a .card element.`)
  const value = within(card as HTMLElement).getByText(/^\d+$/)
  return value.textContent ?? ''
}

function sectionFor(heading: string): HTMLElement {
  const h2 = screen.getByRole('heading', { level: 2, name: heading })
  const section = h2.closest('section')
  if (!section) throw new Error(`Heading "${heading}" is not inside a <section>.`)
  return section as HTMLElement
}

function bodyRows(heading: string): HTMLElement[] {
  return within(sectionFor(heading)).queryAllByRole('row').slice(1)
}

function firstCells(heading: string): string[] {
  return bodyRows(heading).map(row => within(row).getAllByRole('cell')[0]?.textContent ?? '')
}

beforeEach(() => {
  vi.clearAllMocks()
  isDemoMode.mockReturnValue(true)
  fetchMock.mockReset()
  Object.defineProperty(globalThis, 'fetch', { configurable: true, writable: true, value: fetchMock })
})

describe('CollusionAccessPage — typography and punctuation (zero em-dashes)', () => {
  it('renders zero em-dashes across the entire component output in demo mode', () => {
    const { container } = renderPage()
    expect(container.textContent).not.toContain('—')
  })

  it('renders zero em-dashes across the entire component output in live mode', async () => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch()
    const { container } = renderPage()
    await waitFor(() => {
      expect(screen.queryByTestId('collusion-list-loading')).not.toBeInTheDocument()
    })
    expect(container.textContent).not.toContain('—')
  })

  it('verifies CollusionAccessPage.tsx source file contains zero em-dashes and zero en-dashes', async () => {
    const fs = await import('node:fs/promises')
    const path = await import('node:path')
    const sourcePath = path.resolve(__dirname, 'CollusionAccessPage.tsx')
    const content = await fs.readFile(sourcePath, 'utf-8')
    expect(content.includes('—')).toBe(false)
    expect(content.includes('–')).toBe(false)
  })

  it('verifies humanizeRelativeTime helper handles timestamps correctly', () => {
    expect(humanizeRelativeTime(null)).toBe('never')
    expect(humanizeRelativeTime(undefined)).toBe('never')
    expect(humanizeRelativeTime('invalid-date')).toBe('unknown')
    const now = new Date().toISOString()
    expect(humanizeRelativeTime(now)).toMatch(/just now|0s ago|1s ago/)
  })
})


describe('CollusionAccessPage — scan triggers and job creation', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch()
  })

  it('renders "Run Collusion Scan" and "Scan RBAC" trigger buttons in header toolbar', async () => {
    renderPage()
    expect(screen.getByTestId('btn-run-collusion-scan')).toBeInTheDocument()
    expect(screen.getByTestId('btn-scan-rbac')).toBeInTheDocument()
  })

  it('clicking "Run Collusion Scan" initiates AFM scan job creation against /afm/clusters/{id}/jobs', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId('collusion-run-select')).toBeInTheDocument())

    const collusionBtn = screen.getByTestId('btn-run-collusion-scan')
    await userEvent.click(collusionBtn)

    await waitFor(() => {
      expect(requestedUrls()).toContain('/afm/clusters/prod/jobs')
    })
    expect(await screen.findByTestId('scan-feedback-alert')).toHaveTextContent(/Collusion scan started/i)
  })

  it('clicking "Scan RBAC" initiates RBAC correlation scan against /api/rbac/clusters/{id}/scan', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByTestId('collusion-run-select')).toBeInTheDocument())

    const rbacBtn = screen.getByTestId('btn-scan-rbac')
    await userEvent.click(rbacBtn)

    await waitFor(() => {
      expect(requestedUrls()).toContain('/api/rbac/clusters/prod/scan')
    })
    expect(await screen.findByTestId('scan-feedback-alert')).toHaveTextContent(/RBAC scan initiated/i)
  })

  it('displays actionable error feedback when scan trigger fails', async () => {
    routeLiveFetch({
      collusionTrigger: () => Promise.resolve(response(false)),
    })
    renderPage()

    const collusionBtn = screen.getByTestId('btn-run-collusion-scan')
    await userEvent.click(collusionBtn)

    expect(await screen.findByTestId('scan-feedback-alert')).toHaveTextContent(/failed/i)
  })
})

describe('CollusionAccessPage — recency badge and live region', () => {
  it('renders recency badge in demo mode displaying relative time', () => {
    renderPage()
    const badge = screen.getByTestId('collusion-scan-badge')
    expect(badge).toBeInTheDocument()
    expect(badge).toHaveTextContent(/Scanned/)
  })

  it('renders "Never Scanned" when no completed jobs exist in live mode', async () => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch({ jobs: () => Promise.resolve(response(true, [])) })
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('collusion-scan-badge')).toHaveTextContent('Never Scanned')
    })
  })

  it('renders "Scan Running" when active job is running', async () => {
    isDemoMode.mockReturnValue(false)
    const runningJob = { ...LIVE_JOB, status: 'running' }
    routeLiveFetch({ jobs: () => Promise.resolve(response(true, [runningJob])) })
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('collusion-scan-badge')).toHaveTextContent('Scan Running')
    })
  })

  it('announces scan lifecycle events via ARIA live region', async () => {
    isDemoMode.mockReturnValue(false)
    routeLiveFetch()
    renderPage()

    const liveRegion = screen.getByTestId('scan-status-live-region')
    expect(liveRegion).toHaveAttribute('aria-live', 'polite')

    await userEvent.click(screen.getByTestId('btn-run-collusion-scan'))
    await waitFor(() => {
      expect(liveRegion).toHaveTextContent(/Collusion scan/i)
    })
  })
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

    expect(screen.queryByText(/role:secret-reader/)).not.toBeInTheDocument()
    expect(screen.getAllByText(/role:flux-reconciler/).length).toBeGreaterThan(0)
    expect(statCardValue('Collusion pairs')).toBe('2')
  })
})

describe('CollusionAccessPage — page chrome', () => {
  it('renders no decorative page background, so the chrome matches every sibling page', () => {
    const { container } = renderPage()

    expect(screen.queryByTestId('ktp-graph-bg')).not.toBeInTheDocument()
    expect(container.querySelector('[data-bg]')).toBeNull()
    const painted = Array.from(container.querySelectorAll<HTMLElement>('[style]'))
      .filter(el => el.style.backgroundImage !== '')
    expect(painted).toHaveLength(0)
  })
})

describe('CollusionAccessPage — run selector covers the same selections as the AFM/RBAC surfaces', () => {
  it('offers every cluster as well as every run, derived from the fixtures rather than hardcoded', () => {
    renderPage()

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
    expect(console_).toHaveTextContent('pivots through role:flux-reconciler, 4-step joint trace')
    expect(console_).toHaveTextContent('group:dev-eu, sa:ci/runner')
    expect(console_).toHaveTextContent(/not a measurement/i)
  })

  it('sources the shared-role and remediation tables too', async () => {
    renderPage()

    await userEvent.click(screen.getByTestId('collusion-proof-shared-roles'))
    expect(screen.getByTestId('collusion-console-shared-roles'))
      .toHaveTextContent('role:flux-reconciler: shared by 4, privileged: sa:ci/runner')

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

    expect(await screen.findAllByText('sa:prod/api')).not.toHaveLength(0)
    expect(screen.getByText('admin_via_impersonation')).toBeInTheDocument()

    expect(screen.queryByText(/group:dev-eu/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Prod GitOps Cluster \(EU\)/)).not.toBeInTheDocument()

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
    expect(console_).toHaveTextContent("curl -s /afm/jobs/job-live-1/result | jq '.single_escalations[0]'")
    expect(console_).toHaveTextContent('escalation_type: admin_via_impersonation')
    expect(console_).toHaveTextContent('risk.level: high')
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

    expect(screen.getByTestId('group-escalations-filter-all')).toHaveTextContent('all 4')
    expect(screen.getByTestId('group-escalations-filter-critical')).toHaveTextContent('critical 1')
    expect(screen.getByTestId('group-escalations-filter-high')).toHaveTextContent('high 2')
    expect(screen.getByTestId('group-escalations-filter-medium')).toHaveTextContent('medium 1')

    await userEvent.click(screen.getByTestId('group-escalations-filter-critical'))

    expect(bodyRows('Collusion Pairs')).toHaveLength(1)
    expect(firstCells('Collusion Pairs')).toEqual(['group:dev-eu, sa:ci/runner'])
    expect(screen.getByTestId('group-escalations-count')).toHaveTextContent('1 of 4 shown')
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
    await userEvent.type(search, 'sa:ci/runner')
    expect(firstCells('Shared-Role Pivot Points')).toEqual(['role:flux-reconciler'])
  })

  it('narrows Remediation Priorities by search, and offers a kind chip per kind present', async () => {
    renderPage()

    expect(screen.getByTestId('guards-filter-all')).toHaveTextContent('all 4')
    expect(screen.getByTestId('guards-filter-group')).toHaveTextContent('group 4')
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

    expect(screen.getByTestId('shared-roles-filtered-empty')).toBeInTheDocument()

    await userEvent.click(screen.getByTestId('shared-roles-clear-filters'))

    expect(bodyRows('Shared-Role Pivot Points')).toHaveLength(3)
    expect(screen.getByTestId('shared-roles-filter-all')).toHaveAttribute('aria-pressed', 'true')
  })

  it('distinguishes an honest zero from a filter that matched nothing', async () => {
    renderPage()

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
    await userEvent.click(risk)
    await userEvent.click(risk)

    expect(firstCells('Collusion Pairs')[0]).toBe('group:analysts, sa:data/etl')
    expect(risk).toHaveAttribute('aria-sort', 'descending')
  })
})

describe('CollusionAccessPage — Analysis Phases is the method, not the findings', () => {
  it('offers no filter, because a filter here would let the analysis under-report itself', () => {
    renderPage()

    const phases = within(sectionFor('Analysis Phases'))

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

    expect(within(sectionFor('Shared-Role Pivot Points')).getByTestId('shared-roles-facet-help'))
      .toHaveAttribute('aria-label', 'What risk means')
    expect(within(sectionFor('Remediation Priorities')).getByTestId('guards-facet-help'))
      .toHaveAttribute('aria-label', 'What kind means')
  })

  describe('agent drill-down links', () => {
    const mockAgents: AgentResponse[] = [
      {
        id: 'agent-ci-runner',
        name: 'CI Runner Agent',
        type: 'Signal Loom Built',
        tenant_id: 'tenant-1',
        service_account: 'ci/runner',
        lifecycle_state: 'active',
        last_transition_at: null,
        eu_ai_act_risk_class: null,
        compliance_summary: {
          total_controls: 10,
          passing: 10,
          failing: 0,
          pending: 0,
          posture_score: 100,
        },
        created_at: null,
      },
    ]

    it('renders SubjectAgentLink as a link when an agent matches', () => {
      render(
        <MemoryRouter>
          <SubjectAgentLink
            subject="sa:ci/runner"
            agents={mockAgents}
            testId="test-subject-link"
          />
        </MemoryRouter>,
      )
      const link = screen.getByTestId('test-subject-link')
      expect(link.tagName.toLowerCase()).toBe('a')
      expect(link).toHaveAttribute('href', '/agents/agent-ci-runner?tab=overview')
      expect(link).toHaveTextContent('sa:ci/runner')
    })

    it('renders SubjectAgentLink as plain span when no agent matches', () => {
      render(
        <MemoryRouter>
          <SubjectAgentLink
            subject="group:dev-eu"
            agents={mockAgents}
            testId="test-unmatched-link"
          />
        </MemoryRouter>,
      )
      const span = screen.getByTestId('test-unmatched-link')
      expect(span.tagName.toLowerCase()).toBe('span')
      expect(span).toHaveTextContent('group:dev-eu')
    })

    it('renders GroupMembersLink with links for matching members', () => {
      render(
        <MemoryRouter>
          <GroupMembersLink
            group="group:dev-eu, sa:ci/runner"
            agents={mockAgents}
            testIdPrefix="group-members-test"
          />
        </MemoryRouter>,
      )
      const member0 = screen.getByTestId('group-members-test-member-0')
      const member1 = screen.getByTestId('group-members-test-member-1')
      expect(member0.tagName.toLowerCase()).toBe('span')
      expect(member1.tagName.toLowerCase()).toBe('a')
      expect(member1).toHaveAttribute('href', '/agents/agent-ci-runner?tab=overview')
    })

    it('renders CollaboratorGainsLinks parsing subject and permission', () => {
      render(
        <MemoryRouter>
          <CollaboratorGainsLinks
            text="sa:ci/runner: bind role:flux-reconciler"
            agents={mockAgents}
            testIdPrefix="gains-test"
          />
        </MemoryRouter>,
      )
      const sub = screen.getByTestId('gains-test-sub-0')
      expect(sub.tagName.toLowerCase()).toBe('a')
      expect(sub).toHaveAttribute('href', '/agents/agent-ci-runner?tab=overview')
    })

    it('renders CollaboratorGainsLinks fallback when none', () => {
      render(
        <MemoryRouter>
          <CollaboratorGainsLinks
            text="none"
            agents={mockAgents}
            testIdPrefix="gains-empty-test"
          />
        </MemoryRouter>,
      )
      expect(screen.getByText('none')).toBeInTheDocument()
    })

    it('renders Collusion Pairs table with actor and collaborator testids', () => {
      renderPage()
      const actorElement = screen.getByTestId('group-primary-actor-group-0')
      expect(actorElement).toBeInTheDocument()
      const membersElement = screen.getByTestId('group-members-group-0')
      expect(membersElement).toBeInTheDocument()
    })
  })
})
