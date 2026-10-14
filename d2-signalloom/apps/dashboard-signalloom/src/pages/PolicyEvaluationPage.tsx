import React, { useState, useMemo, useEffect } from 'react'
import { useSearchParams, Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { normalizeFrameworkId } from '../data/regulatoryFrameworks'
import type { AgentResponse, FrameworkResponse } from '../types/api'

interface PolicyCheckResult {
  id: string
  name: string
  description: string
  severity: 'critical' | 'high' | 'medium' | 'low'
  cel_expression: string
  passed: boolean
  evaluated_at: string
  cost_units: number
  duration_ms: number
  remediation?: string
  offending_path?: string
  expected_value?: string
  actual_value?: string
  suggested_patch?: string
}

export default function PolicyEvaluationPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [searchParams, setSearchParams] = useSearchParams()

  const agentParam = searchParams.get('agent') || 'a0000000-0000-0000-0000-000000000001'
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
        // Fallback to demo defaults handled below
      }
    }
    loadData()
    return () => {
      mounted = false
    }
  }, [getAccessTokenSilently])

  // Resolve current agent
  const currentAgent = useMemo(() => {
    const found = agents.find(a => a.id === agentParam || a.name.toLowerCase() === agentParam.toLowerCase())
    if (found) {
      return {
        id: found.id,
        name: found.name,
        spiffe_id: found.identity?.spiffe_id || `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/${found.name.toLowerCase()}`,
        model: found.runtime?.model || 'claude-3-5-sonnet',
        compliance_summary: found.compliance_summary,
      }
    }
    return {
      id: agentParam,
      name: agentParam.startsWith('a0000') ? 'agent-cardvault' : agentParam,
      spiffe_id: `spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/${agentParam.startsWith('a0000') ? 'cardvault-agent' : agentParam}`,
      model: 'claude-3-5-sonnet',
      compliance_summary: undefined,
    }
  }, [agents, agentParam])

  // Normalize framework ID
  const normalizedFwId = normalizeFrameworkId(frameworkParam)

  // Demo policy checks executed by CEL policy-engine for this agent and framework
  const evaluationChecks: PolicyCheckResult[] = useMemo(() => {
    if (normalizedFwId === 'k8s-cis-benchmark' || normalizedFwId === 'cis-kubernetes') {
      return [
        {
          id: 'cis-5.2.6',
          name: 'CIS 5.2.6: Minimize the admission of root containers',
          description: 'Containers must run as a non-root user to mitigate privilege escalation and container breakout risks.',
          severity: 'high',
          cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)',
          passed: false,
          evaluated_at: '2026-10-14T01:20:00Z',
          cost_units: 14,
          duration_ms: 0.42,
          offending_path: 'spec.template.spec.containers[0].securityContext.runAsNonRoot',
          expected_value: 'true',
          actual_value: 'false (or unset)',
          remediation: 'Set spec.securityContext.runAsNonRoot: true or spec.containers[*].securityContext.runAsNonRoot: true.',
          suggested_patch: `spec:\n  template:\n    spec:\n      securityContext:\n        runAsNonRoot: true\n        runAsUser: 10001\n        runAsGroup: 10001`,
        },
        {
          id: 'cis-5.2.5',
          name: 'CIS 5.2.5: Minimize admission of containers with allowPrivilegeEscalation',
          description: 'Prohibits a container process from gaining more privileges than its parent process within the pod.',
          severity: 'high',
          cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)',
          passed: true,
          evaluated_at: '2026-10-14T01:20:00Z',
          cost_units: 12,
          duration_ms: 0.35,
        },
        {
          id: 'no-privileged-containers',
          name: 'No privileged containers',
          description: 'Containers must not run in privileged mode.',
          severity: 'critical',
          cel_expression: 'object.spec.containers.all(c, !has(c.securityContext) || !has(c.securityContext.privileged) || c.securityContext.privileged == false)',
          passed: true,
          evaluated_at: '2026-10-14T01:20:00Z',
          cost_units: 8,
          duration_ms: 0.28,
        },
        {
          id: 'read-only-root-filesystem',
          name: 'Read-only root filesystem',
          description: 'Root filesystem of all containers must be mounted read-only.',
          severity: 'medium',
          cel_expression: 'object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem == true)',
          passed: false,
          evaluated_at: '2026-10-14T01:20:00Z',
          cost_units: 11,
          duration_ms: 0.31,
          offending_path: 'spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem',
          expected_value: 'true',
          actual_value: 'false',
          remediation: 'Enable readOnlyRootFilesystem and use emptyDir mounts for scratch directories.',
          suggested_patch: `spec:\n  containers:\n    - name: agent\n      securityContext:\n        readOnlyRootFilesystem: true\n      volumeMounts:\n        - name: tmp\n          mountPath: /tmp`,
        },
      ]
    }

    // Default: EU AI Act checks
    return [
      {
        id: 'EU-AI-ACT-ART-14',
        name: 'EU AI Act Art 14: Human Oversight Intervention Interface',
        description: 'High-risk autonomous agents must expose a human-in-the-loop override channel and emergency stun receiver.',
        severity: 'critical',
        cel_expression: "has(agent.guardrails) && agent.guardrails.human_override_active == true && has(agent.governance.stun_endpoint)",
        passed: false,
        evaluated_at: '2026-10-14T01:20:00Z',
        cost_units: 18,
        duration_ms: 0.48,
        offending_path: 'agent.guardrails.human_override_active',
        expected_value: 'true',
        actual_value: 'false (supervisor unacknowledged)',
        remediation: 'Configure designated human operator identity in agent manifest and register emergency stun endpoint.',
        suggested_patch: `apiVersion: governance.signalloom.dev/v1alpha1\nkind: AgentGovernanceProfile\nmetadata:\n  name: ${currentAgent.name}-oversight\nspec:\n  humanOversight:\n    enabled: true\n    designatedSupervisors:\n      - "operator@signalloom.demo"\n    emergencyStunPolicy: graceful-freeze`,
      },
      {
        id: 'EU-AI-ACT-ART-12',
        name: 'EU AI Act Art 12: Continuous Audit Logging & Traceability',
        description: 'All agent decision steps, prompt inputs, and tool execution traces must be cryptographically attested.',
        severity: 'high',
        cel_expression: "has(agent.telemetry) && agent.telemetry.provenance_attestation == 'in-toto-v1'",
        passed: true,
        evaluated_at: '2026-10-14T01:20:00Z',
        cost_units: 14,
        duration_ms: 0.38,
      },
      {
        id: 'multi-agent-trust-boundary',
        name: 'Art 15 / NIST: Multi-Agent Mutual TLS & SPIFFE Trust Domain',
        description: 'Inter-agent communication must authenticate peer SVID within the signalloom.demo trust domain.',
        severity: 'critical',
        cel_expression: "has(request.peer.trust_domain) && request.peer.trust_domain == 'signalloom.demo' && request.peer.mtls_authenticated == true",
        passed: true,
        evaluated_at: '2026-10-14T01:20:00Z',
        cost_units: 16,
        duration_ms: 0.41,
      },
      {
        id: 'prompt-injection-guardrail-active',
        name: 'Art 9 / OWASP: Active Prompt Injection Defense Guardrail',
        description: 'Agent input ingestion pipeline must employ verified prompt sanitization and adversarial guardrails.',
        severity: 'high',
        cel_expression: 'has(agent.guardrails) && agent.guardrails.prompt_injection_filter == true',
        passed: false,
        evaluated_at: '2026-10-14T01:20:00Z',
        cost_units: 20,
        duration_ms: 0.52,
        offending_path: 'agent.guardrails.prompt_injection_filter',
        expected_value: 'true',
        actual_value: 'false (bypass detected in system prompt)',
        remediation: 'Attach standard Signal Loom Prompt Guardrail filter to incoming inference messages.',
        suggested_patch: `spec:\n  guardrails:\n    promptInjectionFilter: true\n    maxInputTokens: 8192\n    contentModerationStrictness: High`,
      },
      {
        id: 'model-catalog-registration',
        name: 'Art 13: Approved Enterprise Model Catalog Registration',
        description: 'Underlying foundation model must be signed and registered in the enterprise approved catalog.',
        severity: 'medium',
        cel_expression: 'has(agent.registry) && agent.registry.model_registered == true',
        passed: true,
        evaluated_at: '2026-10-14T01:20:00Z',
        cost_units: 10,
        duration_ms: 0.29,
      },
    ]
  }, [normalizedFwId, currentAgent.name])

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

  // Source Data Mock
  const sourceData = useMemo(() => {
    return {
      apiVersion: 'v1',
      kind: 'Pod',
      metadata: {
        name: currentAgent.name,
        namespace: 'fe-signalloom-agents',
        labels: {
          'app.kubernetes.io/name': currentAgent.name,
          'signalloom.ai/agent-id': currentAgent.id,
          'signalloom.ai/framework': normalizedFwId,
          'signalloom.ai/spiffe-id': currentAgent.spiffe_id,
        },
      },
      spec: {
        serviceAccountName: `${currentAgent.name}-sa`,
        securityContext: {
          runAsNonRoot: false,
          seccompProfile: {
            type: 'RuntimeDefault',
          },
        },
        containers: [
          {
            name: 'agent-runtime',
            image: `zot.registry.svc.cluster.local:5000/signalloom/${currentAgent.name}:v1.2.0`,
            securityContext: {
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: false,
              privileged: false,
            },
            env: [
              { name: 'AGENT_MODEL', value: currentAgent.model || 'claude-3-5-sonnet' },
              { name: 'AGENT_TENANT_ID', value: 'tenant-demo' },
              { name: 'SIGNAL_INGEST_ENDPOINT', value: 'http://signal-ingest:8082' },
            ],
            ports: [{ containerPort: 8080, name: 'http' }],
          },
        ],
      },
      agent: {
        id: currentAgent.id,
        name: currentAgent.name,
        spiffe_id: currentAgent.spiffe_id,
        model: currentAgent.model,
        guardrails: {
          prompt_injection_filter: false,
          human_override_active: false,
        },
        governance: {
          stun_endpoint: 'http://signalloom-warden:9090/stun',
        },
        registry: {
          model_registered: true,
          catalog_id: 'cat-2026-sonnet',
        },
        telemetry: {
          provenance_attestation: 'in-toto-v1',
          ebpf_monitored: true,
        },
      },
      request: {
        peer: {
          trust_domain: 'signalloom.demo',
          mtls_authenticated: true,
          subject_spiffe: 'spiffe://signalloom.demo/ns/fe-signalloom/sa/discovery-portal',
        },
      },
    }
  }, [currentAgent, normalizedFwId])

  // In-toto Statement v1 Attestation Object
  const inTotoAttestation = useMemo(() => {
    return {
      _type: 'https://in-toto.io/Statement/v1',
      predicateType: 'https://signalloom.dev/attestation/compliance/v1',
      subject: [
        {
          name: currentAgent.name,
          uri: currentAgent.spiffe_id,
          digest: {
            sha256: '9f83c182a47e2b109c00b832a76f291048a90123456789abcdef0123456789abc',
          },
        },
      ],
      predicate: {
        framework: {
          id: normalizedFwId,
          name: normalizedFwId === 'k8s-cis-benchmark' ? 'CIS Kubernetes Benchmark' : 'EU AI Act',
          version: 'v2.1.0',
        },
        evaluation: {
          status: violations.length > 0 ? 'FAILED' : 'PASSED',
          timestamp: '2026-10-14T01:20:00Z',
          evaluator: 'policy-engine/cel-runtime@v2.1.0',
          evidenceRef: `cel://assessments/${currentAgent.name}/${normalizedFwId}/2026-10-14`,
          summary: {
            total: evaluationChecks.length,
            passed: evaluationChecks.filter(c => c.passed).length,
            failed: violations.length,
            score: (evaluationChecks.filter(c => c.passed).length / evaluationChecks.length).toFixed(2),
          },
        },
        witness: {
          signer: 'cosign:local-demo-only',
          keyId: 'sha256:d8a264a782b1c4e9f908e2ba41b0',
          verified: true,
        },
      },
    }
  }, [currentAgent, normalizedFwId, evaluationChecks, violations])

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
