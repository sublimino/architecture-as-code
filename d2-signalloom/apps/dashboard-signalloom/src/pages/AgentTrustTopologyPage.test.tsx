import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import AgentTrustTopologyPage, { trustEdges, trustNodes } from './AgentTrustTopologyPage'

function renderPage(ui = <AgentTrustTopologyPage />, initialEntries = ['/agent-trust-topology']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      {ui}
    </MemoryRouter>,
  )
}

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

    renderPage()

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

    renderPage()

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

    renderPage()

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

    renderPage()

    await waitFor(() => expect(trustTopology).toHaveBeenCalled())
    expect(screen.queryByTestId('topology-degraded-banner')).not.toBeInTheDocument()
  })

  it('never represents hardcoded topology as runtime-observed', () => {
    expect([...trustNodes, ...trustEdges].every(item => item.evidence !== 'observed')).toBe(true)
    renderPage()
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
    const user = userEvent.setup(); renderPage()
    await user.click(screen.getByRole('button', { name: /^Evidence plane$/i }))
    expect(screen.getByRole('button', { name: /^Evidence plane$/i })).toHaveAttribute('aria-pressed', 'true')
    trustEdges.forEach(edge => expect(screen.getAllByRole('button', { name: new RegExp(edge.source) }).length).toBeGreaterThan(0))
    expect(screen.getAllByText(/Fixture-tested|Modeled/).length).toBeGreaterThan(0)
  })

  it('does not reintroduce unrelated tenant nodes or edges after filtering', async () => {
    const user = userEvent.setup(); renderPage()
    await user.selectOptions(screen.getByLabelText('Tenant'), 'acme')
    expect(screen.getByText('Acme tenant')).toBeInTheDocument()
    expect(screen.queryByText('Northstar tenant')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /cross-tenant network denial/i })).not.toBeInTheDocument()
  })

  it('retains cloud providers and their ancestors for external filtering', async () => {
    const user = userEvent.setup(); renderPage()
    await user.selectOptions(screen.getByLabelText('Location'), 'external')
    expect(screen.getByText('AWS Lambda')).toBeInTheDocument(); expect(screen.getByText('Google Cloud Run')).toBeInTheDocument(); expect(screen.getByText('Azure Container Apps')).toBeInTheDocument()
    expect(screen.getByText('Acme Payments')).toBeInTheDocument(); expect(screen.getByText('Signal Loom platform')).toBeInTheDocument()
  })

  it('distinguishes network blocks from application authorization rejections', async () => {
    const user = userEvent.setup(); renderPage()
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
    renderPage()

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
    renderPage()

    const banner = await screen.findByTestId('topology-degraded-banner')
    // The banner states the fault. Only the hint states the consequence — that
    // a denied arrow drawn from the model is not proof the denial is enforced.
    const hint = screen.getByTestId('topology-degraded-help')
    expect(banner).toContainElement(hint)

    await user.hover(hint)
    expect(await screen.findByRole('tooltip')).toHaveTextContent('Do not read them as proof')
  })

  it('selects node details through a native keyboard button', async () => {
    const user = userEvent.setup(); renderPage()
    const button = screen.getByRole('button', { name: /planner · in-cluster/i })
    button.focus(); await user.keyboard('{Enter}')
    expect(screen.getByRole('heading', { name: 'planner' })).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/signalloom\.demo\/platform\/signalloom/i)).toBeInTheDocument()
  })

  it('keeps stale and unknown semantics out of the green observed treatment', () => {
    renderPage()
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
    return renderPage()
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

describe('AgentTrustTopologyPage — URL deep-link parameter ingestion', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(true)
  })

  it('selects the matching agent node when ?actor= is provided in URL', async () => {
    renderPage(<AgentTrustTopologyPage />, ['/agent-trust-topology?actor=planner'])
    await waitFor(() => {
      expect(screen.getByRole('heading', { name: 'planner' })).toBeInTheDocument()
    })
  })
})

