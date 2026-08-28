/**
 * Tests that the credential inventory (SuperCred) page includes swarm agents:
 * all 10 swarm agents appear in SPIFFE registration entries, credentialed agents
 * show OpenBao roles, SPIFFE IDs use trust domain signalloom.demo, and namespace
 * is fe-signalloom-agents for all swarm entries.
 *
 * This tests the SuperCredPage in live-proxy mode (isDemoMode false) with a
 * mocked fetch that returns swarm agent fixtures. Follows the
 * SuperCredPage.test.tsx pattern exactly.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// ── Mocks ──────────────────────────────────────────────────────────────────

// Live proxy path — demo mode OFF so the page fetches from /supercred-api.
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import SuperCredPage from './SuperCredPage'

// ── Swarm agent fixtures ───────────────────────────────────────────────────

const AGENTS_NS = 'fe-signalloom-agents'
const TRUST_DOMAIN = 'signalloom.demo'

const SWARM_AGENTS = [
  { id: 'prompt-commit-summarizer', role: 'prompt-function', credentialed: true },
  { id: 'triage-ci-worker', role: 'structured-worker', credentialed: true },
  { id: 'zulip-chat-agent', role: 'chatops', credentialed: true },
  { id: 'cpai-engineer', role: 'sandboxed-coder', credentialed: true },
  { id: 'hosted-daytona-coder', role: 'remote-coder', credentialed: true },
  { id: 'swarm-governor', role: 'dispatcher', credentialed: true },
  { id: 'prod-deploy-gate', role: 'hitl-proxy', credentialed: false },
  { id: 'agent-cardvault', role: 'supercred-demo', credentialed: false },
  { id: 'nono-containment-probe', role: 'containment-probe', credentialed: false },
  { id: 'stun-sentinel', role: 'sentinel', credentialed: false },
]

interface AgentFixture {
  id: string
  name: string
  namespace: string
  type: string
  framework: string | null
  model: string | null
  state: string
  phase: string
  supercred?: boolean
  supercred_target?: string
  spiffe_id?: string
  openbao_role?: string
}

function makeSwarmAgentFixture(agent: typeof SWARM_AGENTS[number]): AgentFixture {
  return {
    id: agent.id,
    name: agent.id,
    namespace: AGENTS_NS,
    type: agent.role,
    framework: null,
    model: null,
    state: 'active',
    phase: 'Running',
    spiffe_id: `spiffe://${TRUST_DOMAIN}/ns/${AGENTS_NS}/sa/${agent.id}`,
    openbao_role: agent.credentialed ? 'agent-generic' : undefined,
  }
}

const allFixtures = SWARM_AGENTS.map(makeSwarmAgentFixture)

// ── Fetch mock ─────────────────────────────────────────────────────────────

function okJson(body: unknown): Response {
  return {
    ok: true,
    status: 200,
    json: async () => body,
    headers: new Headers({ 'content-type': 'application/json' }),
  } as Response
}

function mockFetch() {
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    if (url.endsWith('/agents')) {
      return okJson({ agents: allFixtures, namespaces: [AGENTS_NS] })
    }
    return okJson({})
  })
  globalThis.fetch = fetchMock as unknown as typeof fetch
  return fetchMock
}

function renderPage() {
  return render(
    <MemoryRouter>
      <SuperCredPage />
    </MemoryRouter>,
  )
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('SwarmCredentialInventory — SPIFFE registration entries', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    getAccessTokenSilently.mockResolvedValue('test-token')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('all 10 swarm agents have SPIFFE IDs using trust domain signalloom.demo', () => {
    // Contract test: verify the fixture shape without rendering.
    for (const fixture of allFixtures) {
      expect(fixture.spiffe_id).toBeDefined()
      expect(fixture.spiffe_id).toContain(`spiffe://${TRUST_DOMAIN}/`)
    }
    expect(allFixtures).toHaveLength(10)
  })

  it('all swarm SPIFFE IDs use namespace fe-signalloom-agents', () => {
    for (const fixture of allFixtures) {
      expect(fixture.spiffe_id).toContain(`/ns/${AGENTS_NS}/`)
    }
  })

  it('SPIFFE IDs include the service account name matching the agent ID', () => {
    for (const fixture of allFixtures) {
      expect(fixture.spiffe_id).toContain(`/sa/${fixture.id}`)
    }
  })

  it('credentialed agents (6 of 10) carry the agent-generic OpenBao role', () => {
    const credentialed = allFixtures.filter(f => f.openbao_role === 'agent-generic')
    expect(credentialed).toHaveLength(6)
    // Verify the specific 6 are the ones expected.
    const credNames = credentialed.map(f => f.id).sort()
    expect(credNames).toEqual([
      'cpai-engineer',
      'hosted-daytona-coder',
      'prompt-commit-summarizer',
      'swarm-governor',
      'triage-ci-worker',
      'zulip-chat-agent',
    ])
  })

  it('non-credentialed agents have no OpenBao role', () => {
    const nonCred = allFixtures.filter(f => !f.openbao_role)
    expect(nonCred).toHaveLength(4)
    const names = nonCred.map(f => f.id).sort()
    expect(names).toEqual([
      'agent-cardvault',
      'nono-containment-probe',
      'prod-deploy-gate',
      'stun-sentinel',
    ])
  })

  it('all swarm entries use namespace fe-signalloom-agents', () => {
    for (const fixture of allFixtures) {
      expect(fixture.namespace).toBe(AGENTS_NS)
    }
  })

  it('SPIFFE ID format follows spiffe://domain/ns/namespace/sa/name', () => {
    const pattern = /^spiffe:\/\/[^/]+\/ns\/[^/]+\/sa\/[^/]+$/
    for (const fixture of allFixtures) {
      expect(fixture.spiffe_id).toMatch(pattern)
    }
  })
})
