// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import { describe, expect, test, afterAll, beforeAll } from 'bun:test'
import { startHarness, type Harness } from '../acceptance/harness/server'
import { startCodingAgentsHarness, type CodingAgentsHarness } from '../acceptance/harness/coding-agents-server'
import { startCockpitHarness, type CockpitHarness } from '../acceptance/harness/cockpit-telemetry-server'
import { startUserAdminFlagsHarness, type HarnessServer } from '../acceptance/harness/user-admin-flags-server'

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

    test('POST /demo-api/steps returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/steps`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
      const data = await res.json()
      expect(data.detail).toBe('Method Not Allowed')
    })

    test('HEAD /demo-api/runs returns 405 with Allow: POST and empty body', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/runs`, { method: 'HEAD' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
      const text = await res.text()
      expect(text).toBe('')
    })

    test('GET /demo-api/reset returns 405 with Allow: POST', async () => {
      const res = await fetch(`${demoHarness.url}/demo-api/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
    })

    test('GET /api/agents/agent-cardvault/stun returns 405 with Allow: POST', async () => {
      const res = await fetch(`${demoHarness.url}/api/agents/agent-cardvault/stun`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
    })

    test('POST /api/agents/agent-cardvault/stun returns 200', async () => {
      const res = await fetch(`${demoHarness.url}/api/agents/agent-cardvault/stun`, { method: 'POST' })
      expect(res.status).toBe(200)
      const data = await res.json()
      expect(data.ok).toBe(true)
    })
  })

  describe('Coding Agents Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST', async () => {
      const res = await fetch(`${codingHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
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

    test('POST /harness/requests returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${codingHarness.url}/harness/requests`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('DELETE /harness/state returns 405 with Allow: GET, HEAD, POST', async () => {
      const res = await fetch(`${codingHarness.url}/harness/state`, { method: 'DELETE' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD, POST')
    })

    test('HEAD on telemetry without token returns 401 with empty body', async () => {
      const res = await fetch(`${codingHarness.url}/v1/telemetry/coding-agents`, { method: 'HEAD' })
      expect(res.status).toBe(401)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST on telemetry returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${codingHarness.url}/v1/telemetry/coding-agents`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })
  })

  describe('Cockpit Telemetry Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
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

    test('POST /harness/requests returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/requests`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('GET /harness/phase returns 405 with Allow: POST', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/phase`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
    })

    test('GET /harness/drop returns 405 with Allow: POST', async () => {
      const res = await fetch(`${cockpitHarness.url}/harness/drop`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
    })
  })

  describe('User Admin & Flags Harness Server', () => {
    test('GET /harness/reset returns 405 with Allow: POST', async () => {
      const res = await fetch(`${userAdminHarness.url}/harness/reset`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
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

    test('POST /api/v1/me returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/me`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('HEAD /api/v1/features returns 200 with empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/features`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /api/v1/features returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/features`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('HEAD /api/v1/tenants returns 200 with empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/tenants`, { method: 'HEAD' })
      expect(res.status).toBe(200)
      const text = await res.text()
      expect(text).toBe('')
    })

    test('POST /api/v1/tenants returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/tenants`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('POST /api/v1/admin/users returns 405 with Allow: GET, HEAD', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users`, { method: 'POST' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('GET, HEAD')
    })

    test('GET /api/v1/admin/users/invite returns 405 with Allow: POST', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/invite`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('POST')
    })

    test('GET /api/v1/admin/users/usr-demo-001 returns 405 with Allow: PATCH, DELETE', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/usr-demo-001`, { method: 'GET' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('PATCH, DELETE')
    })

    test('HEAD /api/v1/admin/users/usr-demo-001 returns 405 with Allow: PATCH, DELETE and empty body', async () => {
      const res = await fetch(`${userAdminHarness.url}/api/v1/admin/users/usr-demo-001`, { method: 'HEAD' })
      expect(res.status).toBe(405)
      expect(res.headers.get('allow')).toBe('PATCH, DELETE')
      const text = await res.text()
      expect(text).toBe('')
    })
  })
})
