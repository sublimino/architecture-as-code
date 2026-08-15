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

  it('warns when a discovered pod is absent from the declared registration manifest', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    const warning = await screen.findByTestId('unregistered-warning')
    expect(warning).toHaveTextContent(/not in the declared registration manifest/i)
    expect(warning).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/default')
  })

  // The banner's claim has to match the check that produced it. `registered` is
  // decided by set membership against the hardcoded CONFIG_REGISTRATION_ENTRIES
  // — no SPIRE server is contacted anywhere in this page's data path — so a
  // banner asserting "no SPIRE registration entry" was reporting a query that
  // never ran.
  it('does not assert a SPIRE fact it never went and checked', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    const warning = await screen.findByTestId('unregistered-warning')
    expect(warning).not.toHaveTextContent(/no SPIRE registration entry/i)
    expect(warning).toHaveTextContent(/No SPIRE server was queried/i)
  })

  it('shows the literal comparison behind the warning, and both sides of it', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    await screen.findByTestId('unregistered-warning')
    await userEvent.click(screen.getByTestId('unregistered-disclose-proof'))

    const panel = screen.getByTestId('unregistered-proof-console-panel')
    expect(panel).toHaveTextContent('CONFIG_REGISTRATION_ENTRIES.map(e => e.spiffeId).includes(discoveredId)')
    expect(panel).toHaveTextContent('No SPIRE server was contacted')
    // Both sides of the comparison, so the reader can check the verdict.
    expect(panel).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom')
    expect(panel).toHaveTextContent('spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/default')
  })

  it('names the command that would answer the SPIRE question, as one nobody ran', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    await screen.findByTestId('unregistered-warning')
    await userEvent.click(screen.getByTestId('unregistered-disclose-proof'))

    const panel = screen.getByTestId('unregistered-proof-console-panel')
    expect(panel).toHaveTextContent('spire-server entry show')
    expect(panel).toHaveTextContent('this dashboard has no path to run it')
    // Named as unavailable, never staged as a command with fabricated output.
    expect(panel).not.toHaveTextContent('$ spire-server entry show')
  })

  it('keeps the warning proof closed until it is asked for', async () => {
    mockAgentFetch({ agents: [defaultSaPod] })
    renderPage()
    await screen.findByTestId('unregistered-warning')
    expect(screen.queryByTestId('unregistered-proof-console')).toBeNull()
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
  // evidence, and their headers are jargon that the page never expands:
  // "Selectors", "Kind", "Scope", "Rotations", "Source" and "State". A misread
  // here is not cosmetic — "Rotations: 47" looks like a fault until you know a
  // rising count IS the control working, and "pending" reads as "starting up"
  // when it means "this identity was never registered at all".
  //
  // Reached by ACCESSIBLE NAME, not only by test id: a hint a screen reader or
  // a speech-input user cannot address is a hint that is not there for them.
  describe('the tables explain their own jargon', () => {
    it('explains what SPIRE checks before it issues an identity', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      const hint = await screen.findByTestId('identity-help-selectors')
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

    it('says pending means never registered, not still starting up', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      const hint = await screen.findByRole('button', { name: 'What State means' })
      await user.hover(hint)
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/no SVID was ever issued/i)
      // The misreading it exists to prevent, named outright.
      expect(tooltip.textContent).toMatch(/not a workload that is about to start/i)
    })

    it('says which provenance was measured and which is only declared', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      const hint = await screen.findByRole('button', { name: 'What Source means' })
      await user.hover(hint)
      const tooltip = await screen.findByRole('tooltip')
      for (const value of ['live', 'config', 'demo']) {
        expect(tooltip.textContent).toContain(value)
      }
      expect(tooltip.textContent).toMatch(/only a live row was measured/i)
    })

    // The 15-minute boundary is invisible knowledge that also decides a colour
    // twelve rows further down. It is explained where the number is stated —
    // the Expires header stays bare, per the rule asserted below.
    it('explains the 15-minute threshold where the figure is, not on the Expires header', async () => {
      const user = userEvent.setup()
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()

      const hint = await screen.findByRole('button', { name: 'What expiring within 15m means' })
      await user.hover(hint)
      const tooltip = await screen.findByRole('tooltip')
      expect(tooltip.textContent).toMatch(/turns the Expires column amber/i)
      expect(tooltip.textContent).toMatch(/not a fault/i)
    })

    it('leaves self-evident headers alone rather than blanketing every column', async () => {
      mockAgentFetch({ agents: [cardvaultPod()] })
      renderPage()
      await screen.findByTestId('identity-help-selectors')

      // A "?" that restates its label is noise; these four say themselves.
      expect(screen.queryByTestId('credential-inventory-help-workload')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-issuer')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-status')).not.toBeInTheDocument()
      expect(screen.queryByTestId('credential-inventory-help-expiresAt')).not.toBeInTheDocument()
      // Source is a slug on the identities table, where it separates measured
      // from declared, and a plain restatement on the credentials table where
      // the row's own badge already carries a title. Only the first earns a "?".
      expect(screen.queryByTestId('credential-inventory-help-provenance')).not.toBeInTheDocument()
    })
  })
})

