// Shared vocabulary for the Agent Trust Topology surface.
//
// These types used to live inside AgentTrustTopologyPage.tsx. They moved here so
// the diagram components can be typed without importing the page, which would be
// circular (page -> canvas -> page). The page still re-exports the public names,
// so `import { trustNodes } from './AgentTrustTopologyPage'` keeps working.

export type EvidenceState = 'observed' | 'modeled' | 'fixture' | 'stale'
export type EnforcementPlane = 'identity' | 'authorization' | 'network' | 'external'
export type TopologyPlane = EnforcementPlane | 'evidence'
export type Location = 'in-cluster' | 'external'
export type Decision = 'allowed' | 'denied' | 'neutral'
export type NodeKind = 'platform' | 'tenant' | 'project' | 'agent' | 'service'

export type Provenance = {
  evidence: EvidenceState
  source: string
  observedAt: string
  freshness: 'fixture' | 'unknown' | 'stale'
  assurance: 'medium' | 'lower'
  reason: string
}

export type ExternalTrust = {
  providerAssertion?: string
  keyCustody?: string
  rotationReload?: string
  trustBundle?: string
  deEnrollment?: string
  productionGap?: string
}

export type TrustNode = Provenance & ExternalTrust & {
  id: string; label: string; kind: NodeKind
  parentId?: string; tenant: string; location: Location; spiffeId?: string; namespace?: string
  serviceAccount?: string; selectors?: string[]; baoRole?: string; baoPath?: string; audience?: string
  ttl?: string; policyRef?: string; x: number; y: number
}

export type TrustEdge = Provenance & {
  id: string; from: string; to: string; verb: string; plane: EnforcementPlane; decision: Decision
  denialKind?: 'network-block' | 'application-authorization-rejection'
  baoRole?: string; baoPath?: string; audience?: string; ttl?: string; policyRef?: string
}

/** What the page currently has pinned in the inspector. */
export type Selection = { type: 'node' | 'edge'; id: string }
