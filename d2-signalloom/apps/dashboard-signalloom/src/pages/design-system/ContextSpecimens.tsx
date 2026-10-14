import type { IngestRateBucket, PolicyFinding } from '../../api/policyApi'
import FindingsList from '../../components/signals/FindingsList'
import SourceTable from '../../components/signals/SourceTable'
import WindowSelector from '../../components/signals/WindowSelector'
import { LabelChips } from '../../components/signals/presentation'
import type { AgentResponse } from '../../types/api'
import {
  CollaboratorGainsLinks,
  GroupMembersLink,
  SubjectAgentLink,
} from '../CollusionAccessPage'
import { RoleBadge, StatusIndicator } from '../admin/UserTable'

const FINDINGS: PolicyFinding[] = [{
  id: 'finding-gallery-1',
  timestamp: '2026-10-13T20:04:12Z',
  tenant_id: 'tenant-gallery',
  actor: 'agent-ci-runner',
  layer: 'identity_authorization',
  source_observation_id: 'observation-gallery-1',
  rule_id: 'unexpected-role-binding',
  bundle_id: 'signal-loom-defaults',
  bundle_version: '1.4.2',
  severity: 'high',
  mode: 'enforce',
  labels: { namespace: 'ci', environment: 'demo' },
}]

const RATES: IngestRateBucket[] = [
  { bucket_start: '2026-10-13T20:03:00Z', layer: 'identity_authorization', source: 'kubernetes-audit', count: 8 },
  { bucket_start: '2026-10-13T20:04:00Z', layer: 'identity_authorization', source: 'kubernetes-audit', count: 5 },
]

const AGENTS: AgentResponse[] = [{
  id: 'agent-ci-runner',
  name: 'CI Runner Agent',
  type: 'Signal Loom Built',
  tenant_id: 'tenant-gallery',
  service_account: 'ci/runner',
  lifecycle_state: 'Governed',
  last_transition_at: null,
  eu_ai_act_risk_class: null,
  compliance_summary: {
    total_controls: 10,
    passing: 10,
    failing: 0,
    pending: 0,
    posture_score: 100,
  },
  created_at: '2026-10-13T20:00:00Z',
}]

/** Safe, deterministic examples that need realistic domain props but no providers. */
export function ContextSpecimens() {
  return (
    <section id="context-examples" data-testid="context-specimens" style={{ display: 'grid', gap: 18 }}>
      <div>
        <h3 style={{ fontSize: 13, margin: '0 0 8px', color: 'var(--text)' }}>Signal controls and evidence</h3>
        <div style={{ display: 'grid', gap: 12 }}>
          <WindowSelector value="30m" onChange={() => undefined} />
          <LabelChips labels={{ namespace: 'ci', environment: 'demo' }} />
          <FindingsList findings={FINDINGS} />
          <SourceTable rates={RATES} />
        </div>
      </div>

      <div>
        <h3 style={{ fontSize: 13, margin: '0 0 8px', color: 'var(--text)' }}>Administration indicators</h3>
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
          <RoleBadge role="admin" isSuperadmin />
          <StatusIndicator status="active" />
        </div>
      </div>

      <div>
        <h3 style={{ fontSize: 13, margin: '0 0 8px', color: 'var(--text)' }}>Collusion subject links</h3>
        <div style={{ display: 'grid', gap: 8, color: 'var(--text)' }}>
          <SubjectAgentLink subject="sa:ci/runner" agents={AGENTS} testId="context-subject-link" />
          <GroupMembersLink group="group:developers, sa:ci/runner" agents={AGENTS} testIdPrefix="context-group-members" />
          <CollaboratorGainsLinks
            text="sa:ci/runner: bind role:flux-reconciler"
            agents={AGENTS}
            testIdPrefix="context-collaborator-gains"
          />
        </div>
      </div>
    </section>
  )
}
