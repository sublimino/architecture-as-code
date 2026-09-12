import { useState, useId } from 'react'
import { useAuth0 } from '../../auth/oidc'
import { api } from '../../api/client'
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
      description: 'Standard Linux container cgroups/namespaces with eBPF Tetragon kernel flow observability.',
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
  const { getAccessTokenSilently } = useAuth0()
  const titleId = useId()
  const descriptionId = useId()

  const secProfile = getAgentWorkloadSecurityProfile(agent)

  const defaultPodName = agent.runtime?.pod_name || agent.name || agent.id
  const defaultNamespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const defaultSpiffeId =
    agent.identity?.spiffe_id ||
    `spiffe://signalloom.demo/ns/${defaultNamespace}/sa/${agent.runtime?.service_account || agent.service_account || defaultPodName}`
  const defaultHarness = agent.runtime?.framework || agent.framework || agent.type || 'claude-code'
  const defaultModel = agent.runtime?.model || agent.model_name || 'claude-3-5-sonnet'

  const [podName, setPodName] = useState(defaultPodName)
  const [namespace, setNamespace] = useState(defaultNamespace)
  const [spiffeId, setSpiffeId] = useState(defaultSpiffeId)
  const [harness, setHarness] = useState(defaultHarness)
  const [model, setModel] = useState(defaultModel)
  const [tokenBudget, setTokenBudget] = useState<number>(250000)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setError(null)

    const requestPayload: AgentClaimRequest = {
      pod_name: podName.trim() || defaultPodName,
      namespace: namespace.trim() || defaultNamespace,
      spiffe_id: spiffeId.trim() || defaultSpiffeId,
      harness: harness.trim() || defaultHarness,
      model: model.trim() || defaultModel,
      declared_tools: [],
      token_budget_limit: tokenBudget > 0 ? tokenBudget : 100000,
      agent_id: agent.id,
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
          maxWidth: 540,
          background: 'var(--surface, #0F172A)',
          border: '1px solid var(--border, #2a3142)',
          borderRadius: 8,
          padding: 24,
          position: 'relative',
          boxShadow: '0 12px 36px rgba(0,0,0,0.5)',
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

          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, marginTop: 12 }}>
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
      </div>
    </div>
  )
}
