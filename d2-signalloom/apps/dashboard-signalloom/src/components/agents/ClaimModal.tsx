import { useState, useId } from 'react'
import { useAuth0 } from '../../auth/oidc'
import { claimDiscoveredAgent, type AgentClaimRequest, type AgentClaimResponse } from '../../api/agentClaim'
import type { AgentResponse } from '../../types/api'
import { colors } from '../../styles/tokens'

export type WorkloadSecurityProfile = 'nono-sandboxed' | 'standard-container' | 'custom'

export function getAgentWorkloadSecurityProfile(agent: Partial<AgentResponse> | null | undefined): {
  profile: WorkloadSecurityProfile
  label: string
  badgeVariant: 'nono' | 'standard' | 'default'
  description: string
} {
  const name = (agent?.name || agent?.id || '').toLowerCase()
  const framework = (agent?.framework || agent?.runtime?.framework || '').toLowerCase()
  const executionMode = (agent?.runtime?.execution_mode || '').toLowerCase()

  if (name.includes('nono') || framework.includes('nono') || executionMode.includes('nono') || executionMode.includes('landlock')) {
    return {
      profile: 'nono-sandboxed',
      label: 'Nono Sandboxed',
      badgeVariant: 'nono',
      description: 'Linux Landlock LSM confinement with cryptographically signed hash-chained audit trails.',
    }
  }
  if (name.includes('standard') || name.includes('baseline') || framework.includes('standard') || executionMode.includes('container') || executionMode.includes('standard')) {
    return {
      profile: 'standard-container',
      label: 'Standard Container',
      badgeVariant: 'standard',
      description: 'Standard Linux container cgroups/namespaces with stun-sentinel in-kernel eBPF flow observability.',
    }
  }
  return {
    profile: 'custom',
    label: 'Standard Container',
    badgeVariant: 'default',
    description: 'Autonomous container workload.',
  }
}

export interface ClaimModalProps {
  agent: AgentResponse
  onClose: () => void
  onSuccess?: (result: AgentClaimResponse) => void
}