// ─── Filtering ──────────────────────────────────────────────────────────────
//
// Both tables carry the same three controls in DataTable's `toolbar` slot:
// search, the lifecycle select, the provenance select. The two properties worth
// asserting are that each one actually narrows its own table, and that a filter
// matching nothing is always undoable — the second is the bug the slot exists
// to prevent, and it is invisible until someone filters to zero.

describe('CredentialInventoryPage — filtering', () => {
  const identityRows = () => screen.queryAllByTestId(/^identity-row-/)
  const credentialRows = () => screen.queryAllByTestId(/^credential-row-/)

  it('puts both tables\' filters in the shared toolbar slot', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')

    // DataTable renders these; a hand-stacked strip above the table would not
    // produce them, which is what makes this an assertion and not a tautology.
    expect(screen.getByTestId('identity-toolbar')).toBeInTheDocument()
    expect(screen.getByTestId('credential-inventory-toolbar')).toBeInTheDocument()
  })

  // ── Workload Identities ──────────────────────────────────────────────────

  it('narrows the identities by free-text search', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    await user.type(screen.getByTestId('identity-search'), 'cardvault')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
    expect(identityRows()[0]).toHaveTextContent('cardvault-agent')
    expect(screen.getByTestId('identity-count')).toHaveTextContent('1 of 2 identities shown')
  })

  it('searches every identity column the reader can see, not just the name', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    // A selector value — visible in the table, and in no other field.
    await user.type(screen.getByTestId('identity-search'), 'sa:cardvault-agent')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
  })

  it('narrows the identities by state', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod({ state: 'stunned' })] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    await user.selectOptions(screen.getByTestId('identity-state-filter'), 'revoked')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
    expect(identityRows()[0]).toHaveTextContent(/revoked/i)
  })

  it('narrows the identities by source, which is the measured/declared split', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    await user.selectOptions(screen.getByTestId('identity-source-filter'), 'live')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
    expect(identityRows()[0]).toHaveTextContent('cardvault-agent')

    await user.selectOptions(screen.getByTestId('identity-source-filter'), 'config')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
    expect(identityRows()[0]).toHaveTextContent('fe-signalloom')
  })

  it('offers an identity empty state that says which zero this is, and undoes itself', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    await user.type(screen.getByTestId('identity-search'), 'no-such-workload')
    await waitFor(() => expect(identityRows()).toHaveLength(0))

    // Recoverable, and worded as such — never confused with the discovery call
    // having genuinely found nothing.
    expect(screen.getByTestId('identity-empty')).toHaveTextContent('No identity matches those filters')
    expect(screen.queryByText('No workload identities found')).toBeNull()

    // The control that emptied the table outlived it, which is the whole
    // reason the toolbar is a DataTable prop rather than markup above it.
    const clear = screen.getByRole('button', { name: 'Clear filters' })
    await user.click(clear)
    await waitFor(() => expect(identityRows()).toHaveLength(2))
    expect(screen.queryByTestId('identity-empty')).toBeNull()
  })

  it('clears every identity control at once, not just the one last touched', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    await user.type(screen.getByTestId('identity-search'), 'cardvault')
    await user.selectOptions(screen.getByTestId('identity-source-filter'), 'config')
    await waitFor(() => expect(identityRows()).toHaveLength(0))

    await user.click(screen.getByTestId('identity-count-clear'))
    await waitFor(() => expect(identityRows()).toHaveLength(2))
    expect(screen.getByTestId('identity-search')).toHaveValue('')
    expect(screen.getByTestId('identity-source-filter')).toHaveValue('all')
  })

  it('hides the clear control only while nothing is filtered', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(identityRows()).toHaveLength(2))

    expect(screen.queryByTestId('identity-count-clear')).toBeNull()
    await user.selectOptions(screen.getByTestId('identity-state-filter'), 'active')
    expect(screen.getByTestId('identity-count-clear')).toBeInTheDocument()
  })

  // ── Credentials ──────────────────────────────────────────────────────────

  it('narrows the credentials by free-text search', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    await user.type(screen.getByTestId('credential-search'), 'fe-signalloom-api')
    await waitFor(() => expect(credentialRows()).toHaveLength(3))
    expect(screen.getByTestId('credential-count')).toHaveTextContent('3 of 6 credentials shown')
  })

  // Found by writing this suite: searching "cardvault" returns FOUR of the six
  // rows, not three, because `cardvault.inf-signalloom` is the issuer of every
  // service token on the page including fe-signalloom's. That is the search
  // working — the issuer is a column the reader can see, and a search that
  // ignored it would quietly hide the one row that names who minted it.
  it('searches the issuer, so a downstream service finds every token it minted', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    await user.type(screen.getByTestId('credential-search'), 'cardvault.inf-signalloom')
    await waitFor(() => expect(credentialRows()).toHaveLength(2))
    expect(credentialRows().every((r) => /service-token/.test(r.textContent ?? ''))).toBe(true)
  })

  it('narrows the credentials by kind, which is a column with no select of its own', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    await user.type(screen.getByTestId('credential-search'), 'openbao-lease')
    await waitFor(() => expect(credentialRows()).toHaveLength(2))
  })

  it('narrows the credentials by source', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    await user.selectOptions(screen.getByTestId('credential-source-filter'), 'live')
    await waitFor(() => expect(credentialRows()).toHaveLength(3))
    expect(credentialRows().every((r) => /cardvault/.test(r.textContent ?? ''))).toBe(true)
  })

  it('offers a credential empty state that undoes itself', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    await user.type(screen.getByTestId('credential-search'), 'no-such-credential')
    await waitFor(() => expect(credentialRows()).toHaveLength(0))
    expect(screen.getByTestId('credential-inventory-empty')).toHaveTextContent('No credential matches those filters')

    await user.click(screen.getByTestId('credential-count-clear'))
    await waitFor(() => expect(credentialRows()).toHaveLength(6))
  })

  it('combines the status select with search rather than letting one win', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod({ state: 'stunned' })] })
    renderPage()
    await waitFor(() => expect(credentialRows()).toHaveLength(6))

    // Stunned revokes cardvault's three; fe-signalloom's three stay active.
    await user.selectOptions(screen.getByTestId('credential-status-filter'), 'revoked')
    await waitFor(() => expect(credentialRows()).toHaveLength(3))

    // `fe-signalloom-api`, not `fe-signalloom` — the cardvault SVID's scope is
    // `…/ns/fe-signalloom-agents/sa/cardvault-agent`, which contains the
    // shorter string, so the loose term would have matched a revoked row and
    // made this assertion pass for the wrong reason.
    await user.type(screen.getByTestId('credential-search'), 'fe-signalloom-api')
    // Revoked AND fe-signalloom-api is empty — an AND, not a last-one-wins.
    await waitFor(() => expect(credentialRows()).toHaveLength(0))
  })

  // ── The unregistered warning is NOT a view of a filter ───────────────────

  // Worth pinning because it is a trap: "unregistered" and "pending" look
  // interchangeable and are not. `deriveEntriesFromAgents` ranks revocation
  // above pending — a stunned pod that was never registered comes back
  // `state: 'revoked'`, `registered: false` — so `State = pending` silently
  // omits it. The warning banner enumerates `!registered`, which no single
  // select on this table reproduces. Anyone tempted to delete the banner and
  // point the reader at a filter instead would drop exactly this row: an
  // unregistered workload that was ALSO cut off, which is the pairing an
  // operator most needs to see.
  it('lists an unregistered workload in the warning that no single state filter isolates', async () => {
    const user = userEvent.setup()
    const stunnedUnregistered = cardvaultPod({
      id: 'agent-dennis', name: 'Dennis', service_account: 'default',
      supercred: false, state: 'stunned',
    })
    mockAgentFetch({ agents: [stunnedUnregistered] })
    renderPage()

    const warning = await screen.findByTestId('unregistered-warning')
    expect(warning).toHaveTextContent('sa/default')

    // It is in the warning, and it is NOT pending.
    await user.selectOptions(screen.getByTestId('identity-state-filter'), 'pending')
    await waitFor(() => expect(identityRows()).toHaveLength(0))

    // It is revoked, because being stunned outranks never having been asked for.
    await user.selectOptions(screen.getByTestId('identity-state-filter'), 'revoked')
    await waitFor(() => expect(identityRows()).toHaveLength(1))
    expect(identityRows()[0]).toHaveAttribute(
      'data-testid',
      'identity-row-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/default',
    )

    // And the warning never moved while the table was being narrowed.
    expect(screen.getByTestId('unregistered-warning')).toHaveTextContent('sa/default')
  })

  // ── The invariant that makes filtering safe ──────────────────────────────

  // A filter asks what to LOOK at. It must never be readable as a claim that
  // the rest of the estate stopped existing, so the headline counts, the
  // unregistered banner and the proof console all keep reading the full set.
  it('narrows the tables without moving the summary counts or the warning', async () => {
    const user = userEvent.setup()
    mockAgentFetch({ agents: [cardvaultPod({ id: 'agent-dennis', name: 'Dennis', service_account: 'default', supercred: false })] })
    renderPage()
    await screen.findByTestId('unregistered-warning')
    // Both config entries plus the discovered `default`-SA pod = 3 workloads.
    await waitFor(() => expect(screen.getByTestId('summary-workloads')).toHaveTextContent('3'))

    await user.type(screen.getByTestId('identity-search'), 'fe-signalloom/sa/fe-signalloom')
    await user.type(screen.getByTestId('credential-search'), 'fe-signalloom-api')
    await waitFor(() => expect(identityRows()).toHaveLength(1))

    expect(screen.getByTestId('summary-workloads')).toHaveTextContent('3')
    expect(screen.getByTestId('summary-total')).toHaveTextContent('9')
    // The unregistered workload is filtered out of the table and still warned about.
    expect(screen.getByTestId('unregistered-warning')).toHaveTextContent('sa/default')
  })
})

