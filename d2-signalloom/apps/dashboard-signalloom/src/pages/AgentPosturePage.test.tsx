import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { fakeWeaveData } from '../api/fakeWeaveData'
import { clearSignalSummaryCache } from '../hooks/useSignalSummary'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock the API client
vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      summary: vi.fn().mockResolvedValue({
        totalChecks: 20,
        passed: 15,
        failed: 5,
        currency: 'GBP',
        totalAle: { amount: 195500, currency: 'GBP' },
        totalVar95: { amount: 858000, currency: 'GBP' },
        totalTvar: { amount: 1332000, currency: 'GBP' },
        totalCarried: { amount: 98700, currency: 'GBP' },
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [
          { id: 'eu-ai-act', name: 'EU AI Act', versions: ['v1.0', 'v2.0'], totalControls: 10, passedControls: 7, failedControls: 3, totalExposure: { amount: 53200, currency: 'GBP' } },
        ],
      }),
      scan: vi.fn().mockResolvedValue({
        checks: [
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-1', check: 'Model card published', passed: true, policyVersion: 'v2.1', ale: { amount: 8200, currency: 'GBP' }, var95: { amount: 34000, currency: 'GBP' }, tvar: { amount: 52000, currency: 'GBP' }, carried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-2', check: 'Decision explanation logged', passed: false, policyVersion: 'v2.0', ale: { amount: 12400, currency: 'GBP' }, var95: { amount: 58000, currency: 'GBP' }, tvar: { amount: 89000, currency: 'GBP' }, carried: { amount: 12400, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
          { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-1', check: 'Access policy defined', passed: true, policyVersion: 'v2.1', ale: { amount: 9800, currency: 'GBP' }, var95: { amount: 42000, currency: 'GBP' }, tvar: { amount: 65000, currency: 'GBP' }, carried: { amount: 0, currency: 'GBP' }, scanTimestamp: '2026-07-27T12:00:00Z', calibrationSource: 'industry-indicative' },
        ],
        summary: {
          totalChecks: 3,
          passed: 2,
          failed: 1,
          currency: 'GBP',
          totalAle: { amount: 30400, currency: 'GBP' },
          totalVar95: { amount: 134000, currency: 'GBP' },
          totalTvar: { amount: 206000, currency: 'GBP' },
          totalCarried: { amount: 12400, currency: 'GBP' },
          scanTimestamp: '2026-07-27T12:00:00Z',
          frameworks: [],
        },
      }),
    },
  },
}))

const mockWeaveApi = vi.hoisted(() => ({
  getObservations: vi.fn(),
  getActors: vi.fn(),
  getCoverage: vi.fn(),
  getActor: vi.fn(),
  promoteActor: vi.fn(),
  runCorrelation: vi.fn(),
}))

vi.mock('../api/weaveApi', () => ({
  weaveApi: mockWeaveApi,
}))

import AgentPosturePage from './AgentPosturePage'
import { checksForVersion, buildPostureSummary } from '../api/fakeComplianceData'
import type { ComplianceCheck } from '../types/compliance'

function renderPage() {
  return render(
    <MemoryRouter>
      <AgentPosturePage />
    </MemoryRouter>,
  )
}

/** Point the scan mock at an arbitrary set of checks. */
async function scanReturns(checks: ComplianceCheck[]) {
  const { api } = await import('../api/client')
  vi.mocked(api.compliancePolicy.scan).mockResolvedValue({
    checks,
    summary: buildPostureSummary(checks),
  })
}

describe('AgentPosturePage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
  })

  it('renders the Agent Posture heading', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Agent Posture' })).toBeInTheDocument()
  })

  it('renders the agent namespace', async () => {
    renderPage()
    expect(await screen.findByText(/olly-sentinel/)).toBeInTheDocument()
  })

  it('renders check pass/fail summary after loading', async () => {
    renderPage()
    expect(await screen.findByText('Checks Passed')).toBeInTheDocument()
    expect(await screen.findByText('2/3')).toBeInTheDocument()
  })

  it('renders the fresh scan response instead of a pre-scan summary', async () => {
    const { api } = await import('../api/client')
    renderPage()

    expect(await screen.findByText('2/3')).toBeInTheDocument()
    expect(api.compliancePolicy.scan).toHaveBeenCalledWith('test-token', {
      namespace: 'default', policyVersion: 'v2.0', frameworks: [],
    })
    expect(api.compliancePolicy.summary).not.toHaveBeenCalled()
  })

  it('renders control sets as expandable sections', async () => {
    renderPage()
    expect(await screen.findByText(/Transparency/)).toBeInTheDocument()
    expect(await screen.findByText(/Access Control/)).toBeInTheDocument()
  })

  it('renders framework and status filter dropdowns', async () => {
    renderPage()
    await screen.findByText('Checks Passed')
    const selects = screen.getAllByRole('combobox')
    expect(selects.length).toBeGreaterThanOrEqual(2)
  })

  it('renders total exposure stat card', async () => {
    renderPage()
    expect(await screen.findByText('Total Exposure')).toBeInTheDocument()
  })
})

