import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// This file exercises the LIVE proxy path — every test drives a mocked fetch
// against /supercred-api — so demo-data mode must be off. SL_ENV defaults to
// 'demo' under test, which makes the mode ambient rather than declared, and a
// test file that silently changes behaviour with an env default is a trap.
// Taken verbatim from feat/supercred-main-pages, where routing discovery
// through supercredSource makes it load-bearing rather than merely correct.
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

// The page records its stun on the audit trail through the authenticated api
// client, so it needs a token. Same shim AuditTrail.test.tsx uses.
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import SuperCredPage from './SuperCredPage'
import { api } from '../api/client'
import type { StunAgentResponse } from '../types/api'

// This file exercises the LIVE proxy path — every test drives a mocked fetch
// against /supercred-api. Demo-data mode must therefore be off, or discovery is
// served by the simulated cluster in supercredSource instead. (SL_ENV defaults
// to 'demo' under test, so this has to be explicit.)
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

const AGENTS_NS = 'fe-signalloom-agents'
const FLUX_NS = 'fe-signalloom'

interface AgentFixture {
  id: string
  name: string
  namespace: string
  type?: string | null
  framework?: string | null
  model?: string | null
  state?: string | null
  phase?: string | null
  supercred?: boolean
  supercred_target?: string
  stunned_at?: string
  stun_reason?: string
}

/**
 * What POST /api/agents/{id}/stun answers with.
 *
 * Every field is server-sourced, which is the point: the page passes no body,
 * so anything rendered from a stun has to come from here. The proxy's wording
 * sits under `proxy`, apart from what fe-signalloom established itself.
 */
function stunResponse(overrides: Partial<StunAgentResponse> = {}): StunAgentResponse {
  return {
    agent_id: 'agent-cardvault',
    from_state: 'active',
    to_state: 'suspended',
    actor: 'demo-operator',
    stunned_at: '2026-08-02T10:00:00Z',
    proxy: {
      state: 'stunned',
      stunned_at: '2026-08-02T10:00:01Z',
      message: 'Agent agent-cardvault stunned: credentials revoked, state marked as stunned',
    },
    event: {
      id: 'demo-activity-1',
      timestamp: '2026-08-02T10:00:00Z',
      event_type: 'agent.stunned',
      agent_id: 'agent-cardvault',
      agent_name: 'Cardvault Agent',
      actor: 'demo-operator',
      detail: { outcome: 'stunned' },
    },
    ...overrides,
  }
}

function cardvault(overrides: Partial<AgentFixture> = {}): AgentFixture {
  return {
    id: 'agent-cardvault',
    name: 'Cardvault Agent',
    namespace: FLUX_NS,
    type: 'supercred-demo',
    framework: 'langchain',
    model: 'gpt-4',
    state: 'idle',
    phase: 'Running',
    supercred: true,
    supercred_target: 'cardvault.inf-signalloom.svc.cluster.local:8080',
    ...overrides,
  }
}

function plainAgent(id: string): AgentFixture {
  return { id, name: id, namespace: AGENTS_NS, type: 'demo', state: 'active', phase: 'Running' }
}

function stunnedCardvault(): AgentFixture {
  return cardvault({
    state: 'stunned',
    stunned_at: '2026-01-01T00:01:00Z',
    stun_reason: 'non-compliant securityContext',
  })
}

/** Route fetches by URL so a test only declares the payloads it cares about. */
function mockFetch(routes: {
  agents?: AgentFixture[]
  compliance?: unknown
  stun?: unknown
  agentsError?: Error
}) {
  const calls: string[] = []
  const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)
    if (url.includes('/compliance')) {
      return {
        ok: true,
        json: async () =>
          routes.compliance ?? {
            agent_id: 'agent-cardvault',
            compliant: false,
            results: [
              { check: 'security-context-present', pass: false, reason: 'securityContext is not set', severity: 'critical' },
              { check: 'resource-limits-set', pass: true, reason: 'CPU and memory limits configured', severity: 'high' },
              { check: 'network-policy-exists', pass: false, reason: 'No NetworkPolicy targets this pod', severity: 'high' },
            ],
            evaluated_at: '2026-01-01T00:00:00Z',
          },
      } as Response
    }
    if (url.includes('/stun')) {
      return {
        ok: true,
        json: async () =>
          routes.stun ?? {
            agent_id: 'agent-cardvault',
            namespace: FLUX_NS,
            state: 'stunned',
            stunned_at: '2026-01-01T00:00:00Z',
            message: 'Agent agent-cardvault stunned: credentials revoked',
          },
      } as Response
    }
    if (routes.agentsError) throw routes.agentsError
    return {
      ok: true,
      json: async () => ({
        agents: routes.agents ?? [],
        namespaces: [AGENTS_NS, FLUX_NS],
      }),
    } as Response
  })
  globalThis.fetch = fetchMock as unknown as typeof fetch
  return calls
}

