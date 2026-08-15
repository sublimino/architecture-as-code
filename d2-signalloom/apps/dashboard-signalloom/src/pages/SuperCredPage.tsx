import { useState, useCallback, useEffect, useMemo, type CSSProperties } from 'react'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import SuperCredInstructorPanel from '../components/SuperCredInstructorPanel'
import { CredentialEvidencePanel } from '../components/CredentialEvidencePanel'
import HelpHint from '../components/HelpHint'
import ButtonWait from '../components/ButtonWait'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import LoadingState from '../components/LoadingState'
import { StatCard } from '../components/DashKit'
import { useAppContext } from '../App'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { AuditEventResponse, StunAgentResponse } from '../types/api'
import { isDemoMode } from '../api/demoMode'
import {
  discoverSuperCredAgents,
  getSimulatedPhase,
  recordStunResult,
  scanSuperCredAgent,
  setSimulatedPhase,
} from '../api/supercredSource'
import type { SuperCredPhase } from '../api/supercredTypes'

// ─── Types ──────────────────────────────────────────────────────────────────

interface ComplianceResult {
  check: string
  pass: boolean
  reason: string
  severity?: 'critical' | 'high' | 'medium' | 'low'
}

interface ComplianceResponse {
  agent_id: string
  compliant: boolean
  results: ComplianceResult[]
  evaluated_at: string
}

interface RuntimeAgent {
  id: string
  name: string
  /** Namespace the proxy discovered the pod in — Flux may relocate it. */
  namespace?: string | null
  type: string | null
  framework: string | null
  model: string | null
  state: string | null
  phase?: string | null
  supercred?: boolean
  supercred_target?: string
  stunned_at?: string
  stun_reason?: string
}

// ─── Credential Lifecycle Types ─────────────────────────────────────────────

type CredentialStatus = 'pending' | 'issued' | 'active' | 'rotated' | 'revoked' | 'expired'

interface CredentialRecord {
  id: string
  agent_id: string
  status: CredentialStatus
  issued_at: string | null
  expires_at: string | null
  revoked_at: string | null
  issuer: string
  scope: string
  rotation_count: number
}


// A pod whose image never loaded reports phase `Pending` — `ImagePullBackOff` is
// a container waiting reason, not a phase — so `Pending` has to count as blocked.
// The proxy exposes `status.phase` verbatim, so accept the waiting reasons too in
// case a future revision surfaces them.
const BLOCKED_PHASES = new Set(['Pending', 'Failed', 'Unknown', 'ImagePullBackOff', 'ErrImagePull'])

function isBlocked(agent: RuntimeAgent): boolean {
  return agent.phase != null && BLOCKED_PHASES.has(agent.phase)
}

// Distinct from this page's own `/supercred` route: `/supercred/*` used to serve
// both the page and the API, and the API won. Not under `/api/` either — the
// gateway routes /api to fe-signalloom-api and it never reaches the dashboard's
// nginx. See the comment on this location block in nginx.conf.
const SUPERCRED_API = '/supercred-api'

/** Follow the agent to whichever namespace holds it, without requiring one. */
function agentPath(agent: RuntimeAgent, suffix: string): string {
  const base = `${SUPERCRED_API}/agents/${agent.id}/${suffix}`
  return agent.namespace ? `${base}?namespace=${encodeURIComponent(agent.namespace)}` : base
}

// ─── Fake lifecycle data for demo enrichment ────────────────────────────────

function buildCredentialRecords(agent: RuntimeAgent): CredentialRecord[] {
  const isStunned = agent.state === 'stunned'
  return [
    {
      id: `cred-${agent.id}-spiffe`,
      agent_id: agent.id,
      status: isStunned ? 'revoked' : 'active',
      issued_at: '2026-01-01T00:00:02Z',
      expires_at: '2026-01-01T01:00:02Z',
      revoked_at: isStunned ? (agent.stunned_at ?? '2026-01-01T00:01:00Z') : null,
      issuer: 'spire-server.spire-system',
      scope: 'spiffe://signalloom.ai/agent/cardvault',
      rotation_count: 0,
    },
    {
      id: `cred-${agent.id}-openbao`,
      agent_id: agent.id,
      status: isStunned ? 'revoked' : 'active',
      issued_at: '2026-01-01T00:00:03Z',
      expires_at: '2026-01-01T00:05:03Z',
      revoked_at: isStunned ? (agent.stunned_at ?? '2026-01-01T00:01:00Z') : null,
      issuer: 'openbao.openbao-system',
      scope: 'database/creds/cardvault-readonly',
      rotation_count: 2,
    },
    {
      id: `cred-${agent.id}-service`,
      agent_id: agent.id,
      status: isStunned ? 'expired' : 'active',
      issued_at: '2026-01-01T00:00:04Z',
      expires_at: '2026-01-01T00:10:04Z',
      revoked_at: null,
      issuer: 'cardvault-service',
      scope: 'api/v1/transactions:read',
      rotation_count: 0,
    },
  ]
}

// ─── Tables ─────────────────────────────────────────────────────────────────
//
// Both tables on this page are `DataTable` with a `toolbar` and an
// `emptyState`, which is the configuration the Design System page calls
// "Realistic". The division of labour is that page's, not a local invention:
// THIS page owns the search box, the chips and the predicate and hands
// DataTable an already-narrowed array; DataTable owns sorting, paging, the
// position of the strip — and the one guarantee worth having, that the strip
// outlives the table when a filter matches nothing. Stacking those by hand
// (`rows.length === 0 ? <EmptyState/> : <table/>`) takes the control that
// emptied the table down with it and strands the reader with no way back
// short of a reload. Mid-demo that is a reload in front of an audience.
//
// Column `help` strings are the other half of why these are DataTables. This
// screen is read at two altitudes at once — a bank executive who needs to know
// what a scope IS, and an engineer who needs to know which one this is — and a
// "?" in the header is how one table serves both without a second table.

/**
 * The agent list, which was a div-based list of records and is a fleet table.
 *
 * It reads as a card list because it usually holds one row, and that is exactly
 * how it stayed hand-rolled while every other fleet view in the product moved
 * to DataTable: one row hides the absence of sorting and filtering. Discovery
 * can return any number, and the actions column is the demo's own control
 * surface, so it belongs in the same table the rest of the estate is shown in.
 *
 * `Actions` keys off `id` because Column<T> keys must name a field — it is not
 * sortable, and nothing reads the key except the sort handler it never calls.
 */
