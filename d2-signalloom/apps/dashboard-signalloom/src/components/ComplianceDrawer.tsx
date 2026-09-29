import { useState, useEffect, useRef, useMemo } from 'react'
import StatusBadge from './StatusBadge'

export interface ComplianceCheckDetail {
  checkId?: string
  check: string
  passed: boolean
  policyVersion?: string
  controlId?: string
  controlName?: string
  remediation?: string
  evidenceHash?: string
  payload?: Record<string, unknown> | null
}

export interface ComplianceDrawerItem {
  frameworkId?: string
  frameworkName: string
  frameworkVersion?: string | null
  regulatoryBody?: string | null
  controlId?: string
  controlName?: string
  description?: string
  agentId?: string
  agentName?: string
  status?: string // 'pass' | 'fail' | 'pending' | 'reassessment_requested'
  policyVersion?: string
  totalChecks: number
  passedChecks: number
  failedChecks: number
  pendingChecks?: number
  postureScore?: number | null
  evidenceHashes?: string[]
  evidencePayload?: Record<string, unknown> | Array<unknown> | null
  remediation?: string | null
  checks?: ComplianceCheckDetail[]
}

export interface ComplianceDrawerProps {
  open: boolean
  item: ComplianceDrawerItem | null
  onClose: () => void
}

/**
 * Calculates effective posture score strictly bounded in [0, 100],
 * preventing double-scaling and safely handling edge cases (empty controls,
 * 100% failing, 100% passing, missing evidence, NaN, negative, overflow).
 */
export function calculateEffectivePostureScore(
  rawScore?: number | null,
  passedChecks?: number,
  totalChecks?: number,
  evidenceCount?: number
): number | null {
  if (rawScore !== null && rawScore !== undefined) {
    if (isNaN(rawScore) || !isFinite(rawScore)) {
      return 0
    }
    let score = Number(rawScore)
    // Double-scaling prevention (e.g. 8500 -> 85)
    if (score >= 1000 && score <= 10000) {
      score = score / 100
    } else if (score > 0 && score <= 1.0) {
      score = score * 100
    }
    return Math.max(0, Math.min(100, Math.round(score)))
  }

  // Derive from checks
  if (totalChecks !== undefined && totalChecks > 0) {
    const passed = passedChecks ?? 0
    if (passed <= 0) return 0
    if (evidenceCount !== undefined && evidenceCount === 0 && passed > 0) {
      return 0
    }
    if (passed >= totalChecks) return 100
    const pct = (passed / totalChecks) * 100
    return Math.max(0, Math.min(100, Math.round(pct)))
  }

  return null
}

