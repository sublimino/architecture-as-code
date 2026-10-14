import { fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { CORE_SPECIMEN_NAMES, CoreSpecimens } from './CoreSpecimens'

const EXPECTED_NAMES = [
  'ConversionNote',
  'CycleDetectedWarning',
  'DelegationChainNode',
  'DelegationEventFilter',
  'PolicyEditor',
  'RiskWidget',
  'SourceBadge',
  'KernelStateBadge',
  'StreamingLogBlock',
  'PlaneOutcomeTable',
  'PlaneStrip',
  'StunOverallHeadline',
  'StunReasonForm',
  'CodingAgentCard',
  'AgentSuperFilterTable',
  'AgentCockpitTelemetryView',
  'MetricsTopBarView',
  'AlertLink',
  'ArrowIcon',
  'Avatar',
  'BellIcon',
  'ChevronIcon',
  'Chip',
  'HeaderFrame',
  'Mark',
  'SearchIcon',
  'SeverityDot',
  'SeverityTag',
  'UnreadPill',
  'RoleViewSelector',
  'FleetBadge',
  'ConfirmDialog',
] as const

afterEach(() => vi.restoreAllMocks())

describe('CoreSpecimens', () => {
  it('publishes exactly the names of its labelled, mounted specimens', () => {
    render(<CoreSpecimens />)

    expect(CORE_SPECIMEN_NAMES).toEqual(EXPECTED_NAMES)
    for (const name of CORE_SPECIMEN_NAMES) {
      const specimen = screen.getByTestId(`core-specimen-${name}`)
      expect(within(specimen).getByText(name, { selector: 'strong' })).toBeInTheDocument()
      expect(specimen).toHaveAttribute('data-source', expect.stringContaining('/'))
    }
  })

  it('drives filters, role selection, forms, and dialog through local state only', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    render(<CoreSpecimens />)

    fireEvent.change(screen.getByLabelText('Event Type:'), { target: { value: 'delegated' } })
    expect(screen.getByLabelText('Event Type:')).toHaveValue('delegated')

    fireEvent.click(screen.getByTestId('role-btn-compliance'))
    expect(screen.getByTestId('role-btn-compliance')).toHaveAttribute('aria-pressed', 'true')

    const reason = screen.getByLabelText(/Reason for stunning/i)
    fireEvent.change(reason, { target: { value: 'Deterministic gallery drill' } })
    fireEvent.click(screen.getByRole('button', { name: 'Confirm stun' }))
    expect(screen.getByTestId('core-stun-reason-result')).toHaveTextContent('Deterministic gallery drill')

    fireEvent.click(screen.getByRole('button', { name: 'Open confirmation specimen' }))
    const dialog = screen.getByRole('dialog', { name: 'Confirm local specimen' })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Confirm locally' }))
    expect(screen.getByTestId('core-confirm-result')).toHaveTextContent('Confirmed locally')

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('filters the local agent table without issuing requests', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    render(<CoreSpecimens />)

    const table = screen.getByTestId('core-agent-super-filter')
    expect(within(table).getByText('build-agent')).toBeInTheDocument()
    expect(within(table).getByText('audit-agent')).toBeInTheDocument()

    fireEvent.change(within(table).getByRole('searchbox'), { target: { value: 'audit' } })
    expect(within(table).queryByText('build-agent')).not.toBeInTheDocument()
    expect(within(table).getByText('audit-agent')).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})
