import { useState, type CSSProperties, type ReactNode } from 'react'
import ConversionNote from '../../components/ConversionNote'
import { CycleDetectedWarning } from '../../components/CycleDetectedWarning'
import { DelegationChainNode } from '../../components/DelegationChainNode'
import { DelegationEventFilter } from '../../components/DelegationEventFilter'
import PolicyEditor from '../../components/PolicyEditor'
import RiskWidget, { SourceBadge } from '../../components/RiskWidget'
import { KernelStateBadge } from '../../components/StatusBadge'
import StreamingLogBlock from '../../components/StreamingLogBlock'
import GovernancePolicyTable from '../../components/GovernancePolicyTable'
import { PlaneOutcomeTable, PlaneStrip, StunOverallHeadline } from '../../components/StunPlanes'
import StunReasonForm from '../../components/StunReasonForm'
import { CodingAgentCard } from '../../components/CodingAgentCard'
import { AgentSuperFilterTable } from '../../components/AgentSuperFilterTable'
import { AgentCockpitTelemetryView } from '../../components/AgentCockpitTelemetry'
import { MetricsTopBarView } from '../../components/MetricsTopBar'
import {
  AlertLink,
  ArrowIcon,
  Avatar,
  BellIcon,
  ChevronIcon,
  Chip,
  HeaderFrame,
  Mark,
  SearchIcon,
  SeverityDot,
  SeverityTag,
  UnreadPill,
} from '../../components/headers/primitives'
import { ALERTS } from '../../components/headers/alerts'
import RoleViewSelector, { type FleetRole } from '../../components/fleet/RoleViewSelector'
import FleetBadge, { stateToken } from '../../components/fleet/FleetBadge'
import ConfirmDialog from '../../components/ConfirmDialog'
import type { Column } from '../../components/DataTable'
import type { PlaneResult } from '../../types/api'
import type { PolicyBundle } from '../../types/policies'
import type { StoredRecord, ToolCounts } from '../../types/codingAgent'
import type { TelemetrySample } from '../../api/agentTelemetry'

export const CORE_SPECIMEN_NAMES = [
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
  'GovernancePolicyTable',
] as const satisfies readonly string[]

const SPECIMEN_STYLE: CSSProperties = {
  border: '1px solid var(--border)',
  borderRadius: 6,
  background: 'var(--surface)',
  padding: 14,
  minWidth: 220,
  overflow: 'auto',
}

const POLICY_FIXTURE: PolicyBundle = {
  id: 'bundle-gallery',
  framework_id: 'gallery-baseline',
  version: '1.0.0',
  author: 'design-system',
  description: 'Read-only deterministic policy specimen.',
  created_at: '2026-10-13T12:00:00Z',
  checksum: 'sha256:gallery-policy',
  status: 'active',
  rules: [
    {
      id: 'require-non-root',
      name: 'Require non-root execution',
      description: 'Workloads must explicitly reject root execution.',
      cel_expression: 'agent.security.runAsNonRoot == true',
      severity: 'high',
      remediation: 'Set securityContext.runAsNonRoot to true.',
      status: 'active',
    },
  ],
}

const PLANES: PlaneResult[] = [
  { plane: 'freeze', outcome: 'contained', timestamp: '2026-10-13T12:00:00Z', latency_ms: 18 },
  { plane: 'bao', outcome: 'contained', timestamp: '2026-10-13T12:00:01Z', latency_ms: 42 },
  { plane: 'mesh', outcome: 'partial', timestamp: '2026-10-13T12:00:02Z', error: 'One stale route remains', latency_ms: 65 },
]

const TOOL_COUNTS: ToolCounts = {
  view_file: 9,
  write_to_file: 1,
  replace_file_content: 0,
  run_command: 3,
  grep_search: 2,
  find_by_name: 1,
  list_dir: 1,
  read_url_content: 0,
  search_web: 0,
  invoke_subagent: 0,
  send_message: 0,
  manage_task: 1,
  ask_question: 0,
  other_count: 0,
}