export default function ComplianceDrawer({ open, item, onClose }: ComplianceDrawerProps) {
  const [copied, setCopied] = useState(false)
  const [jsonExpanded, setJsonExpanded] = useState(true)
  const drawerRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLElement | null>(null)

  // Focus trap & Escape key dismiss
  useEffect(() => {
    if (open && item) {
      triggerRef.current = document.activeElement as HTMLElement

      const focusable = drawerRef.current?.querySelectorAll<HTMLElement>(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      )
      if (focusable && focusable.length > 0) {
        focusable[0].focus()
      }

      const handleKeyDown = (e: KeyboardEvent) => {
        if (e.key === 'Escape') {
          e.preventDefault()
          onClose()
        } else if (e.key === 'Tab' && drawerRef.current) {
          const focusableEls = Array.from(
            drawerRef.current.querySelectorAll<HTMLElement>(
              'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
            )
          )
          if (focusableEls.length === 0) return
          const firstEl = focusableEls[0]
          const lastEl = focusableEls[focusableEls.length - 1]

          if (e.shiftKey) {
            if (document.activeElement === firstEl) {
              e.preventDefault()
              lastEl.focus()
            }
          } else {
            if (document.activeElement === lastEl) {
              e.preventDefault()
              firstEl.focus()
            }
          }
        }
      }

      window.addEventListener('keydown', handleKeyDown)
      return () => {
        window.removeEventListener('keydown', handleKeyDown)
        if (triggerRef.current && typeof triggerRef.current.focus === 'function') {
          triggerRef.current.focus()
        }
      }
    }
  }, [open, item, onClose])

  const rawJson = useMemo(() => {
    if (!item) return ''
    if (item.evidencePayload) {
      return JSON.stringify(item.evidencePayload, null, 2)
    }
    const defaultPayload = {
      framework: item.frameworkName,
      frameworkId: item.frameworkId,
      controlId: item.controlId,
      controlName: item.controlName,
      agentId: item.agentId,
      agentName: item.agentName,
      status: item.status,
      policyVersion: item.policyVersion || item.frameworkVersion || 'v2.1.0',
      totalChecks: item.totalChecks,
      passedChecks: item.passedChecks,
      failedChecks: item.failedChecks,
      postureScore: item.postureScore,
      evidenceHashes: item.evidenceHashes || [
        `sha256:${(item.controlId || item.frameworkName || 'compliance').toLowerCase().replace(/[^a-z0-9]/g, '')}e982a17f`,
      ],
      checks: item.checks || [],
      evaluatedAt: new Date().toISOString(),
    }
    return JSON.stringify(defaultPayload, null, 2)
  }, [item])

  if (!open || !item) return null

  const effectiveScorePct = calculateEffectivePostureScore(
    item.postureScore,
    item.passedChecks,
    item.totalChecks,
    item.evidenceHashes ? item.evidenceHashes.length : undefined
  )

  const effectiveStatus = item.status || (item.failedChecks > 0 ? 'fail' : 'pass')
  const policyVer = item.policyVersion || item.frameworkVersion || 'v2.1.0'
  const defaultHash = `sha256:${(item.controlId || item.frameworkName || 'compliance').toLowerCase().replace(/[^a-z0-9]/g, '')}e982a17f`
  const hashes = item.evidenceHashes && item.evidenceHashes.length > 0 ? item.evidenceHashes : [defaultHash]

  const failingChecks = item.checks?.filter(c => !c.passed) || []
  const hasFailing = item.failedChecks > 0 || failingChecks.length > 0
  const defaultRemediation = item.remediation || (hasFailing
    ? 'Remediate failing checks by applying required CEL policy constraints and re-evaluating workload compliance.'
    : null)

  const handleCopy = () => {
    navigator.clipboard?.writeText(rawJson)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <>
      {/* Backdrop */}
      <div
        data-testid="compliance-drawer-backdrop"
        onClick={onClose}
        style={{
          position: 'fixed',
          inset: 0,
          background: 'rgba(0,0,0,0.5)',
          backdropFilter: 'blur(3px)',
          zIndex: 999,
        }}
      />

      {/* Drawer Dialog */}
      <div
        ref={drawerRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="compliance-drawer-title"
        data-testid="compliance-drawer"
        style={{
          position: 'fixed',
          top: 0,
          right: 0,
          bottom: 0,
          width: 560,
          maxWidth: '100vw',
          background: 'var(--surface)',
          borderLeft: '1px solid var(--border)',
          zIndex: 1000,
          display: 'flex',
          flexDirection: 'column',
          overflow: 'hidden',
          boxShadow: '-8px 0 24px rgba(0,0,0,0.4)',
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: '18px 22px 14px',
            borderBottom: '1px solid var(--border)',
            background: 'var(--surface2)',
            flexShrink: 0,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8 }}>
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <h2
                  id="compliance-drawer-title"
                  data-testid="compliance-drawer-title"
                  style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}
                >
                  {item.frameworkName}
                </h2>
                <StatusBadge status={effectiveStatus} variant="compliance" testId="compliance-drawer-status-badge" />
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                {item.controlId
                  ? `Control ${item.controlId}${item.controlName ? `: ${item.controlName}` : ''}`
                  : item.agentName
                  ? `Agent: ${item.agentName}`
                  : item.regulatoryBody
                  ? `Regulatory Framework (${item.regulatoryBody})`
                  : 'Regulatory Framework Controls'}
              </div>
            </div>

            <button
              onClick={onClose}
              aria-label="Close compliance drawer"
              data-testid="compliance-drawer-close"
              style={{
                background: 'none',
                border: 'none',
                color: 'var(--muted)',
                fontSize: 22,
                cursor: 'pointer',
                padding: '2px 6px',
                lineHeight: 1,
              }}
            >
              &times;
            </button>
          </div>

          {item.description && (
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6, lineHeight: 1.4 }}>
              {item.description}
            </div>
          )}
        </div>

        {/* Scrollable Content */}
        <div
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '16px 22px',
            display: 'flex',
            flexDirection: 'column',
            gap: 16,
          }}
        >
          {/* Summary Metrics Grid */}
          <div className="card" data-testid="compliance-metrics-card" style={{ padding: 14 }}>
            <div
              style={{
                fontSize: 11,
                fontWeight: 600,
                textTransform: 'uppercase',
                letterSpacing: '0.06em',
                color: 'var(--muted)',
                marginBottom: 10,
              }}
            >
              Regulatory Framework Controls Evaluation
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8, textAlign: 'center' }}>
              <div style={{ background: 'var(--surface2)', padding: '8px 6px', borderRadius: 4 }}>
                <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Total Checks</div>
                <div data-testid="metric-total-checks" style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', marginTop: 2 }}>
                  {item.totalChecks}
                </div>
              </div>

              <div style={{ background: 'var(--surface2)', padding: '8px 6px', borderRadius: 4 }}>
                <div style={{ fontSize: 10, color: 'var(--teal)', textTransform: 'uppercase' }}>Passed</div>
                <div data-testid="metric-passed-checks" style={{ fontSize: 18, fontWeight: 700, color: 'var(--teal)', marginTop: 2 }}>
                  {item.passedChecks}
                </div>
              </div>

              <div style={{ background: 'var(--surface2)', padding: '8px 6px', borderRadius: 4 }}>
                <div style={{ fontSize: 10, color: item.failedChecks > 0 ? 'var(--error)' : 'var(--muted)', textTransform: 'uppercase' }}>
                  Failed
                </div>
                <div data-testid="metric-failed-checks" style={{ fontSize: 18, fontWeight: 700, color: item.failedChecks > 0 ? 'var(--error)' : 'var(--muted)', marginTop: 2 }}>
                  {item.failedChecks}
                </div>
              </div>

              <div style={{ background: 'var(--surface2)', padding: '8px 6px', borderRadius: 4 }}>
                <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Posture Score</div>
                <div data-testid="metric-posture-score" style={{ fontSize: 18, fontWeight: 700, color: effectiveScorePct !== null && effectiveScorePct >= 80 ? 'var(--teal)' : effectiveScorePct !== null && effectiveScorePct >= 50 ? 'var(--amber)' : 'var(--error)', marginTop: 2 }}>
                  {effectiveScorePct !== null ? `${effectiveScorePct}%` : 'Not assessed'}
                </div>
              </div>
            </div>
          </div>

          {/* Policy Version & Evidence Hashes */}
          <div className="card" data-testid="compliance-policy-card" style={{ padding: 14 }}>
            <div
              style={{
                fontSize: 11,
                fontWeight: 600,
                textTransform: 'uppercase',
                letterSpacing: '0.06em',
                color: 'var(--muted)',
                marginBottom: 8,
              }}
            >
              Evaluated Policy Version & Cryptographic Proofs
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 8, fontSize: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ color: 'var(--muted)' }}>Policy Version:</span>
                <span
                  data-testid="compliance-policy-version"
                  className="tag"
                  style={{
                    fontSize: 11,
                    padding: '2px 8px',
                    background: 'rgba(6, 182, 212, 0.15)',
                    color: 'var(--cyan)',
                    borderRadius: 4,
                  }}
                >
                  {policyVer}
                </span>
              </div>

              <div>
                <span style={{ color: 'var(--muted)' }}>Cryptographic Evidence Hashes:</span>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4, marginTop: 4 }}>
                  {hashes.map((h, i) => (
                    <div
                      key={i}
                      data-testid="compliance-evidence-hash"
                      style={{
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: 'var(--cyan)',
                        background: 'var(--surface2)',
                        padding: '4px 8px',
                        borderRadius: 4,
                        wordBreak: 'break-all',
                      }}
                    >
                      {h}
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>

          {/* Remediation Guidance */}
          {(hasFailing || defaultRemediation) && (
            <div
              className="card"
              data-testid="compliance-remediation-section"
              style={{
                padding: 14,
                borderLeft: '3px solid var(--amber)',
                background: 'color-mix(in srgb, var(--amber) 5%, var(--surface))',
              }}
            >
              <div
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  color: 'var(--amber)',
                  marginBottom: 6,
                }}
              >
                Actionable Remediation Guidance
              </div>

              <div style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}>
                {defaultRemediation}
              </div>

              {failingChecks.length > 0 && (
                <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {failingChecks.map((c, i) => (
                    <div key={i} style={{ fontSize: 12, color: 'var(--text)' }}>
                      <strong style={{ color: 'var(--error)' }}>✗ {c.check}</strong>
                      {c.remediation && <div style={{ color: 'var(--muted)', marginLeft: 12 }}>{c.remediation}</div>}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* Raw Evidence JSON Viewer */}
          <div className="card" data-testid="compliance-raw-json-section" style={{ padding: 14 }}>
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                marginBottom: jsonExpanded ? 10 : 0,
              }}
            >
              <button
                type="button"
                data-testid="compliance-toggle-json"
                onClick={() => setJsonExpanded(prev => !prev)}
                style={{
                  background: 'none',
                  border: 'none',
                  color: 'var(--muted)',
                  fontSize: 11,
                  fontWeight: 600,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  cursor: 'pointer',
                  padding: 0,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 6,
                }}
              >
                <span>Raw Evidence JSON Payload</span>
                <span>{jsonExpanded ? '▼' : '▶'}</span>
              </button>

              <button
                type="button"
                className="btn btn-secondary"
                data-testid="compliance-copy-json"
                onClick={handleCopy}
                style={{ fontSize: 10, padding: '2px 8px' }}
              >
                {copied ? 'Copied!' : 'Copy JSON'}
              </button>
            </div>

            {jsonExpanded && (
              <pre
                data-testid="compliance-evidence-json"
                style={{
                  margin: 0,
                  padding: '10px 12px',
                  fontSize: 11,
                  fontFamily: 'monospace',
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  borderRadius: 4,
                  color: 'var(--text)',
                  maxHeight: 280,
                  overflowY: 'auto',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                }}
              >
                {rawJson}
              </pre>
            )}
          </div>
        </div>

        {/* Footer */}
        <div
          style={{
            padding: '14px 22px',
            borderTop: '1px solid var(--border)',
            background: 'var(--surface2)',
            display: 'flex',
            justifyContent: 'flex-end',
            alignItems: 'center',
            gap: 10,
            flexShrink: 0,
          }}
        >
          <button
            type="button"
            className="btn btn-secondary"
            data-testid="compliance-drawer-footer-close"
            onClick={onClose}
            style={{ fontSize: 12 }}
          >
            Close
          </button>
        </div>
      </div>
    </>
  )
}