function renderPage() {
  return render(
    <MemoryRouter>
      <SuperCredPage />
    </MemoryRouter>,
  )
}

async function refresh() {
  await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))
}

describe('SuperCred refresh explanations', () => {
  it('explains that Refresh Agents only reloads the agent list', async () => {
    renderPage()
    await userEvent.hover(screen.getByTestId('supercred-refresh-agents-help'))
    expect(screen.getByRole('tooltip')).toHaveTextContent(/only the visible SuperCred agent list/i)
  })
})

describe('SuperCredPage', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    // restoreAllMocks clears the module-level auth shim's implementation too,
    // so re-arm it here rather than only at declaration.
    getAccessTokenSilently.mockResolvedValue('test-token')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // ─── Core agent rendering ────────────────────────────────────────────────

  it('renders SuperCred agents returned by the proxy', async () => {
    mockFetch({ agents: [cardvault(), plainAgent('agent-dennis')] })
    renderPage()
    await refresh()
    // Agent name appears in multiple sections (agent list + lifecycle); verify
    // at least one renders.
    const matches = await screen.findAllByText('Cardvault Agent')
    expect(matches.length).toBeGreaterThanOrEqual(1)
  })

  it('shows the namespace the agent was discovered in', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('agent-namespace-agent-cardvault')).toHaveTextContent(FLUX_NS)
  })

  it('says so explicitly when agents were found but none is SuperCred', async () => {
    mockFetch({ agents: [plainAgent('agent-dennis'), plainAgent('agent-patsy')] })
    renderPage()
    await refresh()
    const emptyState = await screen.findByTestId('supercred-empty-state')
    expect(emptyState).toHaveTextContent(/2 runtime agents/)
    expect(emptyState).toHaveTextContent(/none carries the SuperCred label/i)
    expect(emptyState).toHaveTextContent('make demo-signalloom-supercred-1')
  })

  it('distinguishes "not loaded yet" from "loaded but empty"', async () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.getByTestId('supercred-not-loaded')).toBeInTheDocument()
    expect(screen.queryByTestId('supercred-empty-state')).not.toBeInTheDocument()
    await refresh()
    expect(await screen.findByTestId('supercred-empty-state')).toBeInTheDocument()
    expect(screen.queryByTestId('supercred-not-loaded')).not.toBeInTheDocument()
  })

  // ─── Compliance ──────────────────────────────────────────────────────────

  it('passes the agent namespace to the compliance call', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    await waitFor(() =>
      expect(
        calls.some(url =>
          url === `/supercred-api/agents/agent-cardvault/compliance?namespace=${FLUX_NS}`,
        ),
      ).toBe(true),
    )
    expect(await screen.findByText('security-context-present')).toBeInTheDocument()
  })

  it('shows compliance summary counts after scan', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    const summary = await screen.findByTestId('supercred-compliance-summary')
    expect(summary).toHaveTextContent('1 passed')
    expect(summary).toHaveTextContent('2 failed')
    expect(summary).toHaveTextContent('3 total checks')
  })

  it('renders severity column for compliance results', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    const compliance = await screen.findByTestId('supercred-compliance')
    expect(compliance).toHaveTextContent('critical')
    expect(compliance).toHaveTextContent('high')
  })

  it('renders multiple compliance check rows', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))
    expect(await screen.findByText('security-context-present')).toBeInTheDocument()
    expect(screen.getByText('resource-limits-set')).toBeInTheDocument()
    expect(screen.getByText('network-policy-exists')).toBeInTheDocument()
  })

  // ─── Stun ────────────────────────────────────────────────────────────────

  // The isolation is performed by POST /api/agents/{id}/stun, which calls the
  // SuperCred proxy server-side. This asserts the browser does NOT also call
  // the proxy: it used to, and a surviving copy would relabel the pod and
  // revoke the lease a second time. The symptom of a double stun is an agent
  // that ends up stunned, which is indistinguishable from success on screen —
  // so nothing but this assertion would catch it.
  it('never calls the proxy itself, so the pod is not stunned twice', async () => {
    const calls = mockFetch({ agents: [cardvault()] })
    vi.spyOn(api.agents, 'stun').mockResolvedValue(stunResponse())
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))

    expect(await screen.findByTestId('supercred-stun-result')).toBeInTheDocument()
    expect(calls.filter(url => url.includes('/stun'))).toEqual([])
  })

  it('shows automated stun actions after stun', async () => {
    mockFetch({ agents: [cardvault()] })
    vi.spyOn(api.agents, 'stun').mockResolvedValue(stunResponse())
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
    const actions = await screen.findByTestId('supercred-stun-actions')
    expect(actions).toHaveTextContent('OpenBao dynamic lease revoked')
    expect(actions).toHaveTextContent('SPIFFE SVID rotation blocked')
    expect(actions).toHaveTextContent('deny-all egress')
    expect(actions).toHaveTextContent('audit trail')
  })

  it("relays the proxy's own wording from where relayed claims live", async () => {
    mockFetch({ agents: [cardvault()] })
    vi.spyOn(api.agents, 'stun').mockResolvedValue(
      stunResponse({ proxy: { state: 'stunned', message: 'lease 7f2a revoked, pod relabelled' } }),
    )
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))

    expect(await screen.findByTestId('supercred-stun-result')).toHaveTextContent(
      /lease 7f2a revoked, pod relabelled/,
    )
  })

  // The failure this pins is silent. `message` sits under `proxy`, and reading
  // it from the top level instead renders `undefined` — which React prints as
  // an empty string, so the line simply vanishes and no test that only checks
  // "the result panel appeared" would notice. A proxy that reports nothing has
  // to produce a sentence too, for the same reason.
  it('never renders a blank line when the proxy reported nothing', async () => {
    mockFetch({ agents: [cardvault()] })
    vi.spyOn(api.agents, 'stun').mockResolvedValue(stunResponse({ proxy: null }))
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))

    // Composed from the lifecycle fields the response always carries, so the
    // operator is told what happened rather than shown a gap.
    expect(await screen.findByTestId('supercred-stun-result')).toHaveTextContent(
      /Agent agent-cardvault isolated: active → suspended/,
    )
  })

  it('hides stun button for already-stunned agents', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    await screen.findAllByText('Cardvault Agent')
    expect(screen.queryByRole('button', { name: /Stun Agent/ })).not.toBeInTheDocument()
  })

  // ─── Stun leaves an audit trace ──────────────────────────────────────────
  //
  // One call both isolates the agent and records it. These pin down that the
  // browser contributes nothing to that record beyond pressing the button, and
  // that a failed stun is reported as a failed stun.

  async function stunOnce() {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Stun Agent/ }))
  }

  it('asks the API to stun the agent and tells it nothing else', async () => {
    const spy = vi.spyOn(api.agents, 'stun').mockResolvedValue(stunResponse())
    await stunOnce()

    await waitFor(() => expect(spy).toHaveBeenCalledTimes(1))

    // Token and target, and that is the whole call. This assertion has been
    // walked backwards twice: it first asserted `outcome: 'stunned'` was sent,
    // then locator-only after the narrative fields were removed, and now no
    // body at all. Asserted on the exact argument list rather than with
    // objectContaining, because objectContaining is satisfied by a call that
    // has quietly grown a third argument again.
    expect(spy.mock.calls[0]).toEqual(['test-token', 'agent-cardvault'])
  })

  it('shows the recorded event and points at the Audit Trail', async () => {
    // Stub the record explicitly rather than letting the real client fall
    // through to demo-mode fixtures. This test is about what the page renders
    // once an event comes back, so it must not also depend on which mode the
    // file happens to run in — SL_ENV defaults to 'demo' under test today, but
    // a sibling change declaring live mode would otherwise silently reroute
    // this through axios and turn a render assertion into a network failure.
    vi.spyOn(api.agents, 'stun').mockResolvedValue(stunResponse())
    await stunOnce()

    const recorded = await screen.findByTestId('supercred-stun-event')
    expect(recorded).toHaveTextContent(/Audit event recorded/)
    expect(within(recorded).getByTestId('stun-event-type')).toHaveTextContent('agent.stunned')
    expect(within(recorded).getByTestId('stun-event-agent')).toHaveTextContent('Cardvault Agent')
    expect(within(recorded).getByTestId('stun-event-actor')).toHaveTextContent(/\S/)
    expect(
      Number.isNaN(Date.parse(within(recorded).getByTestId('stun-event-timestamp').textContent ?? '')),
    ).toBe(false)
    expect(within(recorded).getByRole('link', { name: /Audit Trail/ })).toHaveAttribute('href', '/audit')
  })

  // There used to be a test here asserting the page still reported a successful
  // stun when the audit record failed, and said so in a separate banner. It is
  // gone because the state it described is now unreachable: the isolation and
  // its audit row are one call and one transaction, so "stunned but not
  // recorded" cannot occur. A banner claiming it had could only mislead.
  it('reports a failed stun as a failure, and shows no result', async () => {
    vi.spyOn(api.agents, 'stun').mockRejectedValue(new Error('proxy unreachable'))
    await stunOnce()

    expect(await screen.findByTestId('supercred-error')).toHaveTextContent(/proxy unreachable/)
    // Nothing happened, so nothing may be shown as having happened — the old
    // shape could render a stun result next to a recording failure.
    expect(screen.queryByTestId('supercred-stun-result')).not.toBeInTheDocument()
    expect(screen.queryByTestId('supercred-stun-event')).not.toBeInTheDocument()
  })

  // ─── Phase warnings ─────────────────────────────────────────────────────

  it('warns when an agent pod phase means it cannot run', async () => {
    mockFetch({ agents: [cardvault({ phase: 'Pending' })] })
    renderPage()
    await refresh()
    const warning = await screen.findByTestId('supercred-phase-warning')
    expect(warning).toHaveTextContent(/Pending/)
    expect(warning).toHaveTextContent('make demo-signalloom-supercred-images')
  })

  it('does not warn for a healthy Running agent', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    await screen.findAllByText('Cardvault Agent')
    expect(screen.queryByTestId('supercred-phase-warning')).not.toBeInTheDocument()
  })

  // ─── Error handling ──────────────────────────────────────────────────────

  it('renders a fetch failure without crashing', async () => {
    mockFetch({ agentsError: new Error('proxy unreachable') })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('supercred-error')).toHaveTextContent(/proxy unreachable/)
    expect(screen.getByRole('heading', { level: 1, name: 'SuperCredential Demo' })).toBeInTheDocument()
  })

  // ─── Architecture overview ──────────────────────────────────────────────

  it('renders architecture overview section', () => {
    mockFetch({ agents: [] })
    renderPage()
    const arch = screen.getByTestId('supercred-architecture')
    expect(arch).toHaveTextContent('Architecture Overview')
    expect(arch).toHaveTextContent('zero-trust credential lifecycle')
    expect(arch).toHaveTextContent('SPIFFE SVID')
  })

  it('renders flow diagram with 6 steps', () => {
    mockFetch({ agents: [] })
    renderPage()
    const diagram = screen.getByTestId('supercred-flow-diagram')
    expect(diagram).toHaveTextContent('Agent Deploy')
    expect(diagram).toHaveTextContent('SPIFFE SVID')
    expect(diagram).toHaveTextContent('OpenBao Exchange')
    expect(diagram).toHaveTextContent('Service Call')
    expect(diagram).toHaveTextContent('Compliance Scan')
    expect(diagram).toHaveTextContent('Enforce/Revoke')
  })

  // ─── Lifecycle timeline ─────────────────────────────────────────────────

  // These four used to pin the defect: they asserted steps 1-4 read "completed"
  // and step 5 "active" purely because an agent was running, and step 6 "failed"
  // purely because it was stunned — six steps derived from `!!agent.id` and
  // `isStunned` with hardcoded 2026-01-01 timestamps. The card is now backed by
  // observed evidence, so the contract to pin is the inverse.

  it('renders the credential lifecycle card when an agent is loaded', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('supercred-lifecycle')).toHaveTextContent('Credential Lifecycle')
  })

  it('does NOT derive lifecycle state from the agent being running', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const lifecycle = await screen.findByTestId('supercred-lifecycle')
    expect(lifecycle).not.toHaveTextContent(/completed/i)
    expect(lifecycle.textContent ?? '').not.toMatch(/2026-01-01T00:00:0/)
  })

  it('does NOT derive lifecycle state from the agent being stunned', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('supercred-lifecycle')).not.toHaveTextContent(/completed/i)
  })

  it('does not render lifecycle when no agents are loaded', () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.queryByTestId('supercred-lifecycle')).not.toBeInTheDocument()
  })

  // ─── Credential inventory ───────────────────────────────────────────────

  it('renders credential inventory table when agent is loaded', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const creds = await screen.findByTestId('supercred-credentials')
    expect(creds).toHaveTextContent('Credential Inventory')
  })

  it('shows 3 credential records with correct issuers', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const creds = await screen.findByTestId('supercred-credentials')
    expect(creds).toHaveTextContent('spire-server.spire-system')
    expect(creds).toHaveTextContent('openbao.openbao-system')
    expect(creds).toHaveTextContent('cardvault-service')
  })

  it('shows active status for credentials of a running agent', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const spiffeCred = await screen.findByTestId('credential-status-cred-agent-cardvault-spiffe')
    expect(spiffeCred).toHaveTextContent('active')
    const openbao = screen.getByTestId('credential-status-cred-agent-cardvault-openbao')
    expect(openbao).toHaveTextContent('active')
  })

  it('shows revoked status for credentials of a stunned agent', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    const spiffeCred = await screen.findByTestId('credential-status-cred-agent-cardvault-spiffe')
    expect(spiffeCred).toHaveTextContent('revoked')
    const openbao = screen.getByTestId('credential-status-cred-agent-cardvault-openbao')
    expect(openbao).toHaveTextContent('revoked')
  })

  it('shows rotation count for credentials', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    // The OpenBao credential has rotation_count: 2
    const creds = await screen.findByTestId('supercred-credentials')
    expect(within(creds).getByText('2')).toBeInTheDocument()
  })

  it('does not render credentials when no agents are loaded', () => {
    mockFetch({ agents: [] })
    renderPage()
    expect(screen.queryByTestId('supercred-credentials')).not.toBeInTheDocument()
  })

  // ─── Discovery summary ─────────────────────────────────────────────────

  it('renders discovery summary after loading agents', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const summary = await screen.findByTestId('supercred-discovery-summary')
    expect(summary).toHaveTextContent('Discovery Summary')
    expect(screen.getByTestId('discovery-total')).toHaveTextContent('1')
    expect(screen.getByTestId('discovery-supercred')).toHaveTextContent('1')
    expect(screen.getByTestId('discovery-namespaces')).toHaveTextContent('2')
    expect(screen.getByTestId('discovery-blocked')).toHaveTextContent('0')
  })

  it('shows blocked count in discovery summary for pending agents', async () => {
    mockFetch({ agents: [cardvault({ phase: 'Pending' })] })
    renderPage()
    await refresh()
    expect(await screen.findByTestId('discovery-blocked')).toHaveTextContent('1')
  })

  it('shows namespace list in discovery summary', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    const nsList = await screen.findByTestId('discovery-namespace-list')
    expect(nsList).toHaveTextContent(AGENTS_NS)
    expect(nsList).toHaveTextContent(FLUX_NS)
  })

  // ─── Demo steps ─────────────────────────────────────────────────────────

  it('names the real Makefile targets in the demo steps', async () => {
    mockFetch({ agents: [] })
    renderPage()
    const steps = screen.getByTestId('supercred-demo-steps')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-1')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-2')
    expect(steps).toHaveTextContent('make demo-signalloom-supercred-5')
    expect(steps).not.toHaveTextContent('demo-supercred-step1')
  })

  // ─── Agent detail rendering ─────────────────────────────────────────────

  it('shows framework and model when present', async () => {
    mockFetch({ agents: [cardvault()] })
    renderPage()
    await refresh()
    // Agent namespace test-id is unique to the agent row
    const nsEl = await screen.findByTestId('agent-namespace-agent-cardvault')
    const row = nsEl.closest('div')!.parentElement!
    expect(row).toHaveTextContent('Framework: langchain')
    expect(row).toHaveTextContent('Model: gpt-4')
  })

  it('shows stun reason for stunned agents', async () => {
    mockFetch({ agents: [stunnedCardvault()] })
    renderPage()
    await refresh()
    const nsEl = await screen.findByTestId('agent-namespace-agent-cardvault')
    const row = nsEl.closest('div')!.parentElement!
    expect(row).toHaveTextContent('non-compliant securityContext')
  })
})

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// A control that is merely disabled tells the room nothing. Mid-demo the only
// question anyone has about a running step is "is it slow or is it hung", and
// the answer to that is an elapsed figure that keeps moving. Every wait on this
// page now carries the instructor panel's pixel-grid-and-timer treatment.

