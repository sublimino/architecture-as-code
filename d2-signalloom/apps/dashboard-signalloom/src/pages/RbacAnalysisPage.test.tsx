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
import RbacAnalysisPage from './RbacAnalysisPage'

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

function response(ok: boolean, body?: unknown): Response {
  return { ok, json: vi.fn().mockResolvedValue(body) } as unknown as Response
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
      expect(screen.getByTestId('afm-iframe')).toHaveAttribute('src', '/dashboard/')

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
      await userEvent.click(screen.getByRole('button', { name: /retry connection/i }))

      await waitFor(() => {
        expect(screen.getByTestId('afm-iframe')).toBeInTheDocument()
      })
      expect(requestedUrls().filter(url => url === '/afm/health').length).toBeGreaterThanOrEqual(2)
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
      expect(yaml).toContain('id: local')
      // In live mode (default), the importer relabels the cluster as "Host Cluster"
      expect(yaml).toContain('name: Host Cluster')
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
})