const AGENT_COLUMNS: Column<RuntimeAgent>[] = [
  { key: 'name', label: 'Agent', sortable: true },
  { key: 'state', label: 'State', sortable: true },
  {
    key: 'phase',
    label: 'Phase',
    sortable: true,
    help: 'What Kubernetes says about the pod itself. Running means the container started — it says nothing about whether the agent is compliant, which is the next column along and a different question entirely.',
  },
  {
    key: 'namespace',
    label: 'Namespace',
    sortable: true,
    help: 'Where the pod was found. Discovery follows the agent rather than requiring a fixed location, because Flux can relocate it between deployments.',
  },
  { key: 'model', label: 'Model', sortable: true },
  { key: 'framework', label: 'Framework', sortable: true },
  {
    key: 'supercred_target',
    label: 'Target',
    sortable: true,
    help: 'The service this agent exchanges its credentials to reach. It is the thing that would be exposed if the agent were compromised, which is what makes revoking the chain worth doing.',
  },
  { key: 'id', label: 'Actions' },
]

const CREDENTIAL_COLUMNS: Column<CredentialRecord>[] = [
  { key: 'id', label: 'Credential ID', sortable: true },
  {
    key: 'issuer',
    label: 'Issuer',
    sortable: true,
    help: 'Which authority minted this credential. Three different ones, deliberately: SPIRE proves which workload the pod is, OpenBao mints a database credential from that proof, and the service itself grants the API scope. No shared password exists anywhere in that chain.',
  },
  {
    key: 'scope',
    label: 'Scope',
    sortable: true,
    help: 'Exactly what this credential unlocks, and nothing beyond it. A SPIFFE ID names one workload, an OpenBao path names one database role, an API scope names one endpoint — so a stolen credential buys an attacker one of those, not the estate.',
  },
  { key: 'status', label: 'Status', sortable: true },
  { key: 'issued_at', label: 'Issued', sortable: true },
  {
    key: 'expires_at',
    label: 'Expires',
    sortable: true,
    help: 'These expire in minutes, not months. That is what makes revocation instant: there is no long-lived secret to hunt down and rotate, so withdrawing the agent’s identity stops the next exchange from happening at all.',
  },
  {
    key: 'rotation_count',
    label: 'Rotations',
    sortable: true,
    help: 'How many times this credential has been re-minted since the agent started. Routine, not an incident — a chain that rotates is a chain where any single leaked credential is already stale.',
  },
]

const COMPLIANCE_COLUMNS: Column<ComplianceResult>[] = [
  { key: 'check', label: 'Check', sortable: true },
  { key: 'pass', label: 'Result', sortable: true },
  {
    key: 'severity',
    label: 'Severity',
    sortable: true,
    help: 'How much a failure of this check matters. Critical means the control is load-bearing for the credential chain — without it the agent can be made to do something its identity was never meant to allow.',
  },
  { key: 'reason', label: 'Reason' },
]

/** Lifecycle order, so the chips keep one order regardless of what the data holds. */
const CREDENTIAL_STATUS_ORDER: CredentialStatus[] = [
  'pending', 'issued', 'active', 'rotated', 'revoked', 'expired',
]

/** Which compliance rows to show. `all` first, then the two verdicts. */
const RESULT_FILTERS = ['all', 'pass', 'fail'] as const
type ResultFilter = (typeof RESULT_FILTERS)[number]

const searchStyle: CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  minWidth: 230,
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
}

const countStyle: CSSProperties = { fontSize: 11.5, color: 'var(--muted)' }

/**
 * One filter chip, in the treatment the Design System page settled on.
 *
 * Selected is a tinted fill plus a full-strength border rather than a solid
 * accent fill: text on solid cyan or amber fails AA in at least one of the
 * three themes, and this page is projected onto a screen in a room.
 *
 * The count is on the chip rather than only in the summary line because the
 * whole point of a chip that matches nothing is that you can see it will match
 * nothing before you press it.
 */
function FilterChip({
  label,
  count,
  selected,
  onSelect,
  testId,
}: {
  label: string
  count: number
  selected: boolean
  onSelect: () => void
  testId: string
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      data-testid={testId}
      style={{
        fontSize: 11.5,
        padding: '4px 9px',
        borderRadius: 4,
        cursor: 'pointer',
        color: selected ? 'var(--cyan)' : 'var(--muted)',
        background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
        // Longhands, never the `border` shorthand: mixing the two drops the
        // shorthand on re-render and leaves a chip with no border mid-switch.
        borderWidth: 1,
        borderStyle: 'solid',
        borderColor: selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)',
      }}
    >
      {label} <span style={{ color: 'var(--dim)' }}>{count}</span>
    </button>
  )
}

// ─── Demo-data mode step controls ───────────────────────────────────────────

/**
 * Step driver for demo-data mode.
 *
 * In live mode the cluster is the source of truth: `make demo-signalloom-
 * supercred-N` stamps the agent pod and every page follows. Demo-data mode has
 * no cluster, so steps 1, 2 and 5 — the ones with no button on this page — need
 * a way to advance the simulated one. Rendered only when demo mode is on; in
 * live mode this returns null and the cluster stays authoritative.
 */
const DEMO_STEPS: { phase: SuperCredPhase; label: string; hint: string }[] = [
  { phase: 'deployed', label: '1 · Deploy', hint: 'Agent + SPIRE entry + OpenBao secrets' },
  { phase: 'credentialed', label: '2 · Credential chain', hint: 'SPIFFE SVID → OpenBao → cardvault' },
  { phase: 'non-compliant', label: '3 · Compliance scan', hint: 'Finds the missing securityContext' },
  { phase: 'stunned', label: '4 · Stun', hint: 'Revoke credentials, isolate the agent' },
  { phase: 'absent', label: '5 · Teardown', hint: 'Remove the agent, return to a clean estate' },
]

