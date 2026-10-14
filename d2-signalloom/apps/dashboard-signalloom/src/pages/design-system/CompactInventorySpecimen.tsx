import { useState } from 'react'
import { MemoryRouter, useInRouterContext } from 'react-router-dom'
import { AgentTableRow } from '../AgentsPage'
import { CompactOperationalTable } from '../../components/CompactOperationalTable'
import type { AgentResponse } from '../../types/api'
import { isDemoMode } from '../../api/demoMode'

const BASE: AgentResponse = {
  id: 'specimen-normal', name: 'Invoice operator', type: 'Custom', owner: 'ops@example.com', tenant_id: 'tenant-gallery',
  lifecycle_state: 'active', record_class: 'resolved', is_registry_linked: true,
  last_transition_at: '2026-10-14T11:00:00Z', last_transition_by: null, created_at: '2026-10-01T12:00:00Z',
  eu_ai_act_risk_class: 'limited',
  compliance_summary: isDemoMode()
    ? { total_controls: Number('12'), passing: Number('12'), failing: 0, pending: 0, posture_score: Number('1') }
    : { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null },
  runtime: { namespace: 'fe-signalloom-agents', framework: 'kagent', model: 'openai/gpt-4o', execution_mode: 'autonomous' },
  identity: { spiffe_status: 'linked', spiffe_id: 'spiffe://signalloom.local/ns/tenant-gallery/sa/invoice', aliases: [] },
  timestamps: { last_observed_at: '2026-10-14T11:55:00Z' },
}

const ROWS: AgentResponse[] = [
  BASE,
  { ...BASE, id: 'specimen-unknown', name: 'Unassessed discovery', record_class: 'discovered', is_registry_linked: false, owner: null,
    timestamps: {}, compliance_summary: { total_controls: 0, passing: 0, failing: 0, pending: 0, posture_score: null } },
  { ...BASE, id: 'specimen-unconfirmed', name: 'Containment requested', lifecycle_state: 'Suspended',
    credential_state: { status: 'unknown' } },
  { ...BASE, id: 'specimen-critical', name: 'Long operational agent name with authoritative kernel disagreement',
    owner: 'a.very.long.operator.localpart@long-example-domain.signalloom.local',
    kernel_state: 'frozen', split_brain: ['kernel frozen without stun record'], kernel_observed_at: '2026-10-14T11:54:30Z' },
]

/** Same inventory row, CSS, pills, links and disclosures as /agents; no live transports. */
export function CompactInventorySpecimen() {
  const inRouter = useInRouterContext()
  const [interaction, setInteraction] = useState('Hover or focus a dotted detail affordance; Escape dismisses it.')
  if (!inRouter) return <MemoryRouter><CompactInventorySpecimen /></MemoryRouter>
  return <div data-testid="compact-inventory-specimen">
    <p className="compact-secondary">Opt-in compact density. At narrow widths, More retains runtime, responsibility and identity evidence. Fixture timestamps are fixed, not live observations.</p>
    <CompactOperationalTable label="Compact operational inventory specimen">
      <thead><tr>{['Agent', 'Runtime', 'Responsibility', 'Operational State', 'Attention', 'Identity & Evidence', 'Seen', 'Actions'].map(header => <th key={header} aria-label={header === 'Seen' ? 'Observed' : undefined}>{header}</th>)}</tr></thead>
      {ROWS.map(agent => <AgentTableRow key={agent.id} agent={agent} shown claiming={false}
        onSelect={selected => setInteraction(`Evidence selected: ${selected.name}`)}
        onEdit={selected => setInteraction(`Local edit preview: ${selected.name}`)}
        onClaim={selected => setInteraction(`Claim preview only: ${selected.name}. No request sent.`)} />)}
    </CompactOperationalTable>
    <p role="status" data-testid="compact-inventory-interaction" className="compact-secondary">{interaction}</p>
  </div>
}
