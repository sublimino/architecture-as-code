import { useState, useEffect, useId, useContext } from 'react'
import { QueryClientContext, type QueryClient } from '@tanstack/react-query'
import { useAuth0 } from '../../auth/oidc'
import { claimDiscoveredAgent, type AgentClaimRequest, type AgentClaimResponse } from '../../api/agentClaim'
import { api } from '../../api/client'
import type { AgentResponse } from '../../types/api'
import { colors } from '../../styles/tokens'
import { detectGitOps } from '../../utils/gitops'

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

export function extractWorkloadName(podName: string): string {
  const match = podName.match(/^(.+?)(?:-[0-9a-f]{8,10}-[0-9a-z]{5}|-[0-9a-f]{8,10})$/)
  if (match) return match[1]
  const singleSuffix = podName.match(/^(.+?)-[0-9a-z]{5}$/)
  if (singleSuffix) return singleSuffix[1]
  return podName
}

export function extractDeclaredModel(agent: Partial<AgentResponse> | null | undefined): string | null {
  if (!agent) return null
  return (
    agent.runtime?.model ||
    (agent as any).model ||
    agent.model_name ||
    (agent.labels && agent.labels['signalloom.ai/model']) ||
    ((agent.runtime as any)?.labels && (agent.runtime as any).labels['signalloom.ai/model']) ||
    null
  )
}

export function getUrlClaimError(): string | null {
  if (typeof window !== 'undefined' && window.location && window.location.search) {
    try {
      const params = new URLSearchParams(window.location.search)
      return params.get('claim_error') || params.get('error') || null
    } catch {
      return null
    }
  }
  return null
}

export function clearUrlClaimError(): void {
  if (typeof window !== 'undefined' && window.location) {
    try {
      const params = new URLSearchParams(window.location.search || '')
      if (params.has('claim_error') || params.has('error')) {
        params.delete('claim_error')
        params.delete('error')
        const newSearch = params.toString() ? `?${params.toString()}` : ''
        const newPath = (window.location.pathname || '') + newSearch + (window.location.hash || '')
        if (window.history && window.history.replaceState) {
          window.history.replaceState(window.history.state, '', newPath)
        }
      }
    } catch {
      // ignore
    }
  }
}

export interface ClaimModalProps {
  agent: AgentResponse
  onClose: () => void
  onSuccess?: (result: AgentClaimResponse) => void
  claimError?: string | null
  onRefreshWorkload?: (agentId: string) => Promise<AgentResponse | void>
  onClearClaimError?: () => void
}

