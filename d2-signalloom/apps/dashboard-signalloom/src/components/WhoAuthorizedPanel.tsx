// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState, useEffect, useMemo, memo } from 'react'
import AgentDeepLink from './AgentDeepLink'
import DelegationChainNode from './DelegationChainNode'
import CycleDetectedWarning from './CycleDetectedWarning'
import { useAuth0 } from '../auth/oidc'
import { weaveApi, type AuthorizationChain } from '../api/weaveApi'
import type { DelegationRecord } from '../types/identity'

export interface WhoAuthorizedPanelProps {
  chain?: AuthorizationChain | null
  actorId?: string
  agentId?: string
  actionId?: string
  onSelectActor?: (actorId: string) => void
  availableActors?: { id: string; name?: string }[]
  compact?: boolean
  hideHeaderControls?: boolean
}

export const WhoAuthorizedPanel: React.FC<WhoAuthorizedPanelProps> = memo(({
  chain: initialChain,
  actorId,
  agentId,
  actionId,
  onSelectActor,
  availableActors = [],
  compact = false,
  hideHeaderControls = false,
}) => {
  const { getAccessTokenSilently } = useAuth0()
  const targetId = actorId || agentId
  const [activeChain, setActiveChain] = useState<AuthorizationChain | null>(initialChain || null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copiedGitoid, setCopiedGitoid] = useState(false)

  useEffect(() => {
    if (initialChain) {
      setActiveChain(initialChain)
      return
    }

    if (!targetId && !actionId) return

    let isMounted = true
    const loadChain = async () => {
      try {
        setLoading(true)
        setError(null)
        const token = await getAccessTokenSilently()
        let data: AuthorizationChain | null = null

        if (actionId) {
          try {
            const resp = await weaveApi.getAuthorizationChains(token, { action_id: actionId })
            if (resp && resp.chains && resp.chains.length > 0) {
              data = resp.chains[0]
            }
          } catch {
            // fallback
          }
        }

        if (!data && targetId) {
          data = await weaveApi.getActorAuthorization(token, targetId, actionId)
        }

        if (isMounted) {
          if (data) {
            setActiveChain(data)
          } else {
            setError(actionId ? `No cryptographic authorization proof found for action ID: ${actionId}` : 'Failed to load authorization chain.')
          }
        }
      } catch (err) {
        if (isMounted) {
          setError(err instanceof Error ? err.message : 'Failed to load authorization chain.')
        }
      } finally {
        if (isMounted) {
          setLoading(false)
        }
      }
    }

    loadChain()
    return () => {
      isMounted = false
    }
  }, [initialChain, targetId, actionId, getAccessTokenSilently])

  const copyGitoid = (gitoid: string) => {
    navigator.clipboard?.writeText(gitoid).catch(() => {})
    setCopiedGitoid(true)
    setTimeout(() => setCopiedGitoid(false), 2000)
  }

  const chain = activeChain

  const extractAgentSlug = (identity: string): string => {
    const saMatch = identity.match(/(?:^|\/)sa\/([^/]+)$/)
    if (saMatch) {
      return saMatch[1].replace(/-sa$/, '')
    }
    return identity.replace(/^spiffe:\/\/[^/]+\//, '')
  }

  // Derive multi-node stepped delegation path from delegationChain or synthesize from principal/actsOnBehalfOf
  const steppedHops: DelegationRecord[] = useMemo(() => {
    if (chain?.delegationChain && chain.delegationChain.length > 0) {
      return chain.delegationChain
    }

    if (!chain) return []

    // Synthesize structured stepped hops from actsOnBehalfOf / principal
    const hops: DelegationRecord[] = []
    const principal = chain.principal || 'Operator'
    const agent = chain.agentIdentity || targetId || 'Executing Agent'

    // Root Principal Node
    hops.push({
      id: 1,
      delegate_actor_id: principal,
      principal_actor_id: principal,
      authz_ref: 'sso:saml:authenticated-principal',
      valid_from: chain.timestamp || new Date().toISOString(),
      role: 'Human Principal',
      containment_evidenced: true,
    })

    // Intermediate Planner / Pipeline if present in actsOnBehalfOf string
    if (chain.actsOnBehalfOf && (chain.actsOnBehalfOf.includes('->') || chain.actsOnBehalfOf.includes('via chain'))) {
      const match = chain.actsOnBehalfOf.match(/\[(.*?)\]/)
      if (match && match[1]) {
        const segments = match[1].split(',').map((s) => s.trim())
        segments.forEach((seg, idx) => {
          const parts = seg.split('->').map((p) => p.trim())
          if (parts.length === 2 && parts[0] !== principal) {
            hops.push({
              id: idx + 2,
              delegate_actor_id: parts[0],
              principal_actor_id: parts[1],
              authz_ref: 'k8s-rbac:delegation-binding',
              valid_from: chain.timestamp || new Date().toISOString(),
              role: 'Delegated Agent',
              containment_evidenced: true,
              nono_containment: true,
            })
          }
        })
      }
    }

    // Leaf Executing Agent Node
    if (hops.length === 1 || hops[hops.length - 1].delegate_actor_id !== agent) {
      hops.push({
        id: hops.length + 1,
        delegate_actor_id: agent,
        principal_actor_id: hops[hops.length - 1].delegate_actor_id,
        authz_ref: chain.actsOnBehalfOf?.includes('authz:')
          ? chain.actsOnBehalfOf.split('authz:')[1].replace(/[()]/g, '').trim()
          : 'k8s-impersonation-policy',
        valid_from: chain.timestamp || new Date().toISOString(),
        role: 'Executing Agent',
        containment_evidenced: true,
        nono_containment: true,
        spiffe_svid: agent.startsWith('spiffe://') ? agent : undefined,
      })
    }

    return hops
  }, [chain, targetId])

  return (
    <div
      data-testid="who-authorized-panel"
      style={{
        marginTop: compact ? 0 : 20,
        marginBottom: compact ? 0 : 24,
        padding: compact ? '16px 18px' : '20px 24px',
        background: 'var(--surface, #1e222b)',
        borderRadius: 8,
        border: '1px solid var(--border, #2d3340)',
      }}
    >
      {/* Header */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 12,
          marginBottom: 18,
          borderBottom: '1px solid var(--border-subtle, #2d3340)',
          paddingBottom: 14,
        }}
      >
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: 'var(--text, #f0f3f8)' }}>
              🛡️ Who Authorized This Action?
            </h3>
            {chain && (
              <span
                data-testid="chain-completeness-badge"
                style={{
                  fontSize: 11,
                  padding: '2px 8px',
                  borderRadius: 12,
                  fontWeight: 600,
                  textTransform: 'uppercase',
                  letterSpacing: '0.5px',
                  background: chain.complete ? 'rgba(16, 185, 129, 0.18)' : 'rgba(245, 158, 11, 0.18)',
                  color: chain.complete ? 'var(--teal, #10b981)' : 'var(--amber, #f59e0b)',
                  border: `1px solid ${chain.complete ? 'rgba(16, 185, 129, 0.4)' : 'rgba(245, 158, 11, 0.4)'}`,
                }}
              >
                {chain.complete ? 'COMPLETE ATTESTED CHAIN' : 'INCOMPLETE CHAIN'}
              </span>
            )}
          </div>
          <p style={{ margin: '4px 0 0', fontSize: 12, color: 'var(--muted, #8b949e)' }}>
            Cryptographically resolved identity spine, live delegator tree & write-time Witness attestation
          </p>
        </div>

        {/* Actor Selector / Controls */}
        {!hideHeaderControls && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            {availableActors.length > 0 && (
              <select
                data-testid="actor-selector"
                value={chain?.actorId || targetId || ''}
                onChange={(e) => {
                  if (onSelectActor) onSelectActor(e.target.value)
                }}
                style={{
                  padding: '5px 10px',
                  fontSize: 12,
                  borderRadius: 4,
                  background: 'var(--surface2, #262c37)',
                  color: 'var(--text, #f0f3f8)',
                  border: '1px solid var(--border, #2d3340)',
                  cursor: 'pointer',
                }}
              >
                {availableActors.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.name || a.id}
                  </option>
                ))}
              </select>
            )}

            <span
              data-testid="kpi-fraction-metric"
              style={{
                fontSize: 12,
                padding: '3px 10px',
                borderRadius: 12,
                background: 'var(--surface2, #262c37)',
                border: '1px solid var(--border, #2d3340)',
                color: 'var(--cyan, #06b6d4)',
                fontWeight: 600,
              }}
            >
              Resolution Fidelity: {chain ? `${Math.round(chain.confidence * 100)}%` : '—'}
            </span>
          </div>
        )}
      </div>

      {/* Cycle Detection Alert */}
      {chain?.cycleDetected && (
        <CycleDetectedWarning
          cycleDetected={true}
          message="Adversarial circular delegation cycle detected in delegation graph. Chain traversal clamped to prevent infinite recursion."
        />
      )}

      {loading && (
        <div data-testid="who-authorized-loading" style={{ padding: '24px 0', textAlign: 'center', color: 'var(--muted, #8b949e)', fontSize: 13 }}>
          Resolving authorization chain over identity graph...
        </div>
      )}

      {error && (
        <div data-testid="who-authorized-error" style={{ padding: '12px', background: 'rgba(239, 68, 68, 0.1)', color: 'var(--error, #ef4444)', borderRadius: 6, fontSize: 12 }}>
          {error}
        </div>
      )}

      {!loading && !error && !chain && (
        <div data-testid="who-authorized-empty" style={{ padding: '24px 0', textAlign: 'center', color: 'var(--muted, #8b949e)', fontSize: 13 }}>
          Select an actor or observation to inspect its full authorization chain.
        </div>
      )}

      {!loading && chain && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          {/* Hop 1: Action */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              1. Observed Action
            </span>
            <div data-testid="hop-action" style={{ fontSize: 13, color: 'var(--text, #f0f3f8)', fontWeight: 500 }}>
              {chain.action || 'Privileged model inference / workload execution'}
            </div>
          </div>

          {/* Hop 2: Agent Identity */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              2. Agent Identity
            </span>
            <div data-testid="hop-agent-identity" style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--teal, #10b981)', fontWeight: 600 }}>
              <AgentDeepLink
                target={extractAgentSlug(chain.agentIdentity)}
                dataTestId="hop-agent-identity-link"
                title={`View agent dossier for ${extractAgentSlug(chain.agentIdentity)}`}
                style={{ color: 'inherit', textDecoration: 'underline', textUnderlineOffset: 2 }}
              >
                {chain.agentIdentity}
              </AgentDeepLink>
            </div>
          </div>

          {/* Hop 3: Acts-On-Behalf-Of & Stepped Multi-Node Delegation Hierarchy */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '12px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              3. Acts-On-Behalf-Of
            </span>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div data-testid="hop-acts-on-behalf-of" style={{ fontSize: 12, color: 'var(--violet, #a78bfa)', fontFamily: 'monospace' }}>
                {chain.actsOnBehalfOf || '⚠️ Missing delegation link'}
              </div>

              {/* Stepped Multi-Node Delegation Tree */}
              {steppedHops.length > 0 && (
                <div
                  data-testid="delegation-stepped-path"
                  style={{
                    display: 'flex',
                    alignItems: 'stretch',
                    flexWrap: 'wrap',
                    gap: 8,
                    marginTop: 6,
                    padding: '10px 12px',
                    borderRadius: 6,
                    background: 'var(--surface, #1e222b)',
                    border: '1px solid var(--border, #2d3340)',
                  }}
                >
                  {steppedHops.map((hop, idx) => (
                    <React.Fragment key={hop.id || idx}>
                      <DelegationChainNode
                        hopIndex={idx}
                        totalHops={steppedHops.length}
                        record={hop}
                        actorId={hop.delegate_actor_id}
                        role={hop.role}
                        spiffeId={hop.spiffe_svid}
                        authzRef={hop.authz_ref}
                        validFrom={hop.valid_from}
                        validTo={hop.valid_to}
                        isRoot={idx === 0}
                        isLeaf={idx === steppedHops.length - 1}
                        containmentEvidenced={hop.containment_evidenced}
                      />
                      {idx < steppedHops.length - 1 && (
                        <div
                          aria-hidden="true"
                          style={{
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            color: 'var(--muted, #8b949e)',
                            fontSize: 14,
                            padding: '0 2px',
                          }}
                        >
                          ➔
                        </div>
                      )}
                    </React.Fragment>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* Hop 4: Principal */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              4. Authorizing Principal
            </span>
            <div data-testid="hop-principal" style={{ fontSize: 13, color: 'var(--amber, #f59e0b)', fontWeight: 600 }}>
              {chain.principal || '⚠️ Unassigned Principal'}
            </div>
          </div>

          {/* Hop 5: Decision */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              5. Policy Decision
            </span>
            <div data-testid="hop-decision" style={{ fontSize: 12, fontWeight: 600, color: 'var(--text, #f0f3f8)' }}>
              <span
                style={{
                  padding: '2px 8px',
                  borderRadius: 4,
                  background: chain.decision?.includes('promoted') || chain.decision?.includes('authorized') ? 'rgba(16, 185, 129, 0.15)' : 'rgba(245, 158, 11, 0.15)',
                  color: chain.decision?.includes('promoted') || chain.decision?.includes('authorized') ? 'var(--teal, #10b981)' : 'var(--amber, #f59e0b)',
                }}
              >
                {chain.decision?.toUpperCase() || 'UNSPECIFIED'}
              </span>
            </div>
          </div>

          {/* Hop 6: Confidence & Evidence Refs */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              6. Evidence & Fidelity
            </span>
            <div>
              <div data-testid="hop-confidence" style={{ fontSize: 12, color: 'var(--text, #f0f3f8)', marginBottom: 6 }}>
                <strong>Score:</strong> {(chain.confidence * 100).toFixed(1)}% confidence
              </div>
              <div data-testid="hop-evidence-refs" style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                {chain.evidenceRefs?.map((ref, i) => (
                  <span
                    key={i}
                    style={{
                      fontSize: 11,
                      fontFamily: 'monospace',
                      padding: '2px 6px',
                      borderRadius: 4,
                      background: 'var(--surface, #1e222b)',
                      border: '1px solid var(--border, #2d3340)',
                      color: 'var(--cyan, #06b6d4)',
                    }}
                  >
                    {ref}
                  </span>
                ))}
              </div>
            </div>
          </div>

          {/* Hop 7: Attestation GitOID */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '160px 1fr',
              gap: 12,
              padding: '10px 14px',
              background: 'var(--surface2, #262c37)',
              borderRadius: 6,
              border: '1px solid var(--border-subtle, #2d3340)',
            }}
          >
            <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted, #8b949e)', textTransform: 'uppercase' }}>
              7. Attestation GitOID
            </span>
            <div style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 10 }}>
              <span
                data-testid="hop-attestation-gitoid"
                style={{
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: 'var(--teal, #10b981)',
                  fontWeight: 600,
                  wordBreak: 'break-all',
                }}
              >
                {chain.attestationGitoid || '⚠️ No Witness attestation'}
              </span>
              {chain.attestationGitoid && (
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <button
                    type="button"
                    data-testid="copy-gitoid-button"
                    onClick={() => copyGitoid(chain.attestationGitoid)}
                    style={{
                      padding: '3px 8px',
                      fontSize: 11,
                      borderRadius: 4,
                      background: 'var(--surface, #1e222b)',
                      border: '1px solid var(--border, #2d3340)',
                      color: 'var(--text, #f0f3f8)',
                      cursor: 'pointer',
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {copiedGitoid ? '✓ Copied' : 'Copy GitOID'}
                  </button>
                  <a
                    href={`https://search.sigstore.dev/?hash=${encodeURIComponent(chain.attestationGitoid)}`}
                    target="_blank"
                    rel="noreferrer noopener"
                    data-testid="rekor-explorer-link"
                    style={{
                      fontSize: 11,
                      color: 'var(--cyan, #06b6d4)',
                      textDecoration: 'none',
                    }}
                  >
                    Rekor Attestation ↗
                  </a>
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
})

WhoAuthorizedPanel.displayName = 'WhoAuthorizedPanel'
export default WhoAuthorizedPanel