// ─── Accessible names ───────────────────────────────────────────────────────
//
// WCAG 2.5.3 "Label in Name": an explicit aria-label REPLACES the visible
// label, so it has to contain it or a speech-input user saying the word they
// can see reaches nothing. components/sidebarLabelInName.test.tsx asserts this
// for the rail; the toolbar selects added here are the same shape of control.

describe('CredentialInventoryPage — label in name', () => {
  it('keeps every toolbar select addressable by the word printed beside it', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('identity-search')

    const labelled: Array<[string, string]> = [
      ['identity-state-filter', 'State'],
      ['identity-source-filter', 'Source'],
      ['credential-status-filter', 'Status'],
      ['credential-source-filter', 'Source'],
    ]
    for (const [testId, visible] of labelled) {
      const name = screen.getByTestId(testId).getAttribute('aria-label') ?? ''
      expect(name.toLowerCase()).toContain(visible.toLowerCase())
    }
  })

  it('groups each toolbar so its controls announce what they filter', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await screen.findByTestId('identity-search')

    expect(screen.getByRole('group', { name: 'Filter workload identities' })).toBeInTheDocument()
    expect(screen.getByRole('group', { name: 'Filter credentials' })).toBeInTheDocument()
  })
})

// ─── Design-system conformance ──────────────────────────────────────────────

