import { useMemo, useState } from 'react'
import { Section, StatCard } from '../components/DashKit'

export type EvidenceState = 'observed' | 'modeled' | 'fixture' | 'stale'
export type EnforcementPlane = 'identity' | 'authorization' | 'network' | 'external'
type TopologyPlane = EnforcementPlane | 'evidence'
type Location = 'in-cluster' | 'external'
type Decision = 'allowed' | 'denied' | 'neutral'

type Provenance = {
  evidence: EvidenceState
  source: string
  observedAt: string
  freshness: 'fixture' | 'unknown' | 'stale'
  assurance: 'medium' | 'lower'
  reason: string
}

type ExternalTrust = {
  providerAssertion?: string
  keyCustody?: string
  rotationReload?: string
  trustBundle?: string
  deEnrollment?: string
  productionGap?: string
}

export type TrustNode = Provenance & ExternalTrust & {
  id: string; label: string; kind: 'platform' | 'tenant' | 'project' | 'agent' | 'service'
  parentId?: string; tenant: string; location: Location; spiffeId?: string; namespace?: string
  serviceAccount?: string; selectors?: string[]; baoRole?: string; baoPath?: string; audience?: string
  ttl?: string; policyRef?: string; x: number; y: number
}

export type TrustEdge = Provenance & {
  id: string; from: string; to: string; verb: string; plane: EnforcementPlane; decision: Decision
  denialKind?: 'network-block' | 'application-authorization-rejection'
  baoRole?: string; baoPath?: string; audience?: string; ttl?: string; policyRef?: string
}

const modeled = { evidence: 'modeled' as const, source: 'Trust contract model', observedAt: 'Not runtime-observed', freshness: 'unknown' as const, assurance: 'medium' as const }
const fixture = { evidence: 'fixture' as const, source: 'Fixture-tested topology contract', observedAt: 'Fixture test 2026-08-02T19:40:00Z', freshness: 'fixture' as const, assurance: 'medium' as const }
const external = { ...modeled, assurance: 'lower' as const, reason: 'Modeled external boundary; no runtime attestation ingested' }
const spiffe = (tenant: string, project: string, agent: string) => `spiffe://signalloom.demo/platform/signalloom/tenant/${tenant}/project/${project}/agent/${agent}`

