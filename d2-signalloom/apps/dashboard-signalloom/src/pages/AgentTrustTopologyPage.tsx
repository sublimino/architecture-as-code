import { useCallback, useEffect, useMemo, useState } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'
import type { TrustTopologyResponse } from '../types/api'
import { Section, StatCard } from '../components/DashKit'
import HelpHint from '../components/HelpHint'
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

// The API's evidence vocabulary is richer than the diagram's, because the API
// has to describe collector health and the diagram only has to draw confidence.
// Collapse it here, once, rather than teaching every component both vocabularies.
//
// "modeled" is the deliberate catch-all for error/unavailable/modeled: all three
// mean the same thing to a viewer -- this shape was not observed -- and the
// diagram already draws modeled faintest and slowest. Mapping an unreachable
// collector to anything more confident would be the exact failure this page
// exists to prevent.
const EVIDENCE_FROM_API: Record<string, EvidenceState> = {
  observed: 'observed',
  stale: 'stale',
  modeled: 'modeled',
  error: 'modeled',
  unavailable: 'modeled',
}

// Live responses carry no coordinates; the diagram needs them. Lay out by rank
// so a live topology still reads top-down: platform, then tenants and services,
// then projects, then agents.
const RANK_Y: Record<string, number> = {
  platform: 60, tenant: 280, service: 155, project: 390, agent: 520, external: 700, probe: 520, gap: 700,
}

function toTrustTopology(topology: TrustTopologyResponse): { nodes: TrustNode[]; edges: TrustEdge[] } {
  const perRank = new Map<string, number>()
  const nodes = topology.nodes.map(node => {
    const seen = perRank.get(node.kind) ?? 0
    perRank.set(node.kind, seen + 1)
    return {
      ...node,
      label: node.label ?? node.name ?? node.id,
      tenant: node.tenant ?? 'shared',
      location: node.location ?? 'in-cluster',
      parentId: node.parent_id ?? undefined,
      evidence: EVIDENCE_FROM_API[node.evidence_state] ?? 'modeled',
      source: node.evidence_source,
      observedAt: node.observed_at ?? 'Not runtime-observed',
      // The diagram's freshness/assurance scale is coarser than the API's.
      freshness: node.freshness === 'fresh' ? 'unknown' : node.freshness === 'stale' ? 'stale' : 'unknown',
      assurance: node.assurance === 'modeled' ? 'lower' : 'medium',
      x: node.x ?? 200 + (seen % 4) * 260,
      y: node.y ?? RANK_Y[node.kind] ?? 520,
    } as TrustNode
  })
  const edges = topology.edges.map(edge => ({
    ...edge,
    from: edge.from_id,
    to: edge.to_id,
    denialKind: edge.denial_kind ?? undefined,
    policyRef: edge.policy_ref ?? undefined,
    evidence: EVIDENCE_FROM_API[edge.evidence_state] ?? 'modeled',
    source: edge.evidence_source,
    observedAt: edge.observed_at ?? 'Not runtime-observed',
    freshness: edge.freshness === 'fresh' ? 'unknown' : edge.freshness === 'stale' ? 'stale' : 'unknown',
    assurance: edge.assurance === 'modeled' ? 'lower' : 'medium',
  } as TrustEdge))
  return { nodes, edges }
}

