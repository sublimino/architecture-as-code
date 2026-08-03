import { useCallback, useMemo, useState } from 'react'
import { Section, StatCard } from '../components/DashKit'
import TrustTopologyCanvas from '../components/trust/TrustTopologyCanvas'
import { visual } from '../components/trust/trustVisuals'
import type {
  Decision,
  EvidenceState,
  Location,
  Selection,
  TopologyPlane,
  TrustEdge,
  TrustNode,
} from '../components/trust/trustTypes'
import '../styles/trust-topology.css'

export type { EvidenceState, EnforcementPlane, TrustNode, TrustEdge } from '../components/trust/trustTypes'

const modeled = { evidence: 'modeled' as const, source: 'Trust contract model', observedAt: 'Not runtime-observed', freshness: 'unknown' as const, assurance: 'medium' as const }
const fixture = { evidence: 'fixture' as const, source: 'Fixture-tested topology contract', observedAt: 'Fixture test 2026-08-02T19:40:00Z', freshness: 'fixture' as const, assurance: 'medium' as const }
const external = { ...modeled, assurance: 'lower' as const, reason: 'Modeled external boundary; no runtime attestation ingested' }
const spiffe = (tenant: string, project: string, agent: string) => `spiffe://signalloom.demo/platform/signalloom/tenant/${tenant}/project/${project}/agent/${agent}`