// ─── Framework coverage, rendered from the real fixture ─────────────────────
//
// The tests above run against a three-row hand-written mock, which cannot
// notice a framework going missing. These render the actual demo payload.

describe('AgentPosturePage — framework coverage', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
    await scanReturns(checksForVersion('v2.0'))
  })

  it.each([
    'EU AI Act',
    'NIST 800-53',
    'DORA',
    'NIS2',
    'Cyber Resilience Act',
    'FINOS AI Governance Framework',
  ])('offers %s in the framework filter', async (framework) => {
    renderPage()
    await screen.findByText('Checks Passed')
    expect(screen.getByRole('option', { name: framework })).toBeInTheDocument()
  })

  it.each([
    ['ICT Risk Management', 'DORA'],
    ['ICT Third-Party Risk', 'DORA'],
    ['Supply Chain Security', 'NIS2'],
    ['Vulnerability Handling', 'Cyber Resilience Act'],
    ['AI Security Risks', 'FINOS AI Governance Framework'],
  ])('renders the %s control set and attributes it to %s', async (controlSet, framework) => {
    renderPage()
    await screen.findByText('Checks Passed')

    const heading = await screen.findByRole('heading', { level: 2, name: controlSet })
    expect(heading).toBeInTheDocument()
    // The framework lives in the section hint — a bare "Access Control" or
    // "Supply Chain Security" heading is not answerable across six frameworks.
    expect(heading.parentElement?.textContent).toContain(framework)
  })

  it.each([
    'Art. 19',
    'Art. 21(2)(j)',
    'Annex I Pt II(1)',
    'AIR-SEC-024',
  ])('renders the real control id %s', async (control) => {
    renderPage()
    await screen.findByText('Checks Passed')
    expect(await screen.findByText(new RegExp(control.replace(/[.()[\]]/g, '\\$&')))).toBeInTheDocument()
  })

  it('keeps the FAIR ordering invariant on every row it is handed', async () => {
    const checks = checksForVersion('v2.0')
    expect(checks.length).toBeGreaterThanOrEqual(60)
    for (const c of checks) {
      expect(c.ale.amount).toBeLessThan(c.var95.amount)
      expect(c.var95.amount).toBeLessThan(c.tvar.amount)
      expect(c.carried.amount).toBe(c.passed ? 0 : c.ale.amount)
    }
  })

  it('totals exposure as the sum of the carried amounts, not a formatted string', async () => {
    const checks = checksForVersion('v2.0')
    const expected = checks.reduce((sum, c) => sum + c.carried.amount, 0)
    // Asserted as a number. jsdom reports en-US, so a GBP total and a USD total
    // can render to the same glyphs and a string assertion would not care.
    expect(buildPostureSummary(checks).totalCarried.amount).toBe(expected)
    expect(expected).toBeGreaterThan(0)

    renderPage()
    expect(await screen.findByText('Total Exposure')).toBeInTheDocument()
  })

  it('keeps two frameworks that share a control set name in separate sections', async () => {
    // Regression: sections used to be keyed on the control set name alone, so
    // two regulations that both call something "Supply Chain Security" merged
    // into one section and every row under it was attributed to whichever
    // framework happened to come first.
    const base = checksForVersion('v2.0')[0]
    await scanReturns([
      { ...base, framework: 'Framework A', controlSet: 'Shared Name', control: 'A-1' },
      { ...base, framework: 'Framework B', controlSet: 'Shared Name', control: 'B-1' },
    ])
    renderPage()
    await screen.findByText('Checks Passed')

    const headings = await screen.findAllByRole('heading', { level: 2, name: 'Shared Name' })
    expect(headings).toHaveLength(2)
    const hints = headings.map((h) => h.parentElement?.textContent ?? '')
    expect(hints.some((t) => t.includes('Framework A'))).toBe(true)
    expect(hints.some((t) => t.includes('Framework B'))).toBe(true)
  })
})

