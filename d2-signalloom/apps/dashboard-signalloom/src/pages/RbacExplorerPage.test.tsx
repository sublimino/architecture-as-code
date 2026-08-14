/**
 * Tests for the RBAC Explorer page against the intermediate `/api/rbac/*`
 * correlation API.
 *
 * The correlated-endpoint fixture below intentionally exercises fields that
 * did not exist under the page's old client-side-stitched contract
 * (escalations, role-nested conformance identity, subject-count-derived
 * shared_by) — see rbac_correlation.py's module docstring and
 * docs/signalloom/rbac-live-wiring.md for the real AFM shapes that made the
 * old assumptions wrong. A regression back to those assumptions must fail a
 * test here, not just at the Python layer.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import RbacExplorerPage, { conformanceProofs, correlatedPath, escalationProofs } from './RbacExplorerPage'

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
const isDemoMode = vi.fn(() => false)
const fetchMock = vi.fn()

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
}))

// ── Fixtures ───────────────────────────────────────────────────────────────

const clustersFixture = [
  { id: 'remote', name: 'Remote Cluster' },
  { id: 'local', name: 'Local Cluster' },
]

/** Shaped like rbac_correlation.py's CorrelatedRbacResponse (snake_case wire). */
const correlatedFixture = {
  cluster: { id: 'local', name: 'Local Cluster' },
  namespaces: ['fe-signalloom', 'kube-system'],
  subjects: [
    { name: 'flux', kind: 'ServiceAccount', namespace: 'fe-signalloom', is_admin: false, is_escalation_actor: true },
    { name: 'system:masters', kind: 'Group', namespace: null, is_admin: true, is_escalation_actor: false },
  ],
  roles: [
    {
      name: 'cluster-admin', scope: 'Cluster', namespace: null,
      // `delete` is here because no role in this fixture previously carried a
      // verb the page actually colours, so the red-verb branch — the only key
      // this table has to "dangerous" — was never rendered by any test.
      rules: [{ verbs: ['*', 'delete'], apiGroups: ['*'], resources: ['*'] }],
      conformance_issue_count: 1, shared_by_count: 2, has_privileged_sharing: true,
    },
    {
      name: 'admin', scope: 'Cluster', namespace: null, rules: [],
      conformance_issue_count: 0, shared_by_count: 0, has_privileged_sharing: false,
    },
  ],
  bindings: [
    {
      name: 'cluster-admin', scope: 'Cluster', namespace: null, role_ref: 'cluster-admin',
      subjects: [{ name: 'system:masters', kind: 'Group', namespace: null, is_admin: true, is_escalation_actor: false }],
    },
    {
      name: 'flux', scope: 'Namespace', namespace: 'fe-signalloom', role_ref: 'admin',
      subjects: [{ name: 'flux', kind: 'ServiceAccount', namespace: 'fe-signalloom', is_admin: false, is_escalation_actor: true }],
    },
  ],
  escalations: [
    {
      kind: 'single', subject: 'sa_fe_signalloom_flux', subject_display: 'ServiceAccount/fe-signalloom/flux',
      escalation_type: 'admin_via_impersonation', risk_level: 'high', risk_score: 48,
      summary: 'ServiceAccount fe-signalloom/flux reaches all on * at cluster scope.',
    },
  ],
  conformance: [
    { role_name: 'cluster-admin', role_scope: 'Cluster', role_namespace: null, severity: 'high', reason: 'Contains escalate/bind or wildcard verb' },
  ],
  shared_roles: [
    { role_name: 'cluster-admin', role_scope: 'Cluster', role_namespace: null, shared_by: 2, subjects: ['Group/system:masters', 'ServiceAccount/x/y'], privileged_subject_count: 1 },
  ],
  admin_count: 1,
  non_admin_count: 1,
}

// ── Helpers ────────────────────────────────────────────────────────────────

function response(ok: boolean, body?: unknown, status = ok ? 200 : 500): Response {
  // content-type is part of the shape here because the client reads it: a 200
  // that is not JSON means the SPA catch-all answered instead of the API, and
  // is reported as such rather than parsed (see RbacUnreachableError).
  return {
    ok,
    status,
    headers: new Headers({ 'content-type': 'application/json' }),
    json: vi.fn().mockResolvedValue(body),
  } as unknown as Response
}

interface RouteOverrides {
  clusters?: () => Promise<Response>
  correlated?: () => Promise<Response>
}

