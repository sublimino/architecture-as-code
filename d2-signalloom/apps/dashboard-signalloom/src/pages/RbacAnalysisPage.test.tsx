/**
 * Tests for the RBAC Analysis page and the read-only RBAC importer panel it
 * hosts above the embedded KubeSec-AFM dashboard.
 *
 * The fetch mock is routed by URL rather than by call order on purpose: the
 * page's own health probe and the importer panel's cluster/RBAC load run
 * concurrently on mount, so call ordering is not deterministic and asserting
 * on it would make the suite flaky.
 *
 * The importer is strictly read-only, so one test asserts that no request ever
 * carries a method other than GET.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import RbacAnalysisPage, { afmReachabilityProofs } from './RbacAnalysisPage'

// getAccessTokenSilently must keep a STABLE identity across renders, otherwise
// the effects that depend on it are recreated every render and re-fire.
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
const isDemoMode = vi.fn(() => false)
const fetchMock = vi.fn()
const writeText = vi.fn().mockResolvedValue(undefined)

vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
}))

// ── Fixtures ───────────────────────────────────────────────────────────────

// `local` is deliberately not first — the panel must still default to it.
const clustersFixture = [
  { id: 'remote', name: 'Remote Cluster' },
  { id: 'local', name: 'Local Cluster' },
]

/**
 * Deliberately typed `unknown` and shaped like AFM's actual wire format rather
 * than like `RBACData`: cluster-scoped items carry `namespace: null` (not an
 * omitted key), bindings carry an unmodelled `roleRefKind: null`, subjects
 * carry `annotations`, and an aggregated ClusterRole carries `rules: null`.
 * Writing this fixture to the interface instead of the wire is what let the
 * importer ship unable to parse a single real payload.
 */
const rbacFixture: unknown = {
  subjects: [
    { name: 'frontend', kind: 'ServiceAccount', namespace: 'apps', annotations: {} },
    { name: 'kustomize-controller', kind: 'ServiceAccount', namespace: 'flux-system', annotations: {} },
    { name: 'alice', kind: 'User', namespace: null, annotations: {} },
  ],
  roles: [
    {
      name: 'secret-reader',
      scope: 'Namespace',
      namespace: 'apps',
      rules: [{ verbs: ['get', 'list'], apiGroups: [''], resources: ['secrets'] }],
    },
    {
      name: 'flux-applier',
      scope: 'Namespace',
      namespace: 'flux-system',
      rules: [{ verbs: ['create'], apiGroups: ['apps'], resources: ['deployments'] }],
    },
    {
      name: 'system:masters',
      scope: 'Cluster',
      namespace: null,
      rules: [{ verbs: ['*'], apiGroups: ['*'], resources: ['*'] }],
    },
    { name: 'view', scope: 'Cluster', namespace: null, rules: null },
  ],
  bindings: [
    {
      name: 'frontend-reader',
      scope: 'Namespace',
      namespace: 'apps',
      roleRef: 'secret-reader',
      roleRefKind: null,
      subjects: [{ name: 'frontend', kind: 'ServiceAccount', namespace: 'apps' }],
    },
    {
      name: 'flux-global',
      scope: 'Cluster',
      namespace: null,
      roleRef: 'system:masters',
      roleRefKind: null,
      subjects: [{ name: 'kustomize-controller', kind: 'ServiceAccount', namespace: 'flux-system' }],
    },
  ],
  namespaces: [],
}

// ── Helpers ────────────────────────────────────────────────────────────────

// `status` is part of the shape because a real Response always has one, and
// the page now keeps it: the health proof shows the code the service answered
// with, and a fixture without one would have let "undefined" render as
// evidence.
function response(ok: boolean, body?: unknown, status = ok ? 200 : 500): Response {
  return { ok, status, json: vi.fn().mockResolvedValue(body) } as unknown as Response
}

interface RouteOverrides {
  health?: () => Promise<Response>
  clusters?: () => Promise<Response>
  rbac?: () => Promise<Response>
}