describe('AgentTrustTopologyPage — Inspector Agent Dossier Drilldown', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(true)
  })

  it('renders View Agent Dossier link when an agent node is selected', async () => {
    renderPage(<AgentTrustTopologyPage />, ['/agent-trust-topology?actor=planner'])
    const link = await screen.findByTestId('inspector-agent-dossier-link')
    expect(link).toBeInTheDocument()
    expect(link).toHaveAttribute('href', '/agents/planner?tab=overview')
    expect(link).toHaveTextContent(/View Agent Dossier/i)
  })

  it('renders interactive selector pills and SPIFFE link in inspector', async () => {
    renderPage(<AgentTrustTopologyPage />, ['/agent-trust-topology?actor=planner'])
    const spiffeLink = await screen.findByTestId('inspector-spiffe-link')
    expect(spiffeLink).toBeInTheDocument()
    expect(spiffeLink.getAttribute('href')).toContain('/agents?selector=spiffe%3A%2F%2Fsignalloom.demo')

    const selectorPill = await screen.findByTestId('inspector-selector-k8s:sa:agent-trust-planner')
    expect(selectorPill).toBeInTheDocument()
    expect(selectorPill.getAttribute('href')).toContain('/agents?selector=k8s%3Asa%3Aagent-trust-planner')
  })

  it('renders source and target agent dossier links when an edge between agents is inspected', async () => {
    const user = userEvent.setup()
    renderPage()

    // Default selected edge on identity plane is spire-planner (spire -> planner)
    const targetLinkDefault = await screen.findByTestId('inspector-target-agent-link')
    expect(targetLinkDefault).toHaveAttribute('href', '/agents/planner?tab=overview')

    // Switch to authorization plane to inspect planner-triage (planner -> triage)
    const authPlaneBtn = screen.getByRole('button', { name: /Authorization plane/i })
    await user.click(authPlaneBtn)

    const edgeBtn = await screen.findByRole('button', { name: /planner → triage/i })
    await user.click(edgeBtn)

    const sourceLink = await screen.findByTestId('inspector-source-agent-link')
    expect(sourceLink).toBeInTheDocument()
    expect(sourceLink).toHaveAttribute('href', '/agents/planner?tab=overview')

    const targetLink = await screen.findByTestId('inspector-target-agent-link')
    expect(targetLink).toBeInTheDocument()
    expect(targetLink).toHaveAttribute('href', '/agents/triage?tab=overview')
  })
})

describe('AgentTrustTopologyPage: Interactive Filters and Hidden Nodes Counter', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(true)
  })

  it('filters nodes by Namespace and shows hidden nodes count', async () => {
    const user = userEvent.setup()
    renderPage()

    const namespaceSelect = screen.getByLabelText('Namespace')
    expect(namespaceSelect).toBeInTheDocument()

    await user.selectOptions(namespaceSelect, 'agent-trust-acme-payments')

    expect(screen.getByText('planner')).toBeInTheDocument()
    expect(screen.getByText('triage')).toBeInTheDocument()
    // Nodes from other namespaces should be excluded
    expect(screen.queryByText('risk-reader')).not.toBeInTheDocument()
    expect(screen.queryByText('investigator')).not.toBeInTheDocument()

    // Hidden nodes counter badge should be visible
    const hiddenBadge = await screen.findByTestId('hidden-nodes-badge')
    expect(hiddenBadge).toBeInTheDocument()
    expect(hiddenBadge).toHaveTextContent(/Hidden Nodes/i)
  })

  it('filters nodes by Lifecycle State and resets via reset button', async () => {
    const user = userEvent.setup()
    renderPage()

    const lifecycleSelect = screen.getByLabelText('Lifecycle State')
    expect(lifecycleSelect).toBeInTheDocument()

    await user.selectOptions(lifecycleSelect, 'discovered')

    // Discovered agents (unverified without spiffe)
    expect(screen.getByText('AWS Lambda')).toBeInTheDocument()
    expect(screen.getByText('Google Cloud Run')).toBeInTheDocument()

    // Reset filters restores all nodes
    const resetBtn = screen.getByRole('button', { name: /Reset filters/i })
    await user.click(resetBtn)

    expect(screen.getByText('planner')).toBeInTheDocument()
    expect(screen.getByText('Signal Loom platform')).toBeInTheDocument()
  })
})