export const trustNodes: TrustNode[] = [
  { id: 'platform', label: 'Signal Loom platform', kind: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled platform root of trust', x: 500, y: 58 },
  { id: 'acme', label: 'Acme tenant', kind: 'tenant', parentId: 'platform', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled tenant boundary', x: 250, y: 150 },
  { id: 'northstar', label: 'Northstar tenant', kind: 'tenant', parentId: 'platform', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled tenant boundary', x: 750, y: 150 },
  { id: 'acme-payments', label: 'Acme Payments', kind: 'project', parentId: 'acme', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-acme-payments', x: 135, y: 255 },
  { id: 'acme-risk', label: 'Acme Risk', kind: 'project', parentId: 'acme', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-acme-risk', x: 350, y: 255 },
  { id: 'northstar-investigations', label: 'Northstar Investigations', kind: 'project', parentId: 'northstar', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-northstar-investigations', x: 750, y: 255 },
  { id: 'spire', label: 'SPIRE issuer', kind: 'service', parentId: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled SPIFFE issuer', x: 510, y: 190 },
  { id: 'openbao', label: 'OpenBao', kind: 'service', parentId: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled SuperCredential exchange broker', baoPath: 'auth/jwt/login', audience: 'openbao-supercredential', ttl: '5m', x: 510, y: 340 },
  { id: 'planner', label: 'planner', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-tested A2A caller', spiffeId: spiffe('acme', 'payments', 'planner'), namespace: 'agent-trust-acme-payments', serviceAccount: 'agent-trust-planner', selectors: ['k8s:ns:agent-trust-acme-payments', 'k8s:sa:agent-trust-planner'], baoRole: 'agent-trust-planner', baoPath: 'kv/data/signalloom/agent-trust/acme/payments/*', audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-payments', x: 100, y: 410 },
  { id: 'triage', label: 'triage', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-tested A2A target', spiffeId: spiffe('acme', 'payments', 'triage'), namespace: 'agent-trust-acme-payments', serviceAccount: 'agent-trust-triage', selectors: ['k8s:ns:agent-trust-acme-payments', 'k8s:sa:agent-trust-triage'], baoRole: 'agent-trust-triage', baoPath: 'kv/data/signalloom/agent-trust/acme/payments/*', audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-payments', x: 255, y: 410 },
  { id: 'risk-reader', label: 'risk-reader', kind: 'agent', parentId: 'acme-risk', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-modeled cross-project denial target', spiffeId: spiffe('acme', 'risk', 'risk-reader'), namespace: 'agent-trust-acme-risk', serviceAccount: 'agent-trust-risk-reader', selectors: ['k8s:ns:agent-trust-acme-risk', 'k8s:sa:agent-trust-risk-reader'], audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-risk', x: 405, y: 410 },
  { id: 'investigator', label: 'investigator', kind: 'agent', parentId: 'northstar-investigations', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled cross-tenant network boundary', spiffeId: spiffe('northstar', 'investigations', 'investigator'), namespace: 'agent-trust-northstar-investigations', serviceAccount: 'agent-trust-investigator', selectors: ['k8s:ns:agent-trust-northstar-investigations', 'k8s:sa:agent-trust-investigator'], audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/northstar-investigations', x: 760, y: 410 },
  { id: 'aws-lambda', label: 'AWS Lambda', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'external', ...external, providerAssertion: 'AWS IAM role assertion', keyCustody: 'AWS KMS; no private key export', rotationReload: 'STS rotation; Lambda cold-start reload', trustBundle: 'Modeled SPIFFE bundle delivery', deEnrollment: 'IAM role removal plus trust entry deletion', productionGap: 'No runtime AWS binding or bundle delivery evidence', x: 100, y: 520 },
  { id: 'google-cloud-run', label: 'Google Cloud Run', kind: 'agent', parentId: 'acme-risk', tenant: 'acme', location: 'external', ...external, providerAssertion: 'Google service account OIDC binding', keyCustody: 'Google-managed key; export prohibited', rotationReload: 'Revision rollout reload', trustBundle: 'Modeled workload identity trust bundle', deEnrollment: 'Service account binding removal', productionGap: 'No runtime Cloud Run assertion evidence', x: 405, y: 520 },
  { id: 'azure-container-apps', label: 'Azure Container Apps', kind: 'agent', parentId: 'northstar-investigations', tenant: 'northstar', location: 'external', ...external, providerAssertion: 'Azure managed identity federated credential', keyCustody: 'Managed identity; export unavailable', rotationReload: 'Revision restart reload', trustBundle: 'Modeled federated trust bundle', deEnrollment: 'Federated credential deletion', productionGap: 'No runtime Azure enrollment evidence', x: 760, y: 520 },
]

export const trustEdges: TrustEdge[] = [
  { id: 'spire-planner', from: 'spire', to: 'planner', verb: 'modeled SPIRE issues SVID', plane: 'identity', decision: 'allowed', ...modeled, reason: 'Modeled SPIFFE issuance' },
  { id: 'spire-investigator', from: 'spire', to: 'investigator', verb: 'modeled SPIRE issues SVID', plane: 'identity', decision: 'allowed', ...modeled, reason: 'Modeled SPIFFE issuance' },
  { id: 'bao-planner', from: 'openbao', to: 'planner', verb: 'modeled OpenBao exchanges SuperCredential', plane: 'identity', decision: 'allowed', ...modeled, reason: 'Modeled OpenBao exchange', baoRole: 'agent-trust-planner', baoPath: 'auth/spiffe/login', audience: 'openbao-supercredential', ttl: '5m' },
  { id: 'planner-triage', from: 'planner', to: 'triage', verb: 'fixture-tested planner invokes triage', plane: 'authorization', decision: 'allowed', ...fixture, reason: 'Fixture-tested same-project A2A allow', policyRef: 'policy/a2a/acme-payments' },
  { id: 'planner-risk-deny', from: 'planner', to: 'risk-reader', verb: 'modeled cross-project application denial', plane: 'authorization', decision: 'denied', denialKind: 'application-authorization-rejection', ...modeled, reason: 'Modeled application authorization rejection: project claim does not permit risk.invoke', policyRef: 'policy/a2a/acme-risk' },
  { id: 'planner-northstar-network', from: 'planner', to: 'investigator', verb: 'modeled cross-tenant network denial', plane: 'network', decision: 'denied', denialKind: 'network-block', ...modeled, reason: 'Network block: modeled cross-tenant egress policy' },
  { id: 'payments-aws-enrollment', from: 'acme-payments', to: 'aws-lambda', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
  { id: 'risk-gcp-enrollment', from: 'acme-risk', to: 'google-cloud-run', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
  { id: 'investigations-azure-enrollment', from: 'northstar-investigations', to: 'azure-container-apps', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
]

const nodesById = new Map(trustNodes.map(node => [node.id, node]))
const visual: Record<EvidenceState, { label: string; dash: string; color: string }> = {
  observed: { label: 'Runtime-observed / solid', dash: 'none', color: 'var(--teal)' },
  modeled: { label: 'Modeled / dashed', dash: '9 5', color: 'var(--violet)' },
  fixture: { label: 'Fixture-tested / dotted', dash: '2 5', color: 'var(--cyan)' },
  stale: { label: 'Stale / dotted warning', dash: '2 5', color: 'var(--amber)' },
}

function Detail({ label, value }: { label: string; value?: string }) {
  return value ? <div style={{ marginBottom: 9 }}><div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '.06em' }}>{label}</div><div style={{ fontSize: 12, color: 'var(--text)', overflowWrap: 'anywhere' }}>{value}</div></div> : null
}

export default function AgentTrustTopologyPage() {
  const [plane, setPlane] = useState<TopologyPlane>('identity')
  const [tenant, setTenant] = useState('all'); const [location, setLocation] = useState<'all' | Location>('all')
  const [evidence, setEvidence] = useState<'all' | EvidenceState>('all'); const [decision, setDecision] = useState<'all' | Decision>('all')
  const [selected, setSelected] = useState<{ type: 'node' | 'edge'; id: string }>({ type: 'edge', id: 'spire-planner' })
  const { nodes, edges } = useMemo(() => {
    const matches = (node: TrustNode) => (tenant === 'all' || node.tenant === tenant) && (location === 'all' || node.location === location) && (evidence === 'all' || node.evidence === evidence)
    const visible = new Set(trustNodes.filter(matches).map(node => node.id))
    let changed = true
    while (changed) { changed = false; trustNodes.forEach(node => { if (visible.has(node.id) && node.parentId && !visible.has(node.parentId)) { visible.add(node.parentId); changed = true } }) }
    const edges = trustEdges.filter(edge => (plane === 'evidence' || edge.plane === plane) && (evidence === 'all' || edge.evidence === evidence) && (decision === 'all' || edge.decision === decision) && visible.has(edge.from) && visible.has(edge.to))
    return { nodes: trustNodes.filter(node => visible.has(node.id)), edges }
  }, [decision, evidence, location, plane, tenant])
  const node = selected.type === 'node' ? nodesById.get(selected.id) : undefined
  const edge = selected.type === 'edge' ? trustEdges.find(item => item.id === selected.id) : undefined
  const selectNode = (id: string) => setSelected({ type: 'node', id }); const selectEdge = (id: string) => setSelected({ type: 'edge', id })
  const reset = () => { setPlane('identity'); setTenant('all'); setLocation('all'); setEvidence('all'); setDecision('all') }
  const counts = { observed: trustNodes.filter(item => item.evidence === 'observed').length + trustEdges.filter(item => item.evidence === 'observed').length, modeled: trustNodes.filter(item => item.evidence === 'modeled').length + trustEdges.filter(item => item.evidence === 'modeled').length, fixture: trustNodes.filter(item => item.evidence === 'fixture').length + trustEdges.filter(item => item.evidence === 'fixture').length }
  return <div style={{ paddingBottom: 32 }}>
    <style>{`.trust-layout{display:grid;grid-template-columns:minmax(0,1fr) 290px;gap:14px}.trust-svg{min-width:940px;width:100%;height:590px}.trust-scroll{overflow:auto;-webkit-overflow-scrolling:touch}.trust-native-list{display:flex;flex-wrap:wrap;gap:6px;padding:12px;border-top:1px solid var(--border)}.trust-native-list button:focus-visible,.topology-control:focus-visible{outline:3px solid var(--cyan);outline-offset:2px}@media(max-width:1024px){.trust-layout{grid-template-columns:1fr}.trust-svg{display:block}.trust-native-list{display:flex}}`}</style>
    <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>Agent Trust Topology</h1>
    <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 780, marginBottom: 18 }}>Contract topology only. Relationship evidence is never inferred from this display.</p>
    <div role="status" style={{ border: '1px solid var(--amber)', background: 'rgba(217,119,6,.12)', color: 'var(--text)', padding: '10px 14px', borderRadius: 8, marginBottom: 14, fontSize: 13 }}><strong>Demonstration data — warning.</strong> No relationship on this page is runtime-observed; items are modeled or fixture-tested.</div>
    <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 22 }}><StatCard label="Runtime-observed" value={String(counts.observed)} sub="no runtime API is connected" accent="var(--slate-gray)" /><StatCard label="Modeled items" value={String(counts.modeled)} sub="contract assumptions, not proof" accent="var(--violet)" /><StatCard label="Fixture-tested items" value={String(counts.fixture)} sub="demonstration contract paths" accent="var(--cyan)" /></div>
    <Section title="Trust relationship plane" hint="one display layer at a time"><div className="card" style={{ padding: 16 }}><div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>{(['identity', 'authorization', 'network', 'external', 'evidence'] as TopologyPlane[]).map(value => <button key={value} className="btn topology-control" aria-pressed={plane === value} onClick={() => setPlane(value)} style={{ background: plane === value ? 'rgba(6,182,212,.14)' : 'var(--surface2)', color: plane === value ? 'var(--cyan)' : 'var(--text)', border: `1px solid ${plane === value ? 'var(--cyan)' : 'var(--border)'}` }}>{value[0].toUpperCase() + value.slice(1)} plane</button>)}</div><div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'end' }}>
      <label>Tenant<select aria-label="Tenant" value={tenant} onChange={e => setTenant(e.target.value)}><option value="all">All tenants</option><option value="acme">Acme</option><option value="northstar">Northstar</option></select></label><label>Location<select aria-label="Location" value={location} onChange={e => setLocation(e.target.value as typeof location)}><option value="all">Every location</option><option value="in-cluster">In-cluster</option><option value="external">External</option></select></label><label>Evidence<select aria-label="Evidence" value={evidence} onChange={e => setEvidence(e.target.value as typeof evidence)}><option value="all">Any evidence</option><option value="observed">Runtime-observed</option><option value="modeled">Modeled</option><option value="fixture">Fixture-tested</option><option value="stale">Stale</option></select></label><label>Decision<select aria-label="Allowed or denied" value={decision} onChange={e => setDecision(e.target.value as typeof decision)}><option value="all">Allowed + denied</option><option value="allowed">Allowed</option><option value="denied">Denied</option></select></label><button className="btn btn-secondary topology-control" onClick={reset}>Reset filters</button><span aria-live="polite" style={{ color: 'var(--muted)', fontSize: 12 }}>Showing {nodes.length} nodes · {edges.length} relationships</span>
    </div></div></Section>
    <div className="trust-layout"><section className="card" aria-label="Agent trust topology graph" style={{ padding: 0, overflow: 'hidden' }}><div style={{ padding: '12px 16px', display: 'flex', gap: 12, flexWrap: 'wrap' }}>{(Object.keys(visual) as EvidenceState[]).map(key => <span key={key} style={{ color: visual[key].color, fontSize: 11 }}>━ {visual[key].label}</span>)}<span style={{ color: 'var(--amber)', fontSize: 11 }}>External = lower assurance</span></div><div className="trust-scroll"><svg className="trust-svg" viewBox="0 0 1000 590" aria-label="Topology diagram"><defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto"><path d="M0,0 L0,6 L6,3 z" fill="var(--muted)" /></marker></defs>{edges.map(item => { const from = nodesById.get(item.from)!; const to = nodesById.get(item.to)!; const v = visual[item.evidence]; const x = (from.x + to.x) / 2; const y = (from.y + to.y) / 2; return <g key={item.id}><line x1={from.x} y1={from.y + 24} x2={to.x} y2={to.y - 24} stroke={item.decision === 'denied' ? 'var(--error)' : v.color} strokeWidth="2.5" strokeDasharray={v.dash} markerEnd="url(#arrow)" /><text x={x} y={y} textAnchor="middle" fill={item.decision === 'denied' ? 'var(--error)' : 'var(--text)'} fontSize="10">{item.verb}</text></g> })}{nodes.map(item => { const v = visual[item.evidence]; return <g key={item.id}><rect x={item.x - 78} y={item.y - 24} width="156" height="48" rx="8" fill="var(--surface2)" stroke={v.color} strokeWidth="2" strokeDasharray={v.dash} /><text x={item.x} y={item.y - 4} textAnchor="middle" fill="var(--text)" fontSize="12" fontWeight="700">{item.label}</text><text x={item.x} y={item.y + 11} textAnchor="middle" fill={item.location === 'external' ? 'var(--amber)' : 'var(--muted)'} fontSize="9">{item.location === 'external' ? 'EXTERNAL · LOWER ASSURANCE' : item.evidence.toUpperCase()}</text></g> })}</svg></div><div className="trust-native-list" aria-label="Selectable topology items">{nodes.map(item => <button key={item.id} className="btn btn-secondary" onClick={() => selectNode(item.id)}>{item.label} · {item.location} · {visual[item.evidence].label}</button>)}{edges.map(item => <button key={item.id} className="btn btn-secondary" onClick={() => selectEdge(item.id)}>{item.verb} · {item.decision} · {item.plane} · {visual[item.evidence].label} · {item.source}</button>)}</div></section>
      <aside className="card" aria-label="Persistent topology details" style={{ padding: 16 }}><div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '.07em', marginBottom: 10 }}>Persistent inspector</div>{node && <><h2 style={{ fontSize: 16 }}>{node.label}</h2><Detail label="SPIFFE ID" value={node.spiffeId} /><Detail label="Namespace / service account" value={node.namespace && node.serviceAccount ? `${node.namespace} / ${node.serviceAccount}` : undefined} /><Detail label="Selectors" value={node.selectors?.join(', ')} /><Detail label="OpenBao role / path / audience / TTL" value={[node.baoRole, node.baoPath, node.audience, node.ttl && `TTL: ${node.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Provider assertion / binding" value={node.providerAssertion} /><Detail label="Key custody / export" value={node.keyCustody} /><Detail label="Rotation / reload" value={node.rotationReload} /><Detail label="Trust bundle" value={node.trustBundle} /><Detail label="De-enrollment" value={node.deEnrollment} /><Detail label="Production gap" value={node.productionGap} /><Detail label="Source" value={node.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[node.evidence].label} · ${node.freshness} · ${node.assurance}`} /><Detail label="Reason" value={node.reason} /></>}{edge && <><h2 style={{ fontSize: 16 }}>{edge.verb}</h2>{edge.denialKind && <div style={{ border: '1px solid var(--error)', background: 'rgba(220,38,38,.1)', padding: 8, borderRadius: 5, fontSize: 12, marginBottom: 10 }}>{edge.denialKind === 'network-block' ? 'Network block' : 'Application authorization rejection'}</div>}<Detail label="Plane / decision" value={`${edge.plane} · ${edge.decision}`} /><Detail label="OpenBao role / path / audience / TTL" value={[edge.baoRole, edge.baoPath, edge.audience, edge.ttl && `TTL: ${edge.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Policy reference" value={edge.policyRef} /><Detail label="Source" value={edge.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[edge.evidence].label} · ${edge.freshness} · ${edge.assurance}`} /><Detail label="Failure / denial reason" value={edge.reason} /></>}</aside>
    </div>
  </div>
}
