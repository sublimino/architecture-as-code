import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import CredentialInventoryPage from './CredentialInventoryPage'
import { setDemoMode } from '../api/demoMode'

// The real useAuth0 returns a stable getAccessTokenSilently; the mock must too.
// A fresh identity per render invalidates the page's load useCallback and turns
// its mount effect into an infinite render loop.
const auth0Stub = vi.hoisted(() => ({ getAccessTokenSilently: () => Promise.resolve('test-token') }))
vi.mock('../auth/oidc', () => ({ useAuth0: () => auth0Stub }))

const cryptoMock = vi.hoisted(() => vi.fn())
vi.mock('../api/client', () => ({ api: { health: { crypto: cryptoMock } } }))

interface AgentFixture {
  id: string
  name?: string
  namespace?: string | null
  service_account?: string | null
  state?: string | null
  supercred?: boolean
}

function cardvaultPod(overrides: Partial<AgentFixture> = {}): AgentFixture {
  return {
    id: 'cardvault-agent-7f9c',
    name: 'Cardvault Agent',
    namespace: 'fe-signalloom-agents',
    service_account: 'cardvault-agent',
    state: 'idle',
    supercred: true,
    ...overrides,
  }
}

function mockAgentFetch(opts: { agents?: AgentFixture[]; fail?: boolean } = {}) {
  const fetchMock = vi.fn(async (url: RequestInfo | URL) => {
    void url
    if (opts.fail) throw new Error('proxy unreachable')
    return {
      ok: true,
      // Carried because the page reports the literal status in its proof
      // console; a mock without one would let "HTTP undefined" ship.
      status: 200,
      json: async () => ({ agents: opts.agents ?? [], namespaces: ['fe-signalloom-agents'] }),
    } as unknown as Response
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

function renderPage() {
  return render(
    <MemoryRouter>
      <CredentialInventoryPage />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  setDemoMode(false)
  cryptoMock.mockResolvedValue({ tenant_id: 't1', proofs: [] })
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

// ─── Live path ──────────────────────────────────────────────────────────────

describe('CredentialInventoryPage — live path', () => {
  it('derives the SPIFFE ID from the discovered pod namespace and service account', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => {
      expect(
        screen.getAllByText('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent').length,
      ).toBeGreaterThan(0)
    })
  })

  it('queries the SuperCred agent-discovery endpoint', async () => {
    const fetchMock = mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(String(fetchMock.mock.calls[0][0])).toContain('/supercred-api/agents')
  })

  it('tags a live-derived identity as live', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    const row = await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    expect(within(row).getByTestId(/^identity-provenance/)).toHaveTextContent(/live/i)
  })

  it('keeps the config-sourced identity visible and tagged as config', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    const row = await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom')
    expect(within(row).getByTestId(/^identity-provenance/)).toHaveTextContent(/config/i)
  })

  it('shows a revoked identity for a stunned agent', async () => {
    mockAgentFetch({ agents: [cardvaultPod({ state: 'stunned' })] })
    renderPage()
    const row = await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    expect(within(row).getByTestId(/^identity-state/)).toHaveTextContent(/revoked/i)
  })

  it('renders the OpenBao role and policy path the identity is bound to', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    // Scoped to the identity row: the policy path also appears as the OpenBao
    // lease's scope in the credential table, so an unscoped query is ambiguous.
    const row = await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    expect(within(row).getByText('signalloom-cardvault-agent')).toBeInTheDocument()
    expect(within(row).getByText('kv/data/signalloom/cardvault-agent')).toBeInTheDocument()
  })
})

// ─── Unregistered workloads ─────────────────────────────────────────────────

// Verified against the running cluster on 2026-08-02: the five agent-* pods in
// fe-signalloom-agents all run serviceAccountName `default`, which has no SPIRE
// registration entry. They hold no SVID, and the page must say so.
describe('CredentialInventoryPage — unregistered workloads', () => {
  const defaultSaPod = cardvaultPod({
    id: 'agent-dennis',
    name: 'Dennis',
    service_account: 'default',
    supercred: false,
  })

  it('warns when a discovered pod has no SPIRE registration entry', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    const warning = await screen.findByTestId('unregistered-warning')
    expect(warning).toHaveTextContent(/no SPIRE registration entry/i)
    expect(warning).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/default')
  })

  it('shows the unregistered identity as pending, never active', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    const row = await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/default')
    expect(within(row).getByTestId(/^identity-state/)).toHaveTextContent(/pending/i)
  })

  it('does not claim an SVID exists for an unregistered identity', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    const row = await screen.findByTestId('credential-row-default-x509-svid')
    expect(within(row).getByTestId(/^credential-status/)).toHaveTextContent(/pending/i)
  })

  it('stays silent when every discovered workload is registered', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('credential-row-cardvault-agent-x509-svid')
    expect(screen.queryByTestId('unregistered-warning')).toBeNull()
  })
})

// ─── Demo fallback ──────────────────────────────────────────────────────────