function routeFetch(overrides: RouteOverrides = {}) {
  fetchMock.mockImplementation((input: RequestInfo | URL) => {
    const url = String(input)
    if (url === '/api/rbac/clusters') {
      return overrides.clusters ? overrides.clusters() : Promise.resolve(response(true, clustersFixture))
    }
    if (url === '/api/rbac/clusters/local/correlated' || url === '/api/rbac/clusters/remote/correlated') {
      return overrides.correlated ? overrides.correlated() : Promise.resolve(response(true, correlatedFixture))
    }
    return Promise.reject(new Error(`unexpected fetch: ${url}`))
  })
}

function requestedUrls(): string[] {
  return fetchMock.mock.calls.map(([input]) => String(input))
}

function requestHeaders(url: string): Headers {
  const call = fetchMock.mock.calls.find(([input]) => String(input) === url)
  const init = call?.[1] as RequestInit | undefined
  return new Headers(init?.headers)
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('RbacExplorerPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    isDemoMode.mockReturnValue(false)
    fetchMock.mockReset()
    Object.defineProperty(globalThis, 'fetch', { configurable: true, writable: true, value: fetchMock })
    routeFetch()
  })

  it('defaults to the local cluster and requests it with a bearer token', async () => {
    render(<RbacExplorerPage />)

    await waitFor(() => expect(screen.getByTestId('cluster-selector')).toHaveValue('local'))
    await waitFor(() => expect(requestedUrls()).toContain('/api/rbac/clusters/local/correlated'))

    expect(requestHeaders('/api/rbac/clusters/local/correlated').get('Authorization')).toBe('Bearer test-token')
  })

  it('shows the real escalation count, not zero, when AFM reports single_escalations', async () => {
    render(<RbacExplorerPage />)

    const stats = await screen.findByTestId('rbac-stats')
    expect(within(stats).getByText('1')).toBeInTheDocument()
    expect(within(stats).getByText('Requires attention')).toBeInTheDocument()
    expect(screen.getByText('Escalation Findings')).toBeInTheDocument()
    expect(screen.getByText(/reaches all on \* at cluster scope/i)).toBeInTheDocument()
  })

  it('reads conformance role identity from the nested role object', async () => {
    render(<RbacExplorerPage />)

    const conformanceSection = (await screen.findByRole('heading', { name: 'Conformance Issues' })).closest('section') as HTMLElement
    expect(within(conformanceSection).getByText('Contains escalate/bind or wildcard verb')).toBeInTheDocument()
    // role name must render from role_name, not a top-level field that doesn't exist
    expect(within(conformanceSection).getByText('cluster-admin')).toBeInTheDocument()
  })

  it('derives shared-by count from the correlated response, not an absent risk field', async () => {
    render(<RbacExplorerPage />)

    const sharedSection = (await screen.findByRole('heading', { name: 'Shared-Role Pivot Points' })).closest('section') as HTMLElement
    expect(within(sharedSection).getByText('2 subjects')).toBeInTheDocument()
    expect(within(sharedSection).getByText('1 privileged')).toBeInTheDocument()
  })

  it('flags the escalation-actor subject and admin subject with pills', async () => {
    render(<RbacExplorerPage />)

    await screen.findByTestId('rbac-stats')
    const subjectsSection = screen.getByRole('heading', { name: 'Subjects' }).closest('section') as HTMLElement

    // Scoped to the row rather than the section, as the admin assertion below
    // always was: the section now also holds a filter chip labelled
    // "escalation", and a pill that says nothing about WHICH subject is
    // flagged is not the thing this test means.
    const escalationRow = within(subjectsSection).getByText('flux').closest('tr') as HTMLTableRowElement
    expect(within(escalationRow).getByText('escalation')).toBeInTheDocument()

    const adminRow = within(subjectsSection).getByText('system:masters').closest('tr') as HTMLTableRowElement
    expect(within(adminRow).getByText('admin')).toBeInTheDocument()
  })

  it('fails visibly on a live-mode fetch failure and does not fall back to demo data', async () => {
    routeFetch({ correlated: () => Promise.resolve(response(false, { error: { code: 'afm_unreachable', message: 'KubeSec-AFM is unreachable' } }, 503)) })

    render(<RbacExplorerPage />)

    const error = await screen.findByTestId('rbac-live-error')
    expect(error).toHaveTextContent(/KubeSec-AFM is unreachable/i)
    expect(screen.queryByTestId('rbac-stats')).not.toBeInTheDocument()
  })

  it('retries the same live request when Retry is clicked after a failure', async () => {
    let succeed = false
    routeFetch({
      correlated: () => succeed
        ? Promise.resolve(response(true, correlatedFixture))
        : Promise.resolve(response(false, { error: { code: 'afm_unreachable', message: 'down' } }, 503)),
    })

    render(<RbacExplorerPage />)
    await screen.findByTestId('rbac-live-error')

    succeed = true
    await userEvent.click(within(screen.getByTestId('rbac-live-error')).getByRole('button', { name: /retry/i }))

    await screen.findByTestId('rbac-stats')
    expect(screen.queryByTestId('rbac-live-error')).not.toBeInTheDocument()
  })

  it('never issues a network request in demo mode', async () => {
    isDemoMode.mockReturnValue(true)

    render(<RbacExplorerPage />)

    await waitFor(() => expect(screen.getByTestId('cluster-selector')).toHaveValue('demo'))
    await screen.findByTestId('rbac-stats')

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('filters roles and bindings by the selected namespace', async () => {
    render(<RbacExplorerPage />)

    await screen.findByTestId('rbac-stats')
    await userEvent.selectOptions(screen.getByTestId('namespace-selector'), 'fe-signalloom')

    const rolesSection = screen.getByRole('heading', { name: 'Roles' }).closest('section') as HTMLElement
    // Cluster-scoped roles still show under a namespace filter; the
    // namespace-scoped admin role and flux binding must also be present.
    expect(within(rolesSection).getByText('cluster-admin')).toBeInTheDocument()
  })
  // Two columns here are read wrong by exactly the audiences this page is shown
  // to. "Risk" reads as an incident rather than a route that exists, and the
  // red verbs in "Verbs" have no key anywhere on the page saying what red means.
  describe('the tables explain what a finding and a red verb actually are', () => {
    // Reached by accessible name rather than test id: DataTable derives both
    // the name and the id from the column, and the name is the one a speech-input
    // user actually says. It is also the assertion that keeps failing if a
    // column is renamed without its hint being reconsidered.
    it('says a Risk level describes a route that exists, not a breach', async () => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      const hint = screen.getByRole('button', { name: 'What Risk means' })
      await user.hover(hint)
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/not a breach that happened/i)
    })

    it('gives the red verbs a key, since nothing else on the page has one', async () => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await user.hover(screen.getByRole('button', { name: 'What Verbs means' }))
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/red/i)
      for (const verb of ['escalate', 'impersonate', 'bind']) {
        expect(tooltip.textContent).toContain(verb)
      }
      // The wildcard is the one verb the cell deliberately leaves uncoloured
      // while it grants every red verb, so the key has to say so.
      expect(tooltip.textContent).toMatch(/wildcard/i)
    })

    it('does not hint the headers that already say themselves', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      // Scoped to Roles: this is the table the assertion was written against,
      // and "Namespace" is genuinely not self-evident on Conformance Issues,
      // where the column renders the literal word "cluster" for a ClusterRole.
      const rolesSection = screen.getByRole('heading', { name: 'Roles' }).closest('section') as HTMLElement
      expect(within(rolesSection).queryByRole('button', { name: 'What Name means' })).toBeNull()
      expect(within(rolesSection).queryByRole('button', { name: 'What Namespace means' })).toBeNull()
    })

    // The four things a reader of this page has to guess at today, each
    // reachable by the name a screen reader announces.
    it.each([
      ['What Kind means', /ServiceAccount is an in-cluster identity/i],
      ['What Scope means', /applies in every namespace at once/i],
      ['What Bound Roles means', /a binding carries its own scope/i],
      ['What Flags means', /escalation means the analyser found a route/i],
      ['What the Namespace filter does', /cluster-scoped objects stay listed/i],
      ['What Shared By means', /pivot point/i],
    ])('explains %s', async (name, expected) => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await user.hover(screen.getByRole('button', { name }))
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(expected)
    })
  })

  // Every table gained a toolbar. The rule for each is the same: the search
  // narrows its own table and nothing else, the empty state says which nothing
  // this is, and the control that emptied the table is still on screen.
  describe('every table filters, and an empty result can be undone', () => {
    const TABLES = [
      { name: 'Escalation Findings', prefix: 'rbac-escalations', search: 'rbac-escalations-search', chip: 'rbac-escalations-risk-high', allChip: 'rbac-escalations-risk-all', clear: 'rbac-escalations-clear', match: 'flux' },
      { name: 'Conformance Issues', prefix: 'rbac-conformance', search: 'rbac-conformance-search', chip: 'rbac-conformance-severity-high', allChip: 'rbac-conformance-severity-all', clear: 'rbac-conformance-clear', match: 'wildcard' },
      { name: 'Shared-Role Pivot Points', prefix: 'rbac-shared', search: 'rbac-shared-search', chip: 'rbac-shared-privileged-privileged', allChip: 'rbac-shared-privileged-all', clear: 'rbac-shared-clear', match: 'cluster-admin' },
      { name: 'Roles', prefix: 'rbac-roles', search: 'rbac-roles-search', chip: 'rbac-roles-scope-cluster', allChip: 'rbac-roles-scope-all', clear: 'rbac-roles-clear', match: 'admin' },
      { name: 'Subjects', prefix: 'subjects', search: 'subjects-search', chip: 'subjects-kind-Group', allChip: 'subjects-kind-all', clear: 'subjects-clear', match: 'flux' },
    ] as const

    it.each(TABLES)('$name has a toolbar whose search narrows only its own table', async ({ prefix, search }) => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      expect(screen.getByTestId(`${prefix}-toolbar`)).toBeInTheDocument()
      const total = screen.getByTestId(`${prefix}-count`).textContent?.match(/of (\d+) shown/)?.[1]
      expect(total).toBeDefined()

      await user.type(screen.getByTestId(search), 'zzz-no-such-thing')

      // Shown goes to nothing; the total after "of" does not move. A headline
      // figure a search box can change is the failure this page exists to avoid.
      expect(screen.getByTestId(`${prefix}-count`).textContent).toBe(`0 of ${total} shown`)
      // And no OTHER table's toolbar moved with it.
      for (const other of TABLES.filter((t) => t.prefix !== prefix)) {
        expect(screen.getByTestId(`${other.prefix}-count`).textContent).not.toMatch(/^0 of/)
      }
    })

    it.each(TABLES)('$name shows a clearable empty state when nothing matches', async ({ prefix, search, clear }) => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await user.type(screen.getByTestId(search), 'zzz-no-such-thing')

      const empty = await screen.findByTestId(`${prefix}-empty`)
      expect(empty).toHaveTextContent(/nothing matches those filters/i)
      // The toolbar outlives the table — this is the whole reason `toolbar` is
      // a DataTable prop rather than something the page stacks above it.
      expect(screen.getByTestId(`${prefix}-toolbar`)).toBeInTheDocument()

      await user.click(within(empty).getByTestId(clear))
      expect(screen.queryByTestId(`${prefix}-empty`)).toBeNull()
      expect(screen.getByTestId(search)).toHaveValue('')
    })

    it.each(TABLES)('$name narrows to its chip selection and back', async ({ chip, allChip }) => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      const button = screen.getByTestId(chip)
      expect(button).toHaveAttribute('aria-pressed', 'false')
      expect(screen.getByTestId(allChip)).toHaveAttribute('aria-pressed', 'true')

      await user.click(button)
      expect(button).toHaveAttribute('aria-pressed', 'true')
      expect(screen.getByTestId(allChip)).toHaveAttribute('aria-pressed', 'false')

      await user.click(screen.getByTestId(allChip))
      expect(button).toHaveAttribute('aria-pressed', 'false')
    })

    // The base fixture has one row in most tables, which can show a chip
    // SELECTING but not a chip NARROWING. This one has two rows everywhere,
    // one of which each discriminating chip must exclude.
    const twoRowFixture = {
      ...correlatedFixture,
      escalations: [
        ...correlatedFixture.escalations,
        {
          kind: 'group', subject: 'grp_readers', subject_display: 'Group/readers',
          escalation_type: 'admin_via_bind', risk_level: 'low', risk_score: 4,
          summary: 'Group readers can bind itself to a wider role.',
        },
      ],
      conformance: [
        ...correlatedFixture.conformance,
        { role_name: 'admin', role_scope: 'Cluster', role_namespace: null, severity: 'low', reason: 'Broad resource match' },
      ],
      shared_roles: [
        ...correlatedFixture.shared_roles,
        { role_name: 'view', role_scope: 'Cluster', role_namespace: null, shared_by: 9, subjects: ['Group/readers'], privileged_subject_count: 0 },
      ],
      roles: [
        ...correlatedFixture.roles,
        {
          name: 'ns-reader', scope: 'Namespace', namespace: 'fe-signalloom', rules: [],
          conformance_issue_count: 0, shared_by_count: 0, has_privileged_sharing: false,
        },
      ],
    }

    it.each([
      ['rbac-escalations', 'rbac-escalations-risk-high', '1 of 2 shown'],
      ['rbac-conformance', 'rbac-conformance-severity-high', '1 of 2 shown'],
      ['rbac-shared', 'rbac-shared-privileged-privileged', '1 of 2 shown'],
      ['rbac-roles', 'rbac-roles-scope-namespace', '1 of 3 shown'],
      ['subjects', 'subjects-kind-Group', '1 of 2 shown'],
    ])('%s narrows to %s', async (prefix, chip, expected) => {
      routeFetch({ correlated: () => Promise.resolve(response(true, twoRowFixture)) })
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await user.click(screen.getByTestId(chip))
      expect(screen.getByTestId(`${prefix}-count`).textContent).toBe(expected)
    })

    it('narrows subjects by kind without moving the Subjects stat', async () => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      const stats = await screen.findByTestId('rbac-stats')

      const subjectsSection = screen.getByRole('heading', { name: 'Subjects' }).closest('section') as HTMLElement
      expect(within(subjectsSection).getByText('flux')).toBeInTheDocument()

      await user.click(screen.getByTestId('subjects-kind-Group'))

      expect(within(subjectsSection).queryByText('flux')).toBeNull()
      expect(within(subjectsSection).getByText('system:masters')).toBeInTheDocument()
      // The stat cards read the cluster, not the view: the headline still says
      // 2 subjects while the table below it is showing 1.
      const subjectsCard = within(stats).getByText('Subjects').parentElement as HTMLElement
      expect(subjectsCard.textContent).toBe('Subjects21 admins, 1 non-admin')
    })

    it('filters subjects by the escalation flag, which overlaps with admin', async () => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await user.click(screen.getByTestId('subjects-flag-escalation'))

      const subjectsSection = screen.getByRole('heading', { name: 'Subjects' }).closest('section') as HTMLElement
      expect(within(subjectsSection).getByText('flux')).toBeInTheDocument()
      expect(within(subjectsSection).queryByText('system:masters')).toBeNull()
    })

    it('counts chips against the source, so a count cannot move as you narrow', async () => {
      const user = userEvent.setup()
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      const before = screen.getByTestId('subjects-kind-Group').textContent
      await user.type(screen.getByTestId('subjects-search'), 'flux')
      expect(screen.getByTestId('subjects-kind-Group').textContent).toBe(before)
    })
  })

  // rbac_correlation.py's docstring: "A security dashboard that silently
  // reports zero escalations when there are three is worse than one that
  // errors visibly." These two tests are the UI half of that argument — the
  // same page must look different in the two cases.
  describe('an unreachable upstream never presents as zero', () => {
    it('renders no figure at all when AFM is unreachable', async () => {
      routeFetch({ correlated: () => Promise.resolve(response(false, { error: { code: 'afm_unreachable', message: 'KubeSec-AFM is unreachable' } }, 503)) })

      render(<RbacExplorerPage />)

      await screen.findByTestId('rbac-live-error')
      expect(screen.queryByTestId('rbac-stats')).not.toBeInTheDocument()
      expect(screen.queryByTestId('rbac-escalations-empty')).toBeNull()
      // Nothing anywhere claims a count.
      expect(screen.queryByText('Escalation Paths')).toBeNull()
    })

    it('says AFM reported none — not just "0" — when the analysis genuinely found nothing', async () => {
      routeFetch({
        correlated: () => Promise.resolve(response(true, { ...correlatedFixture, escalations: [] })),
      })

      render(<RbacExplorerPage />)

      const stats = await screen.findByTestId('rbac-stats')
      expect(within(stats).getByText('AFM reported none')).toBeInTheDocument()
      expect(screen.queryByTestId('rbac-live-error')).toBeNull()
      // And the reason that zero can be trusted is on the card itself.
      await userEvent.hover(within(stats).getByRole('button', { name: 'What Escalation Paths counts' }))
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/had AFM been unreachable this panel would not be on screen/i)
    })

    it('distinguishes an empty cluster from an unreachable one', async () => {
      routeFetch({ correlated: () => Promise.resolve(response(true, null)) })

      render(<RbacExplorerPage />)

      // Whichever branch a null payload lands in, it must not be the one that
      // reads as a healthy zero.
      await waitFor(() => {
        const noData = screen.queryByTestId('rbac-no-data')
        const liveError = screen.queryByTestId('rbac-live-error')
        expect(noData ?? liveError).not.toBeNull()
      })
      expect(screen.queryByText('AFM reported none')).toBeNull()
    })
  })

  // The red verbs are the only key this table has to "dangerous", and the help
  // hint above promises them.
  describe('the dangerous verbs actually render red', () => {
    it('tints the chip with color-mix rather than a string concatenation that is not a colour', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      const chip = screen.getByText('delete', { selector: 'span' })
      // `${colors.red}20` produced `var(--error)20`, which every browser drops
      // — so the verb the help hint calls dangerous had no fill at all.
      expect(chip.style.background).not.toContain('var(--error)20')
      expect(chip.style.background).toContain('color-mix')
      expect(chip.style.background).toContain('var(--error)')
      expect(chip.style.color).toBe('var(--error)')
    })

    it('leaves an ordinary verb on the neutral surface', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      // Pinned so the fill fix above cannot quietly turn the whole column red.
      const wildcard = screen.getByText('*', { selector: 'span' })
      expect(wildcard.style.background).toBe('var(--surface2)')
    })
  })

  // A finding here says a ServiceAccount can become admin. Z3 ran two systems
  // away and cannot be re-run from a browser, so the proof is the request this
  // page made and the record it got back, before anything reworded it.
  describe('how do we know a finding is real', () => {
    it('shows the correlated request and the wire record behind an escalation', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await userEvent.click(screen.getByTestId('rbac-escalation-disclose-0'))

      const panel = screen.getByTestId('rbac-escalation-console-0-panel')
      expect(panel.textContent).toContain('/api/rbac/clusters/local/correlated')
      expect(panel.textContent).toContain('Authorization: Bearer $TOKEN')
      expect(panel.textContent).toContain('select(.subject == "sa_fe_signalloom_flux")')
      // Snake_case, because that is what the endpoint prints — the camelCase
      // the page renders from is this client's doing, not AFM's.
      expect(panel.textContent).toContain('"escalation_type": "admin_via_impersonation"')
      expect(panel.textContent).toContain('"risk_score": 48')
    })

    it('shows the role’s whole conformance record behind a conformance issue', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await userEvent.click(screen.getByTestId('rbac-conformance-disclose-0'))

      const panel = screen.getByTestId('rbac-conformance-console-0-panel')
      expect(panel.textContent).toContain('select(.role_name == "cluster-admin")')
      expect(panel.textContent).toContain('"reason": "Contains escalate/bind or wildcard verb"')
      // role_namespace was null on the wire and null is what jq prints.
      expect(panel.textContent).toContain('"role_namespace": null')
    })

    it('closes again from the same control', async () => {
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      const toggle = screen.getByTestId('rbac-escalation-disclose-0')
      await userEvent.click(toggle)
      expect(toggle.textContent).toBe('Hide proof')
      await userEvent.click(toggle)
      expect(screen.queryByTestId('rbac-escalation-console-0')).toBeNull()
    })

    it('refuses to invent a command in demo mode, where no request was made', async () => {
      // Demo mode builds the whole page from buildFakeCorrelated() and never
      // touches the network — asserted by the test above. A curl line here
      // would name a request that did not happen.
      isDemoMode.mockReturnValue(true)
      render(<RbacExplorerPage />)
      await screen.findByTestId('rbac-stats')

      await userEvent.click(screen.getByTestId('rbac-escalation-disclose-0'))
      const console_ = screen.getByTestId('rbac-escalation-console-0')
      expect(console_.textContent).toContain('no proof was recorded')
      expect(console_.textContent).not.toContain('curl')
      expect(fetchMock).not.toHaveBeenCalled()
    })

    it('names the cluster that was actually requested, url-encoded as the client encodes it', () => {
      expect(correlatedPath('a/b')).toBe('/api/rbac/clusters/a%2Fb/correlated')
    })

    it('prints every match, because a subject can carry more than one route', () => {
      const one = { kind: 'single' as const, subject: 's', riskLevel: 'high' }
      const two = { kind: 'group' as const, subject: 's', riskLevel: 'medium' }
      const [proof] = escalationProofs(one, [one, two], 'local', false)
      expect(proof.detail).toContain('"risk_level": "high"')
      expect(proof.detail).toContain('"risk_level": "medium"')
      // Absent optional fields print as null, exactly as the command does.
      expect(proof.detail).toContain('"summary": null')
    })

    it('compares against null when the parse left the key absent', () => {
      const finding = { severity: 'high', reason: 'unnamed role' }
      const [proof] = conformanceProofs(finding, [finding], 'local', false)
      expect(proof.command).toContain('select(.role_name == null)')
    })
  })
})