export default function ClaimModal({
  agent,
  onClose,
  onSuccess,
  claimError,
  onRefreshWorkload,
  onClearClaimError,
}: ClaimModalProps) {
  const { user, getAccessTokenSilently } = useAuth0()
  const titleId = useId()
  const descriptionId = useId()

  const queryClient = useContext(QueryClientContext) as QueryClient | undefined

  const [currentAgent, setCurrentAgent] = useState<AgentResponse>(agent)
  const [isRefreshing, setIsRefreshing] = useState(false)
  const [refreshedBadge, setRefreshedBadge] = useState<string | null>(null)
  const [clearedClaimError, setClearedClaimError] = useState(false)

  useEffect(() => {
    setCurrentAgent(agent)
  }, [agent])

  useEffect(() => {
    if (claimError) {
      setError(claimError)
      setClearedClaimError(false)
    }
  }, [claimError])

  const secProfile = getAgentWorkloadSecurityProfile(currentAgent)

  const defaultPodName =
    currentAgent.runtime?.pod_name ||
    (currentAgent.record_class === 'discovered' ? currentAgent.id : currentAgent.name)
  const defaultNamespace =
    currentAgent.runtime?.namespace || currentAgent.namespace || 'fe-signalloom-agents'
  const deploymentName =
    currentAgent.runtime?.workload_name || extractWorkloadName(currentAgent.name || defaultPodName)
  const defaultSpiffeId =
    currentAgent.identity?.spiffe_id ||
    `spiffe://signalloom.demo/ns/${defaultNamespace}/sa/${currentAgent.runtime?.service_account || currentAgent.service_account || defaultPodName}`
  const defaultHarness =
    currentAgent.runtime?.framework || currentAgent.framework || currentAgent.type || 'claude-code'

  const declaredModel = extractDeclaredModel(currentAgent)
  const hasDeclaredModel = Boolean(declaredModel && declaredModel.trim().length > 0)
  const defaultModel = declaredModel || 'claude-3-5-sonnet'

  const claimantOwner = user?.email || user?.name || user?.sub || ''
  const authenticatedOperator = user?.email || user?.sub || ''

  const workloadTenant =
    currentAgent.tenant ||
    (currentAgent.tenant_id && currentAgent.tenant_id !== 'undeclared' ? currentAgent.tenant_id : null)
  const operatorTenant =
    (user as { tenant?: string; 'https://signalloom.ai/tenant'?: string })?.tenant ||
    (user as { 'https://signalloom.ai/tenant'?: string })?.['https://signalloom.ai/tenant'] ||
    (claimantOwner ? claimantOwner.split('@')[1]?.split('.')[0] : 'default') ||
    'default'

  const isTenantMismatch = Boolean(workloadTenant && operatorTenant && workloadTenant !== operatorTenant)
  const gitops = detectGitOps(currentAgent, { tenant: operatorTenant })

  const [podName, setPodName] = useState(defaultPodName)
  const [namespace, setNamespace] = useState(defaultNamespace)
  const [spiffeId, setSpiffeId] = useState(defaultSpiffeId)
  const [harness, setHarness] = useState(defaultHarness)
  const [model, setModel] = useState(defaultModel)
  const [tokenBudget, setTokenBudget] = useState<number>(250000)
  const [owner, setOwner] = useState(claimantOwner)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(() => claimError || getUrlClaimError() || null)
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null)

  const handleCopy = (text: string, id: string) => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(text).catch(() => {})
      setCopiedCmd(id)
      setTimeout(() => setCopiedCmd(null), 2500)
    }
  }

  const effectiveError = error || (clearedClaimError ? null : claimError) || null

  const isMissingModelError = Boolean(
    !hasDeclaredModel ||
    (effectiveError && (
      effectiveError.toLowerCase().includes('no signalloom.ai/model') ||
      effectiveError.toLowerCase().includes('workload_model_undeclared') ||
      effectiveError.toLowerCase().includes('refusing to record an invented model')
    ))
  )

  const isMissingTenantError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('no signalloom.ai/tenant') ||
      effectiveError.toLowerCase().includes('workload_tenant_undeclared')
    )
  )

  const isCrossTenantError = Boolean(
    isTenantMismatch ||
    (effectiveError && (
      effectiveError.toLowerCase().includes('belongs to another tenant') ||
      effectiveError.toLowerCase().includes('cross_tenant_forbidden')
    ))
  )

  const isAlreadyClaimedError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('already claimed') ||
      effectiveError.toLowerCase().includes('duplicate_claim') ||
      effectiveError.toLowerCase().includes('409') ||
      effectiveError.toLowerCase().includes('conflict')
    )
  )

  const hasBlockers =
    isMissingModelError || isTenantMismatch || isCrossTenantError || isMissingTenantError || isAlreadyClaimedError
  const isClaimable = !hasBlockers && !effectiveError

  const relabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/tenant=${operatorTenant} --overwrite`
  const modelLabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/model=${model || defaultModel} --overwrite`
  const deploymentModelPatchCommand = `kubectl -n ${namespace} patch deployment ${deploymentName} -p '{"spec":{"template":{"metadata":{"labels":{"signalloom.ai/model":"${model || defaultModel}"}}}}}'`

  const refreshWorkload = async (silent = false): Promise<AgentResponse | null> => {
    if (!silent) {
      setIsRefreshing(true)
    }

    try {
      let freshAgent: AgentResponse | undefined
      if (onRefreshWorkload) {
        try {
          const res = await onRefreshWorkload(currentAgent.id || agent.id)
          if (res && typeof res === 'object' && 'id' in res) {
            freshAgent = res as AgentResponse
          }
        } catch {
          // ignore error in onRefreshWorkload
        }
      }

      if (!freshAgent) {
        let token = 'demo-token'
        try {
          token = await getAccessTokenSilently()
        } catch {
          token = 'demo-token'
        }
        try {
          freshAgent = await api.agents.get(token, currentAgent.id || agent.id)
        } catch {
          // ignore error in api.agents.get
        }
      }

      if (freshAgent) {
        const updatedAgent: AgentResponse = {
          ...freshAgent,
          id: agent.id,
          name: agent.name || freshAgent.name,
        }
        setCurrentAgent(updatedAgent)

        const freshDeclaredModel = extractDeclaredModel(freshAgent)
        if (freshDeclaredModel && freshDeclaredModel.trim().length > 0) {
          setModel(freshDeclaredModel)
          setError(null)
          setClearedClaimError(true)
          clearUrlClaimError()
          onClearClaimError?.()
          setRefreshedBadge('Workload refreshed: model detected')
          setTimeout(() => setRefreshedBadge(null), 4000)
        }

        const freshTenant =
          freshAgent.tenant ||
          (freshAgent.tenant_id && freshAgent.tenant_id !== 'undeclared' ? freshAgent.tenant_id : null)
        if (freshTenant && operatorTenant && freshTenant === operatorTenant) {
          if (isCrossTenantError || isTenantMismatch) {
            setError(null)
            setClearedClaimError(true)
            clearUrlClaimError()
            onClearClaimError?.()
          }
        }

        return updatedAgent
      }
    } finally {
      if (!silent) {
        setIsRefreshing(false)
      }
    }

    return null
  }

  useEffect(() => {
    refreshWorkload(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setError(null)

    // Pre-submission refresh
    const fresh = await refreshWorkload(true)
    const activeAgent = fresh || currentAgent

    const activeDeclaredModel = extractDeclaredModel(activeAgent)
    const activeHasDeclaredModel = Boolean(activeDeclaredModel && activeDeclaredModel.trim().length > 0)

    if (!activeHasDeclaredModel) {
      setError(`Workload '${activeAgent.name || podName}' declares no signalloom.ai/model; refusing to record an invented model.`)
      setSubmitting(false)
      return
    }

    const requestPayload: AgentClaimRequest = {
      pod_name: podName.trim() || defaultPodName,
      display_name: agent.name,
      namespace: namespace.trim() || defaultNamespace,
      spiffe_id: spiffeId.trim() || defaultSpiffeId,
      harness: harness.trim() || defaultHarness,
      model: (activeDeclaredModel || model || defaultModel).trim(),
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

      clearUrlClaimError()

      if (queryClient) {
        await Promise.all([
          queryClient.invalidateQueries({ queryKey: ['agents'] }),
          queryClient.invalidateQueries({ queryKey: ['discovery'] }),
          queryClient.invalidateQueries({ queryKey: ['workloads'] }),
        ]).catch(() => {})
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
          Bring discovered workload <strong style={{ color: 'var(--text)' }}>{currentAgent.name || currentAgent.id}</strong> into
          Signal Loom tenant governance. {secProfile.description}
        </p>

        {effectiveError && (
          <div
            data-testid="claim-modal-error"
            style={{
              background: 'rgba(239, 68, 68, 0.12)',
              border: '1px solid rgba(239, 68, 68, 0.35)',
              borderRadius: 6,
              padding: '12px 16px',
              marginBottom: 16,
              lineHeight: 1.4,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
              <div style={{ color: 'var(--error, #ef4444)', fontWeight: 700, fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
                <span>⚠️</span>
                <span>
                  {isMissingModelError
                    ? 'Workload Model Objection: Missing signalloom.ai/model'
                    : isCrossTenantError || isTenantMismatch
                    ? 'Tenant Boundary Objection: Cross-Tenant Protection'
                    : isAlreadyClaimedError
                    ? 'Workload Conflict: Already Governed'
                    : 'Claim Pre-Flight Refusal'}
                </span>
              </div>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: 'rgba(239, 68, 68, 0.2)',
                  color: 'var(--error, #ef4444)',
                  border: '1px solid rgba(239, 68, 68, 0.4)',
                  textTransform: 'uppercase',
                }}
              >
                Refusal
              </span>
            </div>
            <div style={{ color: 'var(--text)', fontSize: 12, marginBottom: 8 }}>
              <strong>Reported Error:</strong> {effectiveError}
            </div>
            <div style={{ color: 'var(--muted)', fontSize: 11, marginBottom: 8, lineHeight: 1.5 }}>
              {isMissingModelError
                ? 'Signal Loom strictly mandates that every governed agent declares an approved AI foundation model via the signalloom.ai/model label or annotation (HTTP 422 workload_model_undeclared). Without an explicit model identifier, token cost accounting, rate limiting, and model-specific compliance policies cannot be established. Refusing to record an invented model guarantees cryptographic attestation integrity.'
                : isCrossTenantError || isTenantMismatch
                ? 'Signal Loom strictly enforces tenant isolation at the API gateway and claim engine (HTTP 403 cross_tenant_forbidden). Workloads provisioned for another tenant cannot be claimed without re-labelling.'
                : 'The claim engine refused the claim request during pre-flight policy evaluation.'}
            </div>
            {isMissingModelError && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 8 }}>
                <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)' }}>Remediation Command:</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <code style={{ background: 'var(--surface)', padding: '4px 6px', borderRadius: 3, color: 'var(--cyan)', fontSize: 10, flex: 1, overflowX: 'auto' }}>
                    {modelLabelCommand}
                  </code>
                  <button
                    type="button"
                    className="btn btn-secondary"
                    data-testid="claim-modal-copy-model-cmd-btn"
                    onClick={() => handleCopy(modelLabelCommand, 'error-model-cmd')}
                    style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                  >
                    {copiedCmd === 'error-model-cmd' ? 'Copied! ✓' : 'Copy'}
                  </button>
                </div>
              </div>
            )}
            {(isCrossTenantError || isTenantMismatch) && !isMissingModelError && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginTop: 8 }}>
                <span style={{ fontSize: 10, fontWeight: 600, color: 'var(--muted)' }}>Remediation Command:</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <code style={{ background: 'var(--surface)', padding: '4px 6px', borderRadius: 3, color: 'var(--cyan)', fontSize: 10, flex: 1, overflowX: 'auto' }}>
                    {relabelCommand}
                  </code>
                  <button
                    type="button"
                    className="btn btn-secondary"
                    data-testid="claim-modal-copy-relabel-cmd-btn"
                    onClick={() => handleCopy(relabelCommand, 'error-relabel-cmd')}
                    style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                  >
                    {copiedCmd === 'error-relabel-cmd' ? 'Copied! ✓' : 'Copy'}
                  </button>
                </div>
              </div>
            )}
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
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                  <label style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)' }}>
                    Model
                  </label>
                  {!hasDeclaredModel && (
                    <span
                      data-testid="claim-modal-model-undeclared-badge"
                      style={{
                        fontSize: 10,
                        fontWeight: 700,
                        color: 'var(--error, #ef4444)',
                        background: 'rgba(239, 68, 68, 0.15)',
                        padding: '1px 6px',
                        borderRadius: 3,
                        border: '1px solid rgba(239, 68, 68, 0.3)',
                      }}
                    >
                      UNDECLARED ON POD
                    </span>
                  )}
                </div>
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
                    border: `1px solid ${!hasDeclaredModel ? 'rgba(239, 68, 68, 0.4)' : 'var(--border, #30363d)'}`,
                    color: 'var(--text, #c9d1d9)',
                    fontSize: 13,
                    boxSizing: 'border-box',
                  }}
                />
                {!hasDeclaredModel && (
                  <div
                    data-testid="claim-modal-model-warning"
                    style={{
                      fontSize: 11,
                      color: 'var(--error, #ef4444)',
                      marginTop: 4,
                      lineHeight: 1.4,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      gap: 6,
                      flexWrap: 'wrap',
                    }}
                  >
                    <span>⚠️ Pod in cluster has no <code>signalloom.ai/model</code> label.</span>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      data-testid="claim-modal-copy-model-fix-btn"
                      onClick={() => handleCopy(modelLabelCommand, 'input-model-cmd')}
                      style={{ fontSize: 10, padding: '1px 6px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'input-model-cmd' ? 'Copied! ✓' : 'Copy Label Cmd'}
                    </button>
                  </div>
                )}
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
                  color: currentAgent.tenant || (currentAgent.tenant_id && currentAgent.tenant_id !== 'undeclared') ? 'var(--text)' : 'var(--muted)',
                }}
              >
                {currentAgent.tenant || (currentAgent.tenant_id && currentAgent.tenant_id !== 'undeclared' ? currentAgent.tenant_id : 'Undeclared (Will bind to claimant tenant on claim)')}
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

            {hasBlockers && (
              <div
                data-testid="claim-modal-blocker-advisory"
                style={{
                  fontSize: 11,
                  color: 'var(--amber, #f59e0b)',
                  background: 'rgba(234, 179, 8, 0.1)',
                  border: '1px solid rgba(234, 179, 8, 0.25)',
                  borderRadius: 4,
                  padding: '6px 10px',
                  lineHeight: 1.4,
                }}
              >
                ⚠️ <strong>Pre-flight blockers detected:</strong> Resolve outstanding objections before claiming.
              </div>
            )}

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

            {/* Overall Claimability Status (Red / Green) */}
            {isClaimable ? (
              <div
                data-testid="claim-modal-claimability-status"
                style={{
                  padding: '12px 14px',
                  background: 'rgba(34, 197, 94, 0.12)',
                  border: '1px solid rgba(34, 197, 94, 0.35)',
                  borderRadius: 6,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: 10,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <span style={{ fontSize: 18 }}>🟢</span>
                  <div>
                    <div style={{ color: 'var(--teal, #10B981)', fontWeight: 700, fontSize: 13 }}>
                      Claimable — Ready for Governance
                    </div>
                    <div style={{ color: 'var(--text)', fontSize: 11, marginTop: 2 }}>
                      All pre-flight requirements verified. Workload will bind to {workloadTenant || operatorTenant}.
                    </div>
                  </div>
                </div>
                <span
                  data-testid="claim-modal-claimability-badge"
                  style={{
                    fontSize: 10,
                    fontWeight: 700,
                    padding: '3px 8px',
                    borderRadius: 4,
                    background: 'rgba(34, 197, 94, 0.2)',
                    color: 'var(--teal, #10B981)',
                    border: '1px solid rgba(34, 197, 94, 0.4)',
                    textTransform: 'uppercase',
                    letterSpacing: '0.04em',
                    whiteSpace: 'nowrap',
                  }}
                >
                  Claimable
                </span>
              </div>
            ) : (
              <div
                data-testid="claim-modal-claimability-status"
                style={{
                  padding: '12px 14px',
                  background: 'rgba(239, 68, 68, 0.12)',
                  border: '1px solid rgba(239, 68, 68, 0.4)',
                  borderRadius: 6,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: 10,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <span style={{ fontSize: 18 }}>🛑</span>
                  <div>
                    <div style={{ color: 'var(--error, #ef4444)', fontWeight: 700, fontSize: 13 }}>
                      Claim Blocked — Action Required
                    </div>
                    <div style={{ color: 'var(--text)', fontSize: 11, marginTop: 2 }}>
                      {isMissingModelError && isTenantMismatch
                        ? 'Missing AI model declaration and tenant boundary mismatch.'
                        : isMissingModelError
                        ? 'Missing signalloom.ai/model declaration on workload pod.'
                        : isTenantMismatch
                        ? `Tenant mismatch: workload belongs to "${workloadTenant}".`
                        : effectiveError || 'Pre-flight checks failed. Resolve blockers to onboard.'}
                    </div>
                  </div>
                </div>
                <span
                  data-testid="claim-modal-claimability-badge"
                  style={{
                    fontSize: 10,
                    fontWeight: 700,
                    padding: '3px 8px',
                    borderRadius: 4,
                    background: 'rgba(239, 68, 68, 0.2)',
                    color: 'var(--error, #ef4444)',
                    border: '1px solid rgba(239, 68, 68, 0.4)',
                    textTransform: 'uppercase',
                    letterSpacing: '0.04em',
                    whiteSpace: 'nowrap',
                  }}
                >
                  Blocked
                </span>
              </div>
            )}

            {/* Pre-Flight Prerequisites Matrix */}
            <div data-testid="claim-modal-prereqs-matrix" style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                  Pre-Flight Prerequisites Verification
                </div>
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="claim-modal-refresh-btn"
                  onClick={() => {
                    void refreshWorkload(false)
                  }}
                  disabled={isRefreshing}
                  style={{
                    fontSize: 11,
                    padding: '3px 8px',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 5,
                    cursor: isRefreshing ? 'not-allowed' : 'pointer',
                    background: 'var(--surface, #1e293b)',
                    border: '1px solid var(--border, #334155)',
                    color: 'var(--text, #f8fafc)',
                    borderRadius: 4,
                  }}
                  aria-label="Refresh Workload"
                >
                  <span
                    data-testid="claim-modal-refresh-spinner"
                    style={{
                      display: 'inline-block',
                      animation: isRefreshing ? 'spin 1s linear infinite' : 'none',
                    }}
                  >
                    🔄
                  </span>
                  <span>{isRefreshing ? 'Refreshing…' : 'Refresh'}</span>
                </button>
              </div>

              {refreshedBadge && (
                <div
                  data-testid="claim-modal-refreshed-badge"
                  style={{
                    padding: '6px 10px',
                    background: 'rgba(34, 197, 94, 0.15)',
                    border: '1px solid rgba(34, 197, 94, 0.35)',
                    borderRadius: 4,
                    color: 'var(--teal, #10B981)',
                    fontSize: 11,
                    fontWeight: 600,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                  }}
                >
                  <span>✓</span>
                  <span>{refreshedBadge}</span>
                </div>
              )}

              {/* Prereq 1: AI Model Attribution */}
              <div
                data-testid="claim-modal-prereq-model"
                style={{
                  padding: '8px 10px',
                  background: isMissingModelError ? 'rgba(239, 68, 68, 0.08)' : 'rgba(34, 197, 94, 0.08)',
                  border: `1px solid ${isMissingModelError ? 'rgba(239, 68, 68, 0.3)' : 'rgba(34, 197, 94, 0.25)'}`,
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                  <span style={{ fontWeight: 600, color: 'var(--text)' }}>AI Model Attribution</span>
                  <span
                    data-testid="claim-modal-prereq-model-badge"
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: isMissingModelError ? 'rgba(239, 68, 68, 0.2)' : 'rgba(34, 197, 94, 0.2)',
                      color: isMissingModelError ? 'var(--error)' : 'var(--teal)',
                    }}
                  >
                    {isMissingModelError ? 'UNDECLARED' : 'VERIFIED'}
                  </span>
                </div>
                <div style={{ fontSize: 11, color: isMissingModelError ? 'var(--error)' : 'var(--muted)', lineHeight: 1.4 }}>
                  {isMissingModelError ? (
                    <div>
                      Workload in cluster declares no <code>signalloom.ai/model</code>. Refusing invented model.
                      <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
                        <code style={{ background: 'var(--surface)', padding: '3px 6px', borderRadius: 3, color: 'var(--cyan)', fontSize: 10, flex: 1, overflowX: 'auto' }}>
                          {modelLabelCommand}
                        </code>
                        <button
                          type="button"
                          className="btn btn-secondary"
                          data-testid="claim-modal-copy-model-btn"
                          onClick={() => handleCopy(modelLabelCommand, 'prereq-model')}
                          style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                        >
                          {copiedCmd === 'prereq-model' ? 'Copied! ✓' : 'Copy'}
                        </button>
                      </div>
                    </div>
                  ) : (
                    <span>Declared model: <strong style={{ color: 'var(--text)' }}>{declaredModel}</strong></span>
                  )}
                </div>
              </div>

              {/* Prereq 2: Tenant Boundary */}
              <div
                data-testid="claim-modal-prereq-tenant"
                style={{
                  padding: '8px 10px',
                  background: isTenantMismatch ? 'rgba(239, 68, 68, 0.08)' : 'rgba(34, 197, 94, 0.08)',
                  border: `1px solid ${isTenantMismatch ? 'rgba(239, 68, 68, 0.3)' : 'rgba(34, 197, 94, 0.25)'}`,
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                  <span style={{ fontWeight: 600, color: 'var(--text)' }}>Tenant Boundary</span>
                  <span
                    data-testid="claim-modal-prereq-tenant-badge"
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: isTenantMismatch ? 'rgba(239, 68, 68, 0.2)' : 'rgba(34, 197, 94, 0.2)',
                      color: isTenantMismatch ? 'var(--error)' : 'var(--teal)',
                    }}
                  >
                    {isTenantMismatch ? 'MISMATCH' : 'ALIGNED'}
                  </span>
                </div>
                <div style={{ fontSize: 11, color: isTenantMismatch ? 'var(--error)' : 'var(--muted)', lineHeight: 1.4 }}>
                  {isTenantMismatch ? (
                    <div>
                      Workload "{workloadTenant}" ≠ Session "{operatorTenant}"
                      <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
                        <code style={{ background: 'var(--surface)', padding: '3px 6px', borderRadius: 3, color: 'var(--cyan)', fontSize: 10, flex: 1, overflowX: 'auto' }}>
                          {relabelCommand}
                        </code>
                        <button
                          type="button"
                          className="btn btn-secondary"
                          data-testid="claim-modal-copy-tenant-btn"
                          onClick={() => handleCopy(relabelCommand, 'prereq-tenant')}
                          style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                        >
                          {copiedCmd === 'prereq-tenant' ? 'Copied! ✓' : 'Copy'}
                        </button>
                      </div>
                    </div>
                  ) : (
                    <span>Aligned to tenant: <strong style={{ color: 'var(--text)' }}>{workloadTenant || operatorTenant}</strong></span>
                  )}
                </div>
              </div>

              {/* Prereq 3: GitOps Reconciliation */}
              <div
                data-testid="claim-modal-prereq-gitops"
                style={{
                  padding: '8px 10px',
                  background: gitops.isGitOps ? 'rgba(234, 179, 8, 0.08)' : 'rgba(34, 197, 94, 0.08)',
                  border: `1px solid ${gitops.isGitOps ? 'rgba(234, 179, 8, 0.3)' : 'rgba(34, 197, 94, 0.25)'}`,
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                  <span style={{ fontWeight: 600, color: 'var(--text)' }}>GitOps Confinement</span>
                  <span
                    data-testid="claim-modal-prereq-gitops-badge"
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: gitops.isGitOps ? 'rgba(234, 179, 8, 0.2)' : 'rgba(34, 197, 94, 0.2)',
                      color: gitops.isGitOps ? 'var(--amber)' : 'var(--teal)',
                    }}
                  >
                    {gitops.isGitOps ? (gitops.engine === 'flux' ? 'FLUX' : gitops.engine === 'argo' ? 'ARGO' : 'GITOPS') : 'STANDALONE'}
                  </span>
                </div>
                <div style={{ fontSize: 11, color: gitops.isGitOps ? 'var(--amber)' : 'var(--muted)', lineHeight: 1.4 }}>
                  {gitops.isGitOps ? 'Managed by GitOps. Commit changes to git repository.' : 'Standalone workload (direct kubectl changes supported).'}
                </div>
              </div>

              {/* Prereq 4: Workload Attestation */}
              <div
                data-testid="claim-modal-prereq-spiffe"
                style={{
                  padding: '8px 10px',
                  background: 'rgba(34, 197, 94, 0.08)',
                  border: '1px solid rgba(34, 197, 94, 0.25)',
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                  <span style={{ fontWeight: 600, color: 'var(--text)' }}>SPIFFE Workload Attestation</span>
                  <span
                    data-testid="claim-modal-prereq-spiffe-badge"
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: 'rgba(34, 197, 94, 0.2)',
                      color: 'var(--teal)',
                    }}
                  >
                    VERIFIED
                  </span>
                </div>
                <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
                  ServiceAccount: <code>{currentAgent.runtime?.service_account || currentAgent.service_account || defaultPodName}</code>
                </div>
              </div>
            </div>

            {/* GitOps Warning Notice if GitOps is detected */}
            {gitops.isGitOps && (
              <div
                data-testid="claim-modal-gitops-notice"
                style={{
                  padding: '10px 12px',
                  background: 'rgba(234, 179, 8, 0.12)',
                  border: '1px solid rgba(234, 179, 8, 0.35)',
                  borderRadius: 6,
                  fontSize: 12,
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
                  <div style={{ color: 'var(--amber, #f59e0b)', fontWeight: 700, display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>⚡</span>
                    <span>GitOps Managed Workload</span>
                  </div>
                  <span
                    data-testid="claim-modal-gitops-badge"
                    style={{
                      fontSize: 10,
                      fontWeight: 700,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: 'rgba(234, 179, 8, 0.2)',
                      color: 'var(--amber, #f59e0b)',
                      textTransform: 'uppercase',
                    }}
                  >
                    {gitops.engine === 'flux' ? 'Flux' : gitops.engine === 'argo' ? 'ArgoCD' : 'GitOps'}
                  </span>
                </div>
                <div style={{ color: 'var(--text)', lineHeight: 1.4, marginBottom: 6 }}>
                  {gitops.recommendation}
                </div>
                {gitops.patchYaml && (
                  <div style={{ marginTop: 6 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
                      <span style={{ fontSize: 10, color: 'var(--muted)', fontWeight: 600 }}>Git Remediation Patch:</span>
                      <button
                        type="button"
                        className="btn btn-secondary"
                        data-testid="claim-modal-copy-gitops-patch-btn"
                        onClick={() => handleCopy(gitops.patchYaml!, 'modal-gitops-patch')}
                        style={{ fontSize: 10, padding: '2px 6px', whiteSpace: 'nowrap' }}
                      >
                        {copiedCmd === 'modal-gitops-patch' ? 'Copied! ✓' : 'Copy'}
                      </button>
                    </div>
                    <pre
                      data-testid="claim-modal-gitops-patch"
                      style={{
                        background: 'var(--surface)',
                        padding: '6px 8px',
                        borderRadius: 3,
                        color: 'var(--cyan)',
                        fontSize: 10,
                        fontFamily: 'monospace',
                        margin: 0,
                        overflowX: 'auto',
                      }}
                    >
                      {gitops.patchYaml}
                    </pre>
                  </div>
                )}
              </div>
            )}

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
                  {currentAgent.runtime?.service_account || currentAgent.service_account || 'default'}
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
                <li>Token budget configured (1k to 10M tokens)</li>
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
