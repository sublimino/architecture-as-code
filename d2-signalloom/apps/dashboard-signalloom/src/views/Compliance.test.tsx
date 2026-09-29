/**
 * Tests for Compliance view framework-selection state-sync,
 * posture score formatting, and ComplianceDrawer interactive drill-down.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import Compliance from './Compliance'
import { api } from '../api/client'

// ── Mocks ──────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../App', () => ({
  useAppContext: () => ({ setFailingControls: vi.fn() }),
}))

vi.mock('../api/client', () => ({
  api: {
    compliance: {
      posture: vi.fn(),
      frameworks: vi.fn(),
      summary: vi.fn(),
      export: vi.fn(),
    },
    agents: { list: vi.fn() },
    settings: vi.fn(),
  },
}))

const FRAMEWORKS = [
  {
    id: 'fw-soc2',
    name: 'SOC 2 Type II',
    version: '2017',
    regulatory_body: 'AICPA',
    compliance_deadline: null,
    control_count: 3,
    controls: [
      { id: 'cc-1', name: 'Access Control', description: 'Logical access controls', control_order: 1 },
      { id: 'cc-2', name: 'Change Management', description: 'Authorized changes', control_order: 2 },
    ],
  },
  {
    id: 'fw-euai',
    name: 'EU AI Act',
    version: 'v2.1',
    regulatory_body: 'EU',
    compliance_deadline: null,
    control_count: 3,
    controls: [
      { id: 'art-9', name: 'Risk Management', description: 'Risk assessment system', control_order: 1 },
      { id: 'art-14', name: 'Human Oversight', description: 'Human-in-the-loop controls', control_order: 2 },
    ],
  },
]

const EMPTY_POSTURE = { agents: [] }
const EMPTY_AGENTS = { agents: [] }
const EMPTY_SUMMARY = { total_agents: 0, agents_assessed: 0, controls_passing: 0, controls_failing: 0, controls_pending: 0, posture_score: null }
const BASE_SETTINGS = { tenant_id: 'tid', org_name: 'Acme', plan_tier: null, agent_count: 0, billing_tier: null, api_key_status: null, consent_required: false, cookie_preferences: null }

function setup() {
  vi.mocked(api.compliance.posture).mockResolvedValue(EMPTY_POSTURE as never)
  vi.mocked(api.compliance.frameworks).mockResolvedValue(FRAMEWORKS as never)
  vi.mocked(api.compliance.summary).mockResolvedValue(EMPTY_SUMMARY as never)
  vi.mocked(api.agents.list).mockResolvedValue(EMPTY_AGENTS as never)
}

function renderCompliance() {
  return render(
    <MemoryRouter>
      <Compliance />
    </MemoryRouter>
  )
}

// ── Tests ──────────────────────────────────────────────────────────────────

describe('Compliance framework filter', () => {
  beforeEach(() => {
    setup()
  })

  it('shows all frameworks when selected_frameworks is empty (unset)', async () => {
    vi.mocked(api.settings).mockResolvedValue({
      ...BASE_SETTINGS,
      selected_frameworks: [],
    } as never)

    renderCompliance()

    await waitFor(() => {
      expect(screen.getByText('SOC 2 Type II')).toBeInTheDocument()
      expect(screen.getByText('EU AI Act')).toBeInTheDocument()
    })
  })

  it('shows only enabled frameworks when selected_frameworks is non-empty', async () => {
    vi.mocked(api.settings).mockResolvedValue({
      ...BASE_SETTINGS,
      selected_frameworks: ['fw-soc2'],
    } as never)

    renderCompliance()

    await waitFor(() => {
      expect(screen.getByText('SOC 2 Type II')).toBeInTheDocument()
    })
    expect(screen.queryByText('EU AI Act')).not.toBeInTheDocument()
  })

  it('shows no framework cards when all frameworks are disabled', async () => {
    vi.mocked(api.settings).mockResolvedValue({
      ...BASE_SETTINGS,
      selected_frameworks: ['fw-other'],
    } as never)

    renderCompliance()

    await waitFor(() => {
      expect(screen.queryByText('SOC 2 Type II')).not.toBeInTheDocument()
      expect(screen.queryByText('EU AI Act')).not.toBeInTheDocument()
    })
  })

  it('shows all frameworks when settings API response omits selected_frameworks (graceful fallback, no crash)', async () => {
    vi.mocked(api.settings).mockResolvedValue({
      ...BASE_SETTINGS,
    } as never)

    renderCompliance()

    await waitFor(() => {
      expect(screen.getByText('SOC 2 Type II')).toBeInTheDocument()
      expect(screen.getByText('EU AI Act')).toBeInTheDocument()
    })
  })
})

describe('the posture table explains the columns an executive will misread', () => {
  beforeEach(() => {
    setup()
    vi.mocked(api.settings).mockResolvedValue({ ...BASE_SETTINGS, selected_frameworks: [] } as never)
    vi.mocked(api.compliance.posture).mockResolvedValue({
      agents: [{ agent_id: 'a1', agent_name: 'Cardvault Agent', posture_score: 62, results: [] }],
    } as never)
  })

  it('says which direction is good on the posture score, and that it is not live', async () => {
    const user = userEvent.setup()
    renderCompliance()

    const hint = await screen.findByTestId('compliance-posture-help')
    expect(hint).toHaveAccessibleName('What Posture Score means')
    await user.hover(hint)
    const tooltip = await screen.findByRole('tooltip')
    expect(tooltip.textContent).toMatch(/Higher is better/i)
    expect(tooltip.textContent).toMatch(/only moves when an assessment runs/i)
  })

  it('says stunned means credentials revoked, not that the workload stopped', async () => {
    const user = userEvent.setup()
    renderCompliance()

    await user.hover(await screen.findByTestId('compliance-lifecycle-help'))
    const tooltip = await screen.findByRole('tooltip')
    expect(tooltip.textContent).toMatch(/revoked its credentials/i)
    expect(tooltip.textContent).toMatch(/may still be running/i)
  })

  it('warns that a stale assessment timestamp makes the row unreliable', async () => {
    const user = userEvent.setup()
    renderCompliance()

    await user.hover(await screen.findByTestId('compliance-assessed-help'))
    expect((await screen.findByRole('tooltip')).textContent).toMatch(/not a live reading/i)
  })

  it('leaves the framework columns unhinted: they link to their own detail page', async () => {
    renderCompliance()
    await screen.findByTestId('compliance-posture-help')

    expect(screen.queryByRole('button', { name: 'What SOC 2 Type II means' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'What Agent means' })).toBeNull()
  })

  it('renders agent name as a drill-down link to the agent overview', async () => {
    renderCompliance()
    const link = await screen.findByRole('link', { name: 'Cardvault Agent' })
    expect(link).toHaveAttribute('href', '/agents/a1?tab=overview')
  })
})

describe('ComplianceDrawer interactive drill-down and score formatting', () => {
  beforeEach(() => {
    setup()
    vi.mocked(api.settings).mockResolvedValue({ ...BASE_SETTINGS, selected_frameworks: [] } as never)
    vi.mocked(api.compliance.posture).mockResolvedValue({
      agents: [
        {
          agent_id: 'a1',
          agent_name: 'Sentinel Alpha',
          posture_score: 0.85,
          results: [
            {
              agent_id: 'a1',
              control_id: 'art-9',
              control_name: 'Risk Management',
              framework_name: 'EU AI Act',
              status: 'pass',
              assessed_at: '2026-09-29T05:00:00Z',
              evidence_ref: 'sha256:abc1234567890',
            },
            {
              agent_id: 'a1',
              control_id: 'art-14',
              control_name: 'Human Oversight',
              framework_name: 'EU AI Act',
              status: 'fail',
              assessed_at: '2026-09-29T05:00:00Z',
              evidence_ref: 'sha256:def1234567890',
            },
          ],
        },
      ],
    } as never)
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [
        {
          id: 'a1',
          name: 'Sentinel Alpha',
          tenant_id: 'tid',
          lifecycle_state: 'Governed',
          last_transition_at: null,
          compliance_summary: {
            total_controls: 2,
            passing: 1,
            failing: 1,
            pending: 0,
            posture_score: 0.85,
          },
        },
      ],
    } as never)
  })

  it('formats 0..1 posture float score as 85% in the table PostureBar', async () => {
    renderCompliance()

    await waitFor(() => {
      expect(screen.getByText('85%')).toBeInTheDocument()
    })
  })

  it('opens ComplianceDrawer on framework card click', async () => {
    const user = userEvent.setup()
    renderCompliance()

    const fwCard = await screen.findByTestId('compliance-framework-card-fw-euai')
    await user.click(fwCard)

    const drawer = await screen.findByTestId('compliance-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByTestId('compliance-drawer-title')).toHaveTextContent('EU AI Act')
    expect(screen.getByTestId('metric-total-checks')).toBeInTheDocument()
    expect(screen.getByTestId('compliance-policy-card')).toBeInTheDocument()
  })

  it('opens ComplianceDrawer on agent posture row click', async () => {
    const user = userEvent.setup()
    renderCompliance()

    const row = await screen.findByTestId('compliance-row-a1')
    await user.click(row)

    const drawer = await screen.findByTestId('compliance-drawer')
    expect(drawer).toBeInTheDocument()
    expect(screen.getByText(/Agent: Sentinel Alpha/i)).toBeInTheDocument()
    expect(screen.getByTestId('metric-total-checks')).toHaveTextContent('2')
    expect(screen.getByTestId('metric-passed-checks')).toHaveTextContent('1')
    expect(screen.getByTestId('metric-failed-checks')).toHaveTextContent('1')
  })

  it('opens ComplianceDrawer via Enter key on focused row', async () => {
    renderCompliance()

    const row = await screen.findByTestId('compliance-row-a1')
    fireEvent.keyDown(row, { key: 'Enter', code: 'Enter' })

    const drawer = await screen.findByTestId('compliance-drawer')
    expect(drawer).toBeInTheDocument()
  })

  it('opens ComplianceDrawer via Space key on focused row', async () => {
    renderCompliance()

    const row = await screen.findByTestId('compliance-row-a1')
    fireEvent.keyDown(row, { key: ' ', code: 'Space' })

    const drawer = await screen.findByTestId('compliance-drawer')
    expect(drawer).toBeInTheDocument()
  })

  it('closes ComplianceDrawer on Escape key and close button', async () => {
    const user = userEvent.setup()
    renderCompliance()

    const row = await screen.findByTestId('compliance-row-a1')
    await user.click(row)

    expect(await screen.findByTestId('compliance-drawer')).toBeInTheDocument()

    // Close on Escape
    fireEvent.keyDown(window, { key: 'Escape' })
    await waitFor(() => {
      expect(screen.queryByTestId('compliance-drawer')).not.toBeInTheDocument()
    })

    // Reopen and close via close button
    await user.click(row)
    expect(await screen.findByTestId('compliance-drawer')).toBeInTheDocument()
    await user.click(screen.getByTestId('compliance-drawer-close'))
    await waitFor(() => {
      expect(screen.queryByTestId('compliance-drawer')).not.toBeInTheDocument()
    })
  })
})