describe('AgentPosturePage — Signal Evidence Section', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
  })

  it('renders the Signal Evidence section when signal data is available', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByTestId('signal-evidence-section')).toBeInTheDocument()
  })

  it('renders layer coverage indicators with tooltips', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')
    expect(screen.getByText('Layer Coverage')).toBeInTheDocument()

    // Check that layer labels are rendered
    expect(screen.getByText('Network/Egress')).toBeInTheDocument()
    expect(screen.getByText('Identity/Auth')).toBeInTheDocument()
    expect(screen.getByText('Application/SaaS')).toBeInTheDocument()
    expect(screen.getByText('Endpoint/Host')).toBeInTheDocument()
    expect(screen.getByText('Behavioural')).toBeInTheDocument()
  })

  it('shows layer tooltips with correct descriptions', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')

    const networkLayer = screen.getByText('Network/Egress').closest('[title]')
    expect(networkLayer).toHaveAttribute('title', expect.stringContaining('Outbound traffic analysis'))

    const identityLayer = screen.getByText('Identity/Auth').closest('[title]')
    expect(identityLayer).toHaveAttribute('title', expect.stringContaining('Identity and access audit'))
  })

  it('shows the View Weave button', async () => {
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    renderPage()

    await screen.findByText('Signal Evidence')
    const btn = screen.getByRole('button', { name: /view weave/i })
    expect(btn).toBeInTheDocument()
  })

  it('shows graceful empty state when no observations exist', async () => {
    mockWeaveApi.getObservations.mockResolvedValue([])
    mockWeaveApi.getActors.mockResolvedValue([])
    renderPage()

    await screen.findByText('Agent Posture')
    // The section renders but says no observations yet
    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByText('No signal observations recorded yet.')).toBeInTheDocument()
  })

  it('shows graceful message when signal API errors', async () => {
    mockWeaveApi.getObservations.mockRejectedValue(new Error('Service down'))
    mockWeaveApi.getActors.mockRejectedValue(new Error('Service down'))
    renderPage()

    await screen.findByText('Agent Posture')
    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByText(/signal-ingest may be offline/)).toBeInTheDocument()
  })
})

// ─── Signal evidence: what the section actually claims ──────────────────────