describe('CredentialInventoryPage — demo fallback', () => {
  it('falls back to demo fixtures when the discovery endpoint is unreachable', async () => {
    mockAgentFetch({ fail: true })
    renderPage()
    const banner = await screen.findByTestId('credential-inventory-source')
    expect(banner).toHaveTextContent(/demo/i)
    expect(screen.getAllByTestId(/^identity-row-/).length).toBeGreaterThan(2)
  })

  it('names the reason the live path was abandoned rather than silently degrading', async () => {
    mockAgentFetch({ fail: true })
    renderPage()
    const banner = await screen.findByTestId('credential-inventory-source')
    expect(banner).toHaveTextContent(/proxy unreachable/i)
  })

  it('uses demo fixtures without calling the proxy when demo mode is on', async () => {
    setDemoMode(true)
    const fetchMock = mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('credential-inventory-source')
    expect(fetchMock).not.toHaveBeenCalled()
    expect(screen.getByTestId('credential-inventory-source')).toHaveTextContent(/demo/i)
  })

  it('tags demo rows as demo so a fixture is never read as a measurement', async () => {
    setDemoMode(true)
    mockAgentFetch()
    renderPage()
    const rows = await screen.findAllByTestId(/^identity-provenance-/)
    expect(rows.every((r) => /demo/i.test(r.textContent ?? ''))).toBe(true)
  })
})

// ─── Credential table ───────────────────────────────────────────────────────

describe('CredentialInventoryPage — credentials', () => {
  it('lists the three links of the identity chain for a discovered workload', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('credential-row-cardvault-agent-x509-svid')
    expect(screen.getByTestId('credential-row-cardvault-agent-openbao-lease')).toBeInTheDocument()
    expect(screen.getByTestId('credential-row-cardvault-agent-service-token')).toBeInTheDocument()
  })

  it('marks the OpenBao lease failed when the live crypto proof failed', async () => {
    cryptoMock.mockResolvedValue({
      tenant_id: 't1',
      proofs: [{ name: 'bao-spire-positive-proof', kind: 'positive', status: 'failed', title: '', description: '', expectation: '', evidence: '' }],
    })
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    const row = await screen.findByTestId('credential-row-cardvault-agent-openbao-lease')
    expect(within(row).getByTestId(/^credential-status/)).toHaveTextContent(/failed/i)
  })

  it('leaves the lease active when the positive proof passed', async () => {
    cryptoMock.mockResolvedValue({
      tenant_id: 't1',
      proofs: [{ name: 'bao-spire-positive-proof', kind: 'positive', status: 'passed', title: '', description: '', expectation: '', evidence: '' }],
    })
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    const row = await screen.findByTestId('credential-row-cardvault-agent-openbao-lease')
    expect(within(row).getByTestId(/^credential-status/)).toHaveTextContent(/active/i)
  })

  it('does not let a failing negative proof mark the lease failed — a denied impostor is the pass case', async () => {
    cryptoMock.mockResolvedValue({
      tenant_id: 't1',
      proofs: [{ name: 'bao-spire-negative-proof', kind: 'negative', status: 'passed', title: '', description: '', expectation: '', evidence: '' }],
    })
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    const row = await screen.findByTestId('credential-row-cardvault-agent-openbao-lease')
    expect(within(row).getByTestId(/^credential-status/)).toHaveTextContent(/active/i)
  })

  it('filters the credential table by status', async () => {
    mockAgentFetch({ agents: [cardvaultPod({ state: 'stunned' })] })
    renderPage()
    await screen.findByTestId('credential-row-cardvault-agent-x509-svid')
    await userEvent.selectOptions(screen.getByTestId('credential-status-filter'), 'revoked')
    await waitFor(() => {
      const rows = screen.getAllByTestId(/^credential-row-/)
      expect(rows.every((r) => /revoked/i.test(r.textContent ?? ''))).toBe(true)
    })
  })
})

// ─── Summary ────────────────────────────────────────────────────────────────

describe('CredentialInventoryPage — summary', () => {
  it('counts workloads and credentials', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    // fe-signalloom (config) + cardvault-agent (live) = 2 workloads, 3 creds each.
    await waitFor(() => expect(screen.getByTestId('summary-workloads')).toHaveTextContent('2'))
    expect(screen.getByTestId('summary-total')).toHaveTextContent('6')
  })

  it('reports revoked credentials for a stunned agent', async () => {
    mockAgentFetch({ agents: [cardvaultPod({ state: 'stunned' })] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('summary-revoked')).toHaveTextContent('3'))
  })
})

// ─── Accessibility / structure ──────────────────────────────────────────────

