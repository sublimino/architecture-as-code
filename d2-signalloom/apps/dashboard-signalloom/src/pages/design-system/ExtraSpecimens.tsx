import { useState, type CSSProperties, type ReactNode } from 'react'
import { MemoryRouter, useInRouterContext } from 'react-router-dom'
import { DelegationAttestationDrawer } from '../../components/DelegationAttestationDrawer'
import { AuthorizationProofDrawer } from '../../components/AuthorizationProofDrawer'
import { WhoAuthorizedPanel } from '../../components/WhoAuthorizedPanel'
import FleetRiskGauge from '../../components/fleet/FleetRiskGauge'
import FleetTopology from '../../components/fleet/FleetTopology'
import { NotificationBell } from '../../components/NotificationBell'
import TriageMenu from '../../components/TriageMenu'
import { CredentialEvidencePanel } from '../../components/CredentialEvidencePanel'
import { IdentityAuditPanel } from '../../components/IdentityAuditPanel'
import ComplianceDrawer from '../../components/ComplianceDrawer'
import SetupBanner from '../../components/onboarding/SetupBanner'
import ProviderConfigureStep from '../../components/onboarding/ProviderConfigureStep'
import DiscoveredWorkloadDrawer from '../../components/DiscoveredWorkloadDrawer'
import SignalBadge from '../../components/SignalBadge'
import EvidenceDrawer from '../../components/EvidenceDrawer'
import OpenFindingsPanel from '../../components/OpenFindingsPanel'
import { TelemetryErrorBoundary } from '../../components/AgentCockpitTelemetry'
import { NodeDetailDrawer } from '../../components/trust/NodeDetailDrawer'
import { TrustGraph } from '../../components/trust/TrustGraph'
import TrustTopologyCanvas from '../../components/trust/TrustTopologyCanvas'
import CredentialActionsMenu from '../../components/CredentialActionsMenu'
import AuditDetailDrawer from '../../components/AuditDetailDrawer'
import AddClusterModal from '../../components/AddClusterModal'
import SyncStatusPill from '../../components/connectors/SyncStatusPill'
import { CurrencyContext } from '../../money/CurrencyContext'
import type { AgentState } from '../../api/fleetApi'
import type { AuthorizationChain, ProvisionalActor } from '../../api/weaveApi'
import type { ConnectorProvider } from '../../types/connectors'
import type { AgentPosture, AuditEventResponse, DiscoveryWorkload } from '../../types/api'
import type { Selection, TrustEdge, TrustNode } from '../../components/trust/trustTypes'
import type { TenantWarning } from '../../hooks/useTenantWarnings'
import { FIXTURE_CURRENCY_CONTEXT_VALUE } from './fixtureCurrency'

export const EXTRA_SPECIMEN_NAMES = [
  'DelegationAttestationDrawer',
  'AuthorizationProofDrawer',
  'WhoAuthorizedPanel',
  'FleetRiskGauge',
  'FleetTopology',
  'NotificationBell',
  'TriageMenu',
  'CredentialEvidencePanel',
  'IdentityAuditPanel',
  'ComplianceDrawer',
  'SetupBanner',
  'ProviderConfigureStep',
  'DiscoveredWorkloadDrawer',
  'SignalBadge',
  'EvidenceDrawer',
  'OpenFindingsPanel',
  'TelemetryErrorBoundary',
  'NodeDetailDrawer',
  'TrustGraph',
  'TrustTopologyCanvas',
  'CredentialActionsMenu',
  'AuditDetailDrawer',
  'AddClusterModal',
  'SyncStatusPill',
] as const satisfies readonly string[]

type SpecimenName = (typeof EXTRA_SPECIMEN_NAMES)[number]
type OverlayName = 'DelegationAttestationDrawer' | 'AuthorizationProofDrawer' | 'ComplianceDrawer' |
  'DiscoveredWorkloadDrawer' | 'EvidenceDrawer' | 'NodeDetailDrawer' | 'AuditDetailDrawer' | 'AddClusterModal'

const CARD: CSSProperties = {
  border: '1px solid var(--border)', borderRadius: 6, background: 'var(--surface)',
  padding: 14, minWidth: 0, overflow: 'auto',
}
const noop = () => undefined