function DemoStepControls({ onAdvance }: { onAdvance: () => void }) {
  const [phase, setPhase] = useState<SuperCredPhase>(() => getSimulatedPhase())
  if (!isDemoMode()) return null

  function advance(next: SuperCredPhase) {
    setSimulatedPhase(next)
    setPhase(next)
    onAdvance()
  }

  return (
    <div data-testid="supercred-demo-steps-control" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
      <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>Demo Mode — Step Control</h2>
      <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', lineHeight: 1.5 }}>
        No cluster is attached. Advance the simulated demo and watch the effects land on{' '}
        <strong>Agents</strong>, <strong>Compliance</strong>, <strong>Policy Compliance</strong>,{' '}
        <strong>Agent Posture</strong>, <strong>Risk Exposure</strong> and <strong>Audit Trail</strong>.
      </p>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {DEMO_STEPS.map((step) => (
          <button
            key={step.phase}
            className="btn btn-secondary"
            data-testid={`demo-step-${step.phase}`}
            title={step.hint}
            aria-pressed={phase === step.phase}
            onClick={() => advance(step.phase)}
            style={{
              fontSize: 12,
              padding: '6px 12px',
              borderColor: phase === step.phase ? 'var(--cyan)' : undefined,
              color: phase === step.phase ? 'var(--cyan)' : undefined,
            }}
          >
            {step.label}
          </button>
        ))}
      </div>
      <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 10 }}>
        Current simulated state: <strong data-testid="demo-current-phase">{phase}</strong>
      </div>
    </div>
  )
}

// ─── SuperCredential Demo Page ──────────────────────────────────────────────

/** The one user-facing name for this page — h1, nav label and document title. */
export const SUPERCRED_PAGE_TITLE = 'SuperCredential Demo'

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// Every wait on this page shows the pixel grid and a live elapsed figure — the
// treatment the instructor panel already uses for a running demo phase. A
// disabled button says "busy" and nothing more, and ninety seconds into a step
// nobody in the room can tell a slow proxy from a hung one.
//
// The three in-button waits are `ButtonWait`, which owns the loader's own
// width, its accessible name and its silence. What stays here is the other
// half of the no-jitter contract: a min-width on each BUTTON that already fits
// both its idle label and the wait, so the idle→busy swap does not move the
// row either. Those widths are RESERVED, not measured.

/** Fits the idle "Refresh Agents" with room to spare, and the wait. */
const LABELLED_BUTTON_W = 176
/** Fits the widest idle label in an agent row ("Compliance Scan") and a wait. */
const ROW_BUTTON_W = 112

