import { useState, useCallback } from 'react'
import { colors } from '../styles/tokens'
import StatusBadge from '../components/StatusBadge'

// ─── Types ──────────────────────────────────────────────────────────────────

interface ComplianceResult {
  check: string
  pass: boolean
  reason: string
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

// A pod whose image never loaded reports phase `Pending` — `ImagePullBackOff` is
// a container waiting reason, not a phase — so `Pending` has to count as blocked.
// The proxy exposes `status.phase` verbatim, so accept the waiting reasons too in
// case a future revision surfaces them.
const BLOCKED_PHASES = new Set(['Pending', 'Failed', 'Unknown', 'ImagePullBackOff', 'ErrImagePull'])

function isBlocked(agent: RuntimeAgent): boolean {
  return agent.phase != null && BLOCKED_PHASES.has(agent.phase)
}

/** Follow the agent to whichever namespace holds it, without requiring one. */
function agentPath(agent: RuntimeAgent, suffix: string): string {
  const base = `/supercred/agents/${agent.id}/${suffix}`
  return agent.namespace ? `${base}?namespace=${encodeURIComponent(agent.namespace)}` : base
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
      const res = await fetch('/supercred/agents')
      const data = await res.json()
      const discovered: RuntimeAgent[] = data.agents ?? []
      setDiscoveredCount(discovered.length)
      setNamespaces(data.namespaces ?? [])
      setAgents(discovered.filter(a => a.supercred === true))
      if (data.error) setError(String(data.error))
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
      const res = await fetch(agentPath(agent, 'compliance'))
      if (!res.ok) throw new Error(`Compliance check failed: ${res.status}`)
      const data: ComplianceResponse = await res.json()
      setCompliance(data)
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
      const res = await fetch(agentPath(agent, 'stun'), { method: 'POST' })
      if (!res.ok) throw new Error(`Stun failed: ${res.status}`)
      const data: StunResponse = await res.json()
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

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>SuperCred Demo</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 24, lineHeight: 1.6 }}>
        Agent identity chain: SPIFFE workload identity → OpenBao secret exchange → credential-based service access.
        Run <code style={code}>make demo-signalloom-supercred-1</code> first.
      </p>

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

      {/* Load agents */}
      <div className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>SuperCred Agents</h2>
          <button className="btn btn-primary" onClick={loadAgents} disabled={loading} style={{ fontSize: 12, padding: '6px 14px' }}>
            {loading ? 'Loading…' : 'Refresh Agents'}
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
                    {agent.supercred_target && <span>Target: {agent.supercred_target}</span>}
                    {agent.stunned_at && <span style={{ color: colors.red }}> · Stunned: {agent.stunned_at}</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button
                    className="btn btn-secondary"
                    style={{ fontSize: 11, padding: '4px 10px' }}
                    onClick={() => runComplianceScan(agent)}
                    disabled={scanLoading}
                  >
                    {scanLoading ? 'Scanning…' : '🔍 Compliance Scan'}
                  </button>
                  {agent.state !== 'stunned' && (
                    <button
                      className="btn btn-secondary"
                      style={{ fontSize: 11, padding: '4px 10px', color: colors.red, borderColor: colors.red }}
                      onClick={() => stunAgent(agent)}
                      disabled={stunLoading}
                    >
                      {stunLoading ? 'Stunning…' : '⚡ Stun Agent'}
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

      {/* Compliance results */}
      {compliance && (
        <div className="card" style={{ padding: '16px 20px', marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Compliance Scan Results</h2>
            <StatusBadge status={compliance.compliant ? 'compliant' : 'non-compliant'} variant="compliance" />
          </div>
          <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 12 }}>
            Agent: {compliance.agent_id} · Evaluated: {compliance.evaluated_at}
          </div>
          <table style={{ width: '100%', fontSize: 13, borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Check</th>
                <th style={{ textAlign: 'left', padding: '8px 12px', fontWeight: 600, fontSize: 12 }}>Result</th>
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
          <p style={{ fontSize: 11, color: 'var(--muted)' }}>Stunned at: {stunResult.stunned_at}</p>
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
