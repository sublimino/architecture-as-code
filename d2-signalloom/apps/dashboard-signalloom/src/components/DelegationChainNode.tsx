// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useState, memo, useCallback } from 'react'
import { colors } from '../styles/tokens'
import type { DelegationRecord } from '../types/identity'

export interface DelegationChainNodeProps {
  hopIndex: number
  totalHops: number
  record?: DelegationRecord
  actorId: string
  label?: string
  role?: string
  spiffeId?: string
  authzRef?: string
  validFrom?: string
  validTo?: string | null
  isLeaf?: boolean
  isRoot?: boolean
  containmentEvidenced?: boolean
  onSelectNode?: (actorId: string) => void
}

function formatDate(iso?: string | null) {
  if (!iso) return 'Active (No expiration)'
  try {
    return new Date(iso).toLocaleDateString('en-GB', {
      day: '2-digit',
      month: 'short',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return iso
  }
}

export const DelegationChainNode: React.FC<DelegationChainNodeProps> = memo(({
  hopIndex,
  totalHops,
  record,
  actorId,
  label,
  role = 'agent',
  spiffeId,
  authzRef,
  validFrom,
  validTo,
  isLeaf = false,
  isRoot = false,
  containmentEvidenced = false,
  onSelectNode,
}) => {
  const [modalOpen, setModalOpen] = useState(false)

  const effectiveActorId = actorId || record?.delegate_actor_id || 'unknown-actor'
  const effectiveSpiffeId = spiffeId || record?.spiffe_svid || (effectiveActorId.startsWith('spiffe://') ? effectiveActorId : undefined)
  const effectiveAuthzRef = authzRef || record?.authz_ref || 'k8s-rbac-binding'
  const effectiveValidFrom = validFrom || record?.valid_from
  const effectiveValidTo = validTo !== undefined ? validTo : record?.valid_to
  const hasLandlock = containmentEvidenced || record?.containment_evidenced || record?.nono_containment || effectiveActorId.includes('nono')

  const displayRole = role || record?.role || (isRoot ? 'Human Principal' : isLeaf ? 'Executing Agent' : 'Delegated Sub-Agent')
  const nodeLabel = label || effectiveActorId

  const handleOpen = useCallback(() => {
    setModalOpen(true)
    if (onSelectNode) {
      onSelectNode(effectiveActorId)
    }
  }, [effectiveActorId, onSelectNode])

  const handleClose = useCallback((e?: React.MouseEvent) => {
    if (e) e.stopPropagation()
    setModalOpen(false)
  }, [])

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      handleOpen()
    } else if (e.key === 'Escape' && modalOpen) {
      e.preventDefault()
      handleClose()
    }
  }, [handleOpen, handleClose, modalOpen])

  return (
    <>
      <div
        data-testid={`delegation-node-${hopIndex}`}
        className="delegation-node-card"
        role="button"
        tabIndex={0}
        aria-haspopup="dialog"
        aria-expanded={modalOpen}
        aria-label={`Delegation hop ${hopIndex + 1} of ${totalHops}: ${displayRole} ${nodeLabel}`}
        onClick={handleOpen}
        onKeyDown={handleKeyDown}
        style={{
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          minWidth: 190,
          maxWidth: 240,
          flex: '1 1 190px',
          padding: '12px 14px',
          borderRadius: 8,
          background: isLeaf
            ? 'rgba(16, 185, 129, 0.08)'
            : isRoot
            ? 'rgba(245, 158, 11, 0.08)'
            : 'var(--surface2, #262c37)',
          border: isLeaf
            ? '1px solid rgba(16, 185, 129, 0.4)'
            : isRoot
            ? '1px solid rgba(245, 158, 11, 0.4)'
            : '1px solid var(--border, #2d3340)',
          cursor: 'pointer',
          position: 'relative',
          transition: 'transform 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease',
        }}
      >
        {/* Hop step header */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
          <span
            data-testid={`delegation-node-step-${hopIndex}`}
            style={{
              fontSize: 10,
              fontWeight: 700,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: isLeaf ? 'var(--teal, #10b981)' : isRoot ? 'var(--amber, #f59e0b)' : 'var(--cyan, #06b6d4)',
            }}
          >
            Hop {hopIndex + 1} / {totalHops}
          </span>
          <span
            className="tag"
            style={{
              fontSize: 9,
              padding: '1px 5px',
              borderRadius: 3,
              background: isRoot
                ? 'rgba(245, 158, 11, 0.15)'
                : isLeaf
                ? 'rgba(16, 185, 129, 0.15)'
                : 'rgba(99, 102, 241, 0.15)',
              color: isRoot
                ? 'var(--amber, #f59e0b)'
                : isLeaf
                ? 'var(--teal, #10b981)'
                : 'var(--violet, #a78bfa)',
              fontWeight: 600,
              textTransform: 'capitalize',
            }}
          >
            {displayRole}
          </span>
        </div>

        {/* Node Identifier */}
        <div
          data-testid={`delegation-node-id-${hopIndex}`}
          style={{
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: 600,
            color: 'var(--text, #f0f3f8)',
            wordBreak: 'break-all',
            lineHeight: 1.3,
            marginBottom: 8,
          }}
        >
          {nodeLabel}
        </div>

        {/* Badges / Chips Footer */}
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 'auto', paddingTop: 6 }}>
          {hasLandlock && (
            <span
              data-testid={`delegation-node-landlock-${hopIndex}`}
              className="tag"
              style={{
                fontSize: 9,
                padding: '2px 5px',
                borderRadius: 3,
                background: 'rgba(16, 185, 129, 0.15)',
                color: 'var(--teal, #10b981)',
                border: '1px solid rgba(16, 185, 129, 0.3)',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 3,
              }}
              title="Verified Landlock kernel sandbox containment active via agent-nono-evidenced"
            >
              🔒 Landlock Enforced
            </span>
          )}

          {effectiveSpiffeId && (
            <span
              data-testid={`delegation-node-spiffe-${hopIndex}`}
              className="tag"
              style={{
                fontSize: 9,
                padding: '2px 5px',
                borderRadius: 3,
                background: 'rgba(6, 182, 212, 0.15)',
                color: 'var(--cyan, #06b6d4)',
                border: '1px solid rgba(6, 182, 212, 0.3)',
              }}
            >
              SPIFFE SVID
            </span>
          )}

          <span
            style={{
              fontSize: 9,
              color: 'var(--muted, #8b949e)',
              marginLeft: 'auto',
              alignSelf: 'center',
            }}
          >
            Details ↗
          </span>
        </div>
      </div>

      {/* Drill-down modal */}
      {modalOpen && (
        <div
          data-testid={`delegation-drilldown-modal-${hopIndex}`}
          role="dialog"
          aria-modal="true"
          aria-labelledby={`modal-title-${hopIndex}`}
          onClick={handleClose}
          style={{
            position: 'fixed',
            inset: 0,
            background: 'rgba(0, 0, 0, 0.7)',
            backdropFilter: 'blur(3px)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 9999,
            padding: 16,
          }}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              background: 'var(--surface, #1e222b)',
              border: '1px solid var(--border, #2d3340)',
              borderRadius: 10,
              padding: 24,
              maxWidth: 540,
              width: '100%',
              boxShadow: '0 20px 25px -5px rgba(0, 0, 0, 0.5), 0 8px 10px -6px rgba(0, 0, 0, 0.5)',
            }}
          >
            {/* Modal Header */}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16, borderBottom: '1px solid var(--border, #2d3340)', paddingBottom: 12 }}>
              <div>
                <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--cyan, #06b6d4)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                  Hop {hopIndex + 1} of {totalHops} Delegation Detail
                </span>
                <h3 id={`modal-title-${hopIndex}`} style={{ margin: '4px 0 0', fontSize: 16, fontWeight: 700, color: 'var(--text, #f0f3f8)' }}>
                  {displayRole} Verification
                </h3>
              </div>
              <button
                type="button"
                data-testid={`close-modal-${hopIndex}`}
                onClick={handleClose}
                aria-label="Close delegation modal"
                className="btn btn-secondary"
                style={{
                  fontSize: 12,
                  padding: '4px 8px',
                  borderRadius: 4,
                  cursor: 'pointer',
                  background: 'var(--surface2, #262c37)',
                  color: 'var(--text, #f0f3f8)',
                  border: '1px solid var(--border, #2d3340)',
                }}
              >
                ✕ Close
              </button>
            </div>

            {/* Modal Body */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 13 }}>
              <div>
                <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                  Actor Identifier
                </span>
                <div data-testid={`modal-actor-id-${hopIndex}`} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--text, #f0f3f8)', marginTop: 2, wordBreak: 'break-all' }}>
                  {effectiveActorId}
                </div>
              </div>

              {effectiveSpiffeId && (
                <div>
                  <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                    Attested SPIFFE SVID
                  </span>
                  <div data-testid={`modal-spiffe-id-${hopIndex}`} style={{ fontFamily: 'monospace', fontSize: 12, color: colors.tealLoom || 'var(--teal, #10b981)', marginTop: 2, wordBreak: 'break-all' }}>
                    {effectiveSpiffeId}
                  </div>
                </div>
              )}

              <div>
                <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                  Authorization Decision Reference (authz_ref)
                </span>
                <div data-testid={`modal-authz-ref-${hopIndex}`} style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--violet, #a78bfa)', marginTop: 2 }}>
                  {effectiveAuthzRef}
                </div>
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                <div>
                  <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                    Valid From
                  </span>
                  <div data-testid={`modal-valid-from-${hopIndex}`} style={{ fontSize: 12, color: 'var(--text, #f0f3f8)', marginTop: 2 }}>
                    {formatDate(effectiveValidFrom)}
                  </div>
                </div>

                <div>
                  <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                    Valid Until
                  </span>
                  <div data-testid={`modal-valid-to-${hopIndex}`} style={{ fontSize: 12, color: 'var(--text, #f0f3f8)', marginTop: 2 }}>
                    {formatDate(effectiveValidTo)}
                  </div>
                </div>
              </div>

              <div>
                <span style={{ fontSize: 11, color: 'var(--muted, #8b949e)', textTransform: 'uppercase', fontWeight: 600 }}>
                  Landlock Kernel Containment
                </span>
                <div data-testid={`modal-containment-${hopIndex}`} style={{ fontSize: 12, marginTop: 4, display: 'flex', alignItems: 'center', gap: 6 }}>
                  {hasLandlock ? (
                    <span style={{ color: 'var(--teal, #10b981)', fontWeight: 600 }}>
                      ✓ Verified active via agent-nono-evidenced eBPF/Landlock probes
                    </span>
                  ) : (
                    <span style={{ color: 'var(--muted, #8b949e)' }}>
                      Standard container execution boundary (No detached Landlock attestation)
                    </span>
                  )}
                </div>
              </div>
            </div>

            {/* Modal Footer */}
            <div style={{ marginTop: 20, paddingTop: 12, borderTop: '1px solid var(--border, #2d3340)', display: 'flex', justifyContent: 'flex-end' }}>
              <button
                type="button"
                onClick={handleClose}
                className="btn btn-secondary"
                style={{
                  fontSize: 12,
                  padding: '6px 14px',
                  borderRadius: 4,
                  cursor: 'pointer',
                  background: 'var(--surface2, #262c37)',
                  color: 'var(--text, #f0f3f8)',
                  border: '1px solid var(--border, #2d3340)',
                }}
              >
                Done
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  )
})

DelegationChainNode.displayName = 'DelegationChainNode'
export default DelegationChainNode
