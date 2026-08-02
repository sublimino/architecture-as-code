import { useState, useCallback } from 'react'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'
import { isDemoMode } from '../api/demoMode'
import {
  discoverSuperCredAgents,
  getSimulatedPhase,
  scanSuperCredAgent,
  setSimulatedPhase,
  stunSuperCredAgent,
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

interface StunResponse {
  agent_id: string
  state: string
  stunned_at: string
  message: string
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

interface LifecycleStep {
  step: number
  label: string
  description: string
  status: 'completed' | 'active' | 'pending' | 'failed'
  timestamp: string | null
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

function buildLifecycleSteps(agent: RuntimeAgent): LifecycleStep[] {
  const isStunned = agent.state === 'stunned'
  const hasAgent = !!agent.id
  return [
    {
      step: 1,
      label: 'Agent Deployment',
      description: 'demo-cc-agent deployed via Flux into cluster namespace',
      status: hasAgent ? 'completed' : 'pending',
      timestamp: hasAgent ? '2026-01-01T00:00:01Z' : null,
    },
    {
      step: 2,
      label: 'SPIFFE Identity',
      description: 'Workload identity issued via SPIRE — SVID bound to pod service account',
      status: hasAgent ? 'completed' : 'pending',
      timestamp: hasAgent ? '2026-01-01T00:00:02Z' : null,
    },
    {
      step: 3,
      label: 'OpenBao Exchange',
      description: 'SVID exchanged for OpenBao dynamic secret — short-lived credential minted',
      status: hasAgent ? 'completed' : 'pending',
      timestamp: hasAgent ? '2026-01-01T00:00:03Z' : null,
    },
    {
      step: 4,
      label: 'Service Access',
      description: 'Agent calls fake credit-card service using minted credential',
      status: hasAgent ? 'completed' : 'pending',
      timestamp: hasAgent ? '2026-01-01T00:00:04Z' : null,
    },
    {
      step: 5,
      label: 'Compliance Scan',
      description: 'Platform scans agent pod for securityContext, resource limits, and network policy',
      status: hasAgent ? 'active' : 'pending',
      timestamp: hasAgent ? '2026-01-01T00:00:05Z' : null,
    },
    {
      step: 6,
      label: 'Platform Response',
      description: isStunned
        ? 'Credential revoked and agent isolated — OpenBao lease terminated'
        : 'Awaiting operator action — stun available if non-compliant',
      status: isStunned ? 'failed' : 'pending',
      timestamp: isStunned ? (agent.stunned_at ?? '2026-01-01T00:01:00Z') : null,
    },
  ]
}

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

const CRED_STATUS_COLORS: Record<CredentialStatus, { bg: string; fg: string }> = {
  pending:  { bg: 'rgba(71,85,105,0.15)', fg: 'var(--muted)' },
  issued:   { bg: 'rgba(6,182,212,0.12)', fg: 'var(--cyan)' },
  active:   { bg: 'rgba(16,185,129,0.12)', fg: 'var(--teal)' },
  rotated:  { bg: 'rgba(139,92,246,0.12)', fg: 'var(--violet)' },
  revoked:  { bg: 'rgba(220,38,38,0.12)', fg: 'var(--error)' },
  expired:  { bg: 'rgba(217,119,6,0.12)', fg: 'var(--amber)' },
}

const STEP_STATUS_COLORS: Record<string, { bg: string; border: string; dot: string }> = {
  completed: { bg: 'rgba(16,185,129,0.08)', border: 'rgba(16,185,129,0.3)', dot: colors.tealLoom },
  active:    { bg: 'rgba(6,182,212,0.08)', border: 'rgba(6,182,212,0.3)', dot: colors.cyanLoom },
  pending:   { bg: 'rgba(71,85,105,0.08)', border: 'rgba(71,85,105,0.2)', dot: colors.slateGray },
  failed:    { bg: 'rgba(220,38,38,0.08)', border: 'rgba(220,38,38,0.3)', dot: colors.red },
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

// ─── SuperCred Demo Page ────────────────────────────────────────────────────

export default function SuperCredPage() {
  const [agents, setAgents] = useState<RuntimeAgent[]>([])
  // null until a fetch completes, so "never loaded" is distinguishable from
  // "loaded and genuinely empty" — the two used to render identically.
  const [discoveredCount, setDiscoveredCount] = useState<number | null>(null)
  const [namespaces, setNamespaces] = useState<string[]>([])
  const [loading, setLoading] = useState(false)
  const [compliance, setCompliance] = useState<ComplianceResponse | null>(null)
  const [scanLoading, setScanLoading] = useState(false)
  const [stunResult, setStunResult] = useState<StunResponse | null>(null)
  const [stunLoading, setStunLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

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
    }
  }, [])

  const stunAgent = useCallback(async (agent: RuntimeAgent) => {
    setStunLoading(true)
    setStunResult(null)
    setError(null)
    try {
      const data = await stunSuperCredAgent(agentPath(agent, 'stun'), agent.id)
      setStunResult(data)
      // Reload agents to reflect new state
      await loadAgents()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Stun failed')
    } finally {
      setStunLoading(false)
    }
  }, [loadAgents])

  const blockedAgents = agents.filter(isBlocked)
  const code = { background: 'var(--surface)', padding: '2px 6px', borderRadius: 3, fontSize: 12 }

  // Derive lifecycle and credential data from the first supercred agent
  const activeAgent = agents[0] ?? null
  const lifecycleSteps = activeAgent ? buildLifecycleSteps(activeAgent) : []
  const credentialRecords = activeAgent ? buildCredentialRecords(activeAgent) : []

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>SuperCred Demo</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 12, lineHeight: 1.6 }}>
        Agent identity chain: SPIFFE workload identity → OpenBao secret exchange → credential-based service access.
        Run <code style={code}>make demo-signalloom-supercred-1</code> first.
      </p>

      {/* Architecture overview */}
      <div data-testid="supercred-architecture" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>Architecture Overview</h2>
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

      {error && (
        <div data-testid="supercred-error" style={{ background: 'rgba(220,38,38,0.1)', border: '1px solid rgba(220,38,38,0.3)', borderRadius: 8, padding: '12px 16px', marginBottom: 16, color: colors.red, fontSize: 13 }}>
          {error}
        </div>
      )}

      {blockedAgents.length > 0 && (
        <div data-testid="supercred-phase-warning" style={{ background: 'rgba(245,158,11,0.1)', border: '1px solid rgba(245,158,11,0.35)', borderRadius: 8, padding: '12px 16px', marginBottom: 16, color: colors.amber, fontSize: 13, lineHeight: 1.6 }}>
          {blockedAgents.map(a => (
            <div key={a.id}>
              <strong>{a.name}</strong> is in phase <code style={code}>{a.phase}</code> — it cannot run.
            </div>
          ))}
          <div style={{ marginTop: 6 }}>
            This is usually a missing kind-loaded image. Load them with{' '}
            <code style={code}>make demo-signalloom-supercred-images</code>.
          </div>
        </div>
      )}

      <DemoStepControls onAdvance={loadAgents} />

      {/* Load agents */}
      <div className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>SuperCred Agents</h2>
          <button className="btn btn-primary" onClick={loadAgents} disabled={loading} style={{ fontSize: 12, padding: '6px 14px' }}>
            {loading ? 'Loading...' : 'Refresh Agents'}
          </button>
        </div>
        {agents.length > 0 && (
          <div style={{ marginTop: 12 }}>
            {agents.map(agent => (
              <div key={agent.id} style={{
                display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                padding: '10px 0', borderBottom: '1px solid var(--border)',
              }}>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 4 }}>
                    <span style={{ fontWeight: 600, fontSize: 14 }}>{agent.name}</span>
                    <StatusBadge status={agent.state ?? 'unknown'} />
                    {agent.type && <span style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>{agent.type}</span>}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--muted)' }}>
                    {agent.namespace && (
                      <span data-testid={`agent-namespace-${agent.id}`}>Namespace: {agent.namespace} · </span>
                    )}
                    {agent.phase && <span>Phase: {agent.phase} · </span>}
                    {agent.model && <span>Model: {agent.model} · </span>}
                    {agent.framework && <span>Framework: {agent.framework} · </span>}
                    {agent.supercred_target && <span>Target: {agent.supercred_target}</span>}
                    {agent.stunned_at && <span style={{ color: colors.red }}> · Stunned: {agent.stunned_at}</span>}
                    {agent.stun_reason && <span style={{ color: colors.red }}> ({agent.stun_reason})</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button
                    className="btn btn-secondary"
                    style={{ fontSize: 11, padding: '4px 10px' }}
                    onClick={() => runComplianceScan(agent)}
                    disabled={scanLoading}
                  >
                    {scanLoading ? 'Scanning...' : 'Compliance Scan'}
                  </button>
                  {agent.state !== 'stunned' && (
                    <button
                      className="btn btn-secondary"
                      style={{ fontSize: 11, padding: '4px 10px', color: colors.red, borderColor: colors.red }}
                      onClick={() => stunAgent(agent)}
                      disabled={stunLoading}
                    >
                      {stunLoading ? 'Stunning...' : 'Stun Agent'}
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
        {agents.length === 0 && !loading && discoveredCount === null && (
          <p data-testid="supercred-not-loaded" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 12 }}>
            Agents not loaded yet. Click <strong>Refresh Agents</strong> to query the runtime.
          </p>
        )}
        {agents.length === 0 && !loading && discoveredCount !== null && (
          <div data-testid="supercred-empty-state" style={{ fontSize: 12, color: 'var(--muted)', marginTop: 12, lineHeight: 1.7 }}>
            {discoveredCount === 0 ? (
              <p style={{ margin: 0 }}>The proxy returned no runtime agents at all.</p>
            ) : (
              <p style={{ margin: 0 }}>
                Discovery found {discoveredCount} runtime agents, but none carries the SuperCred
                label <code style={code}>signalloom.ai/supercred=true</code>.
              </p>
            )}
            <p style={{ margin: '6px 0 0' }}>
              Deploy the SuperCred agent with <code style={code}>make demo-signalloom-supercred-1</code>.
            </p>
            {namespaces.length > 0 && (
              <p style={{ margin: '6px 0 0' }}>Namespaces searched: {namespaces.join(', ')}</p>
            )}
          </div>
        )}
      </div>

      {/* Credential Lifecycle Timeline */}
      {activeAgent && (
        <div data-testid="supercred-lifecycle" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>Credential Lifecycle</h2>
          <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 12, lineHeight: 1.5 }}>
            Each step in the SuperCred chain for <strong>{activeAgent.name}</strong>.
            The platform enforces policy at every transition.
          </p>
          <div data-testid="supercred-lifecycle-steps" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {lifecycleSteps.map((step) => {
              const sc = STEP_STATUS_COLORS[step.status] ?? STEP_STATUS_COLORS.pending
              return (
                <div key={step.step} data-testid={`lifecycle-step-${step.step}`} style={{
                  display: 'flex', alignItems: 'flex-start', gap: 12,
                  padding: '10px 14px', borderRadius: 6,
                  background: sc.bg, border: `1px solid ${sc.border}`,
                }}>
                  <div style={{
                    width: 10, height: 10, borderRadius: '50%',
                    background: sc.dot, marginTop: 4, flexShrink: 0,
                  }} />
                  <div style={{ flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <span style={{ fontWeight: 600, fontSize: 13 }}>
                        Step {step.step}: {step.label}
                      </span>
                      <span data-testid={`lifecycle-status-${step.step}`} style={{
                        fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                        padding: '1px 6px', borderRadius: 3,
                        background: sc.border, color: sc.dot,
                      }}>
                        {step.status}
                      </span>
                    </div>
                    <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, lineHeight: 1.4 }}>
                      {step.description}
                    </div>
                    {step.timestamp && (
                      <div style={{ fontSize: 10, color: 'var(--muted)', marginTop: 2 }}>
                        {step.timestamp}
                      </div>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Credential Status Table */}
      {activeAgent && (
        <div data-testid="supercred-credentials" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>Credential Inventory</h2>
          <table style={{ width: '100%', fontSize: 12, borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Credential ID</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Issuer</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Scope</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Status</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Issued</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Expires</th>
                <th style={{ textAlign: 'left', padding: '8px 10px', fontWeight: 600, fontSize: 11 }}>Rotations</th>
              </tr>
            </thead>
            <tbody>
              {credentialRecords.map(cred => {
                const sc = CRED_STATUS_COLORS[cred.status]
                return (
                  <tr key={cred.id} data-testid={`credential-row-${cred.id}`} style={{ borderBottom: '1px solid var(--border)' }}>
                    <td style={{ padding: '8px 10px', fontFamily: 'monospace', fontSize: 11 }}>{cred.id}</td>
                    <td style={{ padding: '8px 10px', fontFamily: 'monospace', fontSize: 11 }}>{cred.issuer}</td>
                    <td style={{ padding: '8px 10px', fontSize: 11 }}>{cred.scope}</td>
                    <td style={{ padding: '8px 10px' }}>
                      <span data-testid={`credential-status-${cred.id}`} style={{
                        display: 'inline-block', padding: '2px 8px', borderRadius: 4,
                        fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                        background: sc.bg, color: sc.fg,
                      }}>
                        {cred.status}
                      </span>
                    </td>
                    <td style={{ padding: '8px 10px', fontSize: 10, color: 'var(--muted)' }}>{cred.issued_at ?? '-'}</td>
                    <td style={{ padding: '8px 10px', fontSize: 10, color: 'var(--muted)' }}>{cred.expires_at ?? '-'}</td>
                    <td style={{ padding: '8px 10px', textAlign: 'center' }}>{cred.rotation_count}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Compliance results */}
      {compliance && (
        <div data-testid="supercred-compliance" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Compliance Scan Results</h2>
            <StatusBadge status={compliance.compliant ? 'compliant' : 'non-compliant'} variant="compliance" />
          </div>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 8 }}>
            Agent: {compliance.agent_id} · Evaluated: {compliance.evaluated_at}
          </div>
          <div data-testid="supercred-compliance-summary" style={{
            display: 'flex', gap: 16, marginBottom: 12, fontSize: 12,
          }}>
            <span style={{ color: colors.tealLoom }}>
              {compliance.results.filter(r => r.pass).length} passed
            </span>
            <span style={{ color: colors.red }}>
              {compliance.results.filter(r => !r.pass).length} failed
            </span>
            <span style={{ color: 'var(--muted)' }}>
              {compliance.results.length} total checks
            </span>
          </div>
          <table style={{ width: '100%', fontSize: 13, borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Check</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Result</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Severity</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Reason</th>
              </tr>
            </thead>
            <tbody>
              {compliance.results.map(r => (
                <tr key={r.check} style={{ borderBottom: '1px solid var(--border)' }}>
                  <td style={{ padding: '8px 12px', fontFamily: 'monospace', fontSize: 12 }}>{r.check}</td>
                  <td style={{ padding: '8px 12px' }}>
                    <span style={{
                      display: 'inline-block', padding: '2px 8px', borderRadius: 4,
                      fontSize: 11, fontWeight: 600,
                      background: r.pass ? 'rgba(20,184,166,0.15)' : 'rgba(220,38,38,0.12)',
                      color: r.pass ? colors.tealLoom : colors.red,
                    }}>
                      {r.pass ? 'PASS' : 'FAIL'}
                    </span>
                  </td>
                  <td style={{ padding: '8px 12px' }}>
                    <span style={{
                      fontSize: 10, fontWeight: 600, textTransform: 'uppercase',
                      color: r.severity === 'critical' ? colors.red
                        : r.severity === 'high' ? colors.amber
                        : 'var(--muted)',
                    }}>
                      {r.severity ?? 'medium'}
                    </span>
                  </td>
                  <td style={{ padding: '8px 12px', fontSize: 12, color: 'var(--muted)' }}>{r.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Stun result */}
      {stunResult && (
        <div data-testid="supercred-stun-result" className="card" style={{
          padding: '16px 20px', marginBottom: 16,
          border: '1px solid rgba(220,38,38,0.4)', background: 'rgba(220,38,38,0.05)',
        }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8, color: colors.red }}>Agent Stunned</h2>
          <p style={{ fontSize: 13, marginBottom: 4 }}>{stunResult.message}</p>
          <p style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 8 }}>Stunned at: {stunResult.stunned_at}</p>
          <div data-testid="supercred-stun-actions" style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
            <strong>Automated actions taken:</strong>
            <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>
              <li>OpenBao dynamic lease revoked</li>
              <li>SPIFFE SVID rotation blocked</li>
              <li>Agent network policy set to deny-all egress</li>
              <li>Incident logged to audit trail</li>
            </ul>
          </div>
        </div>
      )}

      {/* Agent Discovery Summary */}
      {discoveredCount !== null && (
        <div data-testid="supercred-discovery-summary" className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>Discovery Summary</h2>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
            <div style={{ textAlign: 'center', padding: '12px 8px', background: 'var(--surface)', borderRadius: 6 }}>
              <div data-testid="discovery-total" style={{ fontSize: 24, fontWeight: 700, color: colors.cyanLoom }}>{discoveredCount}</div>
              <div style={{ fontSize: 11, color: 'var(--muted)' }}>Total Agents</div>
            </div>
            <div style={{ textAlign: 'center', padding: '12px 8px', background: 'var(--surface)', borderRadius: 6 }}>
              <div data-testid="discovery-supercred" style={{ fontSize: 24, fontWeight: 700, color: colors.tealLoom }}>{agents.length}</div>
              <div style={{ fontSize: 11, color: 'var(--muted)' }}>SuperCred</div>
            </div>
            <div style={{ textAlign: 'center', padding: '12px 8px', background: 'var(--surface)', borderRadius: 6 }}>
              <div data-testid="discovery-namespaces" style={{ fontSize: 24, fontWeight: 700, color: colors.irisViolet }}>{namespaces.length}</div>
              <div style={{ fontSize: 11, color: 'var(--muted)' }}>Namespaces</div>
            </div>
            <div style={{ textAlign: 'center', padding: '12px 8px', background: 'var(--surface)', borderRadius: 6 }}>
              <div data-testid="discovery-blocked" style={{ fontSize: 24, fontWeight: 700, color: blockedAgents.length > 0 ? colors.red : colors.tealLoom }}>{blockedAgents.length}</div>
              <div style={{ fontSize: 11, color: 'var(--muted)' }}>Blocked</div>
            </div>
          </div>
          {namespaces.length > 0 && (
            <div data-testid="discovery-namespace-list" style={{ fontSize: 11, color: 'var(--muted)', marginTop: 10 }}>
              Searched: {namespaces.join(', ')}
            </div>
          )}
        </div>
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