describe('AgentPosturePage — Signal Evidence claims match the data', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearSignalSummaryCache()
    mockWeaveApi.getObservations.mockResolvedValue(fakeWeaveData.observations)
    mockWeaveApi.getActors.mockResolvedValue(fakeWeaveData.actors)
    mockWeaveApi.getCoverage.mockResolvedValue(fakeWeaveData.coverage)
  })

  it('breaks actors down by status instead of calling them all provisional', async () => {
    // The fixture holds one provisional, one actionable and one already
    // promoted into the registry. The section used to render the total with the
    // word "provisional" welded on, which understated two of the three and
    // hid the promoted one — the row a reviewer would ask about first.
    renderPage()
    await screen.findByText('Signal Evidence')

    const statuses = fakeWeaveData.actors.reduce<Record<string, number>>((acc, a) => {
      acc[a.status] = (acc[a.status] ?? 0) + 1
      return acc
    }, {})
    expect(Object.keys(statuses).length).toBeGreaterThan(1) // else this asserts nothing

    const text = screen.getByTestId('posture-actor-breakdown').textContent ?? ''
    expect(text).toContain(`${fakeWeaveData.actors.length} actors under correlation`)
    for (const [status, n] of Object.entries(statuses)) {
      expect(text).toContain(`${n} ${status}`)
    }
    expect(text).not.toMatch(/\d+ provisional actors? under correlation/)
  })

  it('shows the fidelity distribution, not just the maximum tier', async () => {
    renderPage()
    await screen.findByText('Signal Evidence')

    const byFidelity = fakeWeaveData.observations.reduce<Record<string, number>>((acc, o) => {
      acc[o.fidelity] = (acc[o.fidelity] ?? 0) + 1
      return acc
    }, {})
    // A single definitive observation among many circumstantial ones badges the
    // same as an all-definitive set; the spread is the thing being priced.
    expect(Object.keys(byFidelity).length).toBeGreaterThan(1)

    const text = screen.getByTestId('posture-fidelity-distribution').textContent ?? ''
    expect(text).toContain('Definitive')
    expect(text).toContain('Circumstantial')
    for (const [tier, n] of Object.entries(byFidelity)) {
      const label = tier.charAt(0).toUpperCase() + tier.slice(1)
      expect(text).toContain(`${label}${n}`)
    }
  })

  it('names the layers that have no collector rather than omitting them', async () => {
    renderPage()
    await screen.findByText('Signal Evidence')

    // The fixture's own coverage statement says 5 of 7. Those two dark layers
    // can never produce a contradicting observation, so if the page does not
    // state them the bar reads as an all-clear over a partial picture.
    expect(fakeWeaveData.coverage.covered_layers).toHaveLength(5)

    expect(screen.getByTestId('posture-layer-coverage-ratio'))
      .toHaveTextContent('5 of 7 layers instrumented')

    const blind = screen.getByTestId('posture-blind-spots')
    expect(blind).toHaveTextContent('Cloud Control Plane')
    expect(blind).toHaveTextContent('Protocol')
    expect(blind.textContent).toContain('no collector')
  })

  it('follows the coverage statement rather than its own constant', async () => {
    // The demo fixture's covered_layers happens to equal the list this page
    // used to hardcode, so every assertion above would still pass against the
    // constant. This one cannot: it serves a coverage statement that disagrees
    // with the constant and requires the page to follow the service.
    mockWeaveApi.getCoverage.mockResolvedValue({
      ...fakeWeaveData.coverage,
      covered_layers: ['network_egress', 'cloud_control_plane', 'protocol'],
      blind_spots: [
        { id: 'bs-x', layer: 'behavioural', description: 'Behavioural models not deployed in this tenant.' },
      ],
    })
    renderPage()
    await screen.findByText('Signal Evidence')

    expect(screen.getByTestId('posture-layer-coverage-ratio'))
      .toHaveTextContent('3 of 7 layers instrumented')

    // cloud_control_plane and protocol are now instrumented, so they must leave
    // the blind-spot list; behavioural must join it.
    const blind = screen.getByTestId('posture-blind-spots')
    expect(blind.textContent).not.toContain('Cloud Control Plane')
    expect(blind.textContent).not.toContain('Protocol')
    expect(blind).toHaveTextContent('Behavioural')
    expect(screen.getByText('Behavioural').closest('[title]'))
      .toHaveAttribute('title', expect.stringContaining('Behavioural models not deployed'))
  })

  it('explains each uninstrumented layer with the service blind-spot reason', async () => {
    renderPage()
    await screen.findByText('Signal Evidence')

    const cloud = screen.getByText('Cloud Control Plane').closest('[title]')
    expect(cloud).toHaveAttribute('title', expect.stringContaining('collector not deployed'))
  })

  it('distinguishes a quiet collector from an absent one', async () => {
    // endpoint_host is instrumented; give it nothing to report and it must read
    // as quiet, not as a blind spot.
    mockWeaveApi.getObservations.mockResolvedValue(
      fakeWeaveData.observations.filter((o) => o.layer !== 'endpoint_host'),
    )
    renderPage()
    await screen.findByText('Signal Evidence')

    const endpoint = screen.getByText('Endpoint/Host').closest('[title]')
    expect(endpoint).toHaveAttribute('title', expect.stringContaining('collector deployed, no observations'))
    expect(screen.getByTestId('posture-blind-spots').textContent).not.toContain('Endpoint/Host')
  })

  it('still renders observations when the coverage call fails on its own', async () => {
    // Coverage is supplementary to data that is already supplementary. A
    // coverage outage must not blank a section that has observations to show.
    mockWeaveApi.getCoverage.mockRejectedValue(new Error('coverage unavailable'))
    renderPage()

    expect(await screen.findByText('Signal Evidence')).toBeInTheDocument()
    expect(screen.getByTestId('signal-evidence-section')).toBeInTheDocument()
    expect(screen.getByTestId('posture-signal-badge')).toBeInTheDocument()
    expect(screen.getByText('Network/Egress')).toBeInTheDocument()
    // Falls back to the five layers the page assumed before it asked.
    expect(screen.getByTestId('posture-layer-coverage-ratio'))
      .toHaveTextContent('5 of 7 layers instrumented')
  })
})
