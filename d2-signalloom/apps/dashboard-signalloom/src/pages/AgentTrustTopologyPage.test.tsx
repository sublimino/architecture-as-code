import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import AgentTrustTopologyPage, { trustEdges, trustNodes } from './AgentTrustTopologyPage'

const isDemoMode = vi.fn(() => true)
const getAccessTokenSilently = vi.fn(async () => 'live-token')
const trustTopology = vi.fn()

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => isDemoMode(),
  subscribeDemoMode: () => () => {},
}))
vi.mock('../auth/oidc', () => ({ useAuth0: () => ({ getAccessTokenSilently }) }))
vi.mock('../api/client', () => ({ api: { trustTopology: (token: string) => trustTopology(token) } }))

describe('AgentTrustTopologyPage', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(true)
    trustTopology.mockReset()
  })

  // Shared builders. The live schema is the one the API actually returns --
  // generated_at/version/collectors/modeled_gaps -- not the {nodes, edges}
  // shape an earlier draft assumed.
  const evidence = (state = 'observed', assurance = 'runtime-observed') => ({
    evidence_state: state, evidence_source: 'kubernetes collector',
    observed_at: '2026-08-11T16:00:00Z', freshness: 'fresh', assurance, reason: 'collected',
  })
  const snapshot = (collectors: Record<string, unknown>, state = 'observed', assurance = 'runtime-observed') => ({
    generated_at: '2026-08-11T16:00:00Z', version: 'v1', collectors,
    nodes: [{ id: 'platform', kind: 'platform', label: 'Signal Loom platform', tenant: 'shared', ...evidence(state, assurance) }],
    edges: [], modeled_gaps: [],
  })
  const OK = { kubernetes: { status: 'ok', observed_at: '2026-08-11T16:00:00Z', reason: 'namespaces collected' } }

  it('uses the authenticated topology endpoint in live mode', async () => {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockResolvedValue(snapshot(OK))

    render(<AgentTrustTopologyPage />)

    await waitFor(() => expect(trustTopology).toHaveBeenCalledWith('live-token'))
    // The NODE must render, not merely the StatCard label of the same name --
    // asserting on "Runtime-observed" alone passes even when nothing loaded,
    // because that string is a permanent card heading.
    // Scoped to the node's own label element: that bare string now also appears
    // in a help hint, so a plain getByText matches several elements. The comment
    // above is the point -- this must prove the NODE rendered.
    await waitFor(() =>
      expect(
        Array.from(document.querySelectorAll('.trust-node__label')).map((n) => n.textContent),
      ).toContain('Signal Loom platform'),
    )
    expect(screen.queryByText(/Demonstration data/i)).not.toBeInTheDocument()
    expect(screen.queryByTestId('topology-degraded-banner')).not.toBeInTheDocument()
  })

  // ── The degraded badge ────────────────────────────────────────────────────
  //
  // The API answers even when its collector is unreachable, returning a derived
  // topology with everything marked modeled. A derived diagram and an observed
  // one look identical at a glance, so the ONLY thing standing between a viewer
  // and a false conclusion is this banner. These assert it says what it must.

  it('says plainly that a derived topology is not live', async () => {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockResolvedValue(snapshot(
      { kubernetes: { status: 'unavailable', observed_at: '', reason: 'RBAC denied listing pods' } },
      'modeled', 'modeled',
    ))

    render(<AgentTrustTopologyPage />)

    const banner = await screen.findByTestId('topology-degraded-banner')
    // An alert, not a status: this is a correctness warning about everything
    // below it, and it should interrupt rather than wait its turn.
    expect(banner).toHaveAttribute('role', 'alert')
    expect(banner).toHaveTextContent(/not live/i)
    expect(banner).toHaveTextContent(/derived, not observed/i)
    // The collector's OWN reason, verbatim -- never a guess made in the UI.
    expect(banner).toHaveTextContent('RBAC denied listing pods')
    expect(banner).toHaveTextContent('kubernetes')
  })

  it('distinguishes partial evidence from no evidence at all', async () => {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockResolvedValue(snapshot({
      kubernetes: { status: 'ok', observed_at: '2026-08-11T16:00:00Z', reason: 'collected' },
      spire: { status: 'partial', observed_at: '2026-08-11T16:00:00Z', reason: 'registration API timed out' },
    }))

    render(<AgentTrustTopologyPage />)

    const banner = await screen.findByTestId('topology-degraded-banner')
    expect(banner).toHaveTextContent(/partial evidence/i)
    // Names which one failed and how many, so the reader knows the blast radius.
    expect(banner).toHaveTextContent('1 of 2 collectors')
    expect(banner).toHaveTextContent('registration API timed out')
    // A partial estate is not the same claim as a dead one.
    expect(banner).not.toHaveTextContent(/derived, not observed/i)
  })

  it('shows no banner when every collector reported', async () => {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockResolvedValue(snapshot(OK))

    render(<AgentTrustTopologyPage />)

    await waitFor(() => expect(trustTopology).toHaveBeenCalled())
    expect(screen.queryByTestId('topology-degraded-banner')).not.toBeInTheDocument()
  })

  it('never represents hardcoded topology as runtime-observed', () => {
    expect([...trustNodes, ...trustEdges].every(item => item.evidence !== 'observed')).toBe(true)
    render(<AgentTrustTopologyPage />)
    expect(screen.getByText(/Demonstration data/i)).toBeInTheDocument()
    expect(screen.getAllByText('Runtime-observed').length).toBeGreaterThan(0)
  })

  it('uses canonical SPIFFE, agent-trust service accounts, and five-minute OpenBao TTLs', () => {
    const agents = trustNodes.filter(node => node.kind === 'agent' && node.location === 'in-cluster')
    expect(agents.every(node => /^spiffe:\/\/signalloom\.demo\/platform\/signalloom\/tenant\/[^/]+\/project\/[^/]+\/agent\/[^/]+$/.test(node.spiffeId ?? ''))).toBe(true)
    expect(agents.every(node => node.namespace?.startsWith('agent-trust-') && node.serviceAccount?.startsWith('agent-trust-') && node.ttl === '5m' && node.audience === 'openbao-supercredential')).toBe(true)
  })

  it('models every requested cloud provider with lower-assurance external controls', () => {
    for (const label of ['AWS Lambda', 'Google Cloud Run', 'Azure Container Apps']) {
      const node = trustNodes.find(item => item.label === label)
      expect(node).toMatchObject({ location: 'external', evidence: 'modeled', assurance: 'lower' })
      expect(node?.providerAssertion && node?.keyCustody && node?.rotationReload && node?.trustBundle && node?.deEnrollment && node?.productionGap).toBeTruthy()
    }
  })

  it('offers an evidence plane and visible provenance for every selectable edge', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.click(screen.getByRole('button', { name: /^Evidence plane$/i }))
    expect(screen.getByRole('button', { name: /^Evidence plane$/i })).toHaveAttribute('aria-pressed', 'true')
    trustEdges.forEach(edge => expect(screen.getAllByRole('button', { name: new RegExp(edge.source) }).length).toBeGreaterThan(0))
    expect(screen.getAllByText(/Fixture-tested|Modeled/).length).toBeGreaterThan(0)
  })

  it('does not reintroduce unrelated tenant nodes or edges after filtering', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.selectOptions(screen.getByLabelText('Tenant'), 'acme')
    expect(screen.getByText('Acme tenant')).toBeInTheDocument()
    expect(screen.queryByText('Northstar tenant')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /cross-tenant network denial/i })).not.toBeInTheDocument()
  })

  it('retains cloud providers and their ancestors for external filtering', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.selectOptions(screen.getByLabelText('Location'), 'external')
    expect(screen.getByText('AWS Lambda')).toBeInTheDocument(); expect(screen.getByText('Google Cloud Run')).toBeInTheDocument(); expect(screen.getByText('Azure Container Apps')).toBeInTheDocument()
    expect(screen.getByText('Acme Payments')).toBeInTheDocument(); expect(screen.getByText('Signal Loom platform')).toBeInTheDocument()
  })

  it('distinguishes network blocks from application authorization rejections', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.click(screen.getByRole('button', { name: /^Authorization plane$/i })); await user.click(screen.getByRole('button', { name: /cross-project application denial/i }))
    expect(screen.getByText('Application authorization rejection')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /^Network plane$/i })); await user.click(screen.getByRole('button', { name: /cross-tenant network denial/i }))
    expect(screen.getByText('Network block')).toBeInTheDocument()
  })

  // ── The evidence vocabulary ───────────────────────────────────────────────
  //
  // "Observed", "modeled" and "fixture" appear in the legend, the stat cards,
  // the Evidence filter and the inspector, and the page never defines any of
  // them. A viewer who reads "modeled" as "we checked it and it is fine" draws
  // the exact false conclusion this page exists to prevent, so the definition
  // is not decoration.

  it('defines all three evidence words behind one keyboard-reachable "?"', async () => {
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)

    const hint = screen.getByTestId('topology-evidence-help')
    hint.focus()
    expect(document.activeElement).toBe(hint)
    expect(hint).toHaveAccessibleName('What runtime-observed, fixture-tested and modeled mean')

    await user.hover(hint)
    const tooltip = await screen.findByRole('tooltip')
    expect(tooltip.textContent).toMatch(/Runtime-observed/i)
    expect(tooltip.textContent).toMatch(/Fixture-tested/i)
    expect(tooltip.textContent).toMatch(/Modeled/i)
    // The whole distinction: only one of the three is evidence.
    expect(tooltip.textContent).toMatch(/nobody checked/i)
  })

  it('tells a viewer what the degraded banner forbids them from concluding', async () => {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockResolvedValue(snapshot(
      { kubernetes: { status: 'unavailable', observed_at: '', reason: 'RBAC denied listing pods' } },
      'modeled', 'modeled',
    ))
    const user = userEvent.setup()
    render(<AgentTrustTopologyPage />)

    const banner = await screen.findByTestId('topology-degraded-banner')
    // The banner states the fault. Only the hint states the consequence — that
    // a denied arrow drawn from the model is not proof the denial is enforced.
    const hint = screen.getByTestId('topology-degraded-help')
    expect(banner).toContainElement(hint)

    await user.hover(hint)
    expect(await screen.findByRole('tooltip')).toHaveTextContent('Do not read them as proof')
  })

  it('selects node details through a native keyboard button', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    const button = screen.getByRole('button', { name: /planner · in-cluster/i })
    button.focus(); await user.keyboard('{Enter}')
    expect(screen.getByRole('heading', { name: 'planner' })).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/signalloom\.demo\/platform\/signalloom/i)).toBeInTheDocument()
  })

  it('keeps stale and unknown semantics out of the green observed treatment', () => {
    render(<AgentTrustTopologyPage />)
    // Was pinned to var(--amber). The legend now greys the evidence states that
    // have no instances on this page and marks them "· none" — Runtime-observed
    // and Stale are both empty by design, and rendering "Runtime-observed" in
    // confident green as the first and highest-contrast item in the strip, with
    // a 0 in the StatCard directly above it, had the page arguing against its
    // own thesis.
    //
    // The property this test is named for is unchanged and still asserted: the
    // stale entry must never take the colour reserved for runtime-observed.
    const stale = screen.getByText(/Stale \/ dotted warning/i)
    expect(stale).not.toHaveStyle({ color: 'var(--teal)' })
    expect(stale).toHaveStyle({ color: 'var(--muted)' })
    expect(screen.getAllByText(/unknown/).length).toBeGreaterThan(0)
  })
})

// This page had the last bespoke wait in the app — a bare
// <div role="status">Loading authenticated trust topology…</div> that bypassed
// LoadingState entirely, so it showed no elapsed time and did not match any
// other wait on screen.
describe('the topology wait uses the shared pattern', () => {
  // The wait only exists in LIVE mode (demo mode renders fixtures immediately),
  // and only while the request is in flight — so hold the promise open.
  function renderLoading() {
    isDemoMode.mockReturnValue(false)
    trustTopology.mockReturnValue(new Promise(() => {}))
    return render(<AgentTrustTopologyPage />)
  }

  it('renders the pixel loader while loading, with a specific label', async () => {
    renderLoading()
    const loader = await screen.findByTestId('trust-topology-loading')
    expect(loader).toHaveTextContent(/Loading authenticated trust topology/i)
  })

  it('owns exactly one live region — it must not be wrapped in a second', async () => {
    // The old markup was itself role="status"; nesting the loader inside that
    // would make a screen reader read the same sentence twice.
    renderLoading()
    const loader = await screen.findByTestId('trust-topology-loading')
    expect(loader).toHaveAttribute('role', 'status')
    expect(loader.querySelectorAll('[aria-live]')).toHaveLength(0)
  })
})
