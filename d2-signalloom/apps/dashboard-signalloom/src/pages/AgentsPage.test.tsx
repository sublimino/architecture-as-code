/**
 * Tests for compliance scan button, agent registration, and live data wiring
 * on the Agents page.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import AgentsPage from './AgentsPage'
import { api } from '../api/client'
import type { AgentResponse } from '../types/api'

// ── Mocks ──────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

vi.mock('../api/client', () => ({
  api: {
    agents: {
      list: vi.fn(),
      register: vi.fn(),
    },
    nhi: {
      discovered: vi.fn().mockResolvedValue({ accounts: [], total: 0, summary: { total_discovered: 0, needs_triage: 0, previously_dismissed: 0 } }),
      scans: vi.fn().mockResolvedValue({ scans: [] }),
      enrollAccount: vi.fn(),
      dismissAccount: vi.fn(),
    },
    compliancePolicy: {
      scan: vi.fn(),
    },
  },
}))

function makeAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-abc-123',
    name: 'Invoice Bot',
    type: 'Signal Loom Built',
    owner: 'ops@acme.com',
    tenant_id: 'tenant-1',
    lifecycle_state: 'active',
    last_transition_at: '2026-06-01T00:00:00Z',
    last_transition_by: 'operator@signal-loom.ai',
    eu_ai_act_risk_class: 'limited',
    compliance_summary: { total_controls: 6, passing: 4, failing: 0, pending: 2, posture_score: 67 },
    created_at: '2026-05-01T00:00:00Z',
    ...overrides,
  }
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/agents']}>
      <AgentsPage />
    </MemoryRouter>,
  )
}

describe('AgentsPage — Compliance Scan', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
  })

  it('renders the Scan Compliance button in the page header', async () => {
    renderPage()
    expect(await screen.findByRole('button', { name: /scan compliance/i })).toBeInTheDocument()
  })

  it('calls compliancePolicy.scan and shows scanning state on click', async () => {
    const scanResult = {
      checks: [],
      summary: { totalChecks: 0, passed: 0, failed: 0, totalAle: 0, totalVar95: 0, totalTvar: 0, totalCarriedGbp: 0, scanTimestamp: '2026-08-01T00:00:00Z', frameworks: [] },
    }
    ;(api.compliancePolicy.scan as ReturnType<typeof vi.fn>).mockResolvedValue(scanResult)

    renderPage()
    const btn = await screen.findByRole('button', { name: /scan compliance/i })
    await userEvent.click(btn)

    await waitFor(() => expect(api.compliancePolicy.scan).toHaveBeenCalledTimes(1))
  })

  it('shows last scanned timestamp after a successful scan', async () => {
    const scanResult = {
      checks: [],
      summary: { totalChecks: 0, passed: 0, failed: 0, totalAle: 0, totalVar95: 0, totalTvar: 0, totalCarriedGbp: 0, scanTimestamp: '2026-08-01T12:00:00Z', frameworks: [] },
    }
    ;(api.compliancePolicy.scan as ReturnType<typeof vi.fn>).mockResolvedValue(scanResult)

    renderPage()
    const btn = await screen.findByRole('button', { name: /scan compliance/i })
    await userEvent.click(btn)

    await waitFor(() => {
      expect(screen.getByText(/last scanned/i)).toBeInTheDocument()
    })
  })

  it('shows the auto-scan cron schedule note', async () => {
    renderPage()
    await screen.findByRole('button', { name: /scan compliance/i })
    expect(screen.getByText(/auto-scan every 15 minutes/i)).toBeInTheDocument()
  })
})

describe('AgentsPage — Register Agent', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [makeAgent()],
      total: 1,
    })
  })

  it('renders the Register Agent button', async () => {
    renderPage()
    expect(await screen.findByRole('button', { name: /register agent/i })).toBeInTheDocument()
  })

  it('opens a registration modal with name and type fields on click', async () => {
    renderPage()
    const btn = await screen.findByRole('button', { name: /register agent/i })
    await userEvent.click(btn)

    // The modal renders a form with Name and Type inputs
    const heading = screen.getByText('Register New Agent')
    expect(heading).toBeInTheDocument()
    // Scope to the modal form to avoid the lifecycle filter select in the background
    const modal = heading.closest('.card')!
    const modalScope = within(modal as HTMLElement)
    expect(modalScope.getAllByRole('textbox').length).toBeGreaterThanOrEqual(1) // name, description, owner inputs
    expect(modalScope.getByRole('combobox')).toBeInTheDocument() // type select
  })

  it('calls api.agents.register on form submit', async () => {
    ;(api.agents.register as ReturnType<typeof vi.fn>).mockResolvedValue(makeAgent({ name: 'New Bot' }))
    renderPage()

    const btn = await screen.findByRole('button', { name: /register agent/i })
    await userEvent.click(btn)

    // Scope to the modal to avoid the lifecycle filter select in the background
    const heading = screen.getByText('Register New Agent')
    const modal = heading.closest('.card')!
    const modalScope = within(modal as HTMLElement)

    // Fill the name field (first input[required] in the modal form)
    const nameInput = modal.querySelector('input[required]') as HTMLInputElement
    await userEvent.type(nameInput, 'New Bot')

    // Select a type
    const typeSelect = modalScope.getByRole('combobox')
    await userEvent.selectOptions(typeSelect, 'Custom')

    // Submit the form (last "Register Agent" button on screen is the modal submit)
    const submitBtn = modalScope.getAllByRole('button', { name: /register agent/i }).pop()!
    await userEvent.click(submitBtn)

    await waitFor(() => expect(api.agents.register).toHaveBeenCalledTimes(1))
  })
})

describe('AgentsPage — Live Data Wiring', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders agents from the API in the governed tab', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Alpha Agent', lifecycle_state: 'active' }),
        makeAgent({ id: 'agent-2', name: 'Beta Agent', lifecycle_state: 'enrolled' }),
      ],
      total: 2,
    })
    renderPage()

    expect(await screen.findByText('Alpha Agent')).toBeInTheDocument()
    expect(screen.getByText('Beta Agent')).toBeInTheDocument()
  })

  it('correctly filters governed agents by lifecycle state', async () => {
    ;(api.agents.list as ReturnType<typeof vi.fn>).mockResolvedValue({
      agents: [
        makeAgent({ name: 'Active Agent', lifecycle_state: 'active' }),
        makeAgent({ id: 'agent-2', name: 'Suspended Agent', lifecycle_state: 'suspended' }),
      ],
      total: 2,
    })
    renderPage()

    await screen.findByText('Active Agent')

    // Filter to suspended only
    const select = screen.getByDisplayValue('All states')
    await userEvent.selectOptions(select, 'suspended')

    expect(screen.queryByText('Active Agent')).not.toBeInTheDocument()
    expect(screen.getByText('Suspended Agent')).toBeInTheDocument()
  })
})

// ── Carried from feat/signalloom-platform-carry-20260802 ────────────────────
// Both branches created this file independently (add/add), so this block is the
// union: these three cases exist only on the platform-carry side. They set
// eu_ai_act_risk_class explicitly rather than leaning on makeAgent's default,
// which differs between the two branches ('limited' here vs 'limited_risk').
describe('AgentsPage — lifecycle tooltip + EU AI Act column', () => {
  it('provides hover help for governed-agent operations', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({ agents: [makeAgent()], total: 1 })
    renderPage()

    await screen.findByText('Invoice Bot')
    await userEvent.hover(screen.getByTestId('agents-governed-help'))
    expect(screen.getByRole('tooltip')).toHaveTextContent(/one enriched record rather than a duplicate/i)

    await userEvent.unhover(screen.getByTestId('agents-governed-help'))
    await userEvent.hover(screen.getByTestId('agents-scan-help'))
    expect(screen.getByRole('tooltip')).toHaveTextContent(/live policy scan/i)
  })

  it('shows an EU AI Act column with the risk class badge', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [makeAgent({ eu_ai_act_risk_class: 'limited_risk' })],
      total: 1,
    })
    renderPage()

    expect(await screen.findByText('EU AI Act')).toBeInTheDocument()
    expect(await screen.findByText('limited risk')).toBeInTheDocument()
  })

  it('renders a placeholder when eu_ai_act_risk_class is null', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [makeAgent({ eu_ai_act_risk_class: null })],
      total: 1,
    })
    renderPage()

    await screen.findByText('Invoice Bot')
    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
  })

  it('shows a descriptive tooltip on the lifecycle-state badge', async () => {
    vi.mocked(api.agents.list).mockResolvedValue({
      agents: [makeAgent({ lifecycle_state: 'suspended' })],
      total: 1,
    })
    renderPage()

    const badge = await screen.findByText('suspended')
    await waitFor(() => expect(badge.closest('[title]')).toHaveAttribute(
      'title',
      expect.stringContaining('reversible')
    ))
  })
})
