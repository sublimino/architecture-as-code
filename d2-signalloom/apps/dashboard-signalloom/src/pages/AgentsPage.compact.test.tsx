import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { AgentTableRow } from './AgentsPage'
import { CompactOperationalTable } from '../components/CompactOperationalTable'
import type { AgentResponse } from '../types/api'

const agent: AgentResponse = {
  id: 'compact-agent', name: 'A long operational agent name', type: 'Custom', owner: 'operator.with-long-localpart@example.com',
  lifecycle_state: 'Suspended', record_class: 'discovered', is_registry_linked: false,
  tenant_id: 'controlplane', last_transition_at: '2026-10-14T11:00:00Z', last_transition_by: null,
  eu_ai_act_risk_class: 'limited', created_at: '2026-10-01T12:00:00Z',
  compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
}

function setup(overrides: Partial<AgentResponse> = {}, claiming = false) {
  const onSelect = vi.fn(), onEdit = vi.fn(), onClaim = vi.fn()
  render(<MemoryRouter><CompactOperationalTable label="Inventory"><AgentTableRow agent={{ ...agent, ...overrides }} shown claiming={claiming} onSelect={onSelect} onEdit={onEdit} onClaim={onClaim} /></CompactOperationalTable></MemoryRouter>)
  return { onSelect, onEdit, onClaim, row: screen.getByTestId('agent-row-compact-agent') }
}

describe('compact agent row public actions and evidence', () => {
  it('separates observation from actions without inventing an observation from creation/transition', () => {
    const { row } = setup()
    const cells = row.querySelectorAll('td')
    expect(cells).toHaveLength(8)
    expect(cells[6]).toHaveTextContent('Unknown')
    expect(cells[6].querySelector('button')).not.toHaveTextContent('Dossier')
    expect(within(cells[7]).getByRole('link', { name: /Dossier/ })).toHaveAttribute('href', '/agents/compact-agent?tab=overview')
  })

  it('keeps claim eligibility, claiming state and exact dossier navigation without hover mutations', () => {
    const { onClaim, onSelect, onEdit, row } = setup()
    fireEvent.mouseEnter(row)
    for (const button of within(row).getAllByRole('button')) {
      fireEvent.focus(button)
      fireEvent.keyDown(button, { key: 'Escape' })
      fireEvent.blur(button)
    }
    expect(onClaim).not.toHaveBeenCalled()
    expect(onSelect).not.toHaveBeenCalled()
    expect(onEdit).not.toHaveBeenCalled()
    const edit = within(row).getByRole('button', { name: 'Edit' })
    fireEvent.keyDown(edit, { key: 'Enter' })
    expect(onSelect).not.toHaveBeenCalled()
    fireEvent.click(edit)
    expect(onEdit).toHaveBeenCalledTimes(1)
    fireEvent.click(within(row).getByRole('button', { name: /Claim .* into governance/ }))
    expect(onClaim).toHaveBeenCalledTimes(1)
    expect(onSelect).not.toHaveBeenCalled()
  })

  it('retains disabled claiming affordance', () => {
    setup({}, true)
    expect(screen.getByRole('button', { name: /Claiming .* into governance/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Claiming .* into governance/ })).toHaveAttribute('aria-busy', 'true')
  })

  it('exposes the full copyable owner email on keyboard focus, not just the team/tenant', () => {
    setup()
    fireEvent.focus(screen.getByRole('button', { name: /Responsibility details/ }))
    const tooltip = screen.getByRole('tooltip')
    expect(tooltip).toHaveTextContent(agent.owner!)
    expect(tooltip.querySelector('.compact-email')?.textContent).toBe(agent.owner)
    expect(tooltip.querySelector('.compact-email wbr')).toBeInTheDocument()
  })

  it('never offers Claim for linked governed rows', () => {
    setup({ record_class: 'resolved', is_registry_linked: true })
    expect(screen.queryByTestId('agent-auto-claim-btn')).not.toBeInTheDocument()
  })

  it('keeps unconfirmed containment visible and exposes secondary facts by keyboard', () => {
    setup()
    expect(screen.getByTestId('kernel-telemetry-unconfirmed-compact-agent')).toBeVisible()
    fireEvent.focus(screen.getByRole('button', { name: /Agent details/ }))
    expect(screen.getByRole('tooltip')).toHaveTextContent('controlplane')
    expect(screen.getByRole('tooltip')).toHaveTextContent('Standard Container')
    expect(screen.getByRole('tooltip')).toHaveTextContent('compact-agent')
  })

  it('keeps kernel/control-plane disagreement visible and suppresses stale lifecycle claims', () => {
    const { row } = setup({ lifecycle_state: 'active', kernel_state: 'frozen', split_brain: ['kernel frozen without stun record'] })
    expect(within(row).getByTestId('kernel-state-badge-compact-agent')).toBeVisible()
    expect(row.querySelector('td:nth-child(4)')).not.toHaveTextContent(/^active$/)
  })

  it('uses concise visible critical labels while retaining full authoritative wording on focus', () => {
    setup({ kernel_state: 'running', split_brain: ['stun record without kernel freeze'], credential_state: { status: 'unknown' } })
    expect(screen.getByTestId('kernel-state-badge-compact-agent')).toHaveTextContent(/^Not frozen$/)
    expect(screen.getByTestId('kernel-telemetry-unconfirmed-compact-agent')).toHaveTextContent(/^Unconfirmed$/)
    expect(screen.getByTestId('compact-credential-state-compact-agent')).toHaveTextContent('Credentials unknown')
    fireEvent.focus(screen.getByRole('button', { name: /Kernel observation details/ }))
    expect(screen.getByRole('tooltip')).toHaveTextContent('NOT FROZEN (stun record only)')
    expect(screen.getByRole('tooltip')).toHaveTextContent('A stun record exists but the kernel cgroup is not frozen')
    fireEvent.keyDown(screen.getByRole('button', { name: /Kernel observation details/ }), { key: 'Escape' })
    fireEvent.focus(screen.getByRole('button', { name: /Containment outcome details/ }))
    expect(screen.getByRole('tooltip')).toHaveTextContent('Requested (Outcome unconfirmed)')
  })

  it('provides one combined narrow More affordance with all agent and secondary metadata', () => {
    const { row } = setup({ runtime: { namespace: 'worker-space', framework: 'kagent', model: 'actual-model', execution_mode: 'autonomous' } })
    const meta = row.querySelector('.compact-agent-meta')!
    expect(meta.querySelectorAll('.compact-agent-details')).toHaveLength(1)
    expect(meta.querySelectorAll('.compact-row-details')).toHaveLength(1)
    fireEvent.focus(within(row).getByRole('button', { name: /Inventory details/ }))
    const tooltip = screen.getByRole('tooltip')
    for (const fact of ['compact-agent', 'Standard Container', 'autonomous', 'worker-space', 'kagent', 'actual-model', agent.owner!, 'controlplane', 'Identity']) expect(tooltip).toHaveTextContent(fact)
  })

  it('keeps the primary assessment bounded to a ratio and posture, with full assessment by focus', () => {
    setup({ compliance_summary: { total_controls: 39, passing: 38, failing: 0, pending: 1, posture_score: .97 } })
    const primary = screen.getByRole('button', { name: /Assessment details/ })
    expect(primary).toHaveTextContent('38/39')
    expect(primary).toHaveTextContent('97%')
    expect(primary).not.toHaveTextContent('passing')
    fireEvent.focus(primary)
    expect(screen.getByRole('tooltip')).toHaveTextContent('38/39 passing')
  })
})