export default function SuperCredPage() {
  const { getAccessTokenSilently } = useAuth0()
  const { superadmin } = useAppContext()
  const [agents, setAgents] = useState<RuntimeAgent[]>([])
  // null until a fetch completes, so "never loaded" is distinguishable from
  // "loaded and genuinely empty" — the two used to render identically.
  const [discoveredCount, setDiscoveredCount] = useState<number | null>(null)
  const [namespaces, setNamespaces] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [compliance, setCompliance] = useState<ComplianceResponse | null>(null)
  const [scanLoading, setScanLoading] = useState(false)
  const [stunResult, setStunResult] = useState<StunAgentResponse | null>(null)
  const [stunLoading, setStunLoading] = useState(false)
  const [stunEvent, setStunEvent] = useState<AuditEventResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Which row the in-flight scan or stun belongs to. `scanLoading` and
  // `stunLoading` are page-wide — they disable every row's buttons — so
  // without this the progress timer would tick on all of them at once and
  // claim five operations are running when one is.
  const [busyAgentId, setBusyAgentId] = useState<string | null>(null)
  // Table filters. Purely client-side, and the predicate lives here rather
  // than inside DataTable on purpose: "search" means different things to the
  // two tables — a credential is found by its issuer or its scope, a control
  // by the reason it failed — and a component that owned the word would be
  // handing both of them one opinion about it.
  const [agentSearch, setAgentSearch] = useState('')
  const [agentState, setAgentState] = useState<string>('all')
  const [credSearch, setCredSearch] = useState('')
  const [credStatus, setCredStatus] = useState<CredentialStatus | 'all'>('all')
  const [checkSearch, setCheckSearch] = useState('')
  const [checkResult, setCheckResult] = useState<ResultFilter>('all')

  const loadAgents = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      // Routed through supercredSource so discovery also works in demo-data
      // mode (no cluster) and so every main page observes the same state.
      const data = await discoverSuperCredAgents()
      const discovered = data.agents as RuntimeAgent[]
      setDiscoveredCount(discovered.length)
      setNamespaces(data.namespaces)
      setAgents(discovered.filter(a => a.supercred === true))
      // Surface both total failures and partial namespace failures so the
      // operator knows discovery was incomplete rather than silently short.
      if (data.error) setError(data.error)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load agents')
    } finally {
      setLoading(false)
    }
  }, [])

  const runComplianceScan = useCallback(async (agent: RuntimeAgent) => {
    setScanLoading(true)
    setBusyAgentId(agent.id)
    setCompliance(null)
    setError(null)
    try {
      // The scan result is recorded in the observation store so the finding
      // reaches Compliance, Policy Compliance, Agent Posture and Risk Exposure
      // — the proxy evaluates the pod but does not relabel it.
      const data = await scanSuperCredAgent(agentPath(agent, 'compliance'), agent.id)
      setCompliance(data as ComplianceResponse)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Compliance scan failed')
    } finally {
      setScanLoading(false)
      setBusyAgentId(null)
    }
  }, [])

  // One call isolates the agent AND records it.
  //
  // This used to be two: the browser POSTed the SuperCred proxy to relabel the
  // pod and revoke the lease, then POSTed fe-signalloom to write the audit row.
  // Everything between those two calls was a window in which the cluster was
  // mutated and nothing was written down — a closed tab, a token expiring
  // mid-demo (Dex runs storage: memory and regenerates signing keys on every
  // `make public`, so a 401 there is routine), or simply a failed second
  // request. The page could report the gap, which is why a "stunned but not
  // recorded" banner used to live here, but it could not close it.
  //
  // `POST /agents/{id}/stun` now calls the proxy itself and commits the state
  // change with its audit_events row in one transaction, so the window does not
  // exist to report. That is also why the partial-failure branch is gone rather
  // than merely unused: with one call there is no state in which the agent is
  // isolated but unrecorded, so a banner claiming otherwise could only mislead.
  const stunAgent = useCallback(async (agent: RuntimeAgent) => {
    setStunLoading(true)
    setBusyAgentId(agent.id)
    setStunResult(null)
    setStunEvent(null)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const data = await api.agents.stun(token, agent.id)
      setStunResult(data)
      setStunEvent(data.event ?? null)

      // Local only — no backend counterpart. Advances the simulated cluster in
      // demo mode and drops the cached observation so the other pages re-read.
      recordStunResult()

      // Reload agents to reflect new state
      await loadAgents()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Stun failed')
    } finally {
      setStunLoading(false)
      setBusyAgentId(null)
    }
  }, [loadAgents, getAccessTokenSilently])

  // No app-wide title router exists, so each page that wants one sets it and
  // puts the previous value back on unmount rather than leaving the tab
  // advertising a page the operator has navigated away from.
  useEffect(() => {
    const previous = document.title
    document.title = SUPERCRED_PAGE_TITLE
    return () => {
      document.title = previous
    }
  }, [])

  const blockedAgents = agents.filter(isBlocked)
  const code = { background: 'var(--surface)', padding: '2px 6px', borderRadius: 3, fontSize: 12 }

  // Agent-table filters. Chip set is built from the states discovery actually
  // returned rather than from the lifecycle vocabulary, because an agent's
  // runtime state is whatever the proxy reports and this page does not own
  // that list. Insertion order is first-seen, which is discovery order.
  const agentStateCounts = useMemo(() => {
    const counts = new Map<string, number>()
    for (const agent of agents) {
      const state = agent.state ?? 'unknown'
      counts.set(state, (counts.get(state) ?? 0) + 1)
    }
    return counts
  }, [agents])

  const visibleAgents = useMemo(() => {
    const q = agentSearch.trim().toLowerCase()
    return agents.filter(agent => {
      if (agentState !== 'all' && (agent.state ?? 'unknown') !== agentState) return false
      if (!q) return true
      return [agent.name, agent.namespace, agent.model, agent.framework, agent.type, agent.supercred_target]
        .some(field => field?.toLowerCase().includes(q))
    })
  }, [agents, agentSearch, agentState])

  // Derive lifecycle and credential data from the first supercred agent
  const activeAgent = agents[0] ?? null
  const credentialRecords = useMemo(
    () => (activeAgent ? buildCredentialRecords(activeAgent) : []),
    [activeAgent],
  )

  // Chip counts are read off the FULL record set, never the filtered one — a
  // count that shrinks as you filter tells you about the filter you already
  // applied instead of the one you are considering. Only statuses the data
  // actually holds get a chip: five permanently-zero chips are furniture.
  const credentialStatusCounts = useMemo(() => {
    const counts = new Map<CredentialStatus, number>()
    for (const cred of credentialRecords) {
      counts.set(cred.status, (counts.get(cred.status) ?? 0) + 1)
    }
    return counts
  }, [credentialRecords])

  const visibleCredentials = useMemo(() => {
    const q = credSearch.trim().toLowerCase()
    return credentialRecords.filter(cred => {
      if (credStatus !== 'all' && cred.status !== credStatus) return false
      if (!q) return true
      return (
        cred.id.toLowerCase().includes(q) ||
        cred.issuer.toLowerCase().includes(q) ||
        cred.scope.toLowerCase().includes(q)
      )
    })
  }, [credentialRecords, credSearch, credStatus])

  const complianceResults = useMemo(() => compliance?.results ?? [], [compliance])

  const complianceCounts = useMemo(
    () => ({
      all: complianceResults.length,
      pass: complianceResults.filter(r => r.pass).length,
      fail: complianceResults.filter(r => !r.pass).length,
    }),
    [complianceResults],
  )

  const visibleChecks = useMemo(() => {
    const q = checkSearch.trim().toLowerCase()
    return complianceResults.filter(r => {
      if (checkResult === 'pass' && !r.pass) return false
      if (checkResult === 'fail' && r.pass) return false
      if (!q) return true
      return (
        r.check.toLowerCase().includes(q) ||
        r.reason.toLowerCase().includes(q) ||
        (r.severity ?? 'medium').toLowerCase().includes(q)
      )
    })
  }, [complianceResults, checkSearch, checkResult])

  // The width cap is on the PROSE, not on the page — which is what every other
  // page carrying a DataTable already does (Credential Inventory, Network
  // Tests, Cryptography). A page-wide 900px cap was fine for a page of cards
  // and paragraphs and stopped being fine the moment a seven-column table
  // moved onto it: the last two columns fell off the right edge into a
  // horizontal scrollbar nobody in an audience is ever going to discover.
  return (
    <div style={{ margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>{SUPERCRED_PAGE_TITLE}</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 12, lineHeight: 1.6, maxWidth: 760 }}>
        Agent identity chain: SPIFFE workload identity → OpenBao secret exchange → credential-based service access.
        Run <code style={code}>make demo-signalloom-supercred-1</code> first.
      </p>

      {/* Architecture overview */}
      <div data-testid="supercred-architecture" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Architecture Overview</h2>
          {/* The two words the rest of this page assumes you already know. An
              executive in the room needs them before the first table means
              anything, and an engineer needs the diagram, not a definition —
              which is exactly the split a hint resolves without a second page. */}
          <HelpHint label="What SPIFFE and OpenBao do here" testId="supercred-architecture-help">
            SPIFFE gives each workload a cryptographic identity it cannot forge or lend out — the pod proves what it is rather than presenting a password anyone could steal. OpenBao then exchanges that proof for a credential that lasts minutes and unlocks one named thing. No shared secret exists to leak.
          </HelpHint>
        </div>
        <p style={{ fontSize: 13, color: 'var(--muted)', lineHeight: 1.6, margin: '0 0 12px' }}>
          SuperCred demonstrates a zero-trust credential lifecycle for AI agents operating
          within a Kubernetes cluster. Each agent receives a cryptographic workload identity
          (SPIFFE SVID) that it exchanges with OpenBao for short-lived, scoped credentials.
          The platform continuously monitors compliance posture and can revoke credentials
          and isolate agents in real time.
        </p>
        <div data-testid="supercred-flow-diagram" style={{
          display: 'grid', gridTemplateColumns: 'repeat(6, 1fr)', gap: 4,
          fontSize: 11, textAlign: 'center',
        }}>
          {[
            { label: 'Agent Deploy', icon: '1' },
            { label: 'SPIFFE SVID', icon: '2' },
            { label: 'OpenBao Exchange', icon: '3' },
            { label: 'Service Call', icon: '4' },
            { label: 'Compliance Scan', icon: '5' },
            { label: 'Enforce/Revoke', icon: '6' },
          ].map((s, i) => (
            <div key={s.label} style={{
              padding: '10px 4px', borderRadius: 6,
              background: 'var(--surface)', border: '1px solid var(--border)',
              position: 'relative',
            }}>
              <div style={{
                width: 20, height: 20, borderRadius: '50%', margin: '0 auto 6px',
                background: colors.cyanLoom, color: 'var(--on-accent)', fontSize: 11,
                fontWeight: 700, lineHeight: '20px',
              }}>
                {s.icon}
              </div>
              <div style={{ fontWeight: 600, lineHeight: 1.3 }}>{s.label}</div>
              {i < 5 && (
                <div style={{
                  position: 'absolute', right: -8, top: '50%', transform: 'translateY(-50%)',
                  color: 'var(--muted)', fontSize: 14, zIndex: 1,
                }}>→</div>
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Tinted from the tokens rather than a frozen rgba triple, so the
          banner follows the theme instead of being correct in exactly one of
          Dark, Light and Andy. The wording is --text and the colour is carried
          by the border and the fill: --error measures 3.03:1 on --surface in
          Dark, which is under AA for 13px body text, and an error nobody can
          read on a projector is the one message that must never be decorative.
          Same rule as LoadingState and the Design System's own disclaimer. */}
      {error && (
        <div data-testid="supercred-error" style={{
          background: 'color-mix(in srgb, var(--error) 10%, transparent)',
          border: '1px solid color-mix(in srgb, var(--error) 30%, transparent)',
          borderRadius: 8, padding: '12px 16px', marginBottom: 16,
          color: 'var(--text)', fontSize: 13,
        }}>
          {error}
        </div>
      )}

      {blockedAgents.length > 0 && (
        <div data-testid="supercred-phase-warning" style={{
          background: 'color-mix(in srgb, var(--amber) 10%, transparent)',
          border: '1px solid color-mix(in srgb, var(--amber) 35%, transparent)',
          borderRadius: 8, padding: '12px 16px', marginBottom: 16,
          color: 'var(--text)', fontSize: 13, lineHeight: 1.6,
        }}>
          {blockedAgents.map(a => (
            <div key={a.id}>
              <strong>{a.name}</strong> is in phase <code style={code}>{a.phase}</code> — it cannot run.
            </div>
          ))}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
            <span>
              This is usually a missing kind-loaded image. Load them with{' '}
              <code style={code}>make demo-signalloom-supercred-images</code>.
            </span>
            <HelpHint label="What a blocked pod phase means" tone="var(--amber)" testId="supercred-phase-help">
              Kubernetes reports a pod’s phase, and Pending, Failed or Unknown all mean the container never started. Nothing further down this page has been disproved by that — the agent has simply not run, so there is no credential chain to inspect either way.
            </HelpHint>
          </div>
        </div>
      )}

      {/* Live runner: phase status and links for everyone, controls for
          superadmins. Falls back to the simulated path below when the runner
          reports no script — the two coexist rather than replace each other. */}
      <SuperCredInstructorPanel superadmin={superadmin} onRefreshClients={loadAgents} />

      <DemoStepControls onAdvance={loadAgents} />

      {/* Load agents. A section rather than a card, because DataTable brings
          its own frame and a card inside a card draws two borders around one
          table — the same reason the two tables below this are sections. */}
      <section style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>SuperCred Agents</h2>
            {/* One hint on the section rather than one per row: the same
                explanation repeated down five rows is noise, and the word that
                needs explaining is the same word every time. Toned to --error
                because it explains the destructive control beside it.
                The name deliberately avoids the word "stunning" — the row
                button carries that as its accessible name while the stun is in
                flight, and a hint sharing it makes that assertion ambiguous. */}
            <HelpHint label="What a stun does to an agent" tone="var(--error)" testId="supercred-stun-help">
              Stunning withdraws the agent’s identity: the OpenBao lease is revoked, its next credential exchange is refused, and network policy stops its egress. It is not a shutdown — the pod keeps running, it simply can no longer prove who it is, so nothing downstream will talk to it. There is no undo.
            </HelpHint>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <button
              className="btn btn-primary"
              onClick={loadAgents}
              disabled={loading}
              style={{
                fontSize: 12, padding: '6px 14px', minWidth: LABELLED_BUTTON_W,
                display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
              }}
            >
              {loading
                ? <ButtonWait testId="supercred-refresh-loader" label="Refreshing" />
                : 'Refresh Agents'}
            </button>
            <HelpHint label="About the agent-list refresh" testId="supercred-refresh-agents-help">
              Refreshes only the visible SuperCred agent list from the runtime. It does not refresh demo-runner phase status or clear cached SuperCred state.
            </HelpHint>
          </div>
        </div>
        {/* Rendered only when discovery actually returned SuperCred agents, so
            DataTable's `emptyState` below can mean exactly one thing: a filter
            matched nothing. The two "no agents at all" branches underneath keep
            their own conditions — an estate with nothing in it and a filter
            hiding everything are different sentences and must not share one. */}
        {agents.length > 0 && (
          <div style={{ marginTop: 12 }}>
            <DataTable
              columns={AGENT_COLUMNS}
              data={visibleAgents}
              pageSize={10}
              testIdPrefix="supercred-agents-table"
              toolbar={
                <div
                  role="group"
                  aria-label="Filter the SuperCred agents"
                  style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
                >
                  <input
                    type="search"
                    aria-label="Search agents by name, namespace or model"
                    placeholder="Search name, namespace or model…"
                    value={agentSearch}
                    onChange={(e) => setAgentSearch(e.target.value)}
                    data-testid="supercred-agents-search"
                    style={searchStyle}
                  />
                  <FilterChip
                    label="all"
                    count={agents.length}
                    selected={agentState === 'all'}
                    onSelect={() => setAgentState('all')}
                    testId="supercred-agents-filter-all"
                  />
                  {[...agentStateCounts.keys()].map(state => (
                    <FilterChip
                      key={state}
                      label={state}
                      count={agentStateCounts.get(state) ?? 0}
                      selected={agentState === state}
                      onSelect={() => setAgentState(state)}
                      testId={`supercred-agents-filter-${state}`}
                    />
                  ))}
                  <span data-testid="supercred-agents-count" style={countStyle}>
                    {visibleAgents.length} of {agents.length} shown
                  </span>
                </div>
              }
              emptyState={
                <EmptyState
                  kicker="No agent matches those filters"
                  body="Clear the search box, or pick a different state — discovery still found the agents, this is only what is on screen."
                />
              }
              renderRow={(agent: RuntimeAgent) => (
                <tr key={agent.id} data-testid={`agent-row-${agent.id}`} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={DataTable.td}>
                    <div style={{ fontWeight: 600 }}>{agent.name}</div>
                    {agent.type && (
                      <div style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>{agent.type}</div>
                    )}
                  </td>
                  <td style={DataTable.td}>
                    <StatusBadge status={agent.state ?? 'unknown'} />
                    {/* Kept beside the state rather than in a column of its own:
                        a stun reason only exists for a stunned agent, so a column
                        for it would be empty on every row that is running. */}
                    {agent.stunned_at && (
                      <div style={{ fontSize: 11, color: colors.red }}>Stunned: {agent.stunned_at}</div>
                    )}
                    {agent.stun_reason && (
                      <div style={{ fontSize: 11, color: colors.red }}>{agent.stun_reason}</div>
                    )}
                  </td>
                  <td style={DataTable.td}>{agent.phase ?? '—'}</td>
                  {/* The testid stays on the cell it always named. The word
                      "Namespace:" moved into the column header, where a table
                      puts it. */}
                  <td data-testid={`agent-namespace-${agent.id}`} style={DataTable.td}>{agent.namespace ?? '—'}</td>
                  <td style={DataTable.td}>{agent.model ?? '—'}</td>
                  <td style={DataTable.td}>{agent.framework ?? '—'}</td>
                  <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11 }}>{agent.supercred_target ?? '—'}</td>
                  <td style={DataTable.td}>
                    <div style={{ display: 'flex', gap: 8 }}>
                      {/* Both row buttons carry the same min-width so the pair is
                          one stable block: the row must not re-flow when a label
                          is swapped for a wait, and both must stay put while the
                          figure counts. */}
                      <button
                        className="btn btn-secondary"
                        style={{
                          fontSize: 11, padding: '4px 10px', minWidth: ROW_BUTTON_W,
                          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                        }}
                        onClick={() => runComplianceScan(agent)}
                        disabled={scanLoading}
                      >
                        {scanLoading && busyAgentId === agent.id
                          ? (
                            <ButtonWait
                              testId={`supercred-scan-loader-${agent.id}`}
                              label="Compliance scan running"
                            />
                          )
                          : 'Compliance Scan'}
                      </button>
                      {agent.state !== 'stunned' && (
                        <button
                          className="btn btn-secondary"
                          style={{
                            fontSize: 11, padding: '4px 10px', color: colors.red, borderColor: colors.red,
                            minWidth: ROW_BUTTON_W,
                            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
                          }}
                          onClick={() => stunAgent(agent)}
                          disabled={stunLoading}
                        >
                          {stunLoading && busyAgentId === agent.id
                            ? (
                              <ButtonWait
                                testId={`supercred-stun-loader-${agent.id}`}
                                label="Stunning agent"
                              />
                            )
                            : 'Stun Agent'}
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              )}
            />
          </div>
        )}
        {/* Idle, not empty. LoadingState's fourth phase exists for exactly this
            distinction and it is the one this card must never lose: "we have
            not asked yet" and "we asked and the estate is clean" are opposite
            claims that used to render identically. The sentence naming the
            control to press stays — the phase says what is true, the sentence
            says what to do about it. */}
        {agents.length === 0 && !loading && discoveredCount === null && (
          <div data-testid="supercred-not-loaded" style={{ marginTop: 12 }}>
            <LoadingState status="idle" label="agents" testId="supercred-agents-load-state" />
            <p style={{ fontSize: 12, color: 'var(--muted)', margin: '6px 0 0' }}>
              Click <strong>Refresh Agents</strong> to query the runtime.
            </p>
          </div>
        )}
        {/* Empty, and a healthy zero rather than a fault: the query succeeded
            and the answer was nothing, which is what EmptyState is for. The
            detail underneath is kept verbatim because it is the difference
            between "nothing is deployed" and "things are deployed and none of
            them is labelled", and an operator mid-demo needs the label text and
            the namespaces that were searched, not a kicker. */}
        {agents.length === 0 && !loading && discoveredCount !== null && (
          <div data-testid="supercred-empty-state" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 12, lineHeight: 1.7 }}>
            <EmptyState
              kicker={discoveredCount === 0
                ? 'The proxy returned no runtime agents at all'
                : `Discovery found ${discoveredCount} runtime agents, but none carries the SuperCred label`}
              body="Deploy the SuperCred agent with make demo-signalloom-supercred-1."
            />
            {discoveredCount > 0 && (
              <p style={{ margin: 0 }}>
                The label discovery looks for is <code style={code}>signalloom.ai/supercred=true</code>.
              </p>
            )}
            {namespaces.length > 0 && (
              <p style={{ margin: '6px 0 0' }}>Namespaces searched: {namespaces.join(', ')}</p>
            )}
          </div>
        )}
      </section>

      {/* Credential Lifecycle — observed evidence, not asserted progress.
          The previous card derived all six steps from `!!agent.id` and printed
          hardcoded 2026-01-01 timestamps, which is why it showed everything
          completed after only the first deploy. Backed by the same script as
          `make demo-signalloom-supercred-evidence`. */}
      {activeAgent && (
        <div data-testid="supercred-lifecycle" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <CredentialEvidencePanel getToken={getAccessTokenSilently} />
        </div>
      )}

      {/* Credential inventory — DataTable, sortable, searchable, filterable.
          The status badge is StatusBadge on the `credential` variant rather
          than a colour map kept here: a credential's `pending` (an exchange in
          flight) and a compliance `pending` (an assessment nobody ran) are the
          same word meaning opposite things, and that distinction is already
          drawn once, in the shared component. */}
      {activeAgent && (
        <section data-testid="supercred-credentials" style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Credential Inventory</h2>
            <HelpHint label="What the Credential Inventory lists" testId="supercred-credentials-help">
              Every credential this agent currently holds. Three of them, not one login: an identity proving which workload it is, a database credential minted from that proof, and the API scope it may call. They are separate so that revoking one does not require trusting the other two.
            </HelpHint>
          </div>
          <DataTable
            columns={CREDENTIAL_COLUMNS}
            data={visibleCredentials}
            pageSize={10}
            testIdPrefix="supercred-credentials-table"
            toolbar={
              <div
                role="group"
                aria-label="Filter the credential inventory"
                style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
              >
                <input
                  type="search"
                  aria-label="Search credentials by ID, issuer or scope"
                  placeholder="Search ID, issuer or scope…"
                  value={credSearch}
                  onChange={(e) => setCredSearch(e.target.value)}
                  data-testid="supercred-credentials-search"
                  style={searchStyle}
                />
                <FilterChip
                  label="all"
                  count={credentialRecords.length}
                  selected={credStatus === 'all'}
                  onSelect={() => setCredStatus('all')}
                  testId="supercred-credentials-filter-all"
                />
                {CREDENTIAL_STATUS_ORDER.filter(s => credentialStatusCounts.has(s)).map(status => (
                  <FilterChip
                    key={status}
                    label={status}
                    count={credentialStatusCounts.get(status) ?? 0}
                    selected={credStatus === status}
                    onSelect={() => setCredStatus(status)}
                    testId={`supercred-credentials-filter-${status}`}
                  />
                ))}
                <span data-testid="supercred-credentials-count" style={countStyle}>
                  {visibleCredentials.length} of {credentialRecords.length} shown
                </span>
              </div>
            }
            emptyState={
              <EmptyState
                kicker="No credential matches those filters"
                body="Clear the search box, or pick a different status — the controls above are still there."
              />
            }
            renderRow={(cred: CredentialRecord) => (
              <tr key={cred.id} data-testid={`credential-row-${cred.id}`} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11 }}>{cred.id}</td>
                <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 11 }}>{cred.issuer}</td>
                <td style={{ ...DataTable.td, fontSize: 11 }}>{cred.scope}</td>
                <td style={DataTable.td}>
                  <StatusBadge
                    status={cred.status}
                    variant="credential"
                    testId={`credential-status-${cred.id}`}
                  />
                </td>
                <td style={{ ...DataTable.td, fontSize: 10, color: 'var(--muted)' }}>{cred.issued_at ?? '-'}</td>
                <td style={{ ...DataTable.td, fontSize: 10, color: 'var(--muted)' }}>{cred.expires_at ?? '-'}</td>
                <td style={{ ...DataTable.td, textAlign: 'center' }}>{cred.rotation_count}</td>
              </tr>
            )}
          />
        </section>
      )}

      {/* Compliance results */}
      {compliance && (
        <section data-testid="supercred-compliance" style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Compliance Scan Results</h2>
            <StatusBadge status={compliance.compliant ? 'compliant' : 'non-compliant'} variant="compliance" />
            <HelpHint label="What a compliance scan is checking" testId="supercred-compliance-help">
              Each row is one control evaluated against the running pod just now. A failure does not mean the agent has been attacked — it means a guardrail that would have contained an attack is not in place, which is why the platform can revoke the agent’s credentials rather than wait to find out.
            </HelpHint>
          </div>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 8 }}>
            Agent: {compliance.agent_id} · Evaluated: {compliance.evaluated_at}
          </div>
          {/* Counted over the WHOLE scan, never over the filtered rows. This
              line is the verdict the scan reached; the count in the toolbar
              below is how much of it is currently on screen. Collapsing the two
              would let a filter silently rewrite the finding, which on this
              page of all pages is the failure being argued against. */}
          <div data-testid="supercred-compliance-summary" style={{
            display: 'flex', gap: 16, marginBottom: 12, fontSize: 12,
          }}>
            <span style={{ color: colors.tealLoom }}>
              {complianceCounts.pass} passed
            </span>
            <span style={{ color: colors.red }}>
              {complianceCounts.fail} failed
            </span>
            <span style={{ color: 'var(--muted)' }}>
              {complianceCounts.all} total checks
            </span>
          </div>
          <DataTable
            columns={COMPLIANCE_COLUMNS}
            data={visibleChecks}
            pageSize={10}
            testIdPrefix="supercred-compliance-table"
            toolbar={
              <div
                role="group"
                aria-label="Filter the compliance results"
                style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
              >
                <input
                  type="search"
                  aria-label="Search compliance checks by name, reason or severity"
                  placeholder="Search check, reason or severity…"
                  value={checkSearch}
                  onChange={(e) => setCheckSearch(e.target.value)}
                  data-testid="supercred-compliance-search"
                  style={searchStyle}
                />
                {RESULT_FILTERS.map(filter => (
                  <FilterChip
                    key={filter}
                    label={filter}
                    count={complianceCounts[filter]}
                    selected={checkResult === filter}
                    onSelect={() => setCheckResult(filter)}
                    testId={`supercred-compliance-filter-${filter}`}
                  />
                ))}
                <span data-testid="supercred-compliance-count" style={countStyle}>
                  {visibleChecks.length} of {complianceResults.length} shown
                </span>
              </div>
            }
            emptyState={
              <EmptyState
                kicker="No check matches those filters"
                body="Clear the search box, or switch back to all — the scan itself is unchanged, this is only what is on screen."
              />
            }
            renderRow={(r: ComplianceResult) => (
              <tr key={r.check} data-testid={`compliance-row-${r.check}`} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={{ ...DataTable.td, fontFamily: 'monospace', fontSize: 12 }}>{r.check}</td>
                <td style={DataTable.td}>
                  <StatusBadge status={r.pass ? 'pass' : 'fail'} variant="compliance" />
                </td>
                <td style={DataTable.td}>
                  {/* Still a coloured word rather than a badge: StatusBadge has
                      no severity map, and forcing one of the existing variants
                      would resolve `critical` and `high` through a map that
                      means something else. Reported rather than worked around
                      by editing a component ten pages are using right now. */}
                  <span style={{
                    fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                    color: r.severity === 'critical' ? colors.red
                      : r.severity === 'high' ? colors.amber
                      : 'var(--muted)',
                  }}>
                    {r.severity ?? 'medium'}
                  </span>
                </td>
                <td style={{ ...DataTable.td, fontSize: 12, color: 'var(--muted)', whiteSpace: 'normal' }}>{r.reason}</td>
              </tr>
            )}
          />
        </section>
      )}

      {/* Stun result */}
      {stunResult && (
        <div data-testid="supercred-stun-result" className="card" style={{
          padding: '16px 20px', marginBottom: 16,
          border: '1px solid color-mix(in srgb, var(--error) 40%, transparent)',
          background: 'color-mix(in srgb, var(--error) 5%, transparent)',
        }}>
          {/* The heading is --text and the red is carried by the border and the
              fill. --error at 15px is 3.03:1 on --surface in Dark, under AA,
              and this is the one heading in the demo that the back of the room
              has to be able to read. Same trade the Design System page made for
              its "Simulated" tag. */}
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8, color: 'var(--text)' }}>Agent Stunned</h2>
          {/* The proxy's own wording when it gave one, otherwise composed from
              the lifecycle fields the response always carries. Read from
              `proxy` rather than the top level because that is where relayed
              claims live — see StunProxyReport. Display text, so composing it
              is fine; what must never be composed here is the audit record,
              and that arrives whole in `event` below. */}
          <p style={{ fontSize: 13, marginBottom: 4 }}>
            {stunResult.proxy?.message
              ?? `Agent ${stunResult.agent_id} isolated: ${stunResult.from_state} → ${stunResult.to_state}`}
          </p>
          <p style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 8 }}>Stunned at: {stunResult.stunned_at}</p>
          <div data-testid="supercred-stun-actions" style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
              <strong>Automated actions taken:</strong>
              <HelpHint label="What these four actions mean" tone="var(--error)" testId="supercred-stun-actions-help">
                A lease is a credential OpenBao issued with an expiry; revoking it invalidates it now rather than at expiry. Blocking SVID rotation stops the agent renewing the identity everything downstream checks. Deny-all egress stops it opening new connections. The observed, probe-by-probe version of these steps is the Credential Lifecycle card above, which runs a command per step and shows you the output.
              </HelpHint>
            </span>
            <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>
              <li>OpenBao dynamic lease revoked</li>
              <li>SPIFFE SVID rotation blocked</li>
              <li>Agent network policy set to deny-all egress</li>
              <li>Incident logged to audit trail</li>
            </ul>
          </div>

          {stunEvent && (
            <div data-testid="supercred-stun-event" style={{
              marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)',
              fontSize: 12, color: 'var(--muted)', lineHeight: 1.6,
            }}>
              <strong>Audit event recorded</strong> — visible on the{' '}
              <a href="/audit" style={{ color: 'var(--cyan)' }}>Audit Trail</a>.
              <div style={{ fontFamily: 'monospace', fontSize: 11, marginTop: 4 }}>
                <span data-testid="stun-event-type">{stunEvent.event_type}</span>
                {' · '}
                <span data-testid="stun-event-timestamp">{stunEvent.timestamp}</span>
                {' · agent '}
                <span data-testid="stun-event-agent">{stunEvent.agent_name ?? stunEvent.agent_id ?? '—'}</span>
                {' · actor '}
                <span data-testid="stun-event-actor">{stunEvent.actor}</span>
              </div>
            </div>
          )}

        </div>
      )}

      {/* Agent Discovery Summary */}
      {discoveredCount !== null && (
        <section data-testid="supercred-discovery-summary" style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Discovery Summary</h2>
            <HelpHint label="What discovery counted" testId="supercred-discovery-help">
              Discovery lists every agent running in the namespaces below, then narrows to the ones carrying the SuperCred label. Blocked counts pods Kubernetes never started — they are neither compliant nor non-compliant, because nothing about them has been evaluated.
            </HelpHint>
          </div>
          {/* DashKit's StatCard rather than four hand-rolled tiles: the same
              four numbers, in the treatment the other dashboards already use,
              and each one now says what it counted rather than leaving a bare
              figure under a two-word label. */}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>
            <div data-testid="discovery-total" style={{ display: 'flex', flex: '1 1 180px' }}>
              <StatCard label="Total Agents" value={String(discoveredCount)} sub="returned by discovery" accent={colors.cyanLoom} />
            </div>
            <div data-testid="discovery-supercred" style={{ display: 'flex', flex: '1 1 180px' }}>
              <StatCard label="SuperCred" value={String(agents.length)} sub="carry the supercred label" accent={colors.tealLoom} />
            </div>
            <div data-testid="discovery-namespaces" style={{ display: 'flex', flex: '1 1 180px' }}>
              <StatCard label="Namespaces" value={String(namespaces.length)} sub="searched" accent={colors.irisViolet} />
            </div>
            <div data-testid="discovery-blocked" style={{ display: 'flex', flex: '1 1 180px' }}>
              <StatCard
                label="Blocked"
                value={String(blockedAgents.length)}
                sub="cannot run"
                accent={blockedAgents.length > 0 ? colors.red : colors.tealLoom}
              />
            </div>
          </div>
          {namespaces.length > 0 && (
            <div data-testid="discovery-namespace-list" style={{ fontSize: 11, color: 'var(--muted)', marginTop: 10 }}>
              Searched: {namespaces.join(', ')}
            </div>
          )}
        </section>
      )}

      {/* Demo steps guide */}
      <div className="card" style={{ padding: '16px 20px' }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>Demo Steps</h2>
        <ol data-testid="supercred-demo-steps" style={{ fontSize: 13, lineHeight: 1.8, paddingLeft: 20, margin: 0 }}>
          <li><code>make demo-signalloom-supercred-images</code> — Build and kind-load the demo images</li>
          <li><code>make demo-signalloom-supercred-1</code> — Deploy services + agent + OpenBao secrets</li>
          <li><code>make demo-signalloom-supercred-2</code> — Run SPIFFE → OpenBao → cardvault credential chain</li>
          <li>Click <strong>Refresh Agents</strong> above, then <strong>Compliance Scan</strong> — discovers missing securityContext</li>
          <li>Click <strong>Stun Agent</strong> — revokes OpenBao credentials, marks agent as stunned</li>
          <li><code>make demo-signalloom-supercred-5</code> — Tear down</li>
        </ol>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 10, marginBottom: 0 }}>
          Steps 3 and 4 are also scriptable as <code style={code}>make demo-signalloom-supercred-3</code> and{' '}
          <code style={code}>make demo-signalloom-supercred-4</code>; <code style={code}>make demo-signalloom-supercred-all</code> runs 1→5.
        </p>
      </div>
    </div>
  )
}
