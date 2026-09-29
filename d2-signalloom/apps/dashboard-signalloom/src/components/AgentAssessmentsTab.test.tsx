import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import AgentAssessmentsTab from './AgentAssessmentsTab'
import type { AgentResponse, AgentComplianceResultResponse } from '../types/api'

function renderComponent(ui: React.ReactElement, initialEntries = ['/agents/agent-1234-5678?tab=assessments']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      {ui}
    </MemoryRouter>,
  )
}

function makeTestAgent(overrides: Partial<AgentResponse> = {}): AgentResponse {
  return {
    id: 'agent-1234-5678',
    name: 'Compliance Test Agent',
    type: 'Signal Loom Built',
    owner: 'alice@signal-loom.ai',
    tenant_id: 'tenant-demo',
    lifecycle_state: 'active',
    last_transition_at: '2026-07-20T10:00:00Z',
    last_transition_by: 'admin@acme.co',
    eu_ai_act_risk_class: 'high',
    created_at: '2026-07-01T00:00:00Z',
    compliance_summary: {
      total_controls: 6,
      passing: 5,
      failing: 1,
      pending: 0,
      posture_score: 0.83,
    },
    assessment_summary: {
      status: 'assessed',
      total_controls: 6,
      passed_controls: 5,
      failed_controls: 1,
      pending_controls: 0,
      normalized_score: 0.83,
    },
    attention: {
      level: 'warning',
      highest_issue: '1 failing control detected',
    },
    timestamps: {
      created_at: '2026-07-01T00:00:00Z',
      last_observed_at: '2026-07-20T10:00:00Z',
      last_action_at: '2026-07-20T10:00:00Z',
    },
    ...overrides,
  }
}

const MOCK_RESULTS: AgentComplianceResultResponse[] = [
  {
    agent_id: 'agent-1234-5678',
    control_id: 'eu-ai-act:art-9',
    control_name: 'Risk management system',
    framework_name: 'EU AI Act',
    status: 'pass',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/art-9',
  },
  {
    agent_id: 'agent-1234-5678',
    control_id: 'eu-ai-act:art-12',
    control_name: 'Record keeping and logging',
    framework_name: 'EU AI Act',
    status: 'pass',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/art-12',
  },
  {
    agent_id: 'agent-1234-5678',
    control_id: 'eu-ai-act:art-14',
    control_name: 'Human oversight',
    framework_name: 'EU AI Act',
    status: 'pass',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/art-14',
  },
  {
    agent_id: 'agent-1234-5678',
    control_id: 'soc2:cc6.1',
    control_name: 'Logical access controls',
    framework_name: 'SOC 2',
    status: 'pass',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/cc6.1',
  },
  {
    agent_id: 'agent-1234-5678',
    control_id: 'soc2:cc6.2',
    control_name: 'System access authorization',
    framework_name: 'SOC 2',
    status: 'pass',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/cc6.2',
  },
  {
    agent_id: 'agent-1234-5678',
    control_id: 'soc2:cc7.2',
    control_name: 'System monitoring & telemetry',
    framework_name: 'SOC 2',
    status: 'fail',
    assessed_at: '2026-07-20T10:00:00Z',
    evidence_ref: 'opa://assessments/agent/cc7.2',
  },
]