describe('AgentTrustTopologyPage: NodeDetailDrawer Interactions', () => {
  beforeEach(() => {
    isDemoMode.mockReturnValue(true)
  })

  it('opens NodeDetailDrawer on button click, displays tool chips and SPIFFE identity, and closes on Escape', async () => {
    const user = userEvent.setup()
    renderPage(<AgentTrustTopologyPage />, ['/agent-trust-topology?actor=planner'])

    const inspectDrawerBtn = await screen.findByTestId('open-node-drawer-btn')
    expect(inspectDrawerBtn).toBeInTheDocument()
    await user.click(inspectDrawerBtn)

    const drawer = await screen.findByTestId('node-detail-drawer')
    expect(drawer).toBeInTheDocument()
    expect(drawer).toHaveAttribute('role', 'dialog')
    expect(drawer).toHaveAttribute('aria-modal', 'true')

    // Verifies SPIFFE ID and tool permission chips inside the drawer
    expect(within(drawer).getByText(/spiffe:\/\/signalloom\.demo\/platform\/signalloom\/tenant\/acme\/project\/payments\/agent\/planner/i)).toBeInTheDocument()
    expect(within(drawer).getByTestId('drawer-tool-chip-repo:read')).toBeInTheDocument()
    expect(within(drawer).getByTestId('drawer-tool-chip-task:plan')).toBeInTheDocument()
    expect(within(drawer).getByTestId('drawer-agent-dossier-link')).toBeInTheDocument()
    expect(within(drawer).getByTestId('drawer-isolate-agent-btn')).toBeInTheDocument()

    // Pressing Escape closes drawer
    await user.keyboard('{Escape}')
    await waitFor(() => {
      expect(screen.queryByTestId('node-detail-drawer')).not.toBeInTheDocument()
    })
  })

  it('closes NodeDetailDrawer when close button is clicked', async () => {
    const user = userEvent.setup()
    renderPage(<AgentTrustTopologyPage />, ['/agent-trust-topology?actor=planner'])

    const inspectDrawerBtn = await screen.findByTestId('open-node-drawer-btn')
    await user.click(inspectDrawerBtn)

    const drawer = await screen.findByTestId('node-detail-drawer')
    expect(drawer).toBeInTheDocument()

    const closeBtn = screen.getByTestId('node-drawer-close-btn')
    await user.click(closeBtn)

    await waitFor(() => {
      expect(screen.queryByTestId('node-detail-drawer')).not.toBeInTheDocument()
    })
  })

  it('clicking StatCards updates the evidence filter on the diagram', async () => {
    const user = userEvent.setup()
    renderPage(<AgentTrustTopologyPage />)

    const observedCard = screen.getByTestId('stat-card-observed')
    const modeledCard = screen.getByTestId('stat-card-modeled')
    const fixtureCard = screen.getByTestId('stat-card-fixture')

    expect(observedCard).toHaveAttribute('aria-pressed', 'false')
    expect(modeledCard).toHaveAttribute('aria-pressed', 'false')
    expect(fixtureCard).toHaveAttribute('aria-pressed', 'false')

    // Click Runtime-observed card
    await user.click(observedCard)
    expect(observedCard).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByLabelText('Evidence')).toHaveValue('observed')

    // Click Modeled items card
    await user.click(modeledCard)
    expect(modeledCard).toHaveAttribute('aria-pressed', 'true')
    expect(observedCard).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByLabelText('Evidence')).toHaveValue('modeled')

    // Click Fixture-tested items card
    await user.click(fixtureCard)
    expect(fixtureCard).toHaveAttribute('aria-pressed', 'true')
    expect(modeledCard).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByLabelText('Evidence')).toHaveValue('fixture')

    // Clicking again toggles back to all
    await user.click(fixtureCard)
    expect(fixtureCard).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByLabelText('Evidence')).toHaveValue('all')
  })
})