const AUTHORIZATION_CHAIN: AuthorizationChain = {
  action: 'deploy.release', agentIdentity: 'spiffe://signalloom.local/agent/builder',
  actsOnBehalfOf: 'release-manager', principal: 'operator@example.test', decision: 'allow',
  confidence: 0.98, evidenceRefs: ['sha256:gallery-evidence'],
  attestationGitoid: 'gitoid:blob:sha256:gallery-attestation', complete: true,
}

const FLEET_AGENTS: AgentState[] = [
  { id: 'builder', name: 'Build agent', type: 'data-pipeline', team: 'Platform', trustProfile: 'high', state: 'active' },
  { id: 'vault', name: 'Vault agent', type: 'data-vault', team: 'Security', trustProfile: 'medium', state: 'non-compliant', controlFailures: ['SLSA provenance'] },
]

const TRUST_NODES: TrustNode[] = [
  { id: 'platform', label: 'Signal Loom', kind: 'platform', tenant: 'gallery', location: 'in-cluster', x: 180, y: 100, evidence: 'fixture', source: 'design-system fixture', observedAt: '2026-10-13T12:00:00Z', freshness: 'fixture', assurance: 'medium', reason: 'Deterministic gallery root' },
  { id: 'agent', label: 'Build agent', kind: 'agent', parentId: 'platform', tenant: 'gallery', location: 'in-cluster', spiffeId: 'spiffe://signalloom.local/agent/builder', namespace: 'build', x: 480, y: 260, evidence: 'fixture', source: 'design-system fixture', observedAt: '2026-10-13T12:00:00Z', freshness: 'fixture', assurance: 'medium', reason: 'Deterministic gallery workload', verified: true },
]

const TRUST_EDGES: TrustEdge[] = [
  { id: 'platform-agent', from: 'platform', to: 'agent', verb: 'authorizes', plane: 'authorization', decision: 'allowed', evidence: 'fixture', source: 'design-system fixture', observedAt: '2026-10-13T12:00:00Z', freshness: 'fixture', assurance: 'medium', reason: 'Deterministic gallery authorization' },
]

const WORKLOAD: DiscoveryWorkload = {
  id: 'workload-gallery', name: 'Unregistered build worker', source: 'local_k8s', source_label: 'Local Kubernetes',
  namespace: 'build', status: 'in_review', owner: 'platform@example.test', model: 'claude-sonnet',
  last_seen_at: '2026-10-13T12:00:00Z', recommendations: { config: 'recommended', content: 'pass', supply_chain: 'warning', eu_ai_act: 'not_applicable' },
}

const EVIDENCE_ACTOR: ProvisionalActor = {
  id: 'actor-gallery', display_name: 'Provisional build worker', status: 'actionable', confidence: 0.91,
  correlation_keys: ['spiffe://signalloom.local/agent/builder'], created_at: '2026-10-13T11:00:00Z', updated_at: '2026-10-13T12:00:00Z',
  evidence_chain: [
    { observation_id: 'obs-1', layer: 'identity_authorization', fidelity: 'definitive', contribution: 'SPIFFE identity verified', timestamp: '2026-10-13T11:30:00Z' },
    { observation_id: 'obs-2', layer: 'network_egress', fidelity: 'strong', contribution: 'Expected registry egress observed', timestamp: '2026-10-13T11:31:00Z' },
  ],
}

const FINDINGS: AgentPosture[] = [{
  agent_id: 'builder', agent_name: 'Build agent', posture_score: 72,
  results: [{ agent_id: 'builder', control_id: 'SLSA-3', control_name: 'Workload identity', framework_name: 'SLSA', status: 'fail', assessed_at: '2026-10-13T12:00:00Z', evidence_ref: 'sha256:gallery' }],
}]

const AUDIT_EVENT: AuditEventResponse = {
  id: 'audit-gallery', timestamp: '2026-10-13T12:00:00Z', event_type: 'agent.stunned',
  agent_id: 'builder', agent_name: 'Build agent', actor: 'operator@example.test',
  detail: { reason: 'Design-system containment drill', outcome: 'contained' },
  authorizing_principal_id: 'operator@example.test', executing_actor_id: 'builder',
  spiffe_id: 'spiffe://signalloom.local/agent/builder', evidence_ref: 'sha256:gallery-evidence',
}