export const trustNodes: TrustNode[] = [
  { id: 'platform', label: 'Signal Loom platform', kind: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled platform root of trust', x: 500, y: 60 },
  { id: 'acme', label: 'Acme tenant', kind: 'tenant', parentId: 'platform', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled tenant boundary', x: 300, y: 280 },
  { id: 'northstar', label: 'Northstar tenant', kind: 'tenant', parentId: 'platform', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled tenant boundary', x: 980, y: 280 },
  { id: 'acme-payments', label: 'Acme Payments', kind: 'project', parentId: 'acme', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-acme-payments', x: 200, y: 390 },
  { id: 'acme-risk', label: 'Acme Risk', kind: 'project', parentId: 'acme', tenant: 'acme', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-acme-risk', x: 620, y: 390 },
  { id: 'northstar-investigations', label: 'Northstar Investigations', kind: 'project', parentId: 'northstar', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled project boundary', namespace: 'agent-trust-northstar-investigations', x: 980, y: 390 },
  { id: 'spire', label: 'SPIRE issuer', kind: 'service', parentId: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled SPIFFE issuer', x: 380, y: 155 },
  { id: 'openbao', label: 'OpenBao', kind: 'service', parentId: 'platform', tenant: 'shared', location: 'in-cluster', ...modeled, reason: 'Modeled SuperCredential exchange broker', baoPath: 'auth/jwt/login', audience: 'openbao-supercredential', ttl: '5m', x: 620, y: 155 },
  { id: 'planner', label: 'planner', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-tested A2A caller', spiffeId: spiffe('acme', 'payments', 'planner'), namespace: 'agent-trust-acme-payments', serviceAccount: 'agent-trust-planner', selectors: ['k8s:ns:agent-trust-acme-payments', 'k8s:sa:agent-trust-planner'], baoRole: 'agent-trust-planner', baoPath: 'kv/data/signalloom/agent-trust/acme/payments/*', audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-payments', x: 110, y: 520 },
  { id: 'triage', label: 'triage', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-tested A2A target', spiffeId: spiffe('acme', 'payments', 'triage'), namespace: 'agent-trust-acme-payments', serviceAccount: 'agent-trust-triage', selectors: ['k8s:ns:agent-trust-acme-payments', 'k8s:sa:agent-trust-triage'], baoRole: 'agent-trust-triage', baoPath: 'kv/data/signalloom/agent-trust/acme/payments/*', audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-payments', x: 380, y: 520 },
  { id: 'risk-reader', label: 'risk-reader', kind: 'agent', parentId: 'acme-risk', tenant: 'acme', location: 'in-cluster', ...fixture, reason: 'Fixture-modeled cross-project denial target', spiffeId: spiffe('acme', 'risk', 'risk-reader'), namespace: 'agent-trust-acme-risk', serviceAccount: 'agent-trust-risk-reader', selectors: ['k8s:ns:agent-trust-acme-risk', 'k8s:sa:agent-trust-risk-reader'], audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/acme-risk', x: 620, y: 520 },
  { id: 'investigator', label: 'investigator', kind: 'agent', parentId: 'northstar-investigations', tenant: 'northstar', location: 'in-cluster', ...modeled, reason: 'Modeled cross-tenant network boundary', spiffeId: spiffe('northstar', 'investigations', 'investigator'), namespace: 'agent-trust-northstar-investigations', serviceAccount: 'agent-trust-investigator', selectors: ['k8s:ns:agent-trust-northstar-investigations', 'k8s:sa:agent-trust-investigator'], audience: 'openbao-supercredential', ttl: '5m', policyRef: 'policy/a2a/northstar-investigations', x: 980, y: 520 },
  { id: 'aws-lambda', label: 'AWS Lambda', kind: 'agent', parentId: 'acme-payments', tenant: 'acme', location: 'external', ...external, providerAssertion: 'AWS IAM role assertion', keyCustody: 'AWS KMS; no private key export', rotationReload: 'STS rotation; Lambda cold-start reload', trustBundle: 'Modeled SPIFFE bundle delivery', deEnrollment: 'IAM role removal plus trust entry deletion', productionGap: 'No runtime AWS binding or bundle delivery evidence', x: 110, y: 700 },
  { id: 'google-cloud-run', label: 'Google Cloud Run', kind: 'agent', parentId: 'acme-risk', tenant: 'acme', location: 'external', ...external, providerAssertion: 'Google service account OIDC binding', keyCustody: 'Google-managed key; export prohibited', rotationReload: 'Revision rollout reload', trustBundle: 'Modeled workload identity trust bundle', deEnrollment: 'Service account binding removal', productionGap: 'No runtime Cloud Run assertion evidence', x: 620, y: 700 },
  { id: 'azure-container-apps', label: 'Azure Container Apps', kind: 'agent', parentId: 'northstar-investigations', tenant: 'northstar', location: 'external', ...external, providerAssertion: 'Azure managed identity federated credential', keyCustody: 'Managed identity; export unavailable', rotationReload: 'Revision restart reload', trustBundle: 'Modeled federated trust bundle', deEnrollment: 'Federated credential deletion', productionGap: 'No runtime Azure enrollment evidence', x: 980, y: 700 },
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

/**
 * "spire → planner", the two things a relationship is actually between.
 *
 * Without this, `spire-planner` and `spire-investigator` were indistinguishable
 * anywhere a human could read them: byte-identical list buttons AND
 * byte-identical inspector panels, because every other field on the two edges
 * matches. They cross DIFFERENT TENANTS -- on a page whose subject is which
 * identity trusts which, being unable to tell them apart is a failure of the
 * page's core job, not a labelling nicety.
 */
function endpointsOf(edge: TrustEdge): string {
  return `${nodesById.get(edge.from)?.label ?? edge.from} → ${nodesById.get(edge.to)?.label ?? edge.to}`
}

function Detail({ label, value }: { label: string; value?: string }) {
  return value ? <div style={{ marginBottom: 9 }}><div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '.06em' }}>{label}</div><div style={{ fontSize: 12, color: 'var(--text)', overflowWrap: 'anywhere' }}>{value}</div></div> : null
}

/**
 * How full the assurance bar gets. Nothing on this page reaches the top: the
 * best state available here is fixture-tested, and a full bar would read as
 * "proved in production" — the one claim the page exists to refuse.
 */
const ASSURANCE_FILL: Record<EvidenceState, number> = { observed: 100, fixture: 62, modeled: 34, stale: 20 }

function AssuranceMeter({ evidence }: { evidence: EvidenceState }) {
  const v = visual[evidence]
  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '.06em', marginBottom: 5 }}>
        <span>Assurance</span><span style={{ color: v.color }}>{evidence}</span>
      </div>
      <div className="trust-assurance">
        <div className="trust-assurance__fill" style={{ width: `${ASSURANCE_FILL[evidence]}%`, background: v.color }} />
      </div>
      <div style={{ fontSize: 11, color: 'var(--dim)', marginTop: 6 }}>{v.confidence}</div>
    </div>
  )
}

/** platform › tenant › project › agent, so a node's place in the hierarchy reads without tracing lines. */
function TrustPath({ nodeId }: { nodeId: string }) {
  const chain: TrustNode[] = []
  let cursor = nodesById.get(nodeId)
  while (cursor) { chain.unshift(cursor); cursor = cursor.parentId ? nodesById.get(cursor.parentId) : undefined }
  if (chain.length < 2) return null
  return (
    <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 10, lineHeight: 1.5 }}>
      {chain.map((item, index) => (
        <span key={item.id}>
          {index > 0 && <span style={{ color: 'var(--dim)' }}> › </span>}
          <span style={{ color: index === chain.length - 1 ? 'var(--text)' : 'var(--muted)' }}>{item.label}</span>
        </span>
      ))}
    </div>
  )
}

export default function AgentTrustTopologyPage() {
  const [plane, setPlane] = useState<TopologyPlane>('identity')
  const [tenant, setTenant] = useState('all'); const [location, setLocation] = useState<'all' | Location>('all')
  const [evidence, setEvidence] = useState<'all' | EvidenceState>('all'); const [decision, setDecision] = useState<'all' | Decision>('all')
  const [selected, setSelected] = useState<Selection>({ type: 'edge', id: 'spire-planner' })
  const { nodes, edges } = useMemo(() => {
    // 'shared' is not a tenant -- SPIRE and OpenBao belong to the platform and
    // serve every tenant. Filtering them out with the tenants left a tenant view
    // showing "9 nodes · 0 relationships": every SVID issuance and credential
    // exchange for that tenant's own agents vanished, so the one view a tenant
    // operator would actually open could never show their own identity chain.
    const matches = (node: TrustNode) => (tenant === 'all' || node.tenant === tenant || node.tenant === 'shared') && (location === 'all' || node.location === location) && (evidence === 'all' || node.evidence === evidence)
    const visible = new Set(trustNodes.filter(matches).map(node => node.id))
    let changed = true
    while (changed) { changed = false; trustNodes.forEach(node => { if (visible.has(node.id) && node.parentId && !visible.has(node.parentId)) { visible.add(node.parentId); changed = true } }) }
    const edges = trustEdges.filter(edge => (plane === 'evidence' || edge.plane === plane) && (evidence === 'all' || edge.evidence === evidence) && (decision === 'all' || edge.decision === decision) && visible.has(edge.from) && visible.has(edge.to))
    return { nodes: trustNodes.filter(node => visible.has(node.id)), edges }
  }, [decision, evidence, location, plane, tenant])
  const node = selected.type === 'node' ? nodesById.get(selected.id) : undefined
  const edge = selected.type === 'edge' ? trustEdges.find(item => item.id === selected.id) : undefined
  // useCallback, not inline arrows: these are in the canvas's memo dependency
  // arrays, and a fresh identity every render meant the edge geometry (including
  // wallFraction's search) was recomputed on every unrelated state change.
  const selectNode = useCallback((id: string) => setSelected({ type: 'node', id }), [])
  const selectEdge = useCallback((id: string) => setSelected({ type: 'edge', id }), [])
  const reset = () => { setPlane('identity'); setTenant('all'); setLocation('all'); setEvidence('all'); setDecision('all') }
  const counts = { observed: trustNodes.filter(item => item.evidence === 'observed').length + trustEdges.filter(item => item.evidence === 'observed').length, modeled: trustNodes.filter(item => item.evidence === 'modeled').length + trustEdges.filter(item => item.evidence === 'modeled').length, fixture: trustNodes.filter(item => item.evidence === 'fixture').length + trustEdges.filter(item => item.evidence === 'fixture').length }
  const evidenceCounts = useMemo(() => {
    const out: Record<EvidenceState, number> = { observed: 0, modeled: 0, fixture: 0, stale: 0 }
    for (const item of [...trustNodes, ...trustEdges]) out[item.evidence] += 1
    return out
  }, [])
  const inspectorAccent = visual[(node ?? edge)?.evidence ?? 'modeled'].color
  // The inspector is deliberately persistent, so a filter can leave it
  // describing something that is no longer on the canvas. Keeping the detail is
  // right -- losing your place on every filter change would be worse -- but
  // presenting it silently is not: the reader has no way to tell that the thing
  // they are reading about is not the thing in front of them.
  const pinnedOutOfView = node
    ? !nodes.some(item => item.id === node.id)
    : edge ? !edges.some(item => item.id === edge.id) : false
  return <div style={{ paddingBottom: 32 }}>
    <style>{`.trust-layout{display:grid;grid-template-columns:minmax(0,1fr) 290px;gap:14px}.trust-native-list{display:flex;flex-wrap:wrap;gap:6px;padding:12px;border-top:1px solid var(--border)}.trust-native-list button:focus-visible,.topology-control:focus-visible{outline:3px solid var(--cyan);outline-offset:2px}@media(max-width:1024px){.trust-layout{grid-template-columns:1fr}.trust-native-list{display:flex}}`}</style>
    <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>Agent Trust Topology</h1>
    <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 780, marginBottom: 18 }}>Contract topology only. Relationship evidence is never inferred from this display.</p>
    <div role="status" style={{ border: '1px solid var(--amber)', background: 'color-mix(in srgb, var(--amber) 12%, var(--surface))', color: 'var(--text)', padding: '10px 14px', borderRadius: 8, marginBottom: 14, fontSize: 13 }}><strong>Demonstration data — warning.</strong> No relationship on this page is runtime-observed; items are modeled or fixture-tested.</div>
    <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 22 }}><StatCard label="Runtime-observed" value={String(counts.observed)} sub="no runtime API is connected" accent="var(--slate-gray)" /><StatCard label="Modeled items" value={String(counts.modeled)} sub="contract assumptions, not proof" accent="var(--violet)" /><StatCard label="Fixture-tested items" value={String(counts.fixture)} sub="demonstration contract paths" accent="var(--cyan)" /></div>
    <Section title="Trust relationship plane" hint="one display layer at a time"><div className="card" style={{ padding: 16 }}><div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>{(['identity', 'authorization', 'network', 'external', 'evidence'] as TopologyPlane[]).map(value => <button key={value} className="btn topology-control" aria-pressed={plane === value} onClick={() => setPlane(value)} style={{ background: plane === value ? 'color-mix(in srgb, var(--cyan) 14%, var(--surface2))' : 'var(--surface2)', color: 'var(--text)', border: `1px solid ${plane === value ? 'var(--cyan)' : 'var(--border)'}` }}>{value[0].toUpperCase() + value.slice(1)} plane</button>)}</div><div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'end' }}>
      <label>Tenant<select aria-label="Tenant" value={tenant} onChange={e => setTenant(e.target.value)}><option value="all">All tenants</option><option value="acme">Acme</option><option value="northstar">Northstar</option></select></label><label>Location<select aria-label="Location" value={location} onChange={e => setLocation(e.target.value as typeof location)}><option value="all">Every location</option><option value="in-cluster">In-cluster</option><option value="external">External</option></select></label><label>Evidence<select aria-label="Evidence" value={evidence} onChange={e => setEvidence(e.target.value as typeof evidence)}><option value="all">Any evidence</option><option value="observed">Runtime-observed</option><option value="modeled">Modeled</option><option value="fixture">Fixture-tested</option><option value="stale">Stale</option></select></label><label>Decision<select aria-label="Decision" value={decision} onChange={e => setDecision(e.target.value as typeof decision)}><option value="all">Allowed + denied</option><option value="allowed">Allowed</option><option value="denied">Denied</option></select></label><button className="btn btn-secondary topology-control" onClick={reset}>Reset filters</button><span aria-live="polite" style={{ color: 'var(--muted)', fontSize: 12 }}>Showing {nodes.length} nodes · {edges.length} relationships</span>
    </div></div></Section>
    <div className="trust-layout">
      <section className="card" aria-label="Agent trust topology graph" style={{ padding: 0, overflow: 'hidden' }}>
        <div style={{ padding: '12px 16px', display: 'flex', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
          {/* Absent states are greyed and counted rather than dropped: the
              legend has to keep saying that "Runtime-observed" exists as a
              category, because the whole point is that nothing occupies it.
              Rendering it in confident green as the first and highest-contrast
              item -- with a 0 above it -- was the page arguing against itself. */}
          {(Object.keys(visual) as EvidenceState[]).map(key => {
            const present = evidenceCounts[key] > 0
            return <span key={key} title={present ? visual[key].confidence : `${visual[key].label} — nothing on this page is in this state`} style={{ color: present ? visual[key].color : 'var(--muted)', fontSize: 11 }}>━ {visual[key].label}{present ? '' : ' · none'}</span>
          })}
          <span style={{ color: 'var(--amber)', fontSize: 11 }}>External = lower assurance</span>
          <span style={{ color: 'var(--dim)', fontSize: 11, marginLeft: 'auto' }}>Flow speed tracks evidence strength — modeled links drift, fixture-tested links move</span>
        </div>
        {/* Remounting per plane replays the staggered entrance and refits the view,
            so switching plane reads as the topology reconfiguring rather than as
            arrows quietly appearing and disappearing. */}
        {nodes.length === 0
          ? <div role="status" style={{ height: 320, display: 'flex', flexDirection: 'column', gap: 8, alignItems: 'center', justifyContent: 'center', textAlign: 'center', padding: 24 }}>
              <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)' }}>Nothing matches these filters.</div>
              <div style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 460 }}>
                {evidence === 'observed'
                  ? 'No item on this page is runtime-observed — that is the point of the page, not a fault in the filter. Every relationship here is modeled or fixture-tested.'
                  : evidence === 'stale'
                    ? 'Nothing here is stale: this topology is a contract, so it has no freshness clock to fall behind.'
                    : 'Widen a filter, or reset them, to bring the topology back.'}
              </div>
              <button className="btn btn-secondary topology-control" onClick={reset} style={{ marginTop: 4 }}>Reset filters</button>
            </div>
          : <TrustTopologyCanvas key={plane} nodes={nodes} edges={edges} selected={selected} onSelectNode={selectNode} onSelectEdge={selectEdge} />}
        <div className="trust-native-list" role="group" aria-label="Selectable topology items">{nodes.map(item => <button key={item.id} className="btn btn-secondary" aria-pressed={selected.type === 'node' && selected.id === item.id} onClick={() => selectNode(item.id)}>{item.label} · {item.location} · {visual[item.evidence].label}</button>)}{edges.map(item => <button key={item.id} className="btn btn-secondary" aria-pressed={selected.type === 'edge' && selected.id === item.id} onClick={() => selectEdge(item.id)}>{endpointsOf(item)} · {item.verb} · {item.decision} · {item.plane} · {visual[item.evidence].label} · {item.source}</button>)}</div>
      </section>
      <aside className="card trust-inspector" aria-label="Persistent topology details" aria-live="polite" style={{ padding: '16px 16px 16px 22px' }}>
        {/* The rail takes the evidence colour of whatever is pinned, so the
            inspector states its own confidence before you read a word of it. */}
        <div className="trust-inspector__rail" style={{ left: 10, top: 16, bottom: 16, background: inspectorAccent }} />
        <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '.07em', marginBottom: 10 }}>Persistent inspector</div>
        {pinnedOutOfView && (
          <div role="status" style={{ border: '1px solid var(--amber)', background: 'color-mix(in srgb, var(--amber) 12%, var(--surface))', color: 'var(--text)', padding: '7px 9px', borderRadius: 5, fontSize: 11, marginBottom: 10 }}>
            Not in the current view — the filters above exclude this item.
          </div>
        )}
        <div className="trust-inspector__body" key={`${selected.type}:${selected.id}`}>
          {node && <><h2 style={{ fontSize: 16 }}>{node.label}</h2><TrustPath nodeId={node.id} /><AssuranceMeter evidence={node.evidence} /><Detail label="SPIFFE ID" value={node.spiffeId} /><Detail label="Namespace / service account" value={node.namespace && node.serviceAccount ? `${node.namespace} / ${node.serviceAccount}` : undefined} /><Detail label="Selectors" value={node.selectors?.join(', ')} /><Detail label="OpenBao role / path / audience / TTL" value={[node.baoRole, node.baoPath, node.audience, node.ttl && `TTL: ${node.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Provider assertion / binding" value={node.providerAssertion} /><Detail label="Key custody / export" value={node.keyCustody} /><Detail label="Rotation / reload" value={node.rotationReload} /><Detail label="Trust bundle" value={node.trustBundle} /><Detail label="De-enrollment" value={node.deEnrollment} /><Detail label="Production gap" value={node.productionGap} /><Detail label="Source" value={node.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[node.evidence].label} · ${node.freshness} · ${node.assurance}`} /><Detail label="Reason" value={node.reason} /></>}
          {edge && <><h2 style={{ fontSize: 16 }}>{edge.verb}</h2><div style={{ fontSize: 12, color: 'var(--text)', marginBottom: 10 }}>{endpointsOf(edge)}</div>{edge.denialKind && <div style={{ border: '1px solid var(--error)', background: 'color-mix(in srgb, var(--error) 10%, var(--surface))', color: 'var(--text)', padding: 8, borderRadius: 5, fontSize: 12, marginBottom: 10 }}>{edge.denialKind === 'network-block' ? 'Network block' : 'Application authorization rejection'}</div>}<AssuranceMeter evidence={edge.evidence} /><Detail label="Plane / decision" value={`${edge.plane} · ${edge.decision}`} /><Detail label="OpenBao role / path / audience / TTL" value={[edge.baoRole, edge.baoPath, edge.audience, edge.ttl && `TTL: ${edge.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Policy reference" value={edge.policyRef} /><Detail label="Source" value={edge.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[edge.evidence].label} · ${edge.freshness} · ${edge.assurance}`} /><Detail label="Failure / denial reason" value={edge.reason} /></>}
        </div>
      </aside>
    </div>
  </div>
}
