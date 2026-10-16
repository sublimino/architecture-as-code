import React, { useState, useMemo, useEffect } from 'react'
import { useSearchParams, Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import LoadingState from '../components/LoadingState'
import {
  demoPolicyEvaluationAgent,
  demoPolicyEvaluationAttestation,
  demoPolicyEvaluationChecks,
  demoPolicyEvaluationSource,
} from '../api/fakeData'
import type { PolicyCheckResult } from '../api/fakeData'
import { normalizeFrameworkId } from '../data/regulatoryFrameworks'
import type { AgentResponse, FrameworkResponse } from '../types/api'

// Live and demo are separate components so no fixture value can leak into
// live mode through a shared fallback. Demo renders the fixture evaluation;
// live renders only an agent the API returned, matched by exact identity, and
// shows every check as "not evaluated" because this page has no live
// evaluation-results API to read verdicts from.
export default function PolicyEvaluationPage() {
  return isDemoMode() ? <DemoPolicyEvaluation /> : <LivePolicyEvaluation />
}

// Same rule as the agents page drawer: exact id, exact name, or the bare id
// of a `<tenant>:<id>` record. Never case-folded, never a substring.
function matchesAgent(agent: AgentResponse, ref: string): boolean {
  return agent.id === ref || agent.name === ref || agent.id.endsWith(`:${ref}`)
}

function errorMessage(err: unknown): string {
  if (err instanceof Error && err.message) return err.message
  return String(err)
}

function isNotFound(err: unknown): boolean {
  const status = (err as { response?: { status?: number }; status?: number } | null)
  return status?.response?.status === 404 || status?.status === 404
}

type LiveLookup =
  | { state: 'loading' }
  | { state: 'error'; message: string }
  | { state: 'choose'; agents: AgentResponse[] }
  | { state: 'not-found' }
  | { state: 'found'; agent: AgentResponse }

const label: React.CSSProperties = { fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }

function LivePolicyEvaluation() {
  const { getAccessTokenSilently } = useAuth0()
  const [searchParams] = useSearchParams()
  const agentParam = searchParams.get('agent') ?? ''
  const normalizedFwId = normalizeFrameworkId(searchParams.get('framework') || 'eu-ai-act')
  const [lookup, setLookup] = useState<LiveLookup>({ state: 'loading' })
  // Bumped by the error state's Retry action to re-run the effect below without
  // duplicating its mounted-guard fetch logic at a second call site.
  const [retryKey, setRetryKey] = useState(0)

  useEffect(() => {
    let mounted = true
    setLookup({ state: 'loading' })
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const res = await api.agents.list(token)
        const agents = res.agents ?? []
        if (!agentParam) {
          if (mounted) setLookup({ state: 'choose', agents })
          return
        }
        const listed = agents.find(a => matchesAgent(a, agentParam))
        if (listed) {
          if (mounted) setLookup({ state: 'found', agent: listed })
          return
        }
        // Not on the loaded page of the list: ask for it directly by id.
        try {
          const fetched = await api.agents.get(token, agentParam)
          if (!mounted) return
          setLookup(fetched && matchesAgent(fetched, agentParam) ? { state: 'found', agent: fetched } : { state: 'not-found' })
        } catch (err) {
          if (!mounted) return
          setLookup(isNotFound(err) ? { state: 'not-found' } : { state: 'error', message: errorMessage(err) })
        }
      } catch (err) {
        if (mounted) setLookup({ state: 'error', message: errorMessage(err) })
      }
    })()
    return () => {
      mounted = false
    }
  }, [getAccessTokenSilently, agentParam, retryKey])

  // Breadcrumb landmark with muted links, matching the house pattern
  // (RemoteEnvironmentPage) rather than a plain unlabelled div.
  const breadcrumb = (
    <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--muted)', marginBottom: 16 }}>
      <Link to="/compliance" style={{ color: 'var(--muted)', textDecoration: 'none' }}>
        ← Back to Compliance
      </Link>
      <span>/</span>
      <span style={{ color: 'var(--text)', fontWeight: 600 }}>Policy Evaluation</span>
    </nav>
  )

  let body: React.ReactNode
  if (lookup.state === 'loading') {
    body = <LoadingState variant="block" status="loading" label="agent" testId="eval-loading" />
  } else if (lookup.state === 'error') {
    body = (
      <LoadingState
        variant="block"
        status="error"
        label="agent"
        error={lookup.message}
        onRetry={() => setRetryKey((k) => k + 1)}
        testId="eval-load-error"
      />
    )
  } else if (lookup.state === 'choose') {
    body = (
      <div className="card" data-testid="eval-choose-agent" style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 22, fontWeight: 700, margin: '0 0 8px', color: 'var(--text)' }}>Choose an agent to evaluate</h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginTop: 0 }}>
          Pick an agent below or open one from the <Link to="/agents" style={{ color: 'var(--cyan)' }}>agents page</Link>.
        </p>
        {lookup.agents.length === 0 ? (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No agents are registered for this tenant.</p>
        ) : (
          <ul style={{ margin: 0, paddingLeft: 18, fontSize: 13 }}>
            {lookup.agents.map(a => {
              const q = new URLSearchParams(searchParams)
              q.set('agent', a.id)
              return (
                <li key={a.id} style={{ marginBottom: 4 }}>
                  <Link to={{ search: `?${q.toString()}` }} style={{ color: 'var(--cyan)' }}>
                    {a.name}
                  </Link>
                </li>
              )
            })}
          </ul>
        )}
      </div>
    )
  } else if (lookup.state === 'not-found') {
    body = (
      <div className="card" role="status" data-testid="eval-agent-not-found" style={{ marginBottom: 24 }}>
        <strong>No agent matches {agentParam}</strong>
        <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 0 }}>
          Check the id or name, or pick one from the <Link to="/agents" style={{ color: 'var(--cyan)' }}>agents page</Link>.
        </p>
      </div>
    )
  } else {
    const agent = lookup.agent
    const summary = agent.compliance_summary
    body = (
      <>
        <div className="card" style={{ marginBottom: 24 }}>
          <h1 data-testid="eval-header-title" style={{ fontSize: 22, fontWeight: 700, margin: '0 0 8px', color: 'var(--text)' }}>
            Policy Evaluation: {agent.name}
          </h1>
          <div style={{ fontSize: 13, color: 'var(--muted)', display: 'flex', flexWrap: 'wrap', gap: 16 }}>
            <span>
              Framework: <strong data-testid="eval-framework-badge" style={{ color: 'var(--text)' }}>{normalizedFwId.toUpperCase()}</strong>
            </span>
            <span>
              Agent: <Link to={`/agents?agent=${encodeURIComponent(agent.id)}`} style={{ color: 'var(--cyan)' }}>{agent.id}</Link>
            </span>
            <span>
              SPIFFE:{' '}
              {agent.identity?.spiffe_id ? (
                <code style={{ fontSize: 12, color: 'var(--cyan)' }}>{agent.identity.spiffe_id}</code>
              ) : (
                <em>not reported</em>
              )}
            </span>
            <span>
              Model: {agent.runtime?.model ? <strong style={{ color: 'var(--text)' }}>{agent.runtime.model}</strong> : <em>not reported</em>}
            </span>
          </div>
          <div style={{ marginTop: 16, paddingTop: 16, borderTop: '1px solid var(--border)' }}>
            <div style={label}>Controls passing (agent record)</div>
            <div data-testid="eval-live-controls" style={{ fontSize: 20, fontWeight: 700, color: 'var(--text)', marginTop: 2 }}>
              {summary ? `${summary.passing} / ${summary.total_controls}` : 'not reported'}
            </div>
          </div>
        </div>
        <div className="card" data-testid="eval-not-evaluated" style={{ marginBottom: 24 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700, margin: '0 0 8px', color: 'var(--text)' }}>Policy checks: not evaluated</h2>
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0 }}>
            There is no live policy-evaluation results API behind this page yet, so no per-check verdict, cost or
            attestation is shown. Open the <Link to={`/policies?framework=${normalizedFwId}`} style={{ color: 'var(--cyan)' }}>CEL policy editor</Link>{' '}
            to inspect the rules for this framework.
          </p>
        </div>
      </>
    )
  }

  return (
    <div data-testid="policy-evaluation-page" style={{ maxWidth: 1400, margin: '0 auto', paddingBottom: 48 }}>
      {breadcrumb}
      {body}
    </div>
  )
}