describe('CredentialInventoryPage — structure', () => {
  it('renders a single page heading', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    expect(await screen.findByRole('heading', { level: 1, name: /credential inventory/i })).toBeInTheDocument()
  })

  it('states the trust domain the identities belong to', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('trust-domain')).toHaveTextContent('signalloom.demo'))
  })
  // The two tables on this page are the ones an executive is asked to read as
  // evidence, and four of their headers are jargon that the page never expands:
  // "Selectors", "Kind", "Scope" and "Rotations". A misread here is not
  // cosmetic — "Rotations: 47" looks like a fault until you know a rising count
  // IS the control working.
  describe('the tables explain their own jargon', () => {
    it('explains what SPIRE checks before it issues an identity', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      const hint = await screen.findByTestId('identity-selectors-help')
      expect(hint).toHaveAccessibleName('What Selectors means')
      await user.hover(hint)
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/service account/i)
      // The consequence, not just the definition: matching is what gates issuance.
      expect(tooltip.textContent).toMatch(/cannot obtain the credential/i)
    })

    it('says a rising rotation count is the design, not a fault', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      await user.hover(await screen.findByTestId('credential-inventory-help-rotationCount'))
      expect(await screen.findByRole('tooltip')).toHaveTextContent('not a fault')
    })

    it('distinguishes TTL from Expires, which sit next to each other', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      await user.hover(await screen.findByTestId('credential-inventory-help-ttlSeconds'))
      expect((await screen.findByRole('tooltip')).textContent).toMatch(/Expires is the resulting instant/i)
    })

    it('names all three credential kinds, so none of them is a bare slug', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      await user.hover(await screen.findByTestId('credential-inventory-help-kind'))
      const tooltip = await screen.findByRole('tooltip')
      for (const kind of ['x509-svid', 'openbao-lease', 'service-token']) {
        expect(tooltip.textContent).toContain(kind)
      }
    })

    it('leaves self-evident headers alone rather than blanketing every column', async () => {
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()
      await screen.findByTestId('identity-selectors-help')

      // A "?" that restates its label is noise; these four say themselves.
      expect(screen.queryByTestId('credential-inventory-help-workload')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-issuer')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-status')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-expiresAt')).not.toBeInTheDocument()
    })
  })
})

// ─── The proof behind the provenance banner ─────────────────────────────────
//
// The banner says "Live" or "Demo data" and the rows carry provenance tags —
// a summary of a data path the reader has to take on trust. The Credential
// Lifecycle card is held to a higher standard than that: open the claim, read
// the literal request behind it, rerun it. This page makes the same claims at a
// higher altitude, so it owes the same console.

describe('CredentialInventoryPage — how do we know?', () => {
  it('offers the disclosure and names how many checks are behind the page', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    expect(screen.getByTestId('inventory-disclose-proof')).toHaveTextContent('3 checks')
    // Closed by default — the executive reading is the banner, not the console.
    expect(screen.queryByTestId('inventory-proof-console')).not.toBeInTheDocument()
  })

  it('exposes the literal discovery request and what it answered', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('inventory-disclose-proof'))
    const panel = screen.getByTestId('inventory-proof-console-panel')
    expect(panel).toHaveTextContent('curl -s /supercred-api/agents')
    expect(panel).toHaveTextContent('HTTP 200')
    // The pods it actually saw, not a count it asserts.
    expect(panel).toHaveTextContent('fe-signalloom-agents/Cardvault Agent')
  })

  it('reaches the crypto proof and the manifest source through its tabs', async () => {
    cryptoMock.mockResolvedValue({
      tenant_id: 't1',
      proofs: [{ name: 'bao-spire-positive-proof', status: 'passed' }],
    })
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('inventory-disclose-proof'))

    await userEvent.click(screen.getByTestId('inventory-proof-console-tab-1'))
    expect(screen.getByTestId('inventory-proof-console-panel')).toHaveTextContent('/api/health/crypto')
    expect(screen.getByTestId('inventory-proof-console-panel')).toHaveTextContent('bao-spire-positive-proof: passed')

    await userEvent.click(screen.getByTestId('inventory-proof-console-tab-2'))
    expect(screen.getByTestId('inventory-proof-console-panel')).toHaveTextContent('credentialInventory.ts')
    // Declared is not observed, and the console has to say which it is.
    expect(screen.getByTestId('inventory-proof-console-panel')).toHaveTextContent('DECLARED, not observed')
  })

  it('says a failed look is a failure to look, not an empty cluster', async () => {
    mockAgentFetch({ fail: true })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('inventory-disclose-proof'))
    const panel = screen.getByTestId('inventory-proof-console-panel')
    expect(panel).toHaveTextContent('proxy unreachable')
    expect(panel).toHaveTextContent('failure to look, not a finding that nothing is deployed')
  })

  it('admits the crypto proof was never obtained rather than implying it passed', async () => {
    cryptoMock.mockRejectedValue(new Error('crypto health 503'))
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('inventory-disclose-proof'))
    await userEvent.click(screen.getByTestId('inventory-proof-console-tab-1'))
    expect(screen.getByTestId('inventory-proof-console-panel')).toHaveTextContent('unproven, not disproven')
  })

  it('states plainly that demo mode made no cluster call at all', async () => {
    setDemoMode(true)
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('inventory-disclose-proof'))
    expect(screen.getByTestId('inventory-proof-console')).toHaveTextContent('no cluster call was made')
    setDemoMode(false)
  })
})
