/**
 * Tests for Compliance view framework-selection state-sync.
 *
 * Bug [86caeju0w]: Compliance page was showing ALL governance_frameworks from
 * the DB, ignoring the tenant's selected_frameworks from /tenant/settings.
 * These tests assert that only enabled frameworks are displayed.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
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
    },
    agents: { list: vi.fn() },
    settings: vi.fn(),
  },
}))

const FRAMEWORKS = [
  { id: 'fw-soc2', name: 'SOC 2 Type II', version: '2017', regulatory_body: 'AICPA', compliance_deadline: null, control_count: 3, controls: [] },
  { id: 'fw-euai', name: 'EU AI Act', version: null, regulatory_body: 'EU', compliance_deadline: null, control_count: 3, controls: [] },
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
      selected_frameworks: ['fw-other'],  // an ID not in the DB response
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
      // selected_frameworks deliberately absent — simulates an older API version
    } as never)

    renderCompliance()

    await waitFor(() => {
      expect(screen.getByText('SOC 2 Type II')).toBeInTheDocument()
      expect(screen.getByText('EU AI Act')).toBeInTheDocument()
    })
  })
})

// The posture table is the artefact a bank executive is handed as evidence, and
// three of its columns can be read exactly backwards: "Lifecycle: stunned"
// looks like the agent stopped, "Posture Score: 62" gives no sense of whether
// higher is better, and "Last Assessed" is easily taken for a live reading.
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

  it('leaves the framework columns unhinted — they link to their own detail page', async () => {
    renderCompliance()
    await screen.findByTestId('compliance-posture-help')

    expect(screen.queryByRole('button', { name: 'What SOC 2 Type II means' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'What Agent means' })).toBeNull()
  })
})
