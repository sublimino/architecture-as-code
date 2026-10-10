// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useEffect, useCallback, useState } from 'react'
import type { DiscoveryWorkload, AgentResponse, ControlRecommendations } from '../types/api'
import { colors } from '../styles/tokens'
import AgentDeepLink from './AgentDeepLink'

export interface DiscoveredWorkloadDrawerProps {
  isOpen: boolean
  workload: DiscoveryWorkload | null
  matchedAgent?: AgentResponse | null
  onClose: () => void
  onEnroll: (workloadId: string) => Promise<void> | void
  onDismiss: (workloadId: string) => Promise<void> | void
  onClaim?: (workload: DiscoveryWorkload) => void
}

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return 'None'
  try {
    const d = new Date(iso)
    if (isNaN(d.getTime())) return iso
    return d.toLocaleString('en-GB', {
      day: '2-digit',
      month: 'short',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  } catch {
    return iso
  }
}

function fmtRelative(iso: string | null | undefined): string {
  if (!iso) return 'unknown'
  try {
    const d = new Date(iso)
    if (isNaN(d.getTime())) return 'unknown'
    const diff = Date.now() - d.getTime()
    if (diff < 0) return 'in future'
    const secs = Math.floor(diff / 1000)
    if (secs < 60) return `${secs}s ago`
    const mins = Math.floor(secs / 60)
    if (mins < 60) return `${mins}m ago`
    const hours = Math.floor(mins / 60)
    if (hours < 24) return `${hours}h ago`
    const days = Math.floor(diff / 86400000)
    if (days < 30) return `${days}d ago`
    return fmtDate(iso)
  } catch {
    return 'unknown'
  }
}

interface PillarConfig {
  key: keyof ControlRecommendations
  code: string
  title: string
  description: string
  ruleRequirement: string
}

const PILLARS: PillarConfig[] = [
  {
    key: 'config',
    code: 'CFG',
    title: 'Configuration Governance',
    description: 'Runtime least-privilege, network containment, and credential boundary controls.',
    ruleRequirement: 'Requires automated credential rotation and SPIFFE/OAuth role confinement.',
  },
  {
    key: 'content',
    code: 'CNT',
    title: 'Content & Prompt Guardrails',
    description: 'Prompt injection defenses, semantic safety classifiers, and DLP data leakage prevention.',
    ruleRequirement: 'Requires real-time token scanning and egress DLP filter verification.',
  },
  {
    key: 'supply_chain',
    code: 'SC',
    title: 'Supply Chain Provenance',
    description: 'Cosign container signatures, Witness attestation provenance, and SPDX/SLSA SBOM proofs.',
    ruleRequirement: 'Requires in-toto attestation envelope and signed build verification.',
  },
  {
    key: 'eu_ai_act',
    code: 'EU',
    title: 'EU AI Act Conformance',
    description: 'Article 12 automated logging, Article 14 human oversight, and risk class conformance.',
    ruleRequirement: 'Requires immutable audit trails, documented oversight, and CE technical dossier.',
  },
]

const RECOMMENDATION_STYLES: Record<string, { bg: string; border: string; color: string; label: string }> = {
  pass: {
    bg: 'rgba(20, 184, 166, 0.12)',
    border: 'rgba(20, 184, 166, 0.35)',
    color: colors.tealLoom,
    label: 'Pass',
  },
  recommended: {
    bg: 'rgba(245, 158, 11, 0.12)',
    border: 'rgba(245, 158, 11, 0.35)',
    color: colors.amber,
    label: 'Review',
  },
  warning: {
    bg: 'rgba(239, 68, 68, 0.12)',
    border: 'rgba(239, 68, 68, 0.35)',
    color: colors.red,
    label: 'Action Required',
  },
  not_applicable: {
    bg: 'rgba(100, 116, 139, 0.12)',
    border: 'rgba(100, 116, 139, 0.25)',
    color: 'var(--muted)',
    label: 'N/A',
  },
}

export default function DiscoveredWorkloadDrawer({
  isOpen,
  workload,
  matchedAgent,
  onClose,
  onEnroll,
  onDismiss,
  onClaim,
}: DiscoveredWorkloadDrawerProps) {
  const [copiedId, setCopiedId] = useState(false)
  const [actionInProgress, setActionInProgress] = useState<string | null>(null)

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose()
      }
    },
    [onClose],
  )

  useEffect(() => {
    if (isOpen && workload) {
      window.addEventListener('keydown', handleKeyDown)
      return () => window.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen, workload, handleKeyDown])

  if (!isOpen || !workload) return null

  function handleCopyId() {
    if (workload?.id) {
      navigator.clipboard?.writeText(workload.id)
      setCopiedId(true)
      setTimeout(() => setCopiedId(false), 2000)
    }
  }

  async function handleEnrollClick() {
    if (!workload) return
    setActionInProgress('enroll')
    try {
      await onEnroll(workload.id)
    } finally {
      setActionInProgress(null)
    }
  }

  async function handleDismissClick() {
    if (!workload) return
    setActionInProgress('dismiss')
    try {
      await onDismiss(workload.id)
    } finally {
      setActionInProgress(null)
    }
  }

  const isGoverned = workload.status === 'governed'
  const isIgnored = workload.status === 'ignored'
  const isInReview = workload.status === 'in_review'

  const meta = workload.metadata || {}
  const privilege = (meta.privilege_level as string) || 'standard'
  const findings: string[] = Array.isArray(meta.findings) ? (meta.findings as string[]) : []

  return (
    <>
      {/* Backdrop overlay */}
      <div
        data-testid="discovered-workload-drawer-backdrop"
        onClick={onClose}
        style={{
          position: 'fixed',
          inset: 0,
          background: 'rgba(0, 0, 0, 0.55)',
          backdropFilter: 'blur(3px)',
          zIndex: 1099,
        }}
      />

      {/* Drawer panel */}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="discovered-workload-drawer-title"
        data-testid="discovered-workload-drawer"
        style={{
          position: 'fixed',
          top: 0,
          right: 0,
          bottom: 0,
          width: 580,
          maxWidth: '92vw',
          background: 'var(--surface)',
          borderLeft: '1px solid var(--border)',
          zIndex: 1100,
          display: 'flex',
          flexDirection: 'column',
          boxShadow: '-8px 0 28px rgba(0, 0, 0, 0.4)',
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: '18px 24px',
            borderBottom: '1px solid var(--border)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            background: 'var(--surface2)',
            flexShrink: 0,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 20 }}>🔍</span>
            <div>
              <h2
                id="discovered-workload-drawer-title"
                data-testid="drawer-workload-name"
                style={{ margin: 0, fontSize: 16, fontWeight: 700, color: 'var(--text)' }}
              >
                {workload.name}
              </h2>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 4 }}>
                <span
                  data-testid="drawer-workload-source"
                  style={{
                    fontSize: 11,
                    fontWeight: 600,
                    padding: '2px 8px',
                    borderRadius: 4,
                    background: 'rgba(56, 189, 248, 0.15)',
                    color: colors.cyanLoom,
                  }}
                >
                  {workload.source_label || workload.source}
                </span>
                <span
                  data-testid="drawer-workload-status"
                  style={{
                    fontSize: 11,
                    fontWeight: 600,
                    padding: '2px 8px',
                    borderRadius: 4,
                    textTransform: 'uppercase',
                    letterSpacing: '0.04em',
                    background: isGoverned
                      ? 'rgba(20, 184, 166, 0.15)'
                      : isInReview
                        ? 'rgba(245, 158, 11, 0.15)'
                        : isIgnored
                          ? 'rgba(100, 116, 139, 0.2)'
                          : 'rgba(56, 189, 248, 0.15)',
                    color: isGoverned
                      ? colors.tealLoom
                      : isInReview
                        ? colors.amber
                        : isIgnored
                          ? 'var(--muted)'
                          : colors.cyanLoom,
                  }}
                >
                  {workload.status}
                </span>
              </div>
            </div>
          </div>

          <button
            type="button"
            data-testid="drawer-close-btn"
            aria-label="Close drawer"
            onClick={onClose}
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--muted)',
              fontSize: 20,
              cursor: 'pointer',
              padding: '4px 8px',
              borderRadius: 4,
              lineHeight: 1,
            }}
          >
            ✕
          </button>
        </div>

        {/* Scrollable Body */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '20px 24px', display: 'flex', flexDirection: 'column', gap: 20 }}>
          {/* Identity & Provenance Card */}
          <div
            style={{
              background: 'var(--surface2)',
              borderRadius: 8,
              border: '1px solid var(--border)',
              padding: 16,
            }}
          >
            <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--muted)', marginBottom: 12 }}>
              Workload Provenance & Metadata
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 14 }}>
              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Workload ID</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <code data-testid="drawer-workload-id" style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--text)' }}>
                    {workload.id}
                  </code>
                  <button
                    type="button"
                    data-testid="drawer-copy-id-btn"
                    onClick={handleCopyId}
                    style={{
                      background: 'none',
                      border: '1px solid var(--border)',
                      borderRadius: 4,
                      padding: '1px 5px',
                      fontSize: 10,
                      color: copiedId ? colors.tealLoom : 'var(--muted)',
                      cursor: 'pointer',
                    }}
                  >
                    {copiedId ? 'Copied' : 'Copy'}
                  </button>
                </div>
              </div>

              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Namespace</div>
                <div data-testid="drawer-workload-namespace" style={{ fontSize: 13, color: 'var(--text)', fontWeight: 500 }}>
                  {workload.namespace || '-'}
                </div>
              </div>

              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Owner / Contact</div>
                <div data-testid="drawer-workload-owner" style={{ fontSize: 13, color: workload.owner ? 'var(--text)' : 'var(--muted)' }}>
                  {workload.owner || 'Unassigned (Shadow AI)'}
                </div>
              </div>

              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Observed AI Model</div>
                <div data-testid="drawer-workload-model" style={{ fontSize: 13, color: workload.model ? colors.cyanLoom : 'var(--muted)' }}>
                  {workload.model || 'Non-model identity'}
                </div>
              </div>

              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Last Seen</div>
                <div data-testid="drawer-workload-last-seen" style={{ fontSize: 13, color: 'var(--text)' }}>
                  {fmtRelative(workload.last_seen_at)}
                  <span style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 6 }}>
                    ({fmtDate(workload.last_seen_at)})
                  </span>
                </div>
              </div>

              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>Privilege Level</div>
                <div
                  data-testid="drawer-privilege-level"
                  style={{
                    fontSize: 12,
                    fontWeight: 600,
                    textTransform: 'capitalize',
                    color: privilege === 'high' || privilege === 'domain_admin' ? colors.red : privilege === 'elevated' ? colors.amber : 'var(--text)',
                  }}
                >
                  {privilege}
                </div>
              </div>
            </div>

            {workload.spiffe_id && (
              <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 2 }}>SPIFFE Workload Identity</div>
                <code
                  data-testid="drawer-workload-spiffe-id"
                  style={{ fontSize: 11, color: colors.cyanLoom, wordBreak: 'break-all', fontFamily: 'monospace' }}
                >
                  {workload.spiffe_id}
                </code>
              </div>
            )}
          </div>

          {/* Matched Registered Agent Section */}
          {matchedAgent && (
            <div
              data-testid="drawer-matched-agent-card"
              style={{
                background: 'rgba(20, 184, 166, 0.08)',
                border: '1px solid rgba(20, 184, 166, 0.3)',
                borderRadius: 8,
                padding: 14,
              }}
            >
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <div>
                  <div style={{ fontSize: 11, fontWeight: 700, color: colors.tealLoom, textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                    Matched Registered Agent Dossier
                  </div>
                  <div style={{ fontSize: 13, color: 'var(--text)', marginTop: 4, display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>🤖</span>
                    <strong>{matchedAgent.name}</strong>
                    <span style={{ fontSize: 11, color: 'var(--muted)' }}>({matchedAgent.id})</span>
                  </div>
                </div>
                <AgentDeepLink
                  target={matchedAgent.id}
                  variant="badge"
                  dataTestId="drawer-matched-agent-link"
                  title={`View agent dossier for ${matchedAgent.name}`}
                  showIcon={true}
                >
                  <span>Open Dossier ↗</span>
                </AgentDeepLink>
              </div>
            </div>
          )}

          {/* 4-Pillar Control Recommendations */}
          <div
            data-testid="drawer-control-recommendations"
            style={{
              background: 'var(--surface2)',
              borderRadius: 8,
              border: '1px solid var(--border)',
              padding: 16,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
              <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--muted)' }}>
                4-Pillar Governance Controls
              </div>
              <span style={{ fontSize: 11, color: 'var(--muted)' }}>Policy Baseline</span>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {PILLARS.map((p) => {
                const recStatus = (workload.recommendations?.[p.key] || 'recommended') as string
                const style = RECOMMENDATION_STYLES[recStatus] || RECOMMENDATION_STYLES.recommended
                return (
                  <div
                    key={p.key}
                    data-testid={`drawer-rec-row-${p.key}`}
                    style={{
                      display: 'flex',
                      alignItems: 'flex-start',
                      gap: 12,
                      padding: 10,
                      borderRadius: 6,
                      background: 'var(--surface)',
                      border: '1px solid var(--border)',
                    }}
                  >
                    <span
                      data-testid={`drawer-rec-${p.key}`}
                      style={{
                        fontSize: 10.5,
                        fontWeight: 700,
                        padding: '3px 8px',
                        borderRadius: 4,
                        background: style.bg,
                        border: `1px solid ${style.border}`,
                        color: style.color,
                        letterSpacing: '0.04em',
                        flexShrink: 0,
                      }}
                    >
                      {p.code} &bull; {style.label}
                    </span>

                    <div style={{ flex: 1 }}>
                      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)' }}>
                        {p.title}
                      </div>
                      <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2, lineHeight: 1.35 }}>
                        {p.description}
                      </div>
                      <div style={{ fontSize: 10.5, color: colors.cyanLoom, marginTop: 4 }}>
                        {p.ruleRequirement}
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>

          {/* Security Findings & Discovered Flags */}
          <div
            data-testid="drawer-findings-section"
            style={{
              background: 'var(--surface2)',
              borderRadius: 8,
              border: '1px solid var(--border)',
              padding: 16,
            }}
          >
            <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--muted)', marginBottom: 12 }}>
              Security Findings & Discovered Flags
            </div>

            {findings.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                No active security findings or unrotated credentials flagged for this identity.
              </div>
            ) : (
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                {findings.map((f) => (
                  <span
                    key={f}
                    data-testid="drawer-finding-chip"
                    style={{
                      fontSize: 11,
                      padding: '3px 8px',
                      borderRadius: 4,
                      background: f.includes('stale') || f.includes('over_privileged') ? 'rgba(239, 68, 68, 0.15)' : 'rgba(245, 158, 11, 0.15)',
                      border: `1px solid ${f.includes('stale') || f.includes('over_privileged') ? 'rgba(239, 68, 68, 0.35)' : 'rgba(245, 158, 11, 0.35)'}`,
                      color: f.includes('stale') || f.includes('over_privileged') ? colors.red : colors.amber,
                    }}
                  >
                    ⚠️ {f}
                  </span>
                ))}
              </div>
            )}

            {/* Extended Metadata Properties */}
            {Object.keys(meta).length > 0 && (
              <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1px solid var(--border)', fontSize: 11 }}>
                <div style={{ color: 'var(--muted)', marginBottom: 6, fontWeight: 600 }}>Connector Telemetry:</div>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 6 }}>
                  {Object.entries(meta).map(([k, v]) => {
                    if (k === 'findings' || k === 'privilege_level') return null
                    return (
                      <div key={k} style={{ display: 'flex', gap: 4 }}>
                        <span style={{ color: 'var(--muted)' }}>{k}:</span>
                        <span style={{ color: 'var(--text)', fontFamily: typeof v === 'number' ? 'monospace' : 'inherit' }}>
                          {String(v)}
                        </span>
                      </div>
                    )
                  })}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Footer Actions */}
        <div
          style={{
            padding: '16px 24px',
            borderTop: '1px solid var(--border)',
            background: 'var(--surface2)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 12,
            flexShrink: 0,
          }}
        >
          <button
            type="button"
            className="btn btn-secondary"
            data-testid="drawer-bottom-close-btn"
            onClick={onClose}
            style={{ fontSize: 12 }}
          >
            Close
          </button>

          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            {!isGoverned && !isIgnored && (
              <button
                type="button"
                className="btn btn-secondary"
                data-testid="drawer-dismiss-btn"
                disabled={actionInProgress === 'dismiss'}
                onClick={handleDismissClick}
                style={{ fontSize: 12, color: 'var(--muted)' }}
              >
                {actionInProgress === 'dismiss' ? 'Dismissing...' : 'Ignore / Dismiss'}
              </button>
            )}

            {!isGoverned && (
              <>
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="drawer-enroll-btn"
                  disabled={actionInProgress === 'enroll'}
                  onClick={handleEnrollClick}
                  style={{ fontSize: 12, borderColor: colors.cyanLoom, color: colors.cyanLoom }}
                >
                  {actionInProgress === 'enroll' ? 'Enrolling...' : 'Enroll for Review'}
                </button>

                {onClaim && (
                  <button
                    type="button"
                    className="btn btn-primary"
                    data-testid="drawer-claim-btn"
                    onClick={() => onClaim(workload)}
                    style={{ fontSize: 12, background: colors.tealLoom, borderColor: colors.tealLoom }}
                  >
                    Claim into Governance
                  </button>
                )}
              </>
            )}

            {isGoverned && (
              <span
                style={{
                  fontSize: 12,
                  fontWeight: 600,
                  color: colors.tealLoom,
                  padding: '4px 10px',
                  background: 'rgba(20, 184, 166, 0.15)',
                  borderRadius: 4,
                }}
              >
                ✓ Governed
              </span>
            )}
          </div>
        </div>
      </div>
    </>
  )
}