/** The worst collector state present. Drives the degraded banner. */
export function collectorHealth(topology: TrustTopologyResponse | null): {
  status: 'ok' | 'partial' | 'unavailable'
  failing: { name: string; reason: string }[]
} {
  const entries = Object.entries(topology?.collectors ?? {})
  const failing = entries
    .filter(([, c]) => c.status !== 'ok')
    .map(([name, c]) => ({ name, reason: c.reason }))
  if (!entries.length) return { status: 'unavailable', failing }
  if (entries.some(([, c]) => c.status === 'unavailable')) return { status: 'unavailable', failing }
  if (entries.some(([, c]) => c.status === 'partial')) return { status: 'partial', failing }
  return { status: 'ok', failing }
}

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
  { id: 'bao-planner', from: 'openbao', to: 'planner', verb: 'modeled OpenBao exchanges SuperCredential', plane: 'identity', decision: 'allowed', ...modeled, reason: 'Modeled OpenBao exchange', baoRole: 'agent-trust-planner', baoPath: 'auth/jwt/login', audience: 'openbao-supercredential', ttl: '5m' },
  { id: 'planner-triage', from: 'planner', to: 'triage', verb: 'fixture-tested planner invokes triage', plane: 'authorization', decision: 'allowed', ...fixture, reason: 'Fixture-tested same-project A2A allow', policyRef: 'policy/a2a/acme-payments' },
  { id: 'planner-risk-deny', from: 'planner', to: 'risk-reader', verb: 'modeled cross-project application denial', plane: 'authorization', decision: 'denied', denialKind: 'application-authorization-rejection', ...modeled, reason: 'Modeled application authorization rejection: project claim does not permit risk.invoke', policyRef: 'policy/a2a/acme-risk' },
  { id: 'planner-northstar-network', from: 'planner', to: 'investigator', verb: 'modeled cross-tenant network denial', plane: 'network', decision: 'denied', denialKind: 'network-block', ...modeled, reason: 'Network block: modeled cross-tenant egress policy' },
  { id: 'payments-aws-enrollment', from: 'acme-payments', to: 'aws-lambda', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
  { id: 'risk-gcp-enrollment', from: 'acme-risk', to: 'google-cloud-run', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
  { id: 'investigations-azure-enrollment', from: 'northstar-investigations', to: 'azure-container-apps', verb: 'modeled external enrollment and bundle delivery', plane: 'external', decision: 'allowed', ...external },
]

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
function endpointsOf(edge: TrustEdge, nodesById: Map<string, TrustNode>): string {
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
function TrustPath({ nodeId, nodesById }: { nodeId: string; nodesById: Map<string, TrustNode> }) {
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

/**
 * States, in plain words, that what is on screen was not observed.
 *
 * The API answers even when its collector is unreachable, returning a topology
 * derived from tenant state with everything marked "modeled". That is the right
 * behaviour -- a dead page helps nobody -- but it is only safe if the viewer can
 * tell. A derived diagram and an observed diagram look identical at a glance,
 * and someone doing QA on a demo will believe what they are shown.
 *
 * So this says three things explicitly, in this order:
 *   1. WHAT is wrong, in one sentence, without jargon.
 *   2. WHICH collector, and the reason IT gave -- never a reason invented here.
 *   3. WHAT the diagram below is, so nobody mistakes it for live evidence.
 *
 * role="alert" rather than "status": this is not progress, it is a correctness
 * warning about everything below it, and it should interrupt a screen reader.
 */
function DegradedBanner({ topology }: { topology: TrustTopologyResponse | null }) {
  const { status, failing } = collectorHealth(topology)
  if (status === 'ok') return null

  const total = Object.keys(topology?.collectors ?? {}).length
  const partial = status === 'partial'

  return (
    <div
      role="alert"
      data-testid="topology-degraded-banner"
      style={{
        border: `1px solid var(--${partial ? 'amber' : 'error'})`,
        background: `color-mix(in srgb, var(--${partial ? 'amber' : 'error'}) 12%, var(--surface))`,
        color: 'var(--text)', padding: '12px 14px', borderRadius: 8, marginBottom: 14, fontSize: 13,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
        <span style={{ fontWeight: 700 }}>
          {partial
            ? 'Partial evidence — some of this topology was not observed.'
            : 'Not live — this topology was derived, not observed.'}
        </span>
        {/* The banner says WHAT is degraded. This says what a viewer should
            now refuse to conclude from the diagram, which is the part that
            actually changes a decision. */}
        <HelpHint label="What this warning means for the diagram" testId="topology-degraded-help">
          A collector that should be watching the live cluster did not report, so the parts it covers are drawn from the design instead of from observation. Those parts describe what should exist. Do not read them as proof that it does, or that a denied link would really be denied.
        </HelpHint>
      </div>
      <div style={{ color: 'var(--muted)', marginBottom: failing.length ? 6 : 0 }}>
        {partial
          ? `${failing.length} of ${total} collectors could not report. Anything they cover is drawn as modeled.`
          : 'The live collector could not be reached, so the diagram below is built from this tenant\u2019s own records. Treat it as a description of what should exist, not evidence of what does.'}
      </div>
      {failing.length > 0 && (
        <ul style={{ margin: 0, paddingLeft: 18, color: 'var(--muted)' }}>
          {failing.map(collector => (
            <li key={collector.name}>
              <strong style={{ color: 'var(--text)' }}>{collector.name}</strong>: {collector.reason}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export default function AgentTrustTopologyPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [demo, setDemo] = useState(isDemoMode())
  const [liveTopology, setLiveTopology] = useState<TrustTopologyResponse | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, setLoading] = useState(!isDemoMode())
  const [plane, setPlane] = useState<TopologyPlane>('identity')
  const [tenant, setTenant] = useState('all'); const [location, setLocation] = useState<'all' | Location>('all')
  const [evidence, setEvidence] = useState<'all' | EvidenceState>('all'); const [decision, setDecision] = useState<'all' | Decision>('all')
  const [selected, setSelected] = useState<Selection>({ type: 'edge', id: 'spire-planner' })
  useEffect(() => subscribeDemoMode(setDemo), [])
  useEffect(() => {
    if (demo) {
      setLoading(false); setLoadError(null); setLiveTopology(null)
      return
    }
    let cancelled = false
    setLoading(true); setLoadError(null)
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const topology = await api.trustTopology(token)
        if (!cancelled) setLiveTopology(topology)
      } catch (error) {
        if (!cancelled) setLoadError(error instanceof Error ? error.message : 'Unable to load authenticated trust topology.')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [demo, getAccessTokenSilently])
  // Memoised, because these feed four dependency arrays below.
  //
  // As bare expressions, `topology?.nodes ?? []` produced a fresh array
  // identity on EVERY render — including the `?? []` fallback, which allocates
  // a new empty array each time. Every useMemo and useEffect keyed on them
  // therefore re-ran unconditionally: the derived filter set, nodesById, the
  // selection-repair effect and the edge geometry were all recomputed on any
  // state change at all, which is exactly the memoisation that the diagram's
  // hover path depends on. toTrustTopology also re-mapped the whole live
  // response each time.
  const topology = useMemo(
    () => (demo ? { nodes: trustNodes, edges: trustEdges } : liveTopology ? toTrustTopology(liveTopology) : null),
    [demo, liveTopology],
  )
  const allNodes = useMemo(() => topology?.nodes ?? [], [topology])
  const allEdges = useMemo(() => topology?.edges ?? [], [topology])
  const nodesById = useMemo(() => new Map(allNodes.map(node => [node.id, node])), [allNodes])
  useEffect(() => {
    if (allEdges.some(edge => edge.id === selected.id) || allNodes.some(node => node.id === selected.id)) return
    const first = allEdges[0] ?? allNodes[0]
    if (first) setSelected({ type: allEdges[0] ? 'edge' : 'node', id: first.id })
  }, [allEdges, allNodes, selected.id])
  const { nodes, edges } = useMemo(() => {
    // 'shared' is not a tenant -- SPIRE and OpenBao belong to the platform and
    // serve every tenant. Filtering them out with the tenants left a tenant view
    // showing "9 nodes · 0 relationships": every SVID issuance and credential
    // exchange for that tenant's own agents vanished, so the one view a tenant
    // operator would actually open could never show their own identity chain.
    const matches = (node: TrustNode) => (tenant === 'all' || node.tenant === tenant || node.tenant === 'shared') && (location === 'all' || node.location === location) && (evidence === 'all' || node.evidence === evidence)
    const visible = new Set(allNodes.filter(matches).map(node => node.id))
    let changed = true
    while (changed) { changed = false; allNodes.forEach(node => { if (visible.has(node.id) && node.parentId && !visible.has(node.parentId)) { visible.add(node.parentId); changed = true } }) }
    const edges = allEdges.filter(edge => (plane === 'evidence' || edge.plane === plane) && (evidence === 'all' || edge.evidence === evidence) && (decision === 'all' || edge.decision === decision) && visible.has(edge.from) && visible.has(edge.to))
    return { nodes: allNodes.filter(node => visible.has(node.id)), edges }
  }, [allEdges, allNodes, decision, evidence, location, plane, tenant])
  const node = selected.type === 'node' ? nodesById.get(selected.id) : undefined
  const edge = selected.type === 'edge' ? allEdges.find(item => item.id === selected.id) : undefined
  // useCallback, not inline arrows: these are in the canvas's memo dependency
  // arrays, and a fresh identity every render meant the edge geometry (including
  // wallFraction's search) was recomputed on every unrelated state change.
  const selectNode = useCallback((id: string) => setSelected({ type: 'node', id }), [])
  const selectEdge = useCallback((id: string) => setSelected({ type: 'edge', id }), [])
  const reset = () => { setPlane('identity'); setTenant('all'); setLocation('all'); setEvidence('all'); setDecision('all') }
  const counts = { observed: allNodes.filter(item => item.evidence === 'observed').length + allEdges.filter(item => item.evidence === 'observed').length, modeled: allNodes.filter(item => item.evidence === 'modeled').length + allEdges.filter(item => item.evidence === 'modeled').length, fixture: allNodes.filter(item => item.evidence === 'fixture').length + allEdges.filter(item => item.evidence === 'fixture').length }
  const evidenceCounts = useMemo(() => {
    const out: Record<EvidenceState, number> = { observed: 0, modeled: 0, fixture: 0, stale: 0 }
    for (const item of [...allNodes, ...allEdges]) out[item.evidence] += 1
    return out
  }, [allEdges, allNodes])
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
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, margin: 0 }}>Agent Trust Topology</h1>
      {/* The three words govern the whole page — the legend, the stat cards,
          the Evidence filter and the inspector all repeat them. Explaining
          them once, at the top, beats three hints that each say a third of it. */}
      <HelpHint label="What runtime-observed, fixture-tested and modeled mean" testId="topology-evidence-help">
        Every box and arrow here carries one of three evidence states. Runtime-observed: a collector saw it in the live cluster. Fixture-tested: a test proved the contract holds, not that it is running right now. Modeled: it is what the design says should exist and nobody checked. Only runtime-observed is evidence.
      </HelpHint>
    </div>
    <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 780, marginBottom: 18 }}>{demo ? 'Contract topology fixture. Relationship evidence is never inferred from this display.' : 'Authenticated tenant topology derived from available agent runtime or fixture state.'}</p>
    {demo && <div role="status" style={{ border: '1px solid var(--amber)', background: 'color-mix(in srgb, var(--amber) 12%, var(--surface))', color: 'var(--text)', padding: '10px 14px', borderRadius: 8, marginBottom: 14, fontSize: 13 }}><strong>Demonstration data — warning.</strong> Demo mode is showing modeled and fixture-tested contract data.</div>}
    {!demo && loading && <div role="status">Loading authenticated trust topology…</div>}
    {!demo && loadError && <div role="alert">Unable to load authenticated trust topology: {loadError}</div>}
    {!demo && !loading && !loadError && <DegradedBanner topology={liveTopology} />}
    <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 22 }}><StatCard label="Runtime-observed" value={String(counts.observed)} sub={demo ? 'none in demonstration fixture' : 'authenticated endpoint response'} accent="var(--slate-gray)" /><StatCard label="Modeled items" value={String(counts.modeled)} sub="contract assumptions, not proof" accent="var(--violet)" /><StatCard label="Fixture-tested items" value={String(counts.fixture)} sub="available fixture state" accent="var(--cyan)" /></div>
    <Section title="Trust relationship plane" hint="one display layer at a time"><div className="card" style={{ padding: 16 }}><div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>{(['identity', 'authorization', 'network', 'external', 'evidence'] as TopologyPlane[]).map(value => <button key={value} className="btn topology-control" aria-pressed={plane === value} onClick={() => setPlane(value)} style={{ background: plane === value ? 'color-mix(in srgb, var(--cyan) 14%, var(--surface2))' : 'var(--surface2)', color: 'var(--text)', border: `1px solid ${plane === value ? 'var(--cyan)' : 'var(--border)'}` }}>{value[0].toUpperCase() + value.slice(1)} plane</button>)}</div><div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'end' }}>
      <label>Tenant<select aria-label="Tenant" value={tenant} onChange={e => setTenant(e.target.value)}><option value="all">All tenants</option>{[...new Set(allNodes.map(node => node.tenant).filter(value => value !== 'shared'))].map(value => <option key={value} value={value}>{value}</option>)}</select></label><label>Location<select aria-label="Location" value={location} onChange={e => setLocation(e.target.value as typeof location)}><option value="all">Every location</option><option value="in-cluster">In-cluster</option><option value="external">External</option></select></label><label>Evidence<select aria-label="Evidence" value={evidence} onChange={e => setEvidence(e.target.value as typeof evidence)}><option value="all">Any evidence</option><option value="observed">Runtime-observed</option><option value="modeled">Modeled</option><option value="fixture">Fixture-tested</option><option value="stale">Stale</option></select></label><label>Decision<select aria-label="Decision" value={decision} onChange={e => setDecision(e.target.value as typeof decision)}><option value="all">Allowed + denied</option><option value="allowed">Allowed</option><option value="denied">Denied</option></select></label><button className="btn btn-secondary topology-control" onClick={reset}>Reset filters</button><span aria-live="polite" style={{ color: 'var(--muted)', fontSize: 12 }}>Showing {nodes.length} nodes · {edges.length} relationships</span>
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
                  ? (demo ? 'No item on this demonstration page is runtime-observed. Every relationship here is modeled or fixture-tested.' : 'No runtime-observed item matches the current filters.')
                  : evidence === 'stale'
                    ? 'Nothing here is stale: this topology is a contract, so it has no freshness clock to fall behind.'
                    : 'Widen a filter, or reset them, to bring the topology back.'}
              </div>
              <button className="btn btn-secondary topology-control" onClick={reset} style={{ marginTop: 4 }}>Reset filters</button>
            </div>
          : <TrustTopologyCanvas key={plane} nodes={nodes} edges={edges} selected={selected} onSelectNode={selectNode} onSelectEdge={selectEdge} />}
        <div className="trust-native-list" role="group" aria-label="Selectable topology items">{nodes.map(item => <button key={item.id} className="btn btn-secondary" aria-pressed={selected.type === 'node' && selected.id === item.id} onClick={() => selectNode(item.id)}>{item.label} · {item.location} · {visual[item.evidence].label}</button>)}{edges.map(item => <button key={item.id} className="btn btn-secondary" aria-pressed={selected.type === 'edge' && selected.id === item.id} onClick={() => selectEdge(item.id)}>{endpointsOf(item, nodesById)} · {item.verb} · {item.decision} · {item.plane} · {visual[item.evidence].label} · {item.source}</button>)}</div>
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
          {node && <><h2 style={{ fontSize: 16 }}>{node.label}</h2><TrustPath nodeId={node.id} nodesById={nodesById} /><AssuranceMeter evidence={node.evidence} /><Detail label="SPIFFE ID" value={node.spiffeId} /><Detail label="Namespace / service account" value={node.namespace && node.serviceAccount ? `${node.namespace} / ${node.serviceAccount}` : undefined} /><Detail label="Selectors" value={node.selectors?.join(', ')} /><Detail label="OpenBao role / path / audience / TTL" value={[node.baoRole, node.baoPath, node.audience, node.ttl && `TTL: ${node.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Provider assertion / binding" value={node.providerAssertion} /><Detail label="Key custody / export" value={node.keyCustody} /><Detail label="Rotation / reload" value={node.rotationReload} /><Detail label="Trust bundle" value={node.trustBundle} /><Detail label="De-enrollment" value={node.deEnrollment} /><Detail label="Production gap" value={node.productionGap} /><Detail label="Source" value={node.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[node.evidence].label} · ${node.freshness} · ${node.assurance}`} /><Detail label="Reason" value={node.reason} /></>}
          {edge && <><h2 style={{ fontSize: 16 }}>{edge.verb}</h2><div style={{ fontSize: 12, color: 'var(--text)', marginBottom: 10 }}>{endpointsOf(edge, nodesById)}</div>{edge.denialKind && <div style={{ border: '1px solid var(--error)', background: 'color-mix(in srgb, var(--error) 10%, var(--surface))', color: 'var(--text)', padding: 8, borderRadius: 5, fontSize: 12, marginBottom: 10 }}>{edge.denialKind === 'network-block' ? 'Network block' : 'Application authorization rejection'}</div>}<AssuranceMeter evidence={edge.evidence} /><Detail label="Plane / decision" value={`${edge.plane} · ${edge.decision}`} /><Detail label="OpenBao role / path / audience / TTL" value={[edge.baoRole, edge.baoPath, edge.audience, edge.ttl && `TTL: ${edge.ttl}`].filter(Boolean).join(' · ')} /><Detail label="Policy reference" value={edge.policyRef} /><Detail label="Source" value={edge.source} /><Detail label="Evidence / freshness / assurance" value={`${visual[edge.evidence].label} · ${edge.freshness} · ${edge.assurance}`} /><Detail label="Failure / denial reason" value={edge.reason} /></>}
        </div>
      </aside>
    </div>
  </div>
}
