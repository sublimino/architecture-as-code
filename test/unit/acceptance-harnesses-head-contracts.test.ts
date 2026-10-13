// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, expect, test, afterAll, beforeAll } from 'bun:test'
import {
  drainRequestBody,
  gateMethod,
  jsonResponse,
  methodNotAllowedResponse,
  normalizeAllow,
  notFoundResponse,
  optionsResponse,
  staticResponse,
  suppressHeadBody,
} from '../acceptance/harness/http-gate'
import { startHarness, type Harness } from '../acceptance/harness/server'
import { startCodingAgentsHarness, type CodingAgentsHarness } from '../acceptance/harness/coding-agents-server'
import { startCockpitHarness, type CockpitHarness } from '../acceptance/harness/cockpit-telemetry-server'
import { startUserAdminFlagsHarness, type HarnessServer } from '../acceptance/harness/user-admin-flags-server'

describe('Shared HTTP Gate Helper (test/acceptance/harness/http-gate.ts)', () => {
  test('normalizeAllow expands GET to include HEAD and always appends OPTIONS', () => {
    expect(normalizeAllow(['GET'])).toBe('GET, HEAD, OPTIONS')
    expect(normalizeAllow(['GET', 'HEAD'])).toBe('GET, HEAD, OPTIONS')
    expect(normalizeAllow(['POST'])).toBe('POST, OPTIONS')
    expect(normalizeAllow(['GET', 'POST'])).toBe('GET, HEAD, POST, OPTIONS')
    expect(normalizeAllow(['PATCH', 'DELETE'])).toBe('PATCH, DELETE, OPTIONS')
  })

  test('optionsResponse returns 204 No Content with normalized Allow and empty body', async () => {
    const res = optionsResponse(['GET'])
    expect(res.status).toBe(204)
    expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    expect(res.headers.get('access-control-allow-methods')).toBe('GET, HEAD, OPTIONS')
    expect(await res.text()).toBe('')
  })

  test('methodNotAllowedResponse suppresses body on HEAD and preserves Allow parity', async () => {
    const postReq = new Request('http://localhost/test', { method: 'POST' })
    const postRes = methodNotAllowedResponse(postReq, ['GET'])
    expect(postRes.status).toBe(405)
    expect(postRes.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    expect(await postRes.json()).toEqual({ detail: 'Method Not Allowed' })

    const headReq = new Request('http://localhost/test', { method: 'HEAD' })
    const headRes = methodNotAllowedResponse(headReq, ['POST'])
    expect(headRes.status).toBe(405)
    expect(headRes.headers.get('allow')).toBe('POST, OPTIONS')
    expect(await headRes.text()).toBe('')
  })

  test('jsonResponse, staticResponse, and suppressHeadBody suppress payloads on HEAD', async () => {
    const headReq = new Request('http://localhost/test', { method: 'HEAD' })
    const getReq = new Request('http://localhost/test', { method: 'GET' })

    const jsonHead = jsonResponse({ ok: true }, 200, headReq)
    expect(jsonHead.status).toBe(200)
    expect(await jsonHead.text()).toBe('')

    const staticHead = staticResponse(headReq, 'hello world', 200, { 'content-type': 'text/plain' })
    expect(staticHead.status).toBe(200)
    expect(await staticHead.text()).toBe('')

    const rawRes = new Response('non-empty error', { status: 500, headers: { 'x-test': '1' } })
    const stripped = suppressHeadBody(headReq, rawRes)
    expect(stripped.status).toBe(500)
    expect(stripped.headers.get('x-test')).toBe('1')
    expect(await stripped.text()).toBe('')

    const preserved = suppressHeadBody(getReq, new Response('kept', { status: 200 }))
    expect(await preserved.text()).toBe('kept')
  })

  test('gateMethod drains request body on unsupported methods and OPTIONS', async () => {
    const badReq = new Request('http://localhost/only-get', {
      method: 'POST',
      body: JSON.stringify({ ignored: true }),
      headers: { 'content-type': 'application/json' },
    })
    const gated = await gateMethod(badReq, ['GET'])
    expect(gated).not.toBeNull()
    expect(gated!.status).toBe(405)
    expect(gated!.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    expect(badReq.bodyUsed).toBe(true)

    const optReq = new Request('http://localhost/only-post', {
      method: 'OPTIONS',
      body: 'preflight-payload',
    })
    const optGated = await gateMethod(optReq, ['POST'])
    expect(optGated).not.toBeNull()
    expect(optGated!.status).toBe(204)
    expect(optGated!.headers.get('allow')).toBe('POST, OPTIONS')
    expect(optReq.bodyUsed).toBe(true)

    const okReq = new Request('http://localhost/only-get', { method: 'HEAD' })
    expect(await gateMethod(okReq, ['GET'])).toBeNull()
  })

  test('notFoundResponse drains body and suppresses payload on HEAD', async () => {
    const req = new Request('http://localhost/missing', { method: 'POST', body: 'some-body' })
    const res = await notFoundResponse(req, 'missing route')
    expect(res.status).toBe(404)
    expect(req.bodyUsed).toBe(true)
    expect(await res.json()).toEqual({ detail: 'missing route' })

    const headReq = new Request('http://localhost/missing', { method: 'HEAD' })
    const headRes = await notFoundResponse(headReq, 'missing route')
    expect(headRes.status).toBe(404)
    expect(await headRes.text()).toBe('')
  })

  test('drainRequestBody is idempotent on already-consumed or bodyless requests', async () => {
    const req = new Request('http://localhost/test', { method: 'POST', body: 'abc' })
    await drainRequestBody(req)
    expect(req.bodyUsed).toBe(true)
    await drainRequestBody(req)
  })
})

describe('Acceptance Test Harness Servers RFC 9110 HEAD and Method Gating Contracts', () => {
  let demoHarness: Harness
  let codingHarness: CodingAgentsHarness
  let cockpitHarness: CockpitHarness
  let userAdminHarness: HarnessServer

  beforeAll(async () => {
    demoHarness = startHarness({ port: 0 })
    codingHarness = startCodingAgentsHarness({ port: 0 })
    cockpitHarness = startCockpitHarness({ port: 0 })
    userAdminHarness = startUserAdminFlagsHarness({ port: 0 })
  })

  afterAll(async () => {
    await demoHarness.close()
    await codingHarness.close()
    await cockpitHarness.close()
    await userAdminHarness.close()
  })

  describe('Demo Acceptance Harness Server', () => {
    test('GET /demo-api/steps returns 200 and JSON body', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/steps`)
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(Array.isArray(data.steps)).toBe(true)
    })

    test('HEAD /demo-api/steps returns 200 with empty body and application/json header', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/steps`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      expect(res.headers.get('content-type')).toContain('application/json')
      const text = await res.text()
      expect(text).toBe('')
    })

    test('OPTIONS /demo-api/steps returns 204 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/steps`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('POST /demo-api/steps returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/steps`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
      const data = await res.json()
      expect(data.detail).toBe('Method Not Allowed')
    })

    test('HEAD /demo-api/runs returns 405 with Allow: POST, OPTIONS and empty body', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/runs`, { method: 'HEAD' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
      const text = await res.text()
      expect(text).toBe('')
    })

    test('OPTIONS /demo-api/runs returns 204 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/runs`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('GET /demo-api/reset returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('GET /api/agents/agent-cardvault/stun returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${demoHarness.url}/api/agents/agent-cardvault/stun`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('POST /api/agents/agent-cardvault/stun returns 200', async () => {
      const res = await fetch(`${demoHarness.url}/api/agents/agent-cardvault/stun`, { method: 'POST' })
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(data.ok).toBe(true)
    })
  })

  describe('Coding Agents Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('OPTIONS /harness/reset returns 204 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/harness/reset`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('POST /harness/reset returns 200', async () => {
      const res = await fetch(`${codingHarness.url}/harness/reset`, { method: 'POST' })
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(data.ok).toBe(true)
    })

    test('HEAD /harness/requests returns 200 with empty body', async () => {
      const res = await fetch(`${codingHarness.url}/harness/requests`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /harness/requests returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/harness/requests`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('DELETE /harness/state returns 405 with Allow: GET, HEAD, POST, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/harness/state`, { method: 'DELETE' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, POST, OPTIONS')
    })

    test('OPTIONS /harness/state returns 204 with Allow: GET, HEAD, POST, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/harness/state`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('GET, HEAD, POST, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('HEAD on telemetry without token returns 401 with empty body', async () => {
      const res = await fetch(`${codingHarness.url}/v1/telemetry/coding-agents`, { method: 'HEAD' })
      expect(res.status).toBe(401)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST on telemetry returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${codingHarness.url}/v1/telemetry/coding-agents`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })
  })

  describe('Cockpit Telemetry Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('OPTIONS /harness/reset returns 204 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/reset`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('POST /harness/reset returns 200', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/reset`, { method: 'POST' })
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(data.ok).toBe(true)
    })

    test('HEAD /harness/requests returns 200 with empty body', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/requests`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /harness/requests returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/requests`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('GET /harness/phase returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/phase`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('GET /harness/drop returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/drop`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })
  })

  describe('User Admin & Flags Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('POST /harness/reset returns 200', async () => {
      const res = await fetch(`${userAdminHarness.url}/harness/reset`, { method: 'POST' })
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(data.ok).toBe(true)
    })

    test('HEAD /api/v1/me returns 200 with empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/me`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('OPTIONS /api/v1/me returns 204 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/me`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
      expect(await res.text()).toBe('')
    })

    test('POST /api/v1/me returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/me`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('HEAD /api/v1/features returns 200 with empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/features`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /api/v1/features returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/features`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('HEAD /api/v1/tenants returns 200 with empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/tenants`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /api/v1/tenants returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/tenants`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('POST /api/v1/admin/users returns 405 with Allow: GET, HEAD, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, OPTIONS')
    })

    test('GET /api/v1/admin/users/invite returns 405 with Allow: POST, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/invite`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST, OPTIONS')
    })

    test('GET /api/v1/admin/users/usr-demo-001 returns 405 with Allow: PATCH, DELETE, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/usr-demo-001`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('PATCH, DELETE, OPTIONS')
    })

    test('HEAD /api/v1/admin/users/usr-demo-001 returns 405 with Allow: PATCH, DELETE, OPTIONS and empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/usr-demo-001`, { method: 'HEAD' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('PATCH, DELETE, OPTIONS')
      const text = await res.text()
      expect(text).toBe('')
    })

    test('OPTIONS /api/v1/admin/users/usr-demo-001 returns 204 with Allow: PATCH, DELETE, OPTIONS', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/usr-demo-001`, { method: 'OPTIONS' })
      expect(res.status).toBe(204)
      expect(res.headers.get('allow')).toBe('PATCH, DELETE, OPTIONS')
      expect(await res.text()).toBe('')
    })
  })
})
