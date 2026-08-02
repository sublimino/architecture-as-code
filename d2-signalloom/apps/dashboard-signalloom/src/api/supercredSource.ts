// Observation layer for the SuperCred data plane.
//
// The SuperCred demo runs against the cluster, not against the SignalLoom API,
// so its state lives behind a different endpoint (/supercred-api, served by
// fake-integration-proxy). This module is the only thing that talks to it, and
// it feeds supercredState so client.ts can project the result onto the main
// pages.
//
// In demo-data mode there is no cluster, so the same interface is backed by a
// simulated one — advanced by the SuperCred page's own controls. Both paths
// produce the identical observation shape, which is why the projections and
// every page above them are mode-agnostic.

import { isDemoMode, isProductionEnv } from './demoMode'
import { getSuperCredState, recordObservation, recordScan } from './supercredState'
import type {
  SuperCredAgentObservation,
  SuperCredDemoState,
  SuperCredPhase,
  SuperCredScanObservation,
} from './supercredTypes'

/** Matches SUPERCRED_API in SuperCredPage.tsx — see the nginx.conf comment there. */
const SUPERCRED_API = '/supercred-api'

/**
 * How long an observation stays fresh.
 *
 * Short enough that clicking from Agents to Compliance mid-demo shows the new
 * state, long enough that a page rendering six panels does not fan out into
 * six proxy calls.
 */
const TTL_MS = 4000

const SIM_KEY = 'sl_supercred_demo_phase'

// ─── Simulated cluster (demo-data mode) ──────────────────────────────────────

const SIM_AGENT: SuperCredAgentObservation = {
  id: 'agent-cardvault',
  name: 'Cardvault Agent',
  namespace: 'fe-signalloom-agents',
  type: 'Signal Loom Built',
  framework: 'langchain',
  model: 'gpt-4o',
  phase: 'Running',
  supercred: true,
  supercred_target: 'cardvault.fe-signalloom-services',
  created_at: '2026-08-02T09:55:00Z',
}

/** The `signalloom.ai/state` label the real demo script would have written. */
const SIM_LABEL: Record<SuperCredPhase, string | null> = {
  absent: null,
  deployed: null,
  credentialed: 'active',
  'non-compliant': 'non-compliant',
  stunned: 'stunned',
}

function readPersistedSimPhase(): SuperCredPhase {
  try {
    const stored = localStorage.getItem(SIM_KEY)
    if (stored && stored in SIM_LABEL) return stored as SuperCredPhase
  } catch {
    /* storage unavailable — fall through to absent */
  }
  return 'absent'
}

// In-memory source of truth, seeded from localStorage and synced back
// best-effort — the same pattern demoMode.ts uses, and for the same reason: the
// simulated demo has to keep working where localStorage is absent or inert
// (Node's experimental Web Storage shadows jsdom's, SSR, some test runners).
// localStorage only buys surviving a page reload mid-demo.
let simPhase: SuperCredPhase = readPersistedSimPhase()

function readSimPhase(): SuperCredPhase {
  return simPhase
}

function writeSimPhase(phase: SuperCredPhase): void {
  simPhase = phase
  try {
    localStorage.setItem(SIM_KEY, phase)
  } catch {
    /* storage unavailable — the in-memory value still holds */
  }
}

/** Build the observation the proxy would have returned at this simulated phase. */
function simulate(phase: SuperCredPhase): SuperCredAgentObservation | null {
  if (phase === 'absent') return null
  return {
    ...SIM_AGENT,
    state: SIM_LABEL[phase],
    stunned_at: phase === 'stunned' ? '2026-08-02T10:05:00Z' : null,
    stun_reason: phase === 'stunned' ? 'compliance-failure: securityContext not set' : null,
  }
}

/**
 * Advance the simulated cluster. Demo-data mode only — in live mode the
 * cluster is the source of truth and this is a no-op.
 */
export function setSimulatedPhase(phase: SuperCredPhase): void {
  if (!isDemoMode()) return
  writeSimPhase(phase)
  lastObservedAt = 0
  recordObservation(simulate(phase))
}

