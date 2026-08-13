import { describe, expect, it, vi } from 'vitest'
import { RbacUnreachableError, fetchRbacClusters } from './rbacCorrelationApi'

// The RBAC Explorer rendered
//   RBAC correlation request failed for /api/rbac/clusters with status 503
//   KubeSec-AFM is unreachable: [Errno -2] Name or service not known
// against a cluster where the AFM slice had never been deployed. Two separate
// absences reach this client and both used to read as transport noise: AFM
// missing behind a live API, and the API itself missing behind the SPA
// catch-all. These assert each is named, with its own remedy.

const errorResponse = (status: number, code: string, message: string) =>
  ({
    ok: false,
    status,
    headers: new Headers({ 'content-type': 'application/json' }),
    json: async () => ({ error: { code, message } }),
  }) as unknown as Response

const htmlResponse = () =>
  ({
    ok: true,
    status: 200,
    headers: new Headers({ 'content-type': 'text/html; charset=utf-8' }),
    text: async () => '<!doctype html><html></html>',
    json: async () => {
      throw new SyntaxError(`Unexpected token '<', "<!doctype "... is not valid JSON`)
    },
  }) as unknown as Response

const jsonResponse = (body: unknown) =>
  ({
    ok: true,
    status: 200,
    headers: new Headers({ 'content-type': 'application/json' }),
    json: async () => body,
  }) as unknown as Response

describe('AFM absent behind a live API', () => {
  const notDeployed = () =>
    errorResponse(
      503,
      'afm_not_deployed',
      'KubeSec-AFM is not deployed: afm-platform.fe-k8s-afm.svc.cluster.local:8000 does not ' +
        'resolve, so the cluster list cannot be read. Deploy the AFM slice with `make demo-k8s-afm-up`.',
    )

  it('raises RbacUnreachableError rather than a generic request failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(notDeployed()))
    await expect(fetchRbacClusters('t')).rejects.toBeInstanceOf(RbacUnreachableError)
  })

  it("surfaces the API's remedy without burying it behind the URL and status", async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(notDeployed()))
    await expect(fetchRbacClusters('t')).rejects.toThrow(/make demo-k8s-afm-up/)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(notDeployed()))
    await expect(fetchRbacClusters('t')).rejects.not.toThrow(/request failed for/)
  })

  it('never shows the raw errno the page used to display', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(notDeployed()))
    await expect(fetchRbacClusters('t')).rejects.not.toThrow(/Errno/)
  })
})

describe('the API itself absent behind the SPA catch-all', () => {
  it('diagnoses the HTML answer instead of parsing it', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchRbacClusters('t')).rejects.toBeInstanceOf(RbacUnreachableError)
  })

  it('names this cause and its own remedy, distinct from the AFM one', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchRbacClusters('t')).rejects.toThrow(/not deployed or \/api\/ is not proxied/)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchRbacClusters('t')).rejects.toThrow(/make demo-signalloom-up/)
  })

  it('does not surface the misleading token error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchRbacClusters('t')).rejects.not.toThrow(/Unexpected token/)
  })

  it('still diagnoses it when the response carries no content-type at all', async () => {
    // The header is evidence when present; the failed parse is the evidence
    // when it is not. Neither alone covers both shapes of this failure.
    const noHeader = () =>
      ({
        ok: true,
        status: 200,
        headers: new Headers(),
        json: async () => {
          throw new SyntaxError(`Unexpected token '<', "<!doctype "... is not valid JSON`)
        },
      }) as unknown as Response
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(noHeader()))
    await expect(fetchRbacClusters('t')).rejects.toBeInstanceOf(RbacUnreachableError)
  })
})

describe('a header-less but valid JSON response is still accepted', () => {
  it('does not reject a response merely for omitting content-type', async () => {
    const noHeader = {
      ok: true,
      status: 200,
      headers: new Headers(),
      json: async () => [{ id: 'local', name: 'Local Cluster' }],
    } as unknown as Response
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(noHeader))
    await expect(fetchRbacClusters('t')).resolves.toEqual([{ id: 'local', name: 'Local Cluster' }])
  })
})

describe('errors that are not an absent backend keep their existing shape', () => {
  it('leaves an unrelated 500 as a generic request failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(errorResponse(500, 'internal_error', 'boom')))
    await expect(fetchRbacClusters('t')).rejects.not.toBeInstanceOf(RbacUnreachableError)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(errorResponse(500, 'internal_error', 'boom')))
    await expect(fetchRbacClusters('t')).rejects.toThrow(/with status 500/)
  })
})

describe('a real JSON answer still works', () => {
  it('parses and returns the cluster list unchanged', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse([{ id: 'local', name: 'Local Cluster' }])))
    await expect(fetchRbacClusters('t')).resolves.toEqual([{ id: 'local', name: 'Local Cluster' }])
  })
})
