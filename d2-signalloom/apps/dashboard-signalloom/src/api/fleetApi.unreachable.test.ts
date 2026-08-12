import { describe, expect, it, vi } from 'vitest'
import { FleetUnreachableError, fetchFleetTopology } from './fleetApi'

// A 200 OK carrying index.html is the failure this file exists for. When no
// nginx location matched /fleet-api/, the SPA catch-all answered API calls with
// the dashboard shell, `res.ok` was true, and res.json() threw
//   Unexpected token '<', "<!doctype "... is not valid JSON
// which names the symptom and hides the cause. The page then died before it
// could fall back to anything.

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

describe('an HTML answer is diagnosed, not parsed', () => {
  it('throws FleetUnreachableError instead of a JSON syntax error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchFleetTopology()).rejects.toBeInstanceOf(FleetUnreachableError)
  })

  it('names the cause and the remedy, not the parse failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchFleetTopology()).rejects.toThrow(/not deployed or \/fleet-api\/ is not proxied/)
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchFleetTopology()).rejects.toThrow(/make demo-signalloom-fleet-up/)
  })

  it('does not surface the misleading token error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse()))
    await expect(fetchFleetTopology()).rejects.not.toThrow(/Unexpected token/)
  })
})

describe('a real JSON answer still works', () => {
  it('parses and returns the payload unchanged', async () => {
    const payload = { agents: [], edges: [] }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse(payload)))
    await expect(fetchFleetTopology()).resolves.toEqual(payload)
  })

  it('accepts a charset-qualified JSON content type', async () => {
    const res = {
      ok: true,
      status: 200,
      headers: new Headers({ 'content-type': 'application/json; charset=utf-8' }),
      json: async () => ({ agents: [] }),
    } as unknown as Response
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(res))
    await expect(fetchFleetTopology()).resolves.toEqual({ agents: [] })
  })
})
