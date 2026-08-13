/**
 * Waiting behaviour for the RBAC importer.
 *
 * The panel's three waits all sat behind a bare word — "Loading AFM
 * clusters…", "Generating…", "Sending…" — which reads identically at second
 * one and at second ninety. Each now carries the pixel-grid-and-elapsed
 * treatment, so a slow AFM and a hung AFM stop looking the same.
 *
 * The panel's own behaviour (routing, YAML, read-only guarantees) is covered by
 * RbacAnalysisPage.test.tsx, which renders it inside its page. This file is
 * scoped to the component's waits.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import RbacImporterPanel from './RbacImporterPanel'

const fetchMock = vi.fn()

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
}))

// ── Fixtures ────────────────────────────────────────────────────────────────

const clustersFixture = [{ id: 'local', name: 'Local Cluster' }]

/** AFM's wire shape, not the interface — see RbacAnalysisPage.test.tsx. */
const rbacFixture: unknown = {
  subjects: [{ name: 'frontend', kind: 'ServiceAccount', namespace: 'apps', annotations: {} }],
  roles: [
    {
      name: 'secret-reader',
      scope: 'Namespace',
      namespace: 'apps',
      rules: [{ verbs: ['get'], apiGroups: [''], resources: ['secrets'] }],
    },
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
  ],
  namespaces: [],
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function response(body?: unknown): Response {
  return { ok: true, status: 200, json: vi.fn().mockResolvedValue(body) } as unknown as Response
}

/** A promise held open until the test decides the request has finished. */
function gate<T>() {
  let release!: (value: T) => void
  const promise = new Promise<T>(resolve => { release = resolve })
  return { promise, release }
}

interface Routes {
  clusters?: () => Promise<Response>
  /** Called with the 1-based index of the RBAC request. */
  rbac?: (nth: number) => Promise<Response> | undefined
  importPost?: () => Promise<Response>
}

function routeFetch(routes: Routes = {}) {
  let rbacCalls = 0
  fetchMock.mockImplementation((input: RequestInfo | URL) => {
    const url = String(input)
    if (url === '/afm/clusters') {
      return routes.clusters ? routes.clusters() : Promise.resolve(response(clustersFixture))
    }
    if (url === '/afm/clusters/import') {
      return routes.importPost ? routes.importPost() : Promise.resolve(response({}))
    }
    if (url.endsWith('/rbac')) {
      rbacCalls += 1
      return routes.rbac?.(rbacCalls) ?? Promise.resolve(response(rbacFixture))
    }
    return Promise.reject(new Error(`unexpected fetch: ${url}`))
  })
}

/** Mount and wait for the cluster list plus its namespace preload to settle. */
async function renderReady() {
  render(<RbacImporterPanel />)
  await waitFor(() => expect(screen.getByTestId('importer-fetch')).not.toBeDisabled())
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe('the importer says how long each wait has been waiting', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    globalThis.fetch = fetchMock as unknown as typeof fetch
  })

  it('counts the AFM cluster list up while it loads', async () => {
    const held = gate<Response>()
    routeFetch({ clusters: () => held.promise })
    render(<RbacImporterPanel />)

    const loader = await screen.findByTestId('importer-clusters-loader')
    expect(loader).toHaveTextContent('Loading AFM clusters')
    expect(within(loader).getByTestId('importer-clusters-loader-elapsed')).toHaveTextContent(/^\d+(\.\d)?s$/)

    held.release(response(clustersFixture))
    await waitFor(() => expect(screen.queryByTestId('importer-clusters-loader')).not.toBeInTheDocument())
  })

  it('counts Generate YAML up and keeps the button named while it runs', async () => {
    const held = gate<Response>()
    // The first RBAC read is the mount-time namespace preload; hold the second,
    // which is the one the click issues.
    routeFetch({ rbac: nth => (nth === 2 ? held.promise : undefined) })
    await renderReady()

    const idleWidth = (screen.getByTestId('importer-fetch') as HTMLButtonElement).style.minWidth
    await userEvent.click(screen.getByTestId('importer-fetch'))

    expect(await screen.findByTestId('importer-generate-loader')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /generating/i })).toBeDisabled()
    // Reserved up front, so neither the swap nor a tick moves the control row.
    expect((screen.getByTestId('importer-fetch') as HTMLButtonElement).style.minWidth).toBe(idleWidth)
    expect(idleWidth).not.toBe('')

    held.release(response(rbacFixture))
    await waitFor(() => expect(screen.queryByTestId('importer-generate-loader')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: /generate yaml/i })).toBeEnabled()
  })

  it('counts Send to AFM up while the import is in flight', async () => {
    const held = gate<Response>()
    routeFetch({ importPost: () => held.promise })
    await renderReady()

    await userEvent.click(screen.getByTestId('importer-fetch'))
    await waitFor(() => expect(screen.getByTestId('importer-send')).not.toBeDisabled())
    await userEvent.click(screen.getByTestId('importer-send'))

    const loader = await screen.findByTestId('importer-send-loader')
    expect(within(loader).getByTestId('importer-send-loader-elapsed')).toHaveTextContent(/s$/)
    expect(screen.getByRole('button', { name: /sending/i })).toBeDisabled()

    held.release(response({}))
    await waitFor(() => expect(screen.queryByTestId('importer-send-loader')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: /send to afm/i })).toBeEnabled()
  })
})