const PROVIDER: ConnectorProvider = {
  provider_id: 'github', display_name: 'GitHub',
  wizard_config: {
    fields: [{ name: 'organisation', label: 'Organisation', type: 'text', required: true, placeholder: 'controlplane' }],
    permissions: ['read:org'], docs_link: '/help/connectors/github', help_text: 'Connect a read-only organisation inventory.',
  },
}

const WARNINGS: TenantWarning[] = [{
  id: 'warning-gallery', timestamp: '2026-10-13T12:00:00Z', event_type: 'policy_violation',
  agent_id: 'builder', agent_name: 'Build agent', actor: 'policy-engine', detail: { summary: 'Unsigned artifact rejected' },
}]

const DEFERRALS = [
  ['ClaimModal', 'Uses useAuth0 and directly calls claimDiscoveredAgent/api.claimAgent on submit; no transport prop injection seam exists.'],
  ['SignalFusionDemoControls', 'Mount effect calls getAccessTokenSilently then fetchSignalFusionSteps; no fixture or transport prop exists.'],
  ['AgentEvidenceDrawer', 'Mounting an agent creates AgentRiskSection, whose useAgentRisk hook fetches quantitative risk; no data prop seam exists.'],
  ['OnboardingWizard', 'Mount effects read authentication, AppContext, onboarding APIs, routing state, and persisted tenant state; no state/transport injection seam exists.'],
  ['AgentCockpitSection', 'Always invokes useEstateTelemetry and renders the live telemetry container; no pods or telemetry hook injection seam exists.'],
  ['RbacImporterPanel', 'Owns AFM import API requests and has only an onImported notification prop; no fetcher or initial-data seam exists.'],
  ['SuperCredInstructorPanel', 'Owns demo-runner status, start, reset, and log streaming API calls; no transport seam exists.'],
  ['AgentCockpitTelemetry', 'Always invokes useAgentTelemetry for streaming/polling; the pure AgentCockpitTelemetryView already has a core specimen.'],
  ['CookieSettingsModal', 'Mount effect calls api.cookiePreferences.get and Save calls patch; neither client nor initial preferences are injectable.'],
  ['MetricsTopBar', 'Always invokes useEstateTelemetry; the pure MetricsTopBarView already has a core specimen.'],
  ['ConsentModal', 'Mounts legal iframes from VITE_LEGAL_BASE_URL and installs global consent message handling; legal sources are not injectable even though onAccept is.'],
  ['KeyboardShortcutsOverlay', 'Mounting the closed component installs a global window keydown listener, so CSS Lab editor keystrokes could open it; no ownerDocument or controlled-open seam exists.'],
] as const

function FixtureRouter({ children }: { children: ReactNode }) {
  const hasParentRouter = useInRouterContext()
  return hasParentRouter ? <>{children}</> : <MemoryRouter>{children}</MemoryRouter>
}

function Specimen({ name, source, children }: { name: SpecimenName; source: string; children: ReactNode }) {
  return <fieldset data-testid={`extra-specimen-${name}`} data-source={source} style={{ ...CARD, margin: 0 }}><legend style={{ padding: '0 6px' }}><strong>{name}</strong><code style={{ marginLeft: 8, color: 'var(--muted)', fontSize: 10 }}>{source}</code></legend>{children}</fieldset>
}

function OverlayButton({ name, setActive }: { name: OverlayName; setActive: (name: OverlayName) => void }) {
  return <button type="button" className="btn btn-secondary" onClick={() => setActive(name)}>Open {name} specimen</button>
}

