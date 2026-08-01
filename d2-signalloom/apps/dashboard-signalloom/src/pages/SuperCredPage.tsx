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
  type: string | null
  framework: string | null
  model: string | null
  state: string | null
  supercred?: boolean
  supercred_target?: string
  stunned_at?: string
  stun_reason?: string
}

// ─── SuperCred Demo Page ────────────────────────────────────────────────────

export default function SuperCredPage() {
  const [agents, setAgents] = useState<RuntimeAgent[]>([])
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
      const supercredAgents = (data.agents ?? []).filter(
        (a: RuntimeAgent) => a.supercred === true,
      )
      setAgents(supercredAgents)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load agents')
    } finally {
      setLoading(false)
    }
  }, [])

  const runComplianceScan = useCallback(async (agentId: string) => {
    setScanLoading(true)
    setCompliance(null)
    setError(null)
    try {
      const res = await fetch(`/supercred/agents/${agentId}/compliance`)
      if (!res.ok) throw new Error(`Compliance check failed: ${res.status}`)
      const data: ComplianceResponse = await res.json()
      setCompliance(data)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Compliance scan failed')
    } finally {
      setScanLoading(false)
    }
  }, [])

  const stunAgent = useCallback(async (agentId: string) => {
    setStunLoading(true)
    setStunResult(null)
    setError(null)
    try {
      const res = await fetch(`/supercred/agents/${agentId}/stun`, { method: 'POST' })
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

  const supercredAgent = agents.find(a => a.id === 'agent-cardvault')

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: '32px 24px' }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 6 }}>SuperCred Demo</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 24, lineHeight: 1.6 }}>
        Agent identity chain: SPIFFE workload identity → OpenBao secret exchange → credential-based service access.
        Run <code style={{ background: 'var(--surface)', padding: '2px 6px', borderRadius: 3, fontSize: 12 }}>make demo-supercred-step1</code> first.
      </p>

      {error && (
        <div style={{ background: 'rgba(220,38,38,0.1)', border: '1px solid rgba(220,38,38,0.3)', borderRadius: 8, padding: '12px 16px', marginBottom: 16, color: colors.red, fontSize: 13 }}>
          {error}
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
                    {agent.model && <span>Model: {agent.model} · </span>}
                    {agent.supercred_target && <span>Target: {agent.supercred_target}</span>}
                    {agent.stunned_at && <span style={{ color: colors.red }}> · Stunned: {agent.stunned_at}</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button
                    className="btn btn-secondary"
                    style={{ fontSize: 11, padding: '4px 10px' }}
                    onClick={() => runComplianceScan(agent.id)}
                    disabled={scanLoading}
                  >
                    {scanLoading ? 'Scanning…' : '🔍 Compliance Scan'}
                  </button>
                  {agent.state !== 'stunned' && (
                    <button
                      className="btn btn-secondary"
                      style={{ fontSize: 11, padding: '4px 10px', color: colors.red, borderColor: colors.red }}
                      onClick={() => stunAgent(agent.id)}
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
        {agents.length === 0 && !loading && (
          <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 12 }}>
            No SuperCred agents found. Run <code>make demo-supercred-step1</code> to deploy.
          </p>
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
        <div className="card" style={{
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
        <ol style={{ fontSize: 13, lineHeight: 1.8, paddingLeft: 20, margin: 0 }}>
          <li><code>make demo-supercred-step1</code> — Deploy services + agent + OpenBao secrets</li>
          <li><code>make demo-supercred-step2</code> — Run SPIFFE → OpenBao → cardvault credential chain</li>
          <li>Click <strong>Refresh Agents</strong> above, then <strong>Compliance Scan</strong> — discovers missing securityContext</li>
          <li>Click <strong>Stun Agent</strong> — revokes OpenBao credentials, marks agent as stunned</li>
          <li><code>make demo-supercred-down</code> — Tear down</li>
        </ol>
      </div>
    </div>
  )
}
