// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import type { EvidenceLink } from '../api/weaveApi'

/**
 * Transitive delegation record representing an individual acts-on-behalf-of edge
 * along a multi-hop authority spine.
 * Corresponds to backend identity.DelegationRecord in signal-ingest.
 */
export interface DelegationRecord {
  id?: number
  delegate_actor_id: string
  principal_actor_id: string
  authz_ref: string
  valid_from: string
  valid_to?: string | null
  metadata?: Record<string, any>
  created_at?: string
  // Enriched fields for frontend presentation & containment verification
  containment_evidenced?: boolean
  nono_containment?: boolean
  spiffe_svid?: string
  role?: string
  node_name?: string
  namespace?: string
}

/**
 * Detailed node representation within the multi-node stepped delegation path.
 */
export interface DelegationNodeData {
  actorId: string
  label: string
  role?: 'human_principal' | 'planner' | 'pipeline' | 'agent' | 'workload' | 'root_ca' | string
  spiffeId?: string
  authzRef?: string
  validFrom?: string
  validTo?: string | null
  isTerminal?: boolean
  isRoot?: boolean
  containmentEvidenced?: boolean
  nonoContainment?: boolean
  metadata?: Record<string, any>
}

/**
 * TransitiveDelegationChain encapsulates the complete upstream delegation hierarchy
 * from root human principal or orchestrator down to the executing leaf agent.
 */
export interface TransitiveDelegationChain {
  actorId: string
  agentIdentity: string
  principal: string
  actsOnBehalfOf: string
  decision: string
  confidence: number
  evidenceRefs: string[]
  attestationGitoid: string
  complete: boolean
  cycleDetected?: boolean
  delegationChain?: DelegationRecord[]
  canonicalId?: string
  aliases?: string[]
  evidenceChain?: EvidenceLink[]
  timestamp?: string
}

/**
 * Cycle detection alert metadata.
 */
export interface CycleDetectionInfo {
  cycleDetected: boolean
  cycleNodes?: string[]
  message?: string
}