export function ExtraSpecimens() {
  const [active, setActive] = useState<OverlayName | null>(null)
  const [selection, setSelection] = useState<Selection>({ type: 'node', id: 'agent' })
  const close = () => setActive(null)
  const selectNode = (id: string) => setSelection({ type: 'node', id })
  const selectEdge = (id: string) => setSelection({ type: 'edge', id })

  return (
    <section data-testid="extra-specimens" aria-labelledby="extra-specimens-title">
      <h2 id="extra-specimens-title" style={{ fontSize: 16, color: 'var(--text)' }}>Additional component specimens</h2>
      <p style={{ color: 'var(--muted)', fontSize: 12 }}>Production components driven by fixed props or component-local state only.</p>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 360px), 1fr))', gap: 12 }}>
        <Specimen name="DelegationAttestationDrawer" source="components/DelegationAttestationDrawer.tsx">
          <OverlayButton name="DelegationAttestationDrawer" setActive={setActive} />
          <DelegationAttestationDrawer isOpen={active === 'DelegationAttestationDrawer'} onClose={close} attestation={{ actionId: 'gallery-action-01', timestamp: '2026-10-13T12:00:00Z', landlockStatus: { enabled: true, profile: 'gallery-read-only', abi: 3 }, rawPayload: { outcome: 'verified' } }} />
        </Specimen>
        <Specimen name="AuthorizationProofDrawer" source="components/AuthorizationProofDrawer.tsx">
          <OverlayButton name="AuthorizationProofDrawer" setActive={setActive} />
          <AuthorizationProofDrawer isOpen={active === 'AuthorizationProofDrawer'} onClose={close} actionId="gallery-action-01" chain={AUTHORIZATION_CHAIN} evidenceRef="sha256:gallery-evidence" />
        </Specimen>
        <Specimen name="WhoAuthorizedPanel" source="components/WhoAuthorizedPanel.tsx"><WhoAuthorizedPanel chain={AUTHORIZATION_CHAIN} compact hideHeaderControls /></Specimen>
        <Specimen name="FleetRiskGauge" source="components/fleet/FleetRiskGauge.tsx"><CurrencyContext.Provider value={FIXTURE_CURRENCY_CONTEXT_VALUE}><FleetRiskGauge ale={185_000} var95={420_000} previousAle={210_000} trend="down" currency="GBP" carriedGbp={145_000} sourceLabel="design-system fixture" /></CurrencyContext.Provider></Specimen>
        <Specimen name="FleetTopology" source="components/fleet/FleetTopology.tsx"><div style={{ width: '100%', height: 460 }}><FleetTopology agents={FLEET_AGENTS} edges={[{ from: 'builder', to: 'vault' }]} audience /></div></Specimen>
        <Specimen name="NotificationBell" source="components/NotificationBell.tsx"><FixtureRouter><NotificationBell warnings={WARNINGS} unreadWarnings={WARNINGS} unreadCount={1} onMarkAsRead={noop} onMarkAllAsRead={noop} token="gallery-fixture-token" /></FixtureRouter></Specimen>
        <Specimen name="TriageMenu" source="components/TriageMenu.tsx"><TriageMenu accountId="gallery-account" onAction={noop} /></Specimen>
        <Specimen name="CredentialEvidencePanel" source="components/CredentialEvidencePanel.tsx"><CredentialEvidencePanel autoLoad={false} fetcher={async () => { throw new Error('Gallery fetcher must not run') }} /></Specimen>
        <Specimen name="IdentityAuditPanel" source="components/IdentityAuditPanel.tsx"><IdentityAuditPanel events={[{ id: 'identity-gallery', timestamp: '2026-10-13T12:00:00Z', operation: 'svid_issuance', path: 'spire/agent/workload', spiffeId: 'spiffe://signalloom.local/agent/builder', agentRole: 'builder', accessor: 'hmac-gallery', leaseDuration: '300s' }]} activeLeasesCount={1} /></Specimen>
        <Specimen name="ComplianceDrawer" source="components/ComplianceDrawer.tsx">
          <OverlayButton name="ComplianceDrawer" setActive={setActive} />
          <ComplianceDrawer open={active === 'ComplianceDrawer'} onClose={close} item={{ frameworkName: 'SLSA gallery baseline', frameworkVersion: '1.0', totalChecks: 2, passedChecks: 1, failedChecks: 1, postureScore: 50, policyVersion: 'gallery-1', evidenceHashes: ['sha256:gallery'], remediation: 'Attach signed provenance.' }} />
        </Specimen>
        <Specimen name="SetupBanner" source="components/onboarding/SetupBanner.tsx"><FixtureRouter><SetupBanner connectedCount={2} totalCount={4} onContinue={noop} /></FixtureRouter></Specimen>
        <Specimen name="ProviderConfigureStep" source="components/onboarding/ProviderConfigureStep.tsx"><FixtureRouter><ProviderConfigureStep provider={PROVIDER} submitting={false} onSubmit={noop} onBack={noop} onSkipProvider={noop} /></FixtureRouter></Specimen>
        <Specimen name="DiscoveredWorkloadDrawer" source="components/DiscoveredWorkloadDrawer.tsx">
          <OverlayButton name="DiscoveredWorkloadDrawer" setActive={setActive} />
          <DiscoveredWorkloadDrawer isOpen={active === 'DiscoveredWorkloadDrawer'} workload={WORKLOAD} onClose={close} onEnroll={noop} onDismiss={noop} />
        </Specimen>
        <Specimen name="SignalBadge" source="components/SignalBadge.tsx"><SignalBadge observationCount={7} highestFidelity="definitive" layerCount={3} actorStatus="actionable" testId="extra-signal-badge" /></Specimen>
        <Specimen name="EvidenceDrawer" source="components/EvidenceDrawer.tsx"><OverlayButton name="EvidenceDrawer" setActive={setActive} /><EvidenceDrawer actor={active === 'EvidenceDrawer' ? EVIDENCE_ACTOR : null} onClose={close} /></Specimen>
        <Specimen name="OpenFindingsPanel" source="components/OpenFindingsPanel.tsx"><OpenFindingsPanel agents={FINDINGS} /></Specimen>
        <Specimen name="TelemetryErrorBoundary" source="components/AgentCockpitTelemetry.tsx"><TelemetryErrorBoundary podName="gallery-agent-0"><div data-testid="extra-telemetry-boundary-child">Telemetry renderer boundary child</div></TelemetryErrorBoundary></Specimen>
        <Specimen name="NodeDetailDrawer" source="components/trust/NodeDetailDrawer.tsx"><OverlayButton name="NodeDetailDrawer" setActive={setActive} /><FixtureRouter><NodeDetailDrawer node={TRUST_NODES[1]} isOpen={active === 'NodeDetailDrawer'} onClose={close} nodesById={new Map(TRUST_NODES.map((node) => [node.id, node]))} /></FixtureRouter></Specimen>
        <Specimen name="TrustGraph" source="components/trust/TrustGraph.tsx"><div data-testid="extra-trust-graph-size" style={{ width: '100%', height: 480 }}><TrustGraph nodes={TRUST_NODES} edges={TRUST_EDGES} selected={selection} onSelectNode={selectNode} onSelectEdge={selectEdge} /></div></Specimen>
        <Specimen name="TrustTopologyCanvas" source="components/trust/TrustTopologyCanvas.tsx"><div data-testid="extra-trust-canvas-size" style={{ width: '100%', height: 480 }}><TrustTopologyCanvas nodes={TRUST_NODES} edges={TRUST_EDGES} selected={selection} onSelectNode={selectNode} onSelectEdge={selectEdge} /></div></Specimen>
        <Specimen name="CredentialActionsMenu" source="components/CredentialActionsMenu.tsx"><CredentialActionsMenu onIssue={noop} onRevoke={noop} /></Specimen>
        <Specimen name="AuditDetailDrawer" source="components/AuditDetailDrawer.tsx"><OverlayButton name="AuditDetailDrawer" setActive={setActive} /><FixtureRouter><AuditDetailDrawer isOpen={active === 'AuditDetailDrawer'} event={AUDIT_EVENT} onClose={close} /></FixtureRouter></Specimen>
        <Specimen name="AddClusterModal" source="components/AddClusterModal.tsx"><OverlayButton name="AddClusterModal" setActive={setActive} />{active === 'AddClusterModal' && <AddClusterModal onAdd={noop} onClose={close} />}</Specimen>
        <Specimen name="SyncStatusPill" source="components/connectors/SyncStatusPill.tsx">
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            <SyncStatusPill tone="teal" label="Synced" />
            <SyncStatusPill tone="cyan" label="Live" />
            <SyncStatusPill tone="violet" label="Discovered" />
            <SyncStatusPill tone="amber" label="Not yet scanned" />
            <SyncStatusPill tone="red" label="Sync error" />
            <SyncStatusPill tone="muted" label="Not configured" />
          </div>
        </Specimen>
      </div>
      <div data-testid="extra-deferrals" style={{ display: 'grid', gap: 8, marginTop: 16 }}>
        {DEFERRALS.map(([name, reason]) => <aside key={name} data-testid={`extra-deferral-${name}`} className="card" style={{ borderColor: 'var(--amber)', color: 'var(--muted)', fontSize: 12 }}><strong style={{ color: 'var(--amber)' }}>{name} deferred:</strong> {reason}</aside>)}
      </div>
    </section>
  )
}

export default ExtraSpecimens
