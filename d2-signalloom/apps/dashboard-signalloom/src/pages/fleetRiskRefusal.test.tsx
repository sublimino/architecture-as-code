/**
 * The Fleet risk panel's refusal path, and the gate that keeps the scripted
 * demo scenario off the live one.
 *
 * WHY A SEPARATE FILE
 * -------------------
 * These tests need the DEMO GATE MODULE mocked, which FleetDemoPage.test.tsx
 * cannot do: its mocks are hoisted `vi.mock` calls applied to a statically
 * imported page, and the gate's two values (`isProductionEnv`,
 * `showDemoToggle`) are read from module scope at import time. Changing them
 * per-test needs `vi.doMock` plus a dynamic `import()`, which means a fresh
 * module registry per test and therefore its own file.
 *
 * WHAT IS BEING PROVEN, AND WHY IT NEEDED PROVING
 * -----------------------------------------------
 * `pages/FleetDemoPage.tsx` rendered `BASELINE_RISK` / `ESCALATED_RISK` -- ale
 * 12400 / 847000, var95 58000 / 1200000 -- in BOTH modes, and never read the
 * API for these figures at all. It had never shown a real number in this
 * panel. Four tests in the sibling suite asserted £12,400 while their own
 * mocked /topology reported £847,000, and passed; that is what a page ignoring
 * its own API looks like from the test side.
 *
 * So the two properties below are the ones no existing test could have held:
 *
 *   1. With the API reporting no price, the panel REFUSES -- it says so, it
 *      quotes the producer's reason, and it draws no needle. A needle resting
 *      on "Low" is a reading, and reporting an unpriced fleet as a low-risk
 *      one is the single worst thing this gauge can do.
 *   2. The scripted scenario is reachable only through the demo gate, and the
 *      control that reaches it does not exist where demo content is forbidden.
 *      `isDemoMode` used to be imported into the page and NEVER CALLED -- the
 *      only reference was the import line, `noUnusedLocals` is false, and the
 *      figure sweep's rule 1 is satisfied by an import -- so the fixture was
 *      reachable in uat and prod by clicking a button.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import type { FleetTopology, RiskSummary } from '../api/fleetApi'
import { UNPRICED_NO_SERVER_REASON } from '../components/fleet/FleetRiskGauge'
import { MONEY_UNAVAILABLE } from '../money/format'

// ── Shared mocks ────────────────────────────────────────────────────────────

const mockFetchFleetTopology = vi.fn()

function installCommonMocks() {
  vi.doMock('../auth/oidc', () => ({
    useAuth0: () => ({
      getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
      user: { email: 'demo-user@signalloom.local', preferred_username: 'demo-user' },
    }),
  }))
  vi.doMock('../App', () => ({
    useAppContext: () => ({
      superadmin: true,
      setSuperadmin: vi.fn(),
      failingControls: 0,
      setFailingControls: vi.fn(),
      helpOpen: false,
      setHelpOpen: vi.fn(),
    }),
  }))
  vi.doMock('../api/fleetApi', () => ({
    fetchFleetTopology: (...args: unknown[]) => mockFetchFleetTopology(...args),
    deployFleet: vi.fn(),
    scanFleet: vi.fn(),
    stunFleetAgent: vi.fn(),
    recoverFleet: vi.fn(),
    resetFleet: vi.fn(),
  }))
}

/** The gate module, with the environment tier under the test's control. */
function installGate({ production, toggle }: { production: boolean; toggle: boolean }) {
  vi.doMock('../api/demoMode', () => ({
    isDemoMode: () => !production,
    isProductionEnv: production,
    showDemoToggle: toggle,
    setDemoMode: () => {},
    toggleDemoMode: () => false,
    subscribeDemoMode: () => () => {},
  }))
}

const AGENTS: FleetTopology['agents'] = [
  { id: 'agent-cardvault', name: 'Card Vault', type: 'data-vault', team: 'data', trustProfile: 'high', state: 'active' },
  { id: 'agent-monitor', name: 'Monitor', type: 'observability', team: 'sre', trustProfile: 'high', state: 'active' },
]

function topologyWith(aggregateRisk: RiskSummary): FleetTopology {
  return { agents: AGENTS, edges: [], aggregateRisk, cascadeHistory: [] }
}

async function renderPage() {
  const { default: FleetDemoPage } = await import('./FleetDemoPage')
  return render(
    <MemoryRouter>
      <FleetDemoPage />
    </MemoryRouter>,
  )
}

beforeEach(() => {
  vi.resetModules()
  mockFetchFleetTopology.mockReset()
  installCommonMocks()
})

afterEach(() => {
  vi.resetModules()
  vi.restoreAllMocks()
})

// ── 1. The refusal ──────────────────────────────────────────────────────────