/** A promise held open until the test decides the request has finished. */
function gate<T>() {
  let release!: (value: T) => void
  const promise = new Promise<T>(resolve => { release = resolve })
  return { promise, release }
}

const okJson = (body: unknown) => ({ ok: true, json: async () => body }) as Response

describe('SuperCred waits say what is running and for how long', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    getAccessTokenSilently.mockResolvedValue('test-token')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('counts up on Refresh Agents while discovery is in flight', async () => {
    const held = gate<Response>()
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith('/agents')) return held.promise
      return okJson({})
    }) as unknown as typeof fetch

    renderPage()
    await userEvent.click(screen.getByRole('button', { name: /Refresh Agents/ }))

    const loader = await screen.findByTestId('supercred-refresh-loader')
    // The elapsed figure is present and reading a real duration, not a stub.
    expect(within(loader).getByTestId('supercred-refresh-loader-elapsed')).toHaveTextContent(/^\d+(\.\d)?s$/)
    // Nothing anonymous: the control still names its own operation.
    expect(screen.getByRole('button', { name: /refreshing/i })).toBeDisabled()

    held.release(okJson({ agents: [cardvault()], namespaces: [FLUX_NS] }))

    await waitFor(() => expect(screen.queryByTestId('supercred-refresh-loader')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: /Refresh Agents/ })).toBeEnabled()
  })

  it('ticks only on the row being stunned, never on every row at once', async () => {
    // Held at the API client, not at fetch: the stun is one authenticated call
    // to POST /api/agents/{id}/stun now, and the browser makes no request to
    // the proxy to intercept.
    const held = gate<StunAgentResponse>()
    vi.spyOn(api.agents, 'stun').mockReturnValue(held.promise)
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.endsWith('/agents')) {
        return okJson({
          agents: [cardvault(), cardvault({ id: 'agent-second', name: 'Second Agent' })],
          namespaces: [FLUX_NS],
        })
      }
      return okJson({})
    }) as unknown as typeof fetch

    renderPage()
    await refresh()

    const stunButtons = await screen.findAllByRole('button', { name: /Stun Agent/ })
    expect(stunButtons).toHaveLength(2)
    await userEvent.click(stunButtons[0])

    expect(await screen.findByTestId('supercred-stun-loader-agent-cardvault')).toBeInTheDocument()
    // `stunLoading` is page-wide — it disables every row. A timer on every row
    // would claim two operations are running when one is.
    expect(screen.queryByTestId('supercred-stun-loader-agent-second')).not.toBeInTheDocument()
    // The grid and the figure are decoration; the button carries the name.
    expect(screen.getByRole('button', { name: /stunning/i })).toBeDisabled()

    held.release(stunResponse())

    await waitFor(() =>
      expect(screen.queryByTestId('supercred-stun-loader-agent-cardvault')).not.toBeInTheDocument(),
    )
    expect(await screen.findAllByRole('button', { name: /Stun Agent/ })).toHaveLength(2)
  })

  it('counts up on the compliance scan of the row that started it', async () => {
    const held = gate<Response>()
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.includes('/compliance')) return held.promise
      if (url.endsWith('/agents')) return okJson({ agents: [cardvault()], namespaces: [FLUX_NS] })
      return okJson({})
    }) as unknown as typeof fetch

    renderPage()
    await refresh()
    await userEvent.click(await screen.findByRole('button', { name: /Compliance Scan/ }))

    const loader = await screen.findByTestId('supercred-scan-loader-agent-cardvault')
    expect(within(loader).getByTestId('supercred-scan-loader-agent-cardvault-elapsed')).toHaveTextContent(/s$/)
    expect(screen.getByRole('button', { name: /compliance scan running/i })).toBeDisabled()

    held.release(okJson({
      agent_id: 'agent-cardvault',
      compliant: true,
      results: [],
      evaluated_at: '2026-01-01T00:00:00Z',
    }))

    await waitFor(() =>
      expect(screen.queryByTestId('supercred-scan-loader-agent-cardvault')).not.toBeInTheDocument(),
    )
    expect(screen.getByRole('button', { name: /Compliance Scan/ })).toBeEnabled()
  })
})
