import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { http } from '../../api/connectorsClient'
import * as demoMode from '../../api/demoMode'
import { NOT_CHECKED_MESSAGE, verifyConnectorCredentials } from './connectorVerification'

// Drives the real connectorsApi mode switch: only the HTTP transport is
// stubbed, so these pin the wire contract as well as the verdict mapping.
describe('verifyConnectorCredentials', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    demoMode.setDemoMode(false)
  })
  afterEach(() => demoMode.setDemoMode(true))

  const serverSays = (data: unknown) => vi.spyOn(http, 'request').mockResolvedValue({ data })

  it('live: posts typed credentials to the provider test route and reports the server verdict', async () => {
    const spy = serverSays({ valid: true, scopes_ok: true, error_msg: null, credential_expires_at: null, needs_rotation: false })

    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: { api_key: 'sk-ant-x', workspace_id: '' } })

    expect(spy).toHaveBeenCalledWith(expect.objectContaining({
      url: '/api/connectors/providers/claude/test',
      method: 'POST',
      data: { credentials: { api_key: 'sk-ant-x' } },
    }))
    expect(out.status).toBe('verified')
    expect(out.message).not.toMatch(/demo/i)
  })

  it('live: a stored connector is tested through its own route with no credential body', async () => {
    const spy = serverSays({ connector_id: 'conn-1', valid: true, scopes_ok: true, error_msg: null, credential_expires_at: null, needs_rotation: false })

    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: {}, connectorId: 'conn-1' })

    expect(spy).toHaveBeenCalledTimes(1)
    const call = spy.mock.calls[0][0] as { url: string; data?: unknown }
    expect(call.url).toBe('/api/connectors/conn-1/test')
    expect(call.data).toBeUndefined()
    expect(out.status).toBe('verified')
  })

  it('live: a rejected credential is a failure carrying the server message', async () => {
    serverSays({ valid: false, scopes_ok: false, error_msg: 'invalid x-api-key', credential_expires_at: null, needs_rotation: false })
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: { api_key: 'sk-ant-bad' } })
    expect(out).toEqual({ status: 'failed', message: 'invalid x-api-key' })
  })

  it('live: valid but under-scoped is a failure, not a pass', async () => {
    serverSays({ valid: true, scopes_ok: false, error_msg: 'missing models:read', credential_expires_at: null, needs_rotation: false })
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'openai', credentials: { api_key: 'sk-x' } })
    expect(out.status).toBe('failed')
    expect(out.message).toMatch(/missing models:read/)
  })

  it('live: 501 test_unsupported is reported as not checked', async () => {
    vi.spyOn(http, 'request').mockRejectedValue({ response: { status: 501, data: { error: { code: 'test_unsupported' } } } })
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'okta', credentials: { api_token: 'x' } })
    expect(out).toEqual({ status: 'unchecked', message: NOT_CHECKED_MESSAGE })
  })

  it('live: a transport failure is a failure, never a pass', async () => {
    vi.spyOn(http, 'request').mockRejectedValue(new Error('Network Error'))
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: { api_key: 'sk-ant-x' } })
    expect(out.status).toBe('failed')
    expect(out.message).toMatch(/Network Error/)
  })

  it('nothing typed and nothing stored: no request, no verdict', async () => {
    const spy = vi.spyOn(http, 'request')
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: { api_key: '  ' } })
    expect(spy).not.toHaveBeenCalled()
    expect(out.status).toBe('failed')
  })

  it('demo: routes to the simulator, never the network, and labels the verdict as demo data', async () => {
    demoMode.setDemoMode(true)
    const spy = vi.spyOn(http, 'request')
    const out = await verifyConnectorCredentials({ token: 't', providerId: 'claude', credentials: { api_key: 'sk-ant-x' } })
    expect(spy).not.toHaveBeenCalled()
    expect(out.status).toBe('verified')
    expect(out.message).toMatch(/^Demo data/)
  })
})