describe('CredentialInventoryPage — shared components', () => {
  it('renders every status through StatusBadge rather than a local pill', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()

    const state = await screen.findByTestId('identity-state-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    const credential = screen.getByTestId('credential-status-cardvault-agent-x509-svid')
    for (const badge of [state, credential]) {
      expect(badge).toHaveClass('tag')
      // StatusBadge tints via color-mix; the local Tag it replaced did too, but
      // only StatusBadge also carries the matching border tint.
      expect(badge.style.borderColor).toContain('color-mix')
    }
  })

  it('keeps provenance colour-coded after the migration, not flattened to neutral', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()

    // The most load-bearing colour on the page: measured vs declared.
    const live = await screen.findByTestId('identity-provenance-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent')
    const config = screen.getByTestId('identity-provenance-spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom')
    expect(live.style.color).toBe('var(--teal)')
    expect(config.style.color).toBe('var(--cyan)')
    expect(config).toHaveAttribute('title', expect.stringContaining('not observed'))
  })

  it('opens the proof from a shared .btn, not a bespoke one', async () => {
    mockAgentFetch({ agents: [cardvaultPod()] })
    renderPage()
    await waitFor(() => expect(screen.getByTestId('inventory-disclose-proof')).toBeInTheDocument())

    const button = screen.getByTestId('inventory-disclose-proof')
    expect(button).toHaveClass('btn', 'btn-secondary')
    // Still toggles, which is the only thing the class change could break.
    await userEvent.click(button)
    expect(screen.getByTestId('inventory-proof-console')).toBeInTheDocument()
  })

  it('distinguishes a healthy empty result from a load that has not answered', async () => {
    // Discovery answers with no pods, and both config entries are dropped only
    // in demo mode — so here the table is non-empty and no EmptyState shows.
    mockAgentFetch({ agents: [] })
    renderPage()
    await waitFor(() => expect(screen.getAllByTestId(/^identity-row-/).length).toBeGreaterThan(0))
    expect(screen.queryByText('No workload identities found')).toBeNull()
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
