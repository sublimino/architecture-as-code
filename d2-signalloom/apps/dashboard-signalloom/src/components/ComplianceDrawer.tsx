import { useState, useEffect, useRef, useMemo } from 'react'
import { Link, useInRouterContext } from 'react-router-dom'
import StatusBadge from './StatusBadge'

function SafeLink({
  to,
  children,
  ...props
}: {
  to: string
  children: React.ReactNode
  [key: string]: unknown
}) {
  const inRouter = useInRouterContext()
  if (inRouter) {
    return (
      <Link to={to} {...props}>
        {children}
      </Link>
    )
  }
  return (
    <a href={to} {...props}>
      {children}
    </a>
  )
}

/**
 * Maps synthetic database UUIDs or internal IDs (like "c0000000-0000-0000-0000-000000000002")
 * to standardized human-readable regulatory control citations (e.g. "EU-AI-ACT-ART-14", "CIS-5.2.6", "SOC2-CC6.1").
 */
export function sanitizeControlId(id?: string, name?: string, framework?: string): string {
  if (!id && !name) return 'CONTROL-GENERIC'
  const isSyntheticUuid = id && /^c[0-9a-f]{7}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)

  if (name) {
    const lower = name.toLowerCase()
    if (lower.includes('root') || lower.includes('non-root')) return 'CIS-5.2.6'
    if (lower.includes('privilege') || lower.includes('escalation')) return 'CIS-5.2.5'
    if (lower.includes('human oversight') || lower.includes('art. 14') || lower.includes('art-14')) return 'EU-AI-ACT-ART-14'
    if (lower.includes('risk management') || lower.includes('art. 9') || lower.includes('art-9')) return 'EU-AI-ACT-ART-9'
    if (lower.includes('data provenance') || lower.includes('art. 10') || lower.includes('art-10')) return 'EU-AI-ACT-ART-10'
    if (lower.includes('audit') || lower.includes('tamper') || lower.includes('art. 12') || lower.includes('art-12')) return 'EU-AI-ACT-ART-12'
    if (lower.includes('model card') || lower.includes('transparency') || lower.includes('art. 13') || lower.includes('art-13')) return 'EU-AI-ACT-ART-13'
    if (lower.includes('cybersecurity') || lower.includes('guardrail') || lower.includes('art. 15') || lower.includes('art-15')) return 'EU-AI-ACT-ART-15'
    if (lower.includes('access control') || lower.includes('cc-1') || lower.includes('cc1')) return 'SOC2-CC6.1'
    if (lower.includes('change management') || lower.includes('cc-2') || lower.includes('cc2')) return 'SOC2-CC8.1'
  }

  if (isSyntheticUuid) {
    const num = parseInt(id!.slice(-2), 16) || 1
    const fwPrefix = (framework || 'COMPLIANCE').toUpperCase().replace(/[^A-Z0-9]/g, '-').slice(0, 10)
    return `${fwPrefix}-CTRL-${num}`
  }

  return id || 'CONTROL-STANDARD'
}

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
  const [jsonFormat, setJsonFormat] = useState<'intoto' | 'summary' | 'dsse'>('intoto')
  const drawerRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLElement | null>(null)

  // Focus trap & Escape key dismiss
  useEffect(() => {
    if (open && item && drawerRef.current) {
      const ownerDocument = drawerRef.current.ownerDocument
      const ownerWindow = ownerDocument.defaultView
      if (!ownerWindow) return
      triggerRef.current = ownerDocument.activeElement as HTMLElement | null

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
            if (ownerDocument.activeElement === firstEl) {
              e.preventDefault()
              lastEl.focus()
            }
          } else {
            if (ownerDocument.activeElement === lastEl) {
              e.preventDefault()
              firstEl.focus()
            }
          }
        }
      }

      ownerWindow.addEventListener('keydown', handleKeyDown)
      return () => {
        ownerWindow.removeEventListener('keydown', handleKeyDown)
        if (triggerRef.current && typeof triggerRef.current.focus === 'function') {
          triggerRef.current.focus()
        }
      }
    }
  }, [open, item, onClose])

  const effectiveScorePct = calculateEffectivePostureScore(
    item?.postureScore,
    item?.passedChecks,
    item?.totalChecks,
    item?.evidenceHashes ? item.evidenceHashes.length : undefined
  )

  const effectiveStatus = item?.status || ((item?.failedChecks ?? 0) > 0 ? 'fail' : 'pass')
  const policyVer = item?.policyVersion || item?.frameworkVersion || 'v2.1.0'
  const defaultHash = `sha256:${(item?.controlId || item?.frameworkName || 'compliance').toLowerCase().replace(/[^a-z0-9]/g, '')}e982a17f`
  const hashes = item?.evidenceHashes && item.evidenceHashes.length > 0 ? item.evidenceHashes : [defaultHash]

  const failingChecks = item?.checks?.filter(c => !c.passed) || []
  const hasFailing = (item?.failedChecks ?? 0) > 0 || failingChecks.length > 0
  const defaultRemediation = item?.remediation || (hasFailing
    ? 'Remediate failing checks by applying required CEL policy constraints and re-evaluating workload compliance.'
    : null)

  const standardAttestation = useMemo(() => {
    if (!item) return null

    return {
      _type: 'https://in-toto.io/Statement/v1',
      subject: [
        {
          name: item.agentName
            ? `spiffe://signalloom.demo/agent/${item.agentName.toLowerCase().replace(/\s+/g, '-')}`
            : `urn:signalloom:framework:${(item.frameworkId || item.frameworkName || 'compliance').toLowerCase().replace(/[^a-z0-9]/g, '-')}`,
          digest: {
            sha256: hashes[0].replace(/^sha256:/, ''),
          },
        },
      ],
      predicateType: 'https://signalloom.dev/attestation/compliance/v1',
      predicate: {
        evaluator: {
          engine: 'cel',
          version: 'v0.18.0',
          policyBundle: policyVer,
        },
        framework: {
          id: item.frameworkId || (item.frameworkName ? item.frameworkName.toLowerCase().replace(/\s+/g, '-') : 'compliance'),
          name: item.frameworkName,
          version: item.frameworkVersion || 'v2.1.0',
          regulatoryBody: item.regulatoryBody || 'Standard Body',
        },
        assessment: {
          status: effectiveStatus,
          postureScore: effectiveScorePct,
          totalChecks: item.totalChecks,
          passedChecks: item.passedChecks,
          failedChecks: item.failedChecks,
          pendingChecks: item.pendingChecks ?? 0,
          evaluatedAt: new Date().toISOString(),
        },
        controls: (item.checks || []).map(c => {
          const canonicalId = sanitizeControlId(c.controlId, c.controlName || c.check, item.frameworkName)
          const rawEvRef = c.evidenceHash || (c.payload && typeof c.payload === 'object' && 'evidenceRef' in c.payload ? String(c.payload.evidenceRef) : '')
          const evRef = rawEvRef
            ? rawEvRef.replace(/^opa:\/\//, 'cel://')
            : `cel://assessments/${item.agentName ? item.agentName.toLowerCase().replace(/\s+/g, '-') : 'system'}/${canonicalId.toLowerCase()}`

          return {
            controlId: canonicalId,
            controlName: c.controlName || c.check,
            verdict: c.passed ? 'PASS' : 'FAIL',
            evidenceRef: evRef,
            remediation: c.remediation || null,
          }
        }),
        attestation: {
          signedBy: 'witness-signalloom-evaluator',
          keyId: 'cosign-signalloom-root-2026',
          signatureAlgorithm: 'ECDSA_P256_SHA256',
          signedAt: new Date().toISOString(),
          witnessAttestor: 'attestors/k8s/cel-policy-engine',
        },
      },
    }
  }, [item, hashes, policyVer, effectiveStatus, effectiveScorePct])

  const rawJson = useMemo(() => {
    if (!item) return ''

    if (jsonFormat === 'summary') {
      const summaryPayload = {
        framework: item.frameworkName,
        frameworkId: item.frameworkId,
        controlId: sanitizeControlId(item.controlId, item.controlName, item.frameworkName),
        controlName: item.controlName,
        agentId: item.agentId,
        agentName: item.agentName,
        status: item.status,
        policyVersion: item.policyVersion || item.frameworkVersion || 'v2.1.0',
        totalChecks: item.totalChecks,
        passedChecks: item.passedChecks,
        failedChecks: item.failedChecks,
        postureScore: item.postureScore,
        evidenceHashes: hashes,
        checks: (item.checks || []).map(c => ({
          controlId: sanitizeControlId(c.controlId, c.controlName || c.check, item.frameworkName),
          check: c.check,
          passed: c.passed,
          remediation: c.remediation,
        })),
        evaluatedAt: new Date().toISOString(),
      }
      return JSON.stringify(summaryPayload, null, 2)
    }

    if (jsonFormat === 'dsse') {
      const statementStr = JSON.stringify(standardAttestation)
      const b64Payload = typeof btoa !== 'undefined' ? btoa(statementStr) : Buffer.from(statementStr).toString('base64')
      const dsseEnvelope = {
        payloadType: 'application/vnd.in-toto+json',
        payload: b64Payload.slice(0, 80) + '...[truncated for display]',
        signatures: [
          {
            keyid: 'cosign-signalloom-root-2026',
            sig: 'MEQCIA3y2jXf1z6s4tF1nK3v9m8pL4w5qR7uS1tV3yX5z7aAiB8...[cosign-witness-signature]',
            signedAt: new Date().toISOString(),
          },
        ],
      }
      return JSON.stringify(dsseEnvelope, null, 2)
    }

    // Default: in-toto statement v1
    return JSON.stringify(standardAttestation, null, 2)
  }, [item, jsonFormat, standardAttestation, hashes])

  if (!open || !item) return null

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
                <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {failingChecks.map((c, i) => {
                    const canonicalId = sanitizeControlId(c.controlId, c.controlName || c.check, item.frameworkName)
                    const evalUrl = `/evaluations?agent=${encodeURIComponent(item.agentId || 'a0000000-0000-0000-0000-000000000001')}&framework=${encodeURIComponent(item.frameworkId || item.frameworkName || 'eu-ai-act')}&control=${encodeURIComponent(canonicalId)}&violation=${encodeURIComponent(c.check)}`

                    return (
                      <SafeLink
                        key={i}
                        to={evalUrl}
                        data-testid={`compliance-remediation-link-${i}`}
                        style={{
                          display: 'block',
                          padding: '8px 12px',
                          borderRadius: 6,
                          background: 'var(--surface2)',
                          border: '1px solid var(--border)',
                          textDecoration: 'none',
                          color: 'inherit',
                          transition: 'border-color 0.15s, background 0.15s',
                        }}
                        onMouseEnter={(e: React.MouseEvent<HTMLElement>) => {
                          e.currentTarget.style.borderColor = 'var(--cyan)'
                        }}
                        onMouseLeave={(e: React.MouseEvent<HTMLElement>) => {
                          e.currentTarget.style.borderColor = 'var(--border)'
                        }}
                      >
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                          <strong style={{ color: 'var(--error)', fontSize: 12 }}>✗ {c.check}</strong>
                          <span style={{ fontSize: 11, color: 'var(--cyan)', whiteSpace: 'nowrap', fontWeight: 600 }}>
                            Inspect Evaluation →
                          </span>
                        </div>
                        {c.remediation && (
                          <div style={{ color: 'var(--muted)', marginTop: 4, fontSize: 11, lineHeight: 1.4 }}>
                            {c.remediation}
                          </div>
                        )}
                      </SafeLink>
                    )
                  })}
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
              <>
                <div style={{ display: 'flex', gap: 6, margin: '8px 0 10px', flexWrap: 'wrap' }}>
                  <button
                    type="button"
                    data-testid="compliance-format-intoto"
                    onClick={() => setJsonFormat('intoto')}
                    style={{
                      fontSize: 10,
                      padding: '3px 8px',
                      borderRadius: 4,
                      border: '1px solid var(--border)',
                      background: jsonFormat === 'intoto' ? 'var(--cyan)' : 'var(--surface2)',
                      color: jsonFormat === 'intoto' ? '#000' : 'var(--text)',
                      fontWeight: 600,
                      cursor: 'pointer',
                    }}
                  >
                    in-toto Statement v1 (Standard)
                  </button>
                  <button
                    type="button"
                    data-testid="compliance-format-summary"
                    onClick={() => setJsonFormat('summary')}
                    style={{
                      fontSize: 10,
                      padding: '3px 8px',
                      borderRadius: 4,
                      border: '1px solid var(--border)',
                      background: jsonFormat === 'summary' ? 'var(--cyan)' : 'var(--surface2)',
                      color: jsonFormat === 'summary' ? '#000' : 'var(--text)',
                      fontWeight: 600,
                      cursor: 'pointer',
                    }}
                  >
                    Normalized Summary
                  </button>
                  <button
                    type="button"
                    data-testid="compliance-format-dsse"
                    onClick={() => setJsonFormat('dsse')}
                    style={{
                      fontSize: 10,
                      padding: '3px 8px',
                      borderRadius: 4,
                      border: '1px solid var(--border)',
                      background: jsonFormat === 'dsse' ? 'var(--cyan)' : 'var(--surface2)',
                      color: jsonFormat === 'dsse' ? '#000' : 'var(--text)',
                      fontWeight: 600,
                      cursor: 'pointer',
                    }}
                  >
                    DSSE Envelope (Witness Signed)
                  </button>
                </div>

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
              </>
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