const CODING_AGENT_FIXTURE: StoredRecord = {
  event: {
    schema_version: '1.0.0',
    harness: 'opencode',
    session_id: 'session-gallery-01',
    timestamp: '2026-10-13T12:00:00Z',
    process: { pid: 4242, ppid: 4000, comm: 'opencode', rss_bytes: 134_217_728, cpu_ticks: 1250 },
    kanban: { task_id: 'gallery-01', shortcode: 'CORE', role: 'implementation', elapsed_s: 184 },
    metrics: { step_count: 12, tokens_in: 8200, tokens_out: 2100, tool_counts: TOOL_COUNTS },
    network: { inference_endpoint: 'vertex-ai', egress_bytes: 24_576 },
  },
  observed_at: '2026-10-13T12:00:01Z',
  clock_skew_ms: 4,
  deduplication_key: 'gallery-agent-01',
  ingested_at: '2026-10-13T12:00:02Z',
  tenant_id: 'tenant-gallery',
  subject: 'spiffe://signalloom.local/agent/gallery',
}

const TELEMETRY_SAMPLES: TelemetrySample[] = [
  { podName: 'gallery-agent-0', namespace: 'tenant-gallery', ts: 1000, cpuMillicores: 1.2, memoryRssMiB: 42, frozen: false },
  { podName: 'gallery-agent-0', namespace: 'tenant-gallery', ts: 3000, cpuMillicores: 18.4, memoryRssMiB: 44, frozen: false },
]

interface AgentRow {
  id: string
  name: string
  state: string
  framework: string
  source: string
  namespace: string
  owner: string
  requiresAttention: boolean
}

const AGENT_ROWS: AgentRow[] = [
  { id: 'agent-build', name: 'build-agent', state: 'governed', framework: 'SLSA', source: 'cluster', namespace: 'build', owner: 'platform', requiresAttention: false },
  { id: 'agent-audit', name: 'audit-agent', state: 'suspended', framework: 'SOC 2', source: 'discovery', namespace: 'audit', owner: 'security', requiresAttention: true },
]

const AGENT_COLUMNS: Column<AgentRow>[] = [
  { key: 'name', label: 'Agent', sortable: true },
  { key: 'state', label: 'State', sortable: true },
  { key: 'owner', label: 'Owner', sortable: true },
]

function Specimen({ name, source, children }: { name: (typeof CORE_SPECIMEN_NAMES)[number]; source: string; children: ReactNode }) {
  return (
    <fieldset data-testid={`core-specimen-${name}`} data-source={source} style={{ ...SPECIMEN_STYLE, margin: 0 }}>
      <legend style={{ padding: '0 6px' }}>
        <strong style={{ color: 'var(--text)', fontSize: 12 }}>{name}</strong>
        <code style={{ color: 'var(--muted)', fontSize: 10, marginLeft: 8 }}>{source}</code>
      </legend>
      {children}
    </fieldset>
  )
}

function DelegationEventFilterSpecimen() {
  const [selectedType, setSelectedType] = useState('all')
  const [minHops, setMinHops] = useState(0)
  return (
    <DelegationEventFilter
      selectedType={selectedType}
      onSelectType={setSelectedType}
      availableTypes={['delegated', 'revoked']}
      minHops={minHops}
      onMinHopsChange={setMinHops}
      onReset={() => { setSelectedType('all'); setMinHops(0) }}
      filteredCount={selectedType === 'all' ? 2 : 1}
      totalCount={2}
    />
  )
}

function RoleViewSelectorSpecimen() {
  const [role, setRole] = useState<FleetRole>('admin')
  return <RoleViewSelector activeRole={role} onRoleChange={setRole} testId="core-role-selector" />
}

function StunReasonFormSpecimen() {
  const [reason, setReason] = useState('No local action submitted')
  return (
    <>
      <StunReasonForm agentName="gallery-agent" onConfirm={setReason} onCancel={() => setReason('Cancelled locally')} />
      <p data-testid="core-stun-reason-result" style={{ color: 'var(--muted)', fontSize: 12 }}>{reason}</p>
    </>
  )
}

function ConfirmDialogSpecimen() {
  const [open, setOpen] = useState(false)
  const [result, setResult] = useState('Not confirmed')
  return (
    <>
      <button type="button" className="btn btn-secondary" onClick={() => setOpen(true)}>Open confirmation specimen</button>
      <span data-testid="core-confirm-result" style={{ marginLeft: 8, color: 'var(--muted)', fontSize: 12 }}>{result}</span>
      {open && (
        <ConfirmDialog
          title="Confirm local specimen"
          body="This changes only state inside the design-system specimen."
          confirmLabel="Confirm locally"
          onCancel={() => setOpen(false)}
          onConfirm={() => { setResult('Confirmed locally'); setOpen(false) }}
        />
      )}
    </>
  )
}