function DemoPolicyEvaluation() {
  const { getAccessTokenSilently } = useAuth0()
  const [searchParams, setSearchParams] = useSearchParams()

  const agentParam = searchParams.get('agent')
  const frameworkParam = searchParams.get('framework') || 'eu-ai-act'
  const controlParam = searchParams.get('control') || ''
  const violationParam = searchParams.get('violation') || ''
  const tabParam = (searchParams.get('tab') as 'violations' | 'checks' | 'sources' | 'attestation') || 'violations'

  const [activeTab, setActiveTab] = useState<'violations' | 'checks' | 'sources' | 'attestation'>(tabParam)
  const [agents, setAgents] = useState<AgentResponse[]>([])
  const [frameworks, setFrameworks] = useState<FrameworkResponse[]>([])
  const [reEvaluating, setReEvaluating] = useState(false)
  const [copiedLink, setCopiedLink] = useState(false)
  const [sourceFormat, setSourceFormat] = useState<'json' | 'yaml'>('json')
  const [statusFilter, setStatusFilter] = useState<'all' | 'fail' | 'pass'>('all')

  // Update URL search parameters when tab changes
  const handleTabChange = (newTab: 'violations' | 'checks' | 'sources' | 'attestation') => {
    setActiveTab(newTab)
    setSearchParams(
      prev => {
        const next = new URLSearchParams(prev)
        next.set('tab', newTab)
        return next
      },
      { replace: true },
    )
  }

  // Load live agents & frameworks
  useEffect(() => {
    let mounted = true
    async function loadData() {
      try {
        const token = await getAccessTokenSilently()
        const [agentsRes, fwRes] = await Promise.all([
          api.agents.list(token).catch(() => ({ agents: [] })),
          api.compliance.frameworks(token).catch(() => []),
        ])
        if (mounted) {
          if (agentsRes.agents) setAgents(agentsRes.agents)
          if (Array.isArray(fwRes)) setFrameworks(fwRes)
        }
      } catch {
        // Demo mode only: the fixture agent below covers a failed load.
      }
    }
    loadData()
    return () => {
      mounted = false
    }
  }, [getAccessTokenSilently])

  // Demo-only agent resolution (fixture fallback for a missing or unknown id).
  const currentAgent = useMemo(() => demoPolicyEvaluationAgent(agents, agentParam), [agents, agentParam])

  // Normalize framework ID
  const normalizedFwId = normalizeFrameworkId(frameworkParam)

  // Demo-only: the fixture checks below are never reached in live mode.
  const evaluationChecks: PolicyCheckResult[] = useMemo(
    () => demoPolicyEvaluationChecks(normalizedFwId, currentAgent.name),
    [normalizedFwId, currentAgent.name],
  )

  // Filter checks if violation query param or status filter is present
  const violations = useMemo(() => evaluationChecks.filter(c => !c.passed), [evaluationChecks])

  const filteredViolations = useMemo(() => {
    if (!violationParam) return violations
    return violations.filter(
      v =>
        v.id.toLowerCase().includes(violationParam.toLowerCase()) ||
        v.name.toLowerCase().includes(violationParam.toLowerCase()) ||
        (v.remediation && v.remediation.toLowerCase().includes(violationParam.toLowerCase())),
    )
  }, [violations, violationParam])

  const displayedChecks = useMemo(() => {
    if (statusFilter === 'fail') return evaluationChecks.filter(c => !c.passed)
    if (statusFilter === 'pass') return evaluationChecks.filter(c => c.passed)
    return evaluationChecks
  }, [evaluationChecks, statusFilter])

  const sourceData = useMemo(() => demoPolicyEvaluationSource(currentAgent, normalizedFwId), [currentAgent, normalizedFwId])

  const inTotoAttestation = useMemo(
    () => demoPolicyEvaluationAttestation(currentAgent, normalizedFwId, evaluationChecks, violations),
    [currentAgent, normalizedFwId, evaluationChecks, violations],
  )

  const handleCopyDeepLink = () => {
    navigator.clipboard.writeText(window.location.href)
    setCopiedLink(true)
    setTimeout(() => setCopiedLink(false), 2000)
  }

  const handleReEvaluate = () => {
    setReEvaluating(true)
    setTimeout(() => {
      setReEvaluating(false)
    }, 800)
  }

  return (
    <div data-testid="policy-evaluation-page" style={{ maxWidth: 1400, margin: '0 auto', paddingBottom: 48 }}>
      {/* Breadcrumb & Navigation */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--muted)', marginBottom: 16 }}>
        <Link to="/compliance" style={{ color: 'var(--cyan)', textDecoration: 'none' }}>
          ← Back to Compliance
        </Link>
        <span>/</span>
        <Link to={`/agents/${currentAgent.id}`} style={{ color: 'var(--cyan)', textDecoration: 'none' }}>
          {currentAgent.name}
        </Link>
        <span>/</span>
        <span style={{ color: 'var(--text)', fontWeight: 600 }}>Policy Evaluation Run</span>
      </div>

      {/* Top Banner & Run Summary */}
      <div
        className="card"
        style={{
          padding: 24,
          marginBottom: 24,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 16 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
              <h1 data-testid="eval-header-title" style={{ fontSize: 22, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                Policy Evaluation: {currentAgent.name}
              </h1>
              <span
                style={{
                  fontSize: 12,
                  fontWeight: 700,
                  padding: '3px 10px',
                  borderRadius: 12,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  background: violations.length > 0 ? 'rgba(239, 68, 68, 0.15)' : 'rgba(16, 185, 129, 0.15)',
                  color: violations.length > 0 ? 'var(--error)' : 'var(--teal)',
                  border: `1px solid ${violations.length > 0 ? 'var(--error)' : 'var(--teal)'}`,
                }}
              >
                {violations.length > 0 ? `FAIL (${violations.length} VIOLATIONS)` : 'PASS (COMPLIANT)'}
              </span>
            </div>

            <div style={{ fontSize: 13, color: 'var(--muted)', display: 'flex', flexWrap: 'wrap', gap: 16, marginTop: 8 }}>
              <span>
                Framework: <strong data-testid="eval-framework-badge" style={{ color: 'var(--text)' }}>{normalizedFwId.toUpperCase()}</strong>
              </span>
              <span>
                SPIFFE:{' '}
                <code style={{ fontSize: 12, color: 'var(--cyan)' }}>{currentAgent.spiffe_id}</code>
              </span>
              <span>
                Evaluator: <strong style={{ color: 'var(--text)' }}>policy-engine:cel@v2.1.0</strong>
              </span>
              <span>
                Evaluated: <strong style={{ color: 'var(--text)' }}>Today, 01:20:00 UTC</strong>
              </span>
            </div>
          </div>

          {/* Action Buttons */}
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            <button
              type="button"
              className="btn btn-secondary"
              onClick={handleCopyDeepLink}
              title="Copy shareable URL with current filter and state parameters"
            >
              {copiedLink ? '✓ Copied Link' : '🔗 Share Evaluation'}
            </button>

            <Link
              to={`/policies?framework=${normalizedFwId}`}
              className="btn btn-secondary"
              style={{ textDecoration: 'none' }}
            >
              CEL Policy Editor ↗
            </Link>

            <button
              type="button"
              className="btn btn-primary"
              disabled={reEvaluating}
              onClick={handleReEvaluate}
            >
              {reEvaluating ? 'Evaluating...' : '↻ Re-evaluate'}
            </button>
          </div>
        </div>

        {/* Evaluation Metrics Ribbon */}
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))',
            gap: 16,
            marginTop: 20,
            paddingTop: 16,
            borderTop: '1px solid var(--border)',
          }}
        >
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Total Checks
            </div>
            <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--text)', marginTop: 2 }}>
              {evaluationChecks.length}
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Passed Checks
            </div>
            <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--teal)', marginTop: 2 }}>
              {evaluationChecks.filter(c => c.passed).length}
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Failing Checks
            </div>
            <div style={{ fontSize: 20, fontWeight: 700, color: violations.length > 0 ? 'var(--error)' : 'var(--muted)', marginTop: 2 }}>
              {violations.length}
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Compliance Score
            </div>
            <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--cyan)', marginTop: 2 }}>
              {Math.round((evaluationChecks.filter(c => c.passed).length / evaluationChecks.length) * 100)}%
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Witness Attestation
            </div>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--teal)', marginTop: 4 }}>
              ✓ Cryptographically Verified
            </div>
          </div>
        </div>
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 8, borderBottom: '1px solid var(--border)', marginBottom: 20 }}>
        <button
          type="button"
          data-testid="eval-tab-violations"
          onClick={() => handleTabChange('violations')}
          style={{
            padding: '10px 18px',
            fontSize: 13,
            fontWeight: 600,
            background: 'none',
            border: 'none',
            cursor: 'pointer',
            color: activeTab === 'violations' ? 'var(--cyan)' : 'var(--muted)',
            borderBottom: activeTab === 'violations' ? '2px solid var(--cyan)' : '2px solid transparent',
            marginBottom: -1,
          }}
        >
          Violations & Remediation ({violations.length})
        </button>

        <button
          type="button"
          data-testid="eval-tab-checks"
          onClick={() => handleTabChange('checks')}
          style={{
            padding: '10px 18px',
            fontSize: 13,
            fontWeight: 600,
            background: 'none',
            border: 'none',
            cursor: 'pointer',
            color: activeTab === 'checks' ? 'var(--cyan)' : 'var(--muted)',
            borderBottom: activeTab === 'checks' ? '2px solid var(--cyan)' : '2px solid transparent',
            marginBottom: -1,
          }}
        >
          All Policy Checks ({evaluationChecks.length})
        </button>

        <button
          type="button"
          data-testid="eval-tab-sources"
          onClick={() => handleTabChange('sources')}
          style={{
            padding: '10px 18px',
            fontSize: 13,
            fontWeight: 600,
            background: 'none',
            border: 'none',
            cursor: 'pointer',
            color: activeTab === 'sources' ? 'var(--cyan)' : 'var(--muted)',
            borderBottom: activeTab === 'sources' ? '2px solid var(--cyan)' : '2px solid transparent',
            marginBottom: -1,
          }}
        >
          Input Sources (Source Data)
        </button>

        <button
          type="button"
          data-testid="eval-tab-attestation"
          onClick={() => handleTabChange('attestation')}
          style={{
            padding: '10px 18px',
            fontSize: 13,
            fontWeight: 600,
            background: 'none',
            border: 'none',
            cursor: 'pointer',
            color: activeTab === 'attestation' ? 'var(--cyan)' : 'var(--muted)',
            borderBottom: activeTab === 'attestation' ? '2px solid var(--cyan)' : '2px solid transparent',
            marginBottom: -1,
          }}
        >
          in-toto Attestation Statement
        </button>
      </div>

      {/* Tab 1: Violations & Actionable Remediation Guidance */}
      {activeTab === 'violations' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {violationParam && (
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                padding: '8px 14px',
                borderRadius: 6,
                background: 'rgba(56, 189, 248, 0.1)',
                border: '1px solid rgba(56, 189, 248, 0.3)',
                fontSize: 12,
              }}
            >
              <span>
                Filtered to deep-linked violation: <strong style={{ color: 'var(--cyan)' }}>{violationParam}</strong>
              </span>
              <button
                type="button"
                className="btn btn-secondary"
                style={{ fontSize: 11, padding: '2px 8px' }}
                onClick={() => {
                  setSearchParams(prev => {
                    const next = new URLSearchParams(prev)
                    next.delete('violation')
                    return next
                  })
                }}
              >
                Clear Filter
              </button>
            </div>
          )}

          {filteredViolations.length === 0 ? (
            <div className="card" style={{ padding: 40, textAlign: 'center' }}>
              <div style={{ fontSize: 32, marginBottom: 12 }}>✓</div>
              <h3 style={{ fontSize: 16, fontWeight: 600, color: 'var(--teal)', margin: 0 }}>No Policy Violations Found</h3>
              <p style={{ fontSize: 13, color: 'var(--muted)', marginTop: 6 }}>
                All executed CEL policy checks evaluated successfully against this agent source data.
              </p>
            </div>
          ) : (
            filteredViolations.map((v) => (
              <div
                key={v.id}
                className="card"
                data-testid={`violation-card-${v.id}`}
                style={{
                  padding: 20,
                  borderLeft: '4px solid var(--error)',
                  background: 'var(--surface)',
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 10 }}>
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <span
                        style={{
                          fontSize: 10,
                          fontWeight: 700,
                          padding: '2px 6px',
                          borderRadius: 4,
                          textTransform: 'uppercase',
                          background: 'rgba(239, 68, 68, 0.2)',
                          color: 'var(--error)',
                        }}
                      >
                        {v.severity}
                      </span>
                      <strong style={{ fontSize: 15, color: 'var(--text)' }}>{v.name}</strong>
                      <code style={{ fontSize: 11, color: 'var(--muted)' }}>[{v.id}]</code>
                    </div>
                    <p style={{ fontSize: 13, color: 'var(--muted)', margin: '6px 0 0 0', lineHeight: 1.4 }}>
                      {v.description}
                    </p>
                  </div>

                  <Link
                    to={`/policies?framework=${normalizedFwId}&rule=${v.id}`}
                    className="btn btn-secondary"
                    style={{ fontSize: 11, padding: '4px 10px', textDecoration: 'none' }}
                  >
                    Edit Rule in CEL ↗
                  </Link>
                </div>

                {/* Diagnostic breakdown */}
                <div
                  style={{
                    background: 'var(--surface2)',
                    padding: 12,
                    borderRadius: 6,
                    fontSize: 12,
                    marginTop: 12,
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 6,
                  }}
                >
                  <div>
                    <span style={{ color: 'var(--muted)' }}>Offending Path: </span>
                    <code style={{ color: 'var(--error)', fontWeight: 600 }}>{v.offending_path || 'spec.template'}</code>
                  </div>
                  <div>
                    <span style={{ color: 'var(--muted)' }}>Expected: </span>
                    <code style={{ color: 'var(--teal)' }}>{v.expected_value}</code>
                    <span style={{ color: 'var(--muted)', marginLeft: 16 }}>Actual Evaluated: </span>
                    <code style={{ color: 'var(--error)' }}>{v.actual_value}</code>
                  </div>
                  <div>
                    <span style={{ color: 'var(--muted)' }}>Evaluated CEL: </span>
                    <code style={{ color: 'var(--text)', wordBreak: 'break-all' }}>{v.cel_expression}</code>
                  </div>
                </div>

                {/* Remediation Patch Guidance */}
                {v.suggested_patch && (
                  <div style={{ marginTop: 14 }}>
                    <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--amber)', marginBottom: 6 }}>
                      Actionable Remediation Patch (Manifest Diff):
                    </div>
                    <pre
                      style={{
                        margin: 0,
                        padding: 12,
                        background: 'var(--surface2)',
                        border: '1px solid color-mix(in srgb, var(--amber) 30%, transparent)',
                        borderRadius: 6,
                        fontSize: 11,
                        color: 'var(--teal)',
                        overflowX: 'auto',
                        fontFamily: 'monospace',
                      }}
                    >
                      {v.suggested_patch}
                    </pre>
                  </div>
                )}
              </div>
            ))
          )}
        </div>
      )}

      {/* Tab 2: All Policy Checks */}
      {activeTab === 'checks' && (
        <div className="card" style={{ padding: 20 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
              Evaluated Policy Rules ({displayedChecks.length})
            </h2>

            <div style={{ display: 'flex', gap: 6 }}>
              {(['all', 'fail', 'pass'] as const).map(filter => (
                <button
                  key={filter}
                  type="button"
                  onClick={() => setStatusFilter(filter)}
                  style={{
                    fontSize: 11,
                    padding: '4px 10px',
                    borderRadius: 4,
                    border: '1px solid var(--border)',
                    background: statusFilter === filter ? 'var(--cyan)' : 'var(--surface)',
                    color: statusFilter === filter ? '#000' : 'var(--text)',
                    cursor: 'pointer',
                    fontWeight: 600,
                    textTransform: 'capitalize',
                  }}
                >
                  {filter}
                </button>
              ))}
            </div>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {displayedChecks.map(c => (
              <div
                key={c.id}
                style={{
                  padding: 14,
                  borderRadius: 6,
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span
                      style={{
                        fontSize: 11,
                        fontWeight: 700,
                        padding: '2px 8px',
                        borderRadius: 10,
                        background: c.passed ? 'rgba(16, 185, 129, 0.2)' : 'rgba(239, 68, 68, 0.2)',
                        color: c.passed ? 'var(--teal)' : 'var(--error)',
                      }}
                    >
                      {c.passed ? 'PASS' : 'FAIL'}
                    </span>
                    <strong style={{ fontSize: 13, color: 'var(--text)' }}>{c.name}</strong>
                    <code style={{ fontSize: 11, color: 'var(--muted)' }}>[{c.id}]</code>
                  </div>

                  <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                    Cost: {c.cost_units} units ({c.duration_ms}ms)
                  </span>
                </div>

                <div style={{ marginTop: 8 }}>
                  <code style={{ fontSize: 11, color: 'var(--cyan)', wordBreak: 'break-all' }}>
                    {c.cel_expression}
                  </code>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Tab 3: Input Sources (Source Data) */}
      {activeTab === 'sources' && (
        <div className="card" style={{ padding: 20 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
              Input Source Data (Evaluated Bindings)
            </h2>

            <div style={{ display: 'flex', gap: 8 }}>
              <button
                type="button"
                className="btn btn-secondary"
                style={{ fontSize: 11, padding: '2px 8px' }}
                onClick={() => navigator.clipboard.writeText(JSON.stringify(sourceData, null, 2))}
              >
                Copy Source JSON
              </button>
            </div>
          </div>

          <pre
            style={{
              margin: 0,
              padding: 14,
              fontSize: 11,
              fontFamily: 'monospace',
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              color: 'var(--text)',
              maxHeight: 520,
              overflowY: 'auto',
              whiteSpace: 'pre-wrap',
            }}
          >
            {JSON.stringify(sourceData, null, 2)}
          </pre>
        </div>
      )}

      {/* Tab 4: in-toto Attestation Statement */}
      {activeTab === 'attestation' && (
        <div className="card" style={{ padding: 20 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <div>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
                in-toto Statement v1 Attestation
              </h2>
              <span style={{ fontSize: 12, color: 'var(--muted)' }}>
                Cryptographically verifiable compliance statement conforming to OpenSSF in-toto attestation framework
              </span>
            </div>

            <button
              type="button"
              className="btn btn-secondary"
              style={{ fontSize: 11, padding: '2px 8px' }}
              onClick={() => navigator.clipboard.writeText(JSON.stringify(inTotoAttestation, null, 2))}
            >
              Copy in-toto JSON
            </button>
          </div>

          <pre
            style={{
              margin: 0,
              padding: 14,
              fontSize: 11,
              fontFamily: 'monospace',
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              color: 'var(--cyan)',
              maxHeight: 520,
              overflowY: 'auto',
              whiteSpace: 'pre-wrap',
            }}
          >
            {JSON.stringify(inTotoAttestation, null, 2)}
          </pre>
        </div>
      )}
    </div>
  )
}