/** Routes fetch by URL so concurrent page + panel loads stay deterministic. */
function routeFetch(overrides: RouteOverrides = {}) {
  fetchMock.mockImplementation((input: RequestInfo | URL) => {
    const url = String(input)
    if (url === '/afm/health') {
      return overrides.health ? overrides.health() : Promise.resolve(response(true))
    }
    if (url === '/afm/clusters') {
      return overrides.clusters ? overrides.clusters() : Promise.resolve(response(true, clustersFixture))
    }
    if (url === '/afm/clusters/local/rbac' || url === '/afm/clusters/remote/rbac') {
      return overrides.rbac ? overrides.rbac() : Promise.resolve(response(true, rbacFixture))
    }
    return Promise.reject(new Error(`unexpected fetch: ${url}`))
  })
}

function requestedUrls(): string[] {
  return fetchMock.mock.calls.map(([input]) => String(input))
}

function yamlTextarea(): HTMLTextAreaElement {
  return screen.getByTestId('importer-yaml') as HTMLTextAreaElement
}

/** Waits for both the page health probe and the panel's initial load to settle. */
async function waitForImporterReady() {
  await screen.findByText(/afm connected/i)
  await waitFor(() => {
    expect(screen.getByTestId('importer-fetch')).not.toBeDisabled()
  })
}