export function CoreSpecimens() {
  return (
    <section data-testid="core-specimens" aria-labelledby="core-specimens-title">
      <h2 id="core-specimens-title" style={{ fontSize: 16, color: 'var(--text)' }}>Core component specimens</h2>
      <p style={{ color: 'var(--muted)', fontSize: 12 }}>
        Fixed props and component-local state only. These specimens do not call application APIs.
      </p>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 320px), 1fr))', gap: 12 }}>
        <Specimen name="ConversionNote" source="components/ConversionNote.tsx">
          <ConversionNote note="Converted GBP to USD at 1.2658 using the 2026-10-01 checked-in rate table." testId="core-conversion-note" />
        </Specimen>
        <Specimen name="CycleDetectedWarning" source="components/CycleDetectedWarning.tsx">
          <CycleDetectedWarning message="Circular delegation stopped safely." cyclePath={['planner', 'builder', 'planner']} />
        </Specimen>
        <Specimen name="DelegationChainNode" source="components/DelegationChainNode.tsx">
          <DelegationChainNode hopIndex={1} totalHops={2} actorId="builder" label="Build agent" role="implementation" spiffeId="spiffe://signalloom.local/agent/builder" authzRef="policy/gallery" validFrom="2026-10-13T12:00:00Z" containmentEvidenced />
        </Specimen>
        <Specimen name="DelegationEventFilter" source="components/DelegationEventFilter.tsx"><DelegationEventFilterSpecimen /></Specimen>
        <Specimen name="PolicyEditor" source="components/PolicyEditor.tsx"><PolicyEditor bundle={POLICY_FIXTURE} readOnly /></Specimen>
        <Specimen name="RiskWidget" source="components/RiskWidget.tsx">
          <RiskWidget title="Gallery FAIR exposure" lef={{ min: 0.01, mode: 0.05, max: 0.2 }} lossMagnitude={{ amount: 120000, currency: 'GBP' }} pml={{ amount: 260000, currency: 'GBP' }} ale={{ amount: 18500, currency: 'GBP' }} source="fixture" locale="en-GB" testId="core-risk" />
        </Specimen>
        <Specimen name="SourceBadge" source="components/RiskWidget.tsx"><SourceBadge source="fixture" testId="core-source-badge" /></Specimen>
        <Specimen name="KernelStateBadge" source="components/StatusBadge.tsx"><KernelStateBadge view={{ kernel_state: 'frozen', kernel_observed_at: '2026-10-13T12:00:00Z', split_brain: [] }} testId="core-kernel-badge" /></Specimen>
        <Specimen name="StreamingLogBlock" source="components/StreamingLogBlock.tsx"><StreamingLogBlock log={'policy verified\ncontainment complete'} title="Gallery containment" status="succeeded" statusTone="var(--teal)" label="Gallery run log" testId="core-streaming-log" /></Specimen>
        <Specimen name="PlaneOutcomeTable" source="components/StunPlanes.tsx"><PlaneOutcomeTable planes={PLANES} /></Specimen>
        <Specimen name="PlaneStrip" source="components/StunPlanes.tsx"><PlaneStrip planes={PLANES} testId="core-plane-strip" /></Specimen>
        <Specimen name="StunOverallHeadline" source="components/StunPlanes.tsx"><StunOverallHeadline outcome="partial" /></Specimen>
        <Specimen name="StunReasonForm" source="components/StunReasonForm.tsx"><StunReasonFormSpecimen /></Specimen>
        <Specimen name="CodingAgentCard" source="components/CodingAgentCard.tsx"><CodingAgentCard record={CODING_AGENT_FIXTURE} selected /></Specimen>
        <Specimen name="AgentSuperFilterTable" source="components/AgentSuperFilterTable.tsx">
          <AgentSuperFilterTable
            data={AGENT_ROWS}
            columns={AGENT_COLUMNS}
            testId="core-agent-super-filter"
            pageSize={5}
            extractFields={(row) => row}
            renderRow={(row) => <tr key={row.id}><td>{row.name}</td><td>{row.state}</td><td>{row.owner}</td></tr>}
          />
        </Specimen>
        <Specimen name="AgentCockpitTelemetryView" source="components/AgentCockpitTelemetry.tsx"><AgentCockpitTelemetryView podName="gallery-agent-0" samples={TELEMETRY_SAMPLES} connection="live" /></Specimen>
        <Specimen name="MetricsTopBarView" source="components/MetricsTopBar.tsx"><MetricsTopBarView summary={{ total: 3, active: 2, stunned: 1, totalCpuMillicores: 19.6 }} connection="live" /></Specimen>
        <Specimen name="AlertLink" source="components/headers/primitives.tsx"><AlertLink alert={ALERTS[0]} showHref /></Specimen>
        <Specimen name="ArrowIcon" source="components/headers/primitives.tsx"><span aria-label="Continue"><ArrowIcon /></span></Specimen>
        <Specimen name="Avatar" source="components/headers/primitives.tsx"><span aria-label="Operator A"><Avatar initial="A" /></span></Specimen>
        <Specimen name="BellIcon" source="components/headers/primitives.tsx"><span aria-label="Notifications"><BellIcon /></span></Specimen>
        <Specimen name="ChevronIcon" source="components/headers/primitives.tsx"><span aria-label="Expanded"><ChevronIcon open /></span></Specimen>
        <Specimen name="Chip" source="components/headers/primitives.tsx"><Chip label="mode" value="fixture" tone="accent" testId="core-header-chip" /></Specimen>
        <Specimen name="HeaderFrame" source="components/headers/primitives.tsx"><HeaderFrame testId="core-header-frame"><div style={{ padding: 12 }}><Mark label="Specimen header" /></div></HeaderFrame></Specimen>
        <Specimen name="Mark" source="components/headers/primitives.tsx"><Mark /></Specimen>
        <Specimen name="SearchIcon" source="components/headers/primitives.tsx"><span aria-label="Search"><SearchIcon /></span></Specimen>
        <Specimen name="SeverityDot" source="components/headers/primitives.tsx"><span aria-label="Critical severity"><SeverityDot severity="critical" /></span></Specimen>
        <Specimen name="SeverityTag" source="components/headers/primitives.tsx"><SeverityTag severity="warning" /></Specimen>
        <Specimen name="UnreadPill" source="components/headers/primitives.tsx"><span aria-label="12 unread notifications"><UnreadPill count={12} testId="core-unread-pill" /></span></Specimen>
        <Specimen name="RoleViewSelector" source="components/fleet/RoleViewSelector.tsx"><RoleViewSelectorSpecimen /></Specimen>
        <Specimen name="FleetBadge" source="components/fleet/FleetBadge.tsx"><FleetBadge label="active" token={stateToken('active')} testId="core-fleet-badge" /></Specimen>
        <Specimen name="ConfirmDialog" source="components/ConfirmDialog.tsx"><ConfirmDialogSpecimen /></Specimen>
        <Specimen name="GovernancePolicyTable" source="components/GovernancePolicyTable.tsx">
          <GovernancePolicyTable
            frameworkId="k8s-cis"
            testId="core-governance-policy-table"
            rules={[
              {
                id: 'CIS-5.1.6',
                name: 'CIS 5.1.6 ServiceAccount Tokens Mounted Only Where Necessary',
                description: 'ServiceAccount tokens should only be mounted where necessary to reduce lateral movement risk across tenant workloads.',
                cel_expression: 'object.spec.automountServiceAccountToken == false',
                severity: 'critical',
                remediation: 'Set automountServiceAccountToken to false.',
                attestation_type: 'cel',
                manual_attestation: false,
              },
              {
                id: 'CIS-5.2.2',
                name: 'CIS 5.2.2 Minimize Admission of Privileged Containers',
                description: 'Privileged containers have root capabilities on the host and must be forbidden across agent workloads.',
                cel_expression: 'object.spec.containers.all(c, !has(c.securityContext.privileged) || c.securityContext.privileged == false)',
                severity: 'high',
                remediation: 'Set securityContext.privileged to false.',
                attestation_type: 'cel',
                manual_attestation: false,
              },
              {
                id: 'attestation-annex-iv',
                name: 'Annex IV: Architecture & Threat Model Dossier',
                description: 'Formal architectural documentation attestation signed by designated compliance lead.',
                cel_expression: 'true',
                severity: 'medium',
                remediation: 'Attach signed annex IV dossier.',
                attestation_type: 'manual',
                manual_attestation: true,
                manual_attestation_note: 'Signed by compliance lead',
              },
            ]}
          />
        </Specimen>
      </div>
    </section>
  )
}

export default CoreSpecimens