describe('AgentAssessmentsTab — Tab 4 (Assessments & Control Ratios)', () => {
  let mockReassess: ReturnType<typeof vi.fn>
  let mockScanCompliance: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockReassess = vi.fn().mockResolvedValue(undefined)
    mockScanCompliance = vi.fn().mockResolvedValue(undefined)
  })

  it('renders all 4 StatCards with correct metrics and ratios', () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        openViolations={1}
        onReassess={mockReassess}
        onScanCompliance={mockScanCompliance}
      />
    )

    // 4 StatCards present
    expect(screen.getByTestId('assessments-card-posture')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-counts')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-violations')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-card-lifecycle')).toBeInTheDocument()

    // Metrics checked
    expect(screen.getByTestId('assessments-posture-score')).toHaveTextContent('83%')
    expect(screen.getByTestId('assessments-control-ratio')).toHaveTextContent('5/6 Passing (83%)')
    expect(screen.getByTestId('assessments-total-controls')).toHaveTextContent('6')
    expect(screen.getByTestId('assessments-passed-count')).toHaveTextContent('5')
    expect(screen.getByTestId('assessments-failing-count')).toHaveTextContent('1')
    expect(screen.getByTestId('assessments-open-violations')).toHaveTextContent('1')
    expect(screen.getByTestId('assessments-source-health')).toHaveTextContent('Healthy')
  })

  it('renders truthful "Not assessed" when total evaluated controls is 0', () => {
    const agent = makeTestAgent({
      compliance_summary: {
        total_controls: 0,
        passing: 0,
        failing: 0,
        pending: 0,
        posture_score: null,
      },
      assessment_summary: {
        status: 'not_assessed',
        total_controls: 0,
        passed_controls: 0,
        failed_controls: 0,
        pending_controls: 0,
        normalized_score: null,
      },
    })

    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={[]}
        openViolations={0}
        onReassess={mockReassess}
        onScanCompliance={mockScanCompliance}
      />
    )

    expect(screen.getByTestId('assessments-posture-score')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('assessments-control-ratio')).toHaveTextContent('Not assessed')
    expect(screen.getByTestId('assessments-empty-state')).toBeInTheDocument()
    expect(screen.getByText('No assessment results')).toBeInTheDocument()
  })

  it('renders truthful "Source unavailable" banner when primary collector is offline', () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        sourceHealth="unavailable"
        onReassess={mockReassess}
      />
    )

    expect(screen.getByTestId('assessments-source-health-alert')).toBeInTheDocument()
    expect(screen.getByTestId('assessments-source-health')).toHaveTextContent('Source unavailable')
  })

  it('renders EU AI Act Article 9 (Risk Management System) breakdown section', () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
      />
    )

    expect(screen.getByTestId('assessments-section-article9')).toBeInTheDocument()
    expect(screen.getByText('EU AI Act Article 9: Risk Management System')).toBeInTheDocument()
    expect(screen.getByTestId('article9-risk-badge')).toHaveTextContent('Risk Class: HIGH')
    expect(screen.getByTestId('article9-ratio-score')).toBeInTheDocument()
    expect(screen.getByTestId('article9-card-art--9-1-')).toBeInTheDocument()
    expect(screen.getByTestId('article9-card-art--9-2-')).toBeInTheDocument()
  })

  it('renders Framework Controls grouped by framework with pass rate pills', () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
      />
    )

    expect(screen.getByTestId('assessments-section-frameworks')).toBeInTheDocument()
    expect(screen.getByTestId('framework-card-eu-ai-act')).toBeInTheDocument()
    expect(screen.getByTestId('framework-card-soc-2')).toBeInTheDocument()

    // Pass rate pill in EU AI Act card (3/3 = 100%)
    expect(screen.getByTestId('framework-card-eu-ai-act')).toHaveTextContent('100% Pass Rate')
    // Pass rate in SOC 2 card (2/3 = 67%)
    expect(screen.getByTestId('framework-card-soc-2')).toHaveTextContent('67% Pass Rate')

    // Control rows
    expect(screen.getByTestId('control-row-eu-ai-act:art-9')).toBeInTheDocument()
    expect(screen.getByTestId('control-row-soc2:cc7.2')).toBeInTheDocument()
    expect(screen.getByText('Evidence: opa://assessments/agent/art-9')).toBeInTheDocument()
  })

  it('filters controls by status (failing, passing)', async () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
      />
    )

    // Click 'fail' filter
    const failBtn = screen.getByRole('button', { name: /^fail$/i })
    await userEvent.click(failBtn)

    // Only failing control should be visible (soc2:cc7.2)
    expect(screen.getByTestId('control-row-soc2:cc7.2')).toBeInTheDocument()
    expect(screen.queryByTestId('control-row-eu-ai-act:art-9')).not.toBeInTheDocument()

    // Click 'pass' filter
    const passBtn = screen.getByRole('button', { name: /^pass$/i })
    await userEvent.click(passBtn)

    expect(screen.queryByTestId('control-row-soc2:cc7.2')).not.toBeInTheDocument()
    expect(screen.getByTestId('control-row-eu-ai-act:art-9')).toBeInTheDocument()
  })

  it('triggers reassessment request on button click and updates button state', async () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
      />
    )

    const reassessBtn = screen.getByTestId('reassess-btn-soc2:cc7.2')
    expect(reassessBtn).toBeInTheDocument()
    expect(reassessBtn).toHaveTextContent('Request Reassessment')

    await userEvent.click(reassessBtn)
    expect(mockReassess).toHaveBeenCalledWith('soc2:cc7.2')
    expect(reassessBtn).toHaveTextContent('Requested')
    expect(reassessBtn).toBeDisabled()
  })

  it('triggers compliance scan when scan button is clicked', async () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
        onScanCompliance={mockScanCompliance}
      />
    )

    const scanBtn = screen.getByTestId('assessments-scan-button')
    await userEvent.click(scanBtn)
    expect(mockScanCompliance).toHaveBeenCalledTimes(1)
  })

  it('filters by framework and status from URL search params', () => {
    const agent = makeTestAgent()
    renderComponent(
      <AgentAssessmentsTab
        agent={agent}
        complianceResults={MOCK_RESULTS}
        onReassess={mockReassess}
      />,
      ['/agents/agent-1234-5678?tab=assessments&framework=SOC%202&status=fail']
    )

    expect(screen.getByTestId('control-row-soc2:cc7.2')).toBeInTheDocument()
    expect(screen.queryByTestId('control-row-eu-ai-act:art-9')).not.toBeInTheDocument()
  })
})