function expectDomOrder(first: Element, second: Element) {
  expect(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('RbacAnalysisPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    isDemoMode.mockReturnValue(false)
    fetchMock.mockReset()
    writeText.mockReset()
    writeText.mockResolvedValue(undefined)
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      writable: true,
      value: fetchMock,
    })
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    })
    routeFetch()
  })

  describe('existing page behaviour', () => {
    it('probes AFM health and renders the iframe when reachable', async () => {
      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      // In live mode (default), the cluster count shows "Host Cluster" instead of "2 clusters"
      expect(screen.getByTestId('cluster-count')).toHaveTextContent(/host cluster/i)
      // The embed must name a cluster. AFM selects NOTHING on a bare
      // /dashboard/ — verified against the live instance — so an
      // unparameterised iframe renders an empty frame and every import looks
      // like it never arrived. With no SignalLoom import in this fixture the
      // host cluster is the correct fallback.
      expect(screen.getByTestId('afm-iframe')).toHaveAttribute('src', '/dashboard/?cluster=local')

      expect(requestedUrls()).toContain('/afm/health')
      expect(requestedUrls()).toContain('/afm/clusters')
    })

    it('shows cluster count in demo mode', async () => {
      isDemoMode.mockReturnValue(true)

      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      expect(screen.getByTestId('cluster-count')).toHaveTextContent('2 clusters')
    })

    it('renders the heading controls in a stable DOM order', async () => {
      render(<RbacAnalysisPage />)

      await screen.findByText(/afm connected/i)

      const heading = screen.getByRole('heading', { level: 1, name: /rbac analysis/i })
      const reload = screen.getByRole('button', { name: /reload/i })
      const openFull = screen.getByRole('link', { name: /open full/i })

      expectDomOrder(heading, reload)
      expectDomOrder(reload, openFull)
    })

    it('shows the demo banner when runtime demo mode is enabled', async () => {
      isDemoMode.mockReturnValue(true)

      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/demo mode/i)).toBeInTheDocument()
      expect(screen.getByText(/seeded sample clusters/i)).toBeInTheDocument()
    })

    it('shows the unreachable state and re-probes on Retry connection', async () => {
      let healthy = false
      routeFetch({ health: () => Promise.resolve(response(healthy)) })

      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/platform is not reachable/i)).toBeInTheDocument()
      expect(screen.getByText(/make demo-k8s-afm-up/i)).toBeInTheDocument()
      expect(screen.queryByTestId('afm-iframe')).not.toBeInTheDocument()

      // The importer panel sits above the iframe, so it must survive the
      // page-level unreachable state rather than being replaced by it.
      expect(screen.getByTestId('rbac-importer')).toBeInTheDocument()

      healthy = true
      // "Retry", not "Retry connection": the panel is ErrorState now, which is
      // where the shared wording (and the 401 rule) lives.
      await userEvent.click(within(screen.getByTestId('afm-unreachable')).getByTestId('error-retry'))

      await waitFor(() => {
        expect(screen.getByTestId('afm-iframe')).toBeInTheDocument()
      })
      expect(requestedUrls().filter(url => url === '/afm/health').length).toBeGreaterThanOrEqual(2)
    })
  })

  describe('the header controls are built out of the shared design system', () => {
    it('lets .btn-secondary own the colours instead of overriding half of it inline', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      const add = screen.getByTestId('add-cluster-btn')
      expect(add.className.split(/\s+/)).toEqual(expect.arrayContaining(['btn', 'btn-secondary']))
      // The cyan border-and-colour pair that used to sit here was an inline
      // copy of a different variant, laid over the one the class declares.
      expect(add.style.border).toBe('')
      expect(add.style.color).toBe('')
    })

    it('gives the external link the shared class rather than two JS mouse handlers', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      const link = screen.getByRole('link', { name: /open full/i })
      expect(link.className.split(/\s+/)).toEqual(expect.arrayContaining(['btn', 'btn-secondary']))
      // It stays an anchor: it opens a new tab and must remain middle-clickable.
      expect(link.tagName).toBe('A')
      expect(link).toHaveAttribute('target', '_blank')
      // `.btn:focus-visible` now supplies the focus ring the hand-rolled
      // border never had.
      expect(link.style.borderColor).toBe('')
    })

    it('uses the shared ErrorState for the whole-panel failure, and keeps the remediation command', async () => {
      routeFetch({ health: () => Promise.resolve(response(false)) })
      render(<RbacAnalysisPage />)

      const panel = await screen.findByTestId('afm-unreachable')
      expect(within(panel).getByTestId('error-retry')).toBeInTheDocument()
      expect(within(panel).getByText(/platform is not reachable/i)).toBeInTheDocument()
      // Dropping this to fit the component would have made the migration cost
      // the reader the most useful thing on the screen.
      expect(within(panel).getByText(/make demo-k8s-afm-up/i)).toBeInTheDocument()
    })
  })

  // "AFM connected" and a cluster count are claims about another system. Both
  // came from a request this page issued seconds ago, so both can be re-run.
  describe('how do we know AFM is connected', () => {
    it('shows the status probe and the cluster query behind the indicator', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.click(screen.getByTestId('afm-proof-toggle'))

      const panel = screen.getByTestId('afm-proof-console-panel')
      expect(panel.textContent).toContain('/afm/health')
      expect(panel.textContent).toContain('200')

      // Two proofs, so a tab strip. The second is the source of the count.
      await userEvent.click(screen.getByTestId('afm-proof-console-tab-1'))
      const clusters = screen.getByTestId('afm-proof-console-panel')
      expect(clusters.textContent).toContain(`curl -s /afm/clusters | jq 'length'`)
      expect(clusters.textContent).toContain('2')
    })

    it('sends no bearer header in the command, because the page sends none either', () => {
      const proofs = afmReachabilityProofs({
        reachable: true, clusterCount: 2, checkedAt: new Date(), healthStatus: 200,
      })
      // A command that would not run as written is worse than no proof.
      expect(proofs.every(p => !p.command.includes('Authorization'))).toBe(true)
    })

    it('reports the code the service actually answered with, not a rounded verdict', () => {
      const proofs = afmReachabilityProofs({
        reachable: false, clusterCount: null, checkedAt: new Date(), healthStatus: 503,
      })
      expect(proofs).toHaveLength(1)
      expect(proofs[0].detail).toBe('503')
    })

    it('offers no proof at all when the request never completed', async () => {
      // curl would print its own failure here and this page did not record it.
      // "Unreachable" is the verdict a reader is most entitled to check, which
      // makes it the worst possible place to guess.
      expect(afmReachabilityProofs({
        reachable: false, clusterCount: null, checkedAt: new Date(), healthStatus: null,
      })).toEqual([])

      routeFetch({ health: () => Promise.reject(new Error('connection refused')) })
      render(<RbacAnalysisPage />)

      await userEvent.click(await screen.findByTestId('afm-proof-toggle'))
      const console_ = screen.getByTestId('afm-proof-console')
      expect(console_.textContent).toContain('no proof was recorded')
      expect(console_.textContent).not.toContain('curl')
    })
  })

  describe('RBAC importer panel', () => {
    it('renders above the embedded AFM iframe in DOM order', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()

      expectDomOrder(screen.getByTestId('rbac-importer'), screen.getByTestId('afm-iframe'))
    })

    it('defaults to the local cluster and loads its RBAC on mount', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()

      // In live mode (default), the importer shows a single "Host Cluster" entry
      // as a static div (not a select), so we check text content rather than value.
      const clusterEl = screen.getByTestId('importer-cluster-select')
      expect(clusterEl).toHaveTextContent(/host cluster/i)
      expect(clusterEl).toHaveTextContent(/local/)
      expect(requestedUrls()).toContain('/afm/clusters/local/rbac')
    })

    it('shows multiple clusters as a dropdown in demo mode', async () => {
      isDemoMode.mockReturnValue(true)

      render(<RbacAnalysisPage />)

      await waitForImporterReady()

      const clusterSelect = screen.getByTestId('importer-cluster-select')
      expect(clusterSelect.tagName).toBe('SELECT')
      expect(clusterSelect).toHaveValue('local')
    })

    it('populates the namespace select from the RBAC response', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()

      const select = screen.getByTestId('importer-namespace-select')
      await waitFor(() => {
        expect(within(select).getAllByRole('option')).toHaveLength(3)
      })

      expect(within(select).getAllByRole('option').map(option => option.textContent))
        .toEqual(['All namespaces', 'apps', 'flux-system'])
    })

    it('issues GET /afm/clusters/local/rbac when Generate YAML is clicked', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      const before = requestedUrls().filter(url => url === '/afm/clusters/local/rbac').length

      await userEvent.click(screen.getByTestId('importer-fetch'))

      await waitFor(() => {
        expect(requestedUrls().filter(url => url === '/afm/clusters/local/rbac').length).toBe(before + 1)
      })
    })

    it('puts YAML containing the fetched role names into the textarea', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await userEvent.click(screen.getByTestId('importer-fetch'))

      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })
      const yaml = yamlTextarea().value
      // The importer generates a unique import ID per click (signalloom-<timestamp>-<hex>)
      // rather than reusing the cluster's own id. Assert the pattern, not a literal.
      expect(yaml).toMatch(/id: signalloom-\d{8}T\d{6}-[0-9a-f]{4}/)
      // In live mode (default), the importer relabels the cluster with a timestamped name
      expect(yaml).toMatch(/name: SignalLoom Import \d{4}-\d{2}-\d{2}/)
      expect(yaml).toContain('system:masters')
      expect(yaml).toContain('flux-applier')
    })

    it('excludes another namespace’s roles once a namespace is selected', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await waitFor(() => {
        expect(within(screen.getByTestId('importer-namespace-select')).getAllByRole('option')).toHaveLength(3)
      })

      await userEvent.selectOptions(screen.getByTestId('importer-namespace-select'), 'apps')
      await userEvent.click(screen.getByTestId('importer-fetch'))

      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })
      const yaml = yamlTextarea().value
      // flux-applier is namespace-scoped to flux-system, so it must be dropped.
      expect(yaml).not.toContain('flux-applier')
      // system:masters is cluster-scoped, so it must be retained.
      expect(yaml).toContain('system:masters')
    })

    it('copies the textarea content and confirms the copy', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await userEvent.click(screen.getByTestId('importer-fetch'))
      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })

      const expected = yamlTextarea().value
      await userEvent.click(screen.getByTestId('importer-copy'))

      expect(writeText).toHaveBeenCalledTimes(1)
      expect(writeText).toHaveBeenCalledWith(expected)
      expect(await screen.findByText('Copied')).toBeInTheDocument()
    })

    it('surfaces a hint instead of throwing when the clipboard is unavailable', async () => {
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined })

      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await userEvent.click(screen.getByTestId('importer-fetch'))
      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })

      await userEvent.click(screen.getByTestId('importer-copy'))

      expect(await screen.findByText(/clipboard unavailable/i)).toBeInTheDocument()
    })

    it('surfaces a hint when the clipboard write rejects', async () => {
      writeText.mockRejectedValue(new Error('denied'))

      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await userEvent.click(screen.getByTestId('importer-fetch'))
      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })

      await userEvent.click(screen.getByTestId('importer-copy'))

      expect(await screen.findByText(/clipboard unavailable/i)).toBeInTheDocument()
    })

    it('renders an inline error when the RBAC fetch rejects', async () => {
      routeFetch({ rbac: () => Promise.reject(new Error('network down')) })

      render(<RbacAnalysisPage />)

      expect(await screen.findByTestId('importer-error')).toHaveTextContent(/network down/i)
      // The page itself must be unaffected.
      expect(screen.getByRole('heading', { level: 1, name: /rbac analysis/i })).toBeInTheDocument()
      expect(await screen.findByTestId('afm-iframe')).toBeInTheDocument()
    })

    it('renders an inline error when the RBAC fetch returns a non-OK status', async () => {
      routeFetch({ rbac: () => Promise.resolve(response(false)) })

      render(<RbacAnalysisPage />)

      expect(await screen.findByTestId('importer-error')).toHaveTextContent(/\/afm\/clusters\/local\/rbac/)
      expect(screen.getByTestId('rbac-importer')).toBeInTheDocument()
      expect(yamlTextarea().value).toBe('')
    })

    it('renders an inline error when AFM returns an invalid RBAC shape', async () => {
      routeFetch({ rbac: () => Promise.resolve(response(true, { subjects: 'nope' })) })

      render(<RbacAnalysisPage />)

      expect(await screen.findByTestId('importer-error')).toHaveTextContent(/"subjects" is not an array/i)
      expect(await screen.findByTestId('importer-error')).toHaveTextContent(/\/clusters\/local\/rbac/)
      expect(screen.getByTestId('rbac-importer')).toBeInTheDocument()
    })

    it('accepts null namespaces from the real AFM payload and omits them from the YAML', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      expect(screen.queryByTestId('importer-error')).not.toBeInTheDocument()

      await userEvent.click(screen.getByTestId('importer-fetch'))
      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })

      const yaml = yamlTextarea().value
      expect(yaml).not.toContain('null')
      expect(yaml).toContain('system:masters')
      expect(yaml).toContain('rules: []')       // the aggregated ClusterRole
      expect(yaml).toContain('namespace: apps') // a real namespace still survives
    })

    it('never issues a non-GET request', async () => {
      render(<RbacAnalysisPage />)

      await waitForImporterReady()
      await userEvent.click(screen.getByTestId('importer-fetch'))
      await waitFor(() => {
        expect(yamlTextarea().value).toContain('secret-reader')
      })
      await userEvent.click(screen.getByTestId('importer-copy'))

      expect(fetchMock.mock.calls.length).toBeGreaterThan(0)
      expect(fetchMock.mock.calls.every(([, init]) => {
        const method = (init as RequestInit | undefined)?.method
        return method === undefined || method === 'GET'
      })).toBe(true)
    })
  })

  describe('host cluster and Add Cluster', () => {
    it('shows the host cluster indicator in live mode', async () => {
      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      expect(screen.getByTestId('host-cluster-indicator')).toHaveTextContent(/live mode/i)
      expect(screen.getByTestId('host-cluster-indicator')).toHaveTextContent(/host cluster/i)
    })

    it('hides the host cluster indicator in demo mode', async () => {
      isDemoMode.mockReturnValue(true)

      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      expect(screen.queryByTestId('host-cluster-indicator')).not.toBeInTheDocument()
    })

    it('renders an Add Cluster button', async () => {
      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      expect(screen.getByTestId('add-cluster-btn')).toBeInTheDocument()
      expect(screen.getByTestId('add-cluster-btn')).toHaveTextContent(/add cluster/i)
    })

    it('opens the Add Cluster modal when the button is clicked', async () => {
      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      await userEvent.click(screen.getByTestId('add-cluster-btn'))

      expect(screen.getByTestId('add-cluster-modal')).toBeInTheDocument()
      expect(screen.getByTestId('add-cluster-name')).toBeInTheDocument()
      expect(screen.getByTestId('add-cluster-method')).toBeInTheDocument()
      expect(screen.getByTestId('add-cluster-value')).toBeInTheDocument()
    })

    it('shows success after submitting the Add Cluster form', async () => {
      render(<RbacAnalysisPage />)

      expect(await screen.findByText(/afm connected/i)).toBeInTheDocument()
      await userEvent.click(screen.getByTestId('add-cluster-btn'))

      await userEvent.type(screen.getByTestId('add-cluster-name'), 'staging-eu')
      await userEvent.type(screen.getByTestId('add-cluster-value'), '/home/user/.kube/staging')
      await userEvent.click(screen.getByTestId('add-cluster-submit'))

      expect(await screen.findByTestId('add-cluster-success')).toHaveTextContent(/staging-eu/i)
    })
  })

  // Every noun this page uses is a formal-methods RBAC term, and not one of
  // them means what an English reader would guess: "escalation" sounds like a
  // severity, "collusion" sounds like an accusation, and "min-cut" sounds like
  // nothing at all. Until these hints there was no explanation of any of it
  // anywhere on the page.
  describe('the RBAC vocabulary is explained where it is used', () => {
    const HINTS = [
      ['rbac-hint-escalation', 'What privilege escalation means'],
      ['rbac-hint-collusion', 'What collusion means'],
      ['rbac-hint-mincut', 'What min-cut remediation means'],
      ['rbac-hint-afm-status', 'What the AFM status line means'],
      ['rbac-hint-add-cluster', 'What Add Cluster does'],
    ] as const

    it.each(HINTS)('%s is a named, keyboard-reachable affordance', async (testId, name) => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      const hint = screen.getByTestId(testId)
      // A real <button>, so it is in the tab order and opens on focus — a hint
      // that only answers a mouse is not an explanation, it is a decoration.
      expect(hint.tagName).toBe('BUTTON')
      expect(hint).toHaveAccessibleName(name)
    })

    it('names the wildcard verb as the edge an escalation path is usually built from', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.hover(screen.getByTestId('rbac-hint-escalation'))

      // The three things nobody can infer from the word "escalation": that it
      // is a chain rather than a single bad grant, what the chain is built out
      // of, and that the question being answered is who can become admin.
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip).toHaveTextContent(/cluster-admin/i)
      expect(tooltip).toHaveTextContent(/wildcard verb/i)
      expect(tooltip).toHaveTextContent(/whole chain, not the single grant/i)
    })

    it('says what makes collusion invisible to a per-identity review', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.hover(screen.getByTestId('rbac-hint-collusion'))

      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip).toHaveTextContent(/harmless alone/i)
      // The load-bearing half: this is the class of finding that reviewing one
      // ServiceAccount at a time cannot produce, which is why a solver is here.
      expect(tooltip).toHaveTextContent(/audit of one identity at a time cannot find/i)
    })

    it('says min-cut ranks what to revoke and does not bless what survives', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.hover(screen.getByTestId('rbac-hint-mincut'))

      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip).toHaveTextContent(/smallest set of role bindings/i)
      expect(tooltip).toHaveTextContent(/not a claim that whatever survives the cut is safe/i)
    })

    it('refuses to let "AFM connected" be read as "a cluster was analysed"', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.hover(screen.getByTestId('rbac-hint-afm-status'))

      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip).toHaveTextContent(/answered 200/i)
      // A health route that is up is not an analysis that ran. A page that let
      // those two read alike would be showing a green light for a silence.
      expect(tooltip).toHaveTextContent(/does not mean any cluster has been analysed/i)
    })

    it('says Add Cluster reaches no backend, which its label implies the opposite of', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      await userEvent.hover(screen.getByTestId('rbac-hint-add-cluster'))

      expect(await screen.findByRole('tooltip')).toHaveTextContent(/No request is sent to AFM/i)
    })

    it('leaves the cluster count string exactly what it was', async () => {
      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      // The status hint is a SIBLING of the count, not a child. A "?" inside
      // would land in the count's own textContent, and every assertion in this
      // file that reads the count would silently be reading the affordance too.
      expect(screen.getByTestId('cluster-count').textContent).toBe('Host Cluster')
      expect(screen.getByTestId('cluster-count'))
        .not.toContainElement(screen.getByTestId('rbac-hint-afm-status'))
    })
  })

  describe('Reload reports itself in the control that was pressed', () => {
    it('carries a ButtonWait while the probe is in flight, then gives the label back', async () => {
      // The mount probe must succeed so the page renders; only the reload probe
      // is held open, which is the window this test exists to look at.
      const deferred: { resolve?: (r: Response) => void } = {}
      let healthCalls = 0
      routeFetch({
        health: () => {
          healthCalls += 1
          if (healthCalls === 1) return Promise.resolve(response(true))
          return new Promise<Response>((resolve) => { deferred.resolve = resolve })
        },
      })

      render(<RbacAnalysisPage />)
      await screen.findByText(/afm connected/i)

      const reload = screen.getByTestId('afm-reload-btn')
      // Idle: the visible word IS the accessible name. WCAG 2.5.3 — a speech
      // user has to be able to say what they can see.
      expect(reload).toHaveAccessibleName('Reload')
      expect(reload).not.toBeDisabled()

      // A delta, not a total: the importer panel loads /afm/clusters on mount
      // as well, so the absolute count is not this page's to assert.
      const clustersBefore = requestedUrls().filter(url => url === '/afm/clusters').length

      await userEvent.click(reload)

      await waitFor(() => {
        expect(screen.getByTestId('afm-reload-wait-grid')).toBeInTheDocument()
      })
      expect(reload).toBeDisabled()
      expect(reload).toHaveAttribute('aria-busy', 'true')
      // ButtonWait deletes the visible text, so it has to supply the name
      // itself — a control that goes anonymous while busy is worse than one
      // that never said anything.
      expect(reload).toHaveAccessibleName('Reloading')

      deferred.resolve?.(response(true))

      await waitFor(() => {
        expect(reload).toHaveAccessibleName('Reload')
      })
      expect(reload).not.toBeDisabled()
      expect(screen.queryByTestId('afm-reload-wait-grid')).not.toBeInTheDocument()
      // Exactly the two probes the page always made: one on mount, one on the
      // press. The wait is a report on requests, not a new one — the press
      // still issues the same health/clusters pair and nothing else.
      expect(healthCalls).toBe(2)
      expect(requestedUrls().filter(url => url === '/afm/clusters').length)
        .toBe(clustersBefore + 1)
    })

    it('leaves the button alone for the probe on mount, which nobody pressed', async () => {
      const deferred: { resolve?: (r: Response) => void } = {}
      routeFetch({ health: () => new Promise<Response>((resolve) => { deferred.resolve = resolve }) })

      render(<RbacAnalysisPage />)

      const reload = await screen.findByTestId('afm-reload-btn')
      // A wait belongs to the control the reader used. The mount probe is the
      // page's own business and borrowing this button to narrate it would make
      // the button unpressable for a second every time the page opened.
      expect(reload).toHaveAccessibleName('Reload')
      expect(reload).not.toBeDisabled()
      expect(screen.queryByTestId('afm-reload-wait-grid')).not.toBeInTheDocument()

      deferred.resolve?.(response(true))
      await screen.findByText(/afm connected/i)
    })
  })

  describe('the mode banners take their colour from the theme', () => {
    it('tints the demo banner from var(--amber) rather than a frozen literal', async () => {
      isDemoMode.mockReturnValue(true)

      render(<RbacAnalysisPage />)

      const notice = await screen.findByTestId('demo-mode-notice')
      // It carried rgba(245,158,11,…) — the Dark theme's amber, pinned. The
      // text on it is var(--amber), which does follow the theme, so under Light
      // and Andy the fill and the text it was tinting were two different hues
      // by construction rather than by accident.
      expect(notice.style.background).toContain('var(--amber)')
      expect(notice.style.borderColor).toContain('var(--amber)')
      expect(notice.style.background).not.toMatch(/rgba?\(/)
    })

    it('tints the live-mode banner from var(--cyan) the same way', async () => {
      render(<RbacAnalysisPage />)

      const notice = await screen.findByTestId('host-cluster-indicator')
      expect(notice.style.background).toContain('var(--cyan)')
      expect(notice.style.borderColor).toContain('var(--cyan)')
      expect(notice.style.background).not.toMatch(/rgba?\(/)
      // Longhands rather than the `border` shorthand, per the lesson recorded
      // in HelpHint: jsdom cannot read a shorthand carrying a custom property,
      // so the shorthand form would make the tint untestable outside a browser
      // — which is exactly how the frozen literals survived this long.
      expect(notice.style.borderStyle).toBe('solid')
    })
  })
})