export function getSimulatedPhase(): SuperCredPhase {
  return readSimPhase()
}

// ─── Live observation ────────────────────────────────────────────────────────

interface DiscoveryResponse {
  agents?: SuperCredAgentObservation[]
}

async function observeLive(): Promise<SuperCredAgentObservation | null> {
  const res = await fetch(`${SUPERCRED_API}/agents`)
  if (!res.ok) throw new Error(`supercred discovery failed: ${res.status}`)
  const data = (await res.json()) as DiscoveryResponse
  const agents = Array.isArray(data.agents) ? data.agents : []
  return agents.find((a) => a?.supercred === true) ?? null
}

// ─── Refresh scheduling ──────────────────────────────────────────────────────

let lastObservedAt = 0
let inflight: Promise<void> | null = null
let consecutiveFailures = 0

/**
 * Consecutive failures after which the proxy is assumed simply not to be there.
 *
 * Outside a demo cluster /supercred-api does not exist, and a dashboard left
 * open all day should not keep probing it every few seconds. After this many
 * failures the retry interval stretches to BACKOFF_MS; one success resets it.
 */
const FAILURE_THRESHOLD = 3
const BACKOFF_MS = 60_000

/**
 * True when the demo overlay is permitted at all.
 *
 * Hard-gated off in uat/prod: a demo narrative must never appear on a
 * production tenant's compliance figures, whatever the cluster happens to be
 * running.
 */
export function isSuperCredEnabled(): boolean {
  return !isProductionEnv
}

async function refresh(): Promise<void> {
  try {
    const agent = isDemoMode() ? simulate(readSimPhase()) : await observeLive()
    recordObservation(agent)
    consecutiveFailures = 0
  } catch {
    // Fail open. No SuperCred proxy (the normal case outside a demo cluster)
    // must never break a main page, so an unobservable data plane is simply
    // reported as "demo not running".
    consecutiveFailures++
    if (getSuperCredState().phase !== 'absent') recordObservation(null)
  } finally {
    lastObservedAt = Date.now()
  }
}

function staleAfter(): number {
  return consecutiveFailures >= FAILURE_THRESHOLD ? BACKOFF_MS : TTL_MS
}

/**
 * Return the current demo state, refreshing it first if the last observation
 * has gone stale. Concurrent callers share one in-flight refresh.
 */
export async function ensureSuperCredState(): Promise<SuperCredDemoState> {
  if (!isSuperCredEnabled()) return getSuperCredState()

  if (Date.now() - lastObservedAt < staleAfter()) return getSuperCredState()
  if (!inflight) {
    inflight = refresh().finally(() => {
      inflight = null
    })
  }
  await inflight
  return getSuperCredState()
}

/** Force the next read to re-observe — used right after a demo action lands. */
export function invalidateSuperCredState(): void {
  lastObservedAt = 0
  consecutiveFailures = 0
}

// ─── Demo actions ────────────────────────────────────────────────────────────

interface ComplianceScanResponse {
  agent_id: string
  compliant: boolean
  results: { check: string; pass: boolean; reason: string }[]
  evaluated_at: string
}

/**
 * Record a compliance scan result so step 3 moves the main pages.
 *
 * The proxy evaluates the pod spec but does not relabel the pod, so a
 * UI-driven scan would otherwise be invisible outside the SuperCred page.
 */
export function recordScanResult(response: ComplianceScanResponse): SuperCredScanObservation {
  const observation: SuperCredScanObservation = {
    evaluated_at: response.evaluated_at,
    compliant: response.compliant,
    failed_checks: (response.results ?? []).filter((r) => !r.pass).map((r) => r.check),
  }
  recordScan(observation)
  invalidateSuperCredState()
  return observation
}

/** Reset everything — used by tests and by a demo teardown. */
export function resetSuperCredSource(): void {
  lastObservedAt = 0
  inflight = null
  consecutiveFailures = 0
  simPhase = 'absent'
  try {
    localStorage.removeItem(SIM_KEY)
  } catch {
    /* storage unavailable */
  }
}