export default function ClaimModal({ agent, onClose, onSuccess }: ClaimModalProps) {
  const { user, getAccessTokenSilently } = useAuth0()
  const titleId = useId()
  const descriptionId = useId()

  const secProfile = getAgentWorkloadSecurityProfile(agent)

  const defaultPodName = agent.runtime?.pod_name || (agent.record_class === 'discovered' ? agent.id : agent.name)
  const defaultNamespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const defaultSpiffeId =
    agent.identity?.spiffe_id ||
    `spiffe://signalloom.demo/ns/${defaultNamespace}/sa/${agent.runtime?.service_account || agent.service_account || defaultPodName}`
  const defaultHarness = agent.runtime?.framework || agent.framework || agent.type || 'claude-code'
  const defaultModel = agent.runtime?.model || agent.model_name || 'claude-3-5-sonnet'

  const claimantOwner = user?.email || user?.name || user?.sub || ''
  const authenticatedOperator = user?.email || user?.sub || ''

  const workloadTenant = agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : null)
  const operatorTenant =
    (user as { tenant?: string; 'https://signalloom.ai/tenant'?: string })?.tenant ||
    (user as { 'https://signalloom.ai/tenant'?: string })?.['https://signalloom.ai/tenant'] ||
    (claimantOwner ? claimantOwner.split('@')[1]?.split('.')[0] : 'default') ||
    'default'

  const isTenantMismatch = Boolean(workloadTenant && operatorTenant && workloadTenant !== operatorTenant)

  const [podName, setPodName] = useState(defaultPodName)
  const [namespace, setNamespace] = useState(defaultNamespace)
  const [spiffeId, setSpiffeId] = useState(defaultSpiffeId)
  const [harness, setHarness] = useState(defaultHarness)
  const [model, setModel] = useState(defaultModel)
  const [tokenBudget, setTokenBudget] = useState<number>(250000)
  const [owner, setOwner] = useState(claimantOwner)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null)

  const handleCopy = (text: string, id: string) => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(text).catch(() => {})
      setCopiedCmd(id)
      setTimeout(() => setCopiedCmd(null), 2500)
    }
  }

  const relabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/tenant=${operatorTenant} --overwrite`

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setError(null)

    const requestPayload: AgentClaimRequest = {
      pod_name: podName.trim() || defaultPodName,
      display_name: agent.name,
      namespace: namespace.trim() || defaultNamespace,
      spiffe_id: spiffeId.trim() || defaultSpiffeId,
      harness: harness.trim() || defaultHarness,
      model: model.trim() || defaultModel,
      declared_tools: [],
      token_budget_limit: tokenBudget > 0 ? tokenBudget : 100000,
      agent_id: agent.id,
      owner: (owner.trim() || claimantOwner) || undefined,
    }

    try {
      let token = ''
      try {
        token = await getAccessTokenSilently()
      } catch {
        token = 'demo-token'
      }

      const result = await claimDiscoveredAgent(token, agent.id, requestPayload)

      if (result.status === 'denied') {
        throw new Error('Claim was rejected by governance policy.')
      }

      onSuccess?.(result)
      onClose()
    } catch (err: unknown) {
      const status =
        (err as { status?: number })?.status ??
        (err as { response?: { status?: number } })?.response?.status
      if (
        status === 409 ||
        (err instanceof Error &&
          (err.message.includes('already claimed') ||
            err.message.includes('409') ||
            err.message.includes('Conflict')))
      ) {
        setError(`Agent '${podName}' is already claimed by another operator tenant.`)
      } else if (err instanceof Error) {
        setError(err.message)
      } else {
        setError('Failed to claim agent.')
      }
      setSubmitting(false)
    }
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
      aria-describedby={descriptionId}
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.65)',
        backdropFilter: 'blur(8px)',
        zIndex: 1000,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 16,
      }}
      onClick={(e) => e.target === e.currentTarget && onClose()}
      data-testid="claim-modal"
    >
      <div
        className="card slide-up"
        style={{
          width: '100%',
          maxWidth: 960,
          background: 'var(--surface, #0F172A)',
          border: '1px solid var(--border, #2a3142)',
          borderRadius: 8,
          padding: 24,
          position: 'relative',
          boxShadow: '0 12px 36px rgba(0,0,0,0.5)',
          maxHeight: '92vh',
          overflowY: 'auto',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <h3 id={titleId} style={{ margin: 0, fontSize: 18, color: 'var(--text, #f0f4fc)' }}>
              Claim Agent Workload
            </h3>
            <span
              data-testid="claim-modal-security-badge"
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 4,
                fontSize: 11,
                fontWeight: 600,
                padding: '2px 8px',
                borderRadius: 4,
                background: secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.15)' : 'rgba(56, 189, 248, 0.15)',
                color: secProfile.profile === 'nono-sandboxed' ? colors.tealLoom : colors.cyanLoom,
                border: `1px solid ${secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.3)' : 'rgba(56, 189, 248, 0.3)'}`,
              }}
            >
              {secProfile.label}
            </span>
          </div>
          <button
            type="button"
            data-testid="claim-modal-close-btn"
            onClick={onClose}
            aria-label="Close"
            style={{
              background: 'transparent',
              border: 'none',
              color: 'var(--muted, #8b949e)',
              cursor: 'pointer',
              fontSize: 18,
              padding: 4,
              lineHeight: 1,
            }}
          >
            ✕
          </button>
        </div>

        <p id={descriptionId} style={{ fontSize: 12, color: 'var(--muted, #8b949e)', marginBottom: 18, lineHeight: 1.5 }}>
          Bring discovered workload <strong style={{ color: 'var(--text)' }}>{agent.name || agent.id}</strong> into
          Signal Loom tenant governance. {secProfile.description}
        </p>

        {error && (
          <div
            data-testid="claim-modal-error"
            style={{
              background: 'rgba(239, 68, 68, 0.12)',
              border: '1px solid rgba(239, 68, 68, 0.35)',
              color: 'var(--error, #ef4444)',
              borderRadius: 6,
              padding: '10px 14px',
              fontSize: 12,
              marginBottom: 16,
              lineHeight: 1.4,
            }}
          >
            <strong>Claim Error:</strong> {error}
          </div>
        )}

        {/* ─── 2-Column Split: Left = Form, Right = Info & Pre-Flight Panels ────── */}
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))',
            gap: 24,
            alignItems: 'start',
          }}
        >
          {/* Left Column: Form */}
          <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            <div>
              <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                Pod Name / Identifier
              </label>
              <input
                type="text"
                data-testid="claim-modal-pod-name"
                value={podName}
                onChange={(e) => setPodName(e.target.value)}
                required
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 4,
                  background: 'var(--surface, #0d1117)',
                  border: '1px solid var(--border, #30363d)',
                  color: 'var(--text, #c9d1d9)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              />
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <div>
                <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                  Namespace
                </label>
                <input
                  type="text"
                  data-testid="claim-modal-namespace"
                  value={namespace}
                  onChange={(e) => setNamespace(e.target.value)}
                  required
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    borderRadius: 4,
                    background: 'var(--surface, #0d1117)',
                    border: '1px solid var(--border, #30363d)',
                    color: 'var(--text, #c9d1d9)',
                    fontSize: 13,
                    boxSizing: 'border-box',
                  }}
                />
              </div>
              <div>
                <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                  Harness / Framework
                </label>
                <input
                  type="text"
                  data-testid="claim-modal-harness"
                  value={harness}
                  onChange={(e) => setHarness(e.target.value)}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    borderRadius: 4,
                    background: 'var(--surface, #0d1117)',
                    border: '1px solid var(--border, #30363d)',
                    color: 'var(--text, #c9d1d9)',
                    fontSize: 13,
                    boxSizing: 'border-box',
                  }}
                />
              </div>
            </div>

            <div>
              <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                SPIFFE Workload Identity
              </label>
              <input
                type="text"
                data-testid="claim-modal-spiffe-id"
                value={spiffeId}
                onChange={(e) => setSpiffeId(e.target.value)}
                required
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 4,
                  background: 'var(--surface, #0d1117)',
                  border: '1px solid var(--border, #30363d)',
                  color: 'var(--text, #c9d1d9)',
                  fontSize: 12,
                  fontFamily: 'monospace',
                  boxSizing: 'border-box',
                }}
              />
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <div>
                <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                  Model
                </label>
                <input
                  type="text"
                  data-testid="claim-modal-model"
                  value={model}
                  onChange={(e) => setModel(e.target.value)}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    borderRadius: 4,
                    background: 'var(--surface, #0d1117)',
                    border: '1px solid var(--border, #30363d)',
                    color: 'var(--text, #c9d1d9)',
                    fontSize: 13,
                    boxSizing: 'border-box',
                  }}
                />
              </div>
              <div>
                <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                  Token Budget Limit
                </label>
                <input
                  type="number"
                  data-testid="claim-modal-token-budget"
                  value={tokenBudget}
                  onChange={(e) => setTokenBudget(Number(e.target.value))}
                  min={1000}
                  max={10000000}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    borderRadius: 4,
                    background: 'var(--surface, #0d1117)',
                    border: '1px solid var(--border, #30363d)',
                    color: 'var(--text, #c9d1d9)',
                    fontSize: 13,
                    boxSizing: 'border-box',
                  }}
                />
              </div>
            </div>

            <div>
              <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                Tenant Boundary
              </label>
              <div
                data-testid="claim-modal-tenant"
                style={{
                  fontSize: 12,
                  fontFamily: 'monospace',
                  padding: '8px 12px',
                  borderRadius: 4,
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  color: agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared') ? 'var(--text)' : 'var(--muted)',
                }}
              >
                {agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : 'Undeclared (Will bind to claimant tenant on claim)')}
              </div>
            </div>

            <div>
              <label style={{ display: 'block', fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                Assigned Owner
              </label>
              <input
                type="text"
                data-testid="claim-modal-owner"
                value={owner}
                onChange={(e) => setOwner(e.target.value)}
                placeholder="e.g. operator@signalloom.local"
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 4,
                  background: 'var(--surface)',
                  border: '1px solid var(--border)',
                  color: 'var(--text)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              />
            </div>

            <div>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 4 }}>
                Authenticated Operator
              </div>
              <div
                data-testid="claim-modal-operator"
                style={{
                  fontSize: 12,
                  fontFamily: 'monospace',
                  padding: '8px 12px',
                  borderRadius: 4,
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  color: authenticatedOperator ? 'var(--text)' : 'var(--muted)',
                }}
              >
                {authenticatedOperator || 'Authenticated identity unavailable'}
              </div>
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, marginTop: 8 }}>
              <button
                type="button"
                data-testid="claim-modal-cancel-btn"
                onClick={onClose}
                disabled={submitting}
                style={{
                  padding: '8px 16px',
                  borderRadius: 4,
                  background: 'transparent',
                  border: '1px solid var(--border, #30363d)',
                  color: 'var(--text, #c9d1d9)',
                  cursor: submitting ? 'not-allowed' : 'pointer',
                  fontSize: 13,
                }}
              >
                Cancel
              </button>
              <button
                type="submit"
                data-testid="claim-modal-submit-btn"
                disabled={submitting}
                style={{
                  padding: '8px 18px',
                  borderRadius: 4,
                  background: 'var(--cyan, #06B6D4)',
                  border: 'none',
                  color: 'var(--text, #F8FAFC)',
                  fontWeight: 600,
                  cursor: submitting ? 'not-allowed' : 'pointer',
                  fontSize: 13,
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 6,
                }}
              >
                {submitting && (
                  <span data-testid="claim-modal-spinner" style={{ animation: 'spin 1s linear infinite' }}>
                    ⏳
                  </span>
                )}
                {submitting ? 'Claiming Agent…' : 'Claim Agent'}
              </button>
            </div>
          </form>

          {/* Right Column: Info Panels & Pre-Flight Objection Handling */}
          <div
            data-testid="claim-modal-info-panel"
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 12,
              background: 'var(--surface2, rgba(255,255,255,0.02))',
              border: '1px solid var(--border, #2a3142)',
              borderRadius: 6,
              padding: 16,
            }}
          >
            <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', borderBottom: '1px solid var(--border)', paddingBottom: 8 }}>
              Workload Pre-Flight & Diagnostics
            </div>

            {/* Tenant Boundary Pre-Flight Check */}
            {isTenantMismatch ? (
              <div
                data-testid="claim-modal-tenant-mismatch-warning"
                style={{
                  padding: '10px 12px',
                  background: 'rgba(239, 68, 68, 0.12)',
                  border: '1px solid rgba(239, 68, 68, 0.35)',
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ color: 'var(--error)', fontWeight: 700, marginBottom: 4 }}>
                  ⚠️ Pre-Flight Warning: Tenant Mismatch
                </div>
                <div style={{ color: 'var(--text)', lineHeight: 1.4, marginBottom: 6 }}>
                  Workload declares tenant <code style={{ color: 'var(--cyan)' }}>"{workloadTenant}"</code>,
                  while your active operator session is in <code style={{ color: 'var(--violet)' }}>"{operatorTenant}"</code>.
                </div>
                <div style={{ color: 'var(--muted)', fontSize: 11, lineHeight: 1.4, marginBottom: 8 }}>
                  Submitting will fail with HTTP 403 <code>cross_tenant_forbidden</code>.
                  To claim into your tenant, re-label the pod:
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <code style={{ background: 'var(--surface)', padding: '4px 6px', borderRadius: 3, color: 'var(--cyan)', fontSize: 10, flex: 1, overflowX: 'auto' }}>
                    {relabelCommand}
                  </code>
                  <button
                    type="button"
                    className="btn btn-secondary"
                    onClick={() => handleCopy(relabelCommand, 'modal-relabel')}
                    style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                  >
                    {copiedCmd === 'modal-relabel' ? 'Copied! ✓' : 'Copy'}
                  </button>
                </div>
              </div>
            ) : (
              <div
                data-testid="claim-modal-tenant-verified"
                style={{
                  padding: '8px 12px',
                  background: 'rgba(34, 197, 94, 0.1)',
                  border: '1px solid rgba(34, 197, 94, 0.25)',
                  borderRadius: 6,
                  fontSize: 12,
                  color: 'var(--teal)',
                  display: 'flex',
                  alignItems: 'center',
                  gap: 6,
                }}
              >
                <span>✓</span>
                <span>Tenant boundary aligned: Workload will bind to <strong>{workloadTenant || operatorTenant}</strong>.</span>
              </div>
            )}

            {/* Workload Profile Summary */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, fontSize: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ color: 'var(--muted)' }}>Security Profile:</span>
                <span style={{ fontWeight: 600, color: 'var(--text)' }}>{secProfile.label}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ color: 'var(--muted)' }}>eBPF Flow Sensor:</span>
                <span style={{ color: 'var(--teal)', fontWeight: 600 }}>Active (signalloom-warden)</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span style={{ color: 'var(--muted)' }}>ServiceAccount:</span>
                <span style={{ fontFamily: 'monospace', color: 'var(--text)' }}>
                  {agent.runtime?.service_account || agent.service_account || 'default'}
                </span>
              </div>
            </div>

            {/* Checklist */}
            <div style={{ borderTop: '1px solid var(--border)', paddingTop: 10 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', marginBottom: 6, textTransform: 'uppercase' }}>
                Pre-Flight Invariants
              </div>
              <ul style={{ margin: 0, paddingLeft: 18, fontSize: 11, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>RFC 1123 DNS-compliant namespace format</li>
                <li>Valid SPIFFE URI prefix (<code>spiffe://</code>)</li>
                <li>Token budget configured (1k – 10M tokens)</li>
                <li>CEL admission and continuous posture hooks</li>
              </ul>
            </div>

            {/* How-to helper */}
            <div style={{ background: 'var(--surface)', padding: 10, borderRadius: 4, fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              💡 <strong>Seamless Onboarding:</strong> Claiming transitions this workload from <em>Discovered</em> to <em>Governed</em>,
              automatically issuing cryptographic identity credentials and activating continuous policy attestation.
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