describe('the fleet risk panel refuses rather than inventing a figure', () => {
  beforeEach(() => installGate({ production: false, toggle: true }))

  it('says "not priced" and quotes the producer\'s own reason when the API omits ale', async () => {
    // Exactly the shape policy-engine now emits: the money fields are absent
    // from the payload, and a `pricing` block with every key present says why.
    // Modelled as absent KEYS rather than explicit undefined, because
    // omitempty omits the key.
    //
    // `available: true` is set DELIBERATELY against a refusal status -- a
    // combination the server cannot produce, since it derives `available` from
    // the status through a method.
    //
    // I expected this to be the test that catches a client reading `available`
    // instead of `status`. It is NOT, and I checked rather than assuming:
    // mutating `isPriced` to `return risk.pricing.available` leaves this test
    // GREEN. The page passes only `status` down to the gauge, and the gauge
    // re-checks it, so a page-level mutation is masked by the gauge's own
    // check. The mutation is caught by "shows the figure when the status says
    // PRICED" -- the INVERSE fixture, PRICED with `available: false` -- and by
    // that test alone. Defence in depth means the obvious probe is the wrong
    // one. The fixture stays as a statement of the contract.
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({
        trend: 'stable',
        pricing: {
          available: true,
          status: 'NO_DECLARED_LOSS_FREQUENCY',
          reason:
            'three pod-spec checks map to no control in risk/packs/agent-policy, so no declared loss frequency exists',
          unpricedFields: ['ale', 'var95', 'tvar', 'carriedGbp'],
          unmappedChecks: ['securityContext', 'dropCapabilities', 'readOnlyRootFilesystem'],
        },
      }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-band')[0]).toHaveTextContent('Not priced')
    })
    expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(MONEY_UNAVAILABLE)
    expect(screen.getAllByTestId('fleet-risk-carried')[0]).toHaveTextContent(MONEY_UNAVAILABLE)
    // The server's sentence, verbatim. Not a dashboard paraphrase of it.
    expect(screen.getAllByTestId('fleet-risk-unpriced-reason')[0]).toHaveTextContent(
      /no declared loss frequency exists/,
    )
  })

  /** The shared refusal object, every key present, as the three routes send it. */
  function pricing(status: string, reason: string) {
    // Inverted on purpose: the server derives `available` from `status`, so an
    // inverted pair is unproducible and any client that reads `available`
    // instead of `status` gets the wrong answer on every one of these.
    return { available: status !== 'PRICED', status, reason, unpricedFields: [], unmappedChecks: [] }
  }

  it('keeps the two refusal causes apart, because they need different people to act', async () => {
    // NO_DECLARED_LOSS_FREQUENCY is fixed in the policy pack.
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ trend: 'stable', pricing: pricing('NO_DECLARED_LOSS_FREQUENCY', 'no mapping') }),
    )
    const first = await renderPage()
    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-unpriced-action')[0]).toHaveTextContent(
        /risk pack|risk\/packs\/agent-policy/,
      )
    })
    const mapping = screen.getAllByTestId('fleet-risk-unpriced-action')[0].textContent ?? ''
    first.unmount()

    // NO_RISK_DATA_PLANE is fixed by giving the route something to aggregate.
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ trend: 'stable', pricing: pricing('NO_RISK_DATA_PLANE', 'no money column') }),
    )
    await renderPage()
    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-unpriced-action')[0]).toHaveTextContent(
        /risk data plane|priced scan/,
      )
    })
    const plane = screen.getAllByTestId('fleet-risk-unpriced-action')[0].textContent ?? ''

    // The point of the assertion: one label over two facts would read as
    // authoritative precisely because it is uniform.
    expect(plane).not.toBe(mapping)
  })

  it('treats a status it has never heard of as unpriced, and offers no guessed action', async () => {
    // Version skew: the server is newer than this build. Failing closed is the
    // only safe default -- the alternative is coercing an unknown status to
    // PRICED and rendering a figure that is not there.
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({
        ale: 999_999,
        var95: 999_999,
        trend: 'stable',
        pricing: pricing('SOME_FUTURE_STATUS', 'a cause this build predates'),
      }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-band')[0]).toHaveTextContent('Not priced')
    })
    // Note the fixture DOES carry an ale. The status overrides it, which is the
    // contract: status is the thing branched on, not field presence.
    expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(MONEY_UNAVAILABLE)
    expect(screen.queryByTestId('fleet-risk-unpriced-action')).not.toBeInTheDocument()
  })

  it('shows the figure when the status says PRICED', async () => {
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({
        ale: 420_000,
        var95: 900_000,
        trend: 'up',
        pricing: pricing('PRICED', 'computed from declared inputs'),
      }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(/420[,.]?000/)
    })
    expect(screen.queryByTestId('fleet-risk-unpriced-reason')).not.toBeInTheDocument()
  })

  it('draws no needle when there is no figure, so an unpriced fleet cannot read as low risk', async () => {
    mockFetchFleetTopology.mockResolvedValue(topologyWith({ trend: 'stable' }))
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-band')[0]).toHaveTextContent('Not priced')
    })
    expect(screen.queryByTestId('fleet-gauge-needle')).not.toBeInTheDocument()
  })

  it('names the endpoint that owes the figure when the response states no reason', async () => {
    mockFetchFleetTopology.mockResolvedValue(topologyWith({ trend: 'stable' }))
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-unpriced-reason')[0]).toHaveTextContent(
        UNPRICED_NO_SERVER_REASON,
      )
    })
  })

  it('treats a null ale as absent, not as a zero it can format', async () => {
    // fe-signalloom's /compliance/policy/* routes report absence as JSON null
    // rather than by omitting the key. Both arrive here as "no figure".
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ ale: null, var95: null, carriedGbp: null, trend: 'stable' }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(MONEY_UNAVAILABLE)
    })
    // The specific regression: a zero would render as "£0" and read as
    // "this fleet costs you nothing in a typical year".
    expect(screen.getAllByTestId('fleet-risk-ale')[0]).not.toHaveTextContent(/£\s*0\b/)
  })

  it('reports a MEASURED zero as a figure, because zero is an answer', async () => {
    // The counterpart that keeps the rule honest: `0` is priced. A gauge that
    // refused on zero would be as wrong as one that invented it.
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ ale: 0, var95: 0, carriedGbp: 0, trend: 'stable' }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-band')[0]).toHaveTextContent('Low Risk')
    })
    expect(screen.queryByTestId('fleet-risk-unpriced-reason')).not.toBeInTheDocument()
    expect(screen.getByTestId('fleet-gauge-needle')).toBeInTheDocument()
  })

  it('renders the API figure with no provenance badge, because it IS the measurement', async () => {
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ ale: 420_000, var95: 900_000, trend: 'up', previousAle: 300_000 }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(/420[,.]?000/)
    })
    expect(screen.queryByTestId('fleet-risk-source')).not.toBeInTheDocument()
    expect(screen.queryByTestId('fleet-risk-unpriced-reason')).not.toBeInTheDocument()
  })
})

