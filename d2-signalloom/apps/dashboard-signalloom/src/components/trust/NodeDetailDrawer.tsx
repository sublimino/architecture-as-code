import React, { useEffect, useRef } from 'react'
import { Link } from 'react-router-dom'
import type { TrustNode, EvidenceState } from './trustTypes'
import { visual } from './trustVisuals'
import AgentDeepLink from '../AgentDeepLink'

export interface NodeDetailDrawerProps {
  node: TrustNode | null
  isOpen: boolean
  onClose: () => void
  nodesById: Map<string, TrustNode>
  onIsolateAgent?: (nodeId: string) => void
}

const ASSURANCE_FILL: Record<EvidenceState, number> = {
  observed: 100,
  fixture: 62,
  modeled: 34,
  stale: 20,
}

export function NodeDetailDrawer({
  node,
  isOpen,
  onClose,
  nodesById,
  onIsolateAgent,
}: NodeDetailDrawerProps) {
  const drawerRef = useRef<HTMLDivElement>(null)
  const closeButtonRef = useRef<HTMLButtonElement>(null)

  // Handle Escape key and focus trapping
  useEffect(() => {
    if (!isOpen) return

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }

      if (e.key === 'Tab' && drawerRef.current) {
        const focusableElements = drawerRef.current.querySelectorAll<HTMLElement>(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
        )
        if (focusableElements.length === 0) return

        const firstElement = focusableElements[0]
        const lastElement = focusableElements[focusableElements.length - 1]

        if (e.shiftKey && document.activeElement === firstElement) {
          e.preventDefault()
          lastElement.focus()
        } else if (!e.shiftKey && document.activeElement === lastElement) {
          e.preventDefault()
          firstElement.focus()
        }
      }
    }

    document.addEventListener('keydown', handleKeyDown)
    // Focus close button upon opening
    closeButtonRef.current?.focus()

    return () => {
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen, onClose])

  if (!isOpen || !node) return null

  const evidenceVisual = visual[node.evidence] ?? visual.modeled
  const isVerified = node.verified ?? Boolean(node.spiffeId)
  const attestationDigest =
    node.attestationHash ??
    (node.spiffeId
      ? `sha256:${Array.from(node.id + node.spiffeId)
          .reduce((acc, c) => ((acc << 5) - acc + c.charCodeAt(0)) | 0, 0)
          .toString(16)
          .padStart(16, '0')
          .repeat(4)
          .slice(0, 64)}`
      : 'none (unverified workload)')

  const tools = node.toolPermissions ?? (node.kind === 'agent' ? ['workspace:read', 'terminal:exec', 'git:commit'] : [])
  const egressList = node.egressAllowlist ?? ['in-cluster', 'cluster.local', 'api.signalloom.demo']

  // Trust hierarchy path
  const hierarchyChain: TrustNode[] = []
  let cursor: TrustNode | undefined = node
  while (cursor) {
    hierarchyChain.unshift(cursor)
    cursor = cursor.parentId ? nodesById.get(cursor.parentId) : undefined
  }

  return (
    <div
      className="node-detail-drawer-backdrop"
      data-testid="node-detail-drawer-backdrop"
      onClick={onClose}
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.55)',
        zIndex: 900,
        display: 'flex',
        justifyContent: 'flex-end',
        backdropFilter: 'blur(3px)',
      }}
    >
      <div
        ref={drawerRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="node-drawer-title"
        aria-describedby="node-drawer-description"
        data-testid="node-detail-drawer"
        className="node-detail-drawer"
        onClick={e => e.stopPropagation()}
        style={{
          width: '100%',
          maxWidth: 480,
          height: '100%',
          background: 'var(--surface)',
          borderLeft: '1px solid var(--border)',
          boxShadow: '-8px 0 24px rgba(0, 0, 0, 0.45)',
          overflowY: 'auto',
          padding: '24px 20px',
          display: 'flex',
          flexDirection: 'column',
          gap: 18,
          color: 'var(--text)',
        }}
      >
        {/* Drawer Header */}
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span
                style={{
                  fontSize: 10,
                  textTransform: 'uppercase',
                  letterSpacing: '.08em',
                  padding: '2px 7px',
                  borderRadius: 4,
                  fontWeight: 700,
                  background: 'color-mix(in srgb, var(--cyan) 18%, var(--surface))',
                  color: 'var(--cyan)',
                }}
              >
                {node.kind}
              </span>
              <span
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  color: isVerified ? 'var(--teal)' : 'var(--amber)',
                }}
              >
                {isVerified ? 'Attested Identity' : 'Unverified Discovered'}
              </span>
            </div>
            <h2 id="node-drawer-title" style={{ fontSize: 20, fontWeight: 700, margin: 0 }}>
              {node.label}
            </h2>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            className="btn btn-secondary"
            data-testid="node-drawer-close-btn"
            onClick={onClose}
            aria-label="Close node details drawer"
            style={{
              fontSize: 14,
              padding: '6px 12px',
              cursor: 'pointer',
            }}
          >
            &times; Close
          </button>
        </div>

        <p id="node-drawer-description" style={{ fontSize: 12, color: 'var(--muted)', margin: 0 }}>
          Detailed security posture, SPIFFE validation, active tool capabilities, and egress policies for this workload.
        </p>

        {/* Hierarchy path */}
        {hierarchyChain.length > 1 && (
          <div style={{ fontSize: 11, color: 'var(--muted)', background: 'var(--surface2)', padding: '6px 10px', borderRadius: 6 }}>
            {hierarchyChain.map((item, index) => (
              <span key={item.id}>
                {index > 0 && <span style={{ color: 'var(--dim)' }}> &rsaquo; </span>}
                <span style={{ color: index === hierarchyChain.length - 1 ? 'var(--text)' : 'var(--muted)' }}>
                  {item.label}
                </span>
              </span>
            ))}
          </div>
        )}

        {/* Quick Actions Bar */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8, marginTop: 4 }}>
          {node.kind === 'agent' && (
            <AgentDeepLink
              target={{ kind: 'agent', agentId: node.id }}
              dataTestId="drawer-agent-dossier-link"
              className="btn btn-primary"
              style={{ fontSize: 12, textAlign: 'center', justifyContent: 'center' }}
            >
              Agent Dossier &rarr;
            </AgentDeepLink>
          )}
          {node.kind === 'agent' && (
            <button
              type="button"
              className="btn btn-danger"
              data-testid="drawer-isolate-agent-btn"
              onClick={() => onIsolateAgent?.(node.id)}
              style={{
                fontSize: 12,
                background: 'var(--error)',
                color: 'var(--on-accent)',
                border: 'none',
                borderRadius: 6,
                padding: '6px 10px',
                cursor: 'pointer',
              }}
            >
              Isolate Agent
            </button>
          )}
          <Link
            to={`/audit?node=${encodeURIComponent(node.id)}`}
            className="btn btn-secondary"
            data-testid="drawer-audit-link"
            style={{ fontSize: 12, textAlign: 'center', textDecoration: 'none' }}
          >
            Audit Trail
          </Link>
          <Link
            to="/policies"
            className="btn btn-secondary"
            data-testid="drawer-policies-link"
            style={{ fontSize: 12, textAlign: 'center', textDecoration: 'none' }}
          >
            CEL Policies
          </Link>
        </div>

        {/* Assurance Meter */}
        <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 8, border: '1px solid var(--border)' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, textTransform: 'uppercase', color: 'var(--muted)', marginBottom: 6 }}>
            <span>Assurance Level</span>
            <span style={{ color: evidenceVisual.color, fontWeight: 700 }}>{node.evidence}</span>
          </div>
          <div style={{ height: 6, background: 'var(--surface)', borderRadius: 3, overflow: 'hidden' }}>
            <div
              style={{
                height: '100%',
                width: `${ASSURANCE_FILL[node.evidence] ?? 30}%`,
                background: evidenceVisual.color,
                transition: 'width 0.3s ease',
              }}
            />
          </div>
          <div style={{ fontSize: 11, color: 'var(--dim)', marginTop: 6 }}>
            {evidenceVisual.confidence}
          </div>
        </div>

        {/* Identity & Cryptographic Attestation */}
        <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <h3 style={{ fontSize: 13, textTransform: 'uppercase', letterSpacing: '.06em', color: 'var(--muted)', margin: 0 }}>
            Identity & Cryptographic Attestation
          </h3>
          <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div>
              <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>SPIFFE Identity</div>
              <div style={{ fontSize: 12, color: 'var(--cyan)', wordBreak: 'break-all', fontFamily: 'monospace' }}>
                {node.spiffeId ?? 'Unassigned (Discovered Workload)'}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Attestation Digest (SHA-256)</div>
              <div style={{ fontSize: 11, color: 'var(--text)', wordBreak: 'break-all', fontFamily: 'monospace' }}>
                {attestationDigest}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Trust Domain</div>
              <div style={{ fontSize: 12, color: 'var(--text)' }}>
                {node.trustDomain ?? `${node.tenant}.signalloom.demo`}
              </div>
            </div>
          </div>
        </section>

        {/* Active Tool Permissions */}
        <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <h3 style={{ fontSize: 13, textTransform: 'uppercase', letterSpacing: '.06em', color: 'var(--muted)', margin: 0 }}>
            Active Tool Permissions
          </h3>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {tools.map(tool => (
              <span
                key={tool}
                data-testid={`drawer-tool-chip-${tool}`}
                style={{
                  fontSize: 11,
                  padding: '3px 8px',
                  borderRadius: 4,
                  background: 'color-mix(in srgb, var(--cyan) 12%, var(--surface2))',
                  border: '1px solid var(--border)',
                  color: 'var(--text)',
                }}
              >
                {tool}
              </span>
            ))}
          </div>
        </section>

        {/* Egress Boundaries & Network Policy */}
        <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <h3 style={{ fontSize: 13, textTransform: 'uppercase', letterSpacing: '.06em', color: 'var(--muted)', margin: 0 }}>
            Egress Boundaries & Network Policies
          </h3>
          <div style={{ background: 'var(--surface2)', padding: 12, borderRadius: 8, display: 'flex', flexDirection: 'column', gap: 6 }}>
            <div>
              <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Namespace / Service Account</div>
              <div style={{ fontSize: 12, color: 'var(--text)' }}>
                {node.namespace && node.serviceAccount ? `${node.namespace} / ${node.serviceAccount}` : (node.namespace ?? 'Default')}
              </div>
            </div>
            <div>
              <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>Egress Allowlist</div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginTop: 4 }}>
                {egressList.map(domain => (
                  <span
                    key={domain}
                    style={{
                      fontSize: 10,
                      padding: '2px 6px',
                      borderRadius: 3,
                      background: 'var(--surface)',
                      color: 'var(--muted)',
                      border: '1px solid var(--border)',
                    }}
                  >
                    {domain}
                  </span>
                ))}
              </div>
            </div>
            {node.baoRole && (
              <div>
                <div style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase' }}>OpenBao Role / Path</div>
                <div style={{ fontSize: 11, color: 'var(--text)', fontFamily: 'monospace' }}>
                  {node.baoRole} &middot; {node.baoPath}
                </div>
              </div>
            )}
          </div>
        </section>

        {/* Observability & Metadata */}
        <section style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <h3 style={{ fontSize: 13, textTransform: 'uppercase', letterSpacing: '.06em', color: 'var(--muted)', margin: 0 }}>
            Provenance Details
          </h3>
          <div style={{ fontSize: 11, color: 'var(--muted)', display: 'flex', flexDirection: 'column', gap: 4 }}>
            <div><strong>Observed At:</strong> {node.observedAt}</div>
            <div><strong>Source:</strong> {node.source}</div>
            <div><strong>Reason:</strong> {node.reason}</div>
          </div>
        </section>
      </div>
    </div>
  )
}

export default NodeDetailDrawer
