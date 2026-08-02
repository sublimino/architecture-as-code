// Shared types for the SuperCred demo projection layer.
//
// The SuperCred demo runs against a real Kubernetes cluster. Each step of
// scripts/supercred-demo.sh stamps the agent pod with a `signalloom.ai/state`
// label, which fake-integration-proxy surfaces verbatim as `agent.state` on
// GET /supercred-api/agents. That label is therefore the single observable
// that tells the dashboard how far the demo has progressed — and it reads the
// same whether the operator drove the step from the CLI or from a button in
// the UI.
//
// Nothing here fabricates demo progress: `SuperCredPhase` is *derived* from
// what the cluster reports (or, in demo-data mode, from the simulated cluster
// in supercredSource.ts).

/** How far the SuperCred demo has progressed, derived from cluster state. */
export type SuperCredPhase =
  /** No SuperCred agent discovered — before step 1, or after step 5 teardown. */
  | 'absent'
  /** Step 1: pod deployed, SPIRE entry registered, no state label yet. */
  | 'deployed'
  /** Step 2: `signalloom.ai/state=active` — SPIFFE → OpenBao chain verified. */
  | 'credentialed'
  /** Step 3: scan found the missing securityContext. */
  | 'non-compliant'
  /** Step 4: `signalloom.ai/state=stunned` — credentials revoked, agent isolated. */
  | 'stunned'

/** The raw agent record as returned by GET /supercred-api/agents. */
export interface SuperCredAgentObservation {
  id: string
  name: string
  namespace?: string | null
  type?: string | null
  framework?: string | null
  model?: string | null
  /** The `signalloom.ai/state` pod label — the demo's step marker. */
  state?: string | null
  phase?: string | null
  supercred?: boolean
  supercred_target?: string | null
  stunned_at?: string | null
  stun_reason?: string | null
  created_at?: string | null
}

/**
 * The result of a compliance scan, held in memory for the UI-driven path.
 *
 * The CLI path (`supercred-demo.sh 3`) writes `state=non-compliant` onto the
 * pod, so the finding survives a reload. The UI path (the Compliance Scan
 * button) calls the policy engine through the proxy, which does NOT relabel
 * the pod — so the scan result only exists in this observation until the
 * operator stuns the agent. Both paths must move the main pages, hence both
 * are inputs to the phase derivation.
 */
export interface SuperCredScanObservation {
  evaluated_at: string
  compliant: boolean
  /** Check names that failed, e.g. ['security-context-present', …]. */
  failed_checks: string[]
}

export interface SuperCredDemoState {
  phase: SuperCredPhase
  agent: SuperCredAgentObservation | null
  scan: SuperCredScanObservation | null
  /** ISO timestamp of the last successful observation, or null if never observed. */
  observedAt: string | null
  /**
   * When each phase was first observed, keyed by phase.
   *
   * This is the time the dashboard SAW the transition, not the cluster's own
   * event time — the proxy reports current pod state, not a history. A phase
   * reached before the dashboard was open (or skipped past on a reload) will be
   * missing, which consumers must handle rather than invent a time for.
   */
  enteredAt: Partial<Record<SuperCredPhase, string>>
}

export const EMPTY_SUPERCRED_STATE: SuperCredDemoState = {
  phase: 'absent',
  agent: null,
  scan: null,
  observedAt: null,
  enteredAt: {},
}