// ── 2. The gate ─────────────────────────────────────────────────────────────

describe('the scripted demo scenario is reachable only through the demo gate', () => {
  it('badges a demo figure as scripted, derived from the branch that produced it', async () => {
    installGate({ production: false, toggle: true })
    mockFetchFleetTopology.mockResolvedValue(topologyWith({ trend: 'stable' }))
    const user = userEvent.setup()
    await renderPage()

    await waitFor(() => expect(screen.getByTestId('fleet-source-toggle')).toBeInTheDocument())
    await user.click(screen.getByTestId('fleet-source-toggle'))

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-source')[0]).toHaveTextContent(/Demo scenario/i)
    })
    // And the scenario's own baseline, not the API's absence.
    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(/12[,.]?400/)
    })
  })

  it('offers no fixture toggle at all in a production tier', async () => {
    installGate({ production: true, toggle: false })
    mockFetchFleetTopology.mockResolvedValue(topologyWith({ trend: 'stable' }))
    await renderPage()

    await waitFor(() => expect(screen.getByTestId('fleet-demo-page')).toBeInTheDocument())
    // The control that serves a fixture must not exist in a tier that may not
    // show one. Previously it was rendered unconditionally and one click put
    // ale 847000 / var95 1200000 on a production screen.
    expect(screen.queryByTestId('fleet-source-toggle')).not.toBeInTheDocument()
    expect(screen.queryByTestId('fleet-risk-source')).not.toBeInTheDocument()
  })

  it('serves the live figure in a production tier and none of the scenario', async () => {
    // HONEST SCOPE. Mutating `demoFixturePermitted` to `return true` does NOT
    // fail this test, which I checked rather than assumed. The reason is that
    // `sourceMode` defaults to 'live' and, with the toggle gone, nothing in
    // the component can set it to 'demo' -- so the gated branches are
    // unreachable from outside and this asserts only that the live path is
    // what renders. The gate itself is pinned by the test above, which DOES
    // fail under that mutation.
    //
    // Keeping it anyway: it is the end-to-end statement that a production
    // render shows the API's figure and none of 12,400 / 847,000 / 58,000 /
    // 1,200,000, which is the property a reader actually cares about.
    installGate({ production: true, toggle: false })
    mockFetchFleetTopology.mockResolvedValue(
      topologyWith({ ale: 420_000, var95: 900_000, trend: 'up' }),
    )
    await renderPage()

    await waitFor(() => {
      expect(screen.getAllByTestId('fleet-risk-ale')[0]).toHaveTextContent(/420[,.]?000/)
    })
    expect(mockFetchFleetTopology).toHaveBeenCalled()
    // The scenario's figures are nowhere on screen.
    expect(screen.queryByText(/12[,.]?400/)).not.toBeInTheDocument()
  })
})
