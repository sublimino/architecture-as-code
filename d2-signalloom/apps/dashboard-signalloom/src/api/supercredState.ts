// Observable store for the SuperCred demo's derived state.
//
// Everything the main pages show about the demo is a projection of this store,
// and the store itself only ever holds *observations* — what the cluster (or,
// in demo-data mode, the simulated cluster) reported. No page writes to it and
// no page reads it directly; client.ts consults it when projecting responses.

import type {
  SuperCredAgentObservation,
  SuperCredDemoState,
  SuperCredPhase,
  SuperCredScanObservation,
} from './supercredTypes'
import { EMPTY_SUPERCRED_STATE } from './supercredTypes'

/**
 * Map a cluster observation onto a demo phase.
 *
 * The `signalloom.ai/state` pod label is authoritative because both drivers
 * write it: the CLI (`supercred-demo.sh` steps 2/3/4) and the proxy's stun
 * handler. The one gap is the UI's Compliance Scan button — the proxy
 * evaluates the pod spec but does not relabel the pod — so a failing scan
 * observation is accepted as an equivalent signal for the same phase.
 *
 * Unrecognised labels fall back to `deployed` rather than being guessed at: a
 * demo that invents a phase it does not understand is worse than one that
 * under-reports.
 */
export function derivePhase(
  agent: SuperCredAgentObservation | null,
  scan: SuperCredScanObservation | null,
): SuperCredPhase {
  if (!agent) return 'absent'

  switch (agent.state) {
    case 'stunned':
      return 'stunned'
    case 'non-compliant':
      return 'non-compliant'
    case 'active':
      // A failing UI scan advances an otherwise-active agent to step 3.
      return scan && !scan.compliant ? 'non-compliant' : 'credentialed'
    default:
      return 'deployed'
  }
}

let current: SuperCredDemoState = { ...EMPTY_SUPERCRED_STATE }

type Listener = (state: SuperCredDemoState) => void
const listeners = new Set<Listener>()

function commit(next: SuperCredDemoState): void {
  const phaseChanged = next.phase !== current.phase
  current = next
  if (phaseChanged) listeners.forEach((l) => l(current))
}

export function getSuperCredState(): SuperCredDemoState {
  return current
}

/**
 * Record the agent discovered by the SuperCred data plane, or null if none.
 *
 * A null observation is teardown (step 5): it also clears any held scan so a
 * re-run of the demo starts from a clean step 1 rather than inheriting the
 * previous run's finding.
 */
export function recordObservation(agent: SuperCredAgentObservation | null): void {
  const scan = agent ? current.scan : null
  commit({
    phase: derivePhase(agent, scan),
    agent,
    scan,
    observedAt: new Date().toISOString(),
  })
}

/** Record the result of a compliance scan driven from the UI. */
export function recordScan(scan: SuperCredScanObservation): void {
  commit({
    ...current,
    phase: derivePhase(current.agent, scan),
    scan,
    observedAt: new Date().toISOString(),
  })
}

export function resetSuperCredState(): void {
  current = { ...EMPTY_SUPERCRED_STATE }
  listeners.clear()
}

export function subscribeSuperCredState(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
