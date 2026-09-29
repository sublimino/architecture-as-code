// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

import React, { useEffect, useState, useCallback, useRef, type ReactNode } from 'react'
import type { AuditEventResponse } from '../types/api'
import AgentDeepLink from './AgentDeepLink'

export interface AuditDetailDrawerProps {
  isOpen: boolean
  event: AuditEventResponse | null
  onClose: () => void
}

const EVENT_COLORS: Record<string, string> = {
  'agent.stunned': 'var(--error)',
  'agent.credential_revoked': 'var(--error)',
  'agent.created': 'var(--teal)',
  'agent.transitioned': 'var(--violet)',
  'agent.credential_issued': 'var(--cyan)',
  'violation.acknowledged': 'var(--amber)',
  'compliance.reassess_requested': 'var(--cyan)',
  'compliance.scan_completed': 'var(--cyan)',
  'api_key.created': 'var(--teal)',
  'api_key.rotated': 'var(--cyan)',
  'nhi.enrolled': 'var(--teal)',
  'nhi.dismissed': 'var(--amber)',
  'tenant.frameworks_updated': 'var(--violet)',
  'tenant.preferences_updated': 'var(--violet)',
  'user.currency_updated': 'var(--violet)',
  'consent.accepted': 'var(--teal)',
  'cookie.preferences_updated': 'var(--violet)',
  'support.requested': 'var(--amber)',
  onboarding_completed: 'var(--teal)',
  onboarding_skipped: 'var(--amber)',
  'operator.created': 'var(--teal)',
  'operator.sign_in_succeeded': 'var(--cyan)',
  'operator.sign_in_denied': 'var(--amber)',
  'operator.removed': 'var(--error)',
  'demo.phase_run': 'var(--violet)',
  'demo.reset_requested': 'var(--amber)',
  'demo.supercred.phase_run': 'var(--violet)',
  'demo.supercred.reset_requested': 'var(--amber)',
  'demo.signalfusion.phase_run': 'var(--violet)',
  'demo.signalfusion.reset_requested': 'var(--amber)',
  'demo.distancelatency.phase_run': 'var(--violet)',
  'demo.distancelatency.reset_requested': 'var(--amber)',
  'eap_environment.registered': 'var(--teal)',
  'eap_environment.lease_extended': 'var(--cyan)',
  'eap_environment.reaping_triggered': 'var(--amber)',
  'eap_environment.provisioned': 'var(--teal)',
  'eap_environment.ttl_extended': 'var(--cyan)',
  'eap_environment.teardown_requested': 'var(--amber)',
  'eap_environment.webhook_triggered': 'var(--violet)',
  'eap_scenario.executed': 'var(--violet)',
  'eap_tenant.isolation_provisioned': 'var(--teal)',
  'eap_tenant.isolation_torn_down': 'var(--amber)',
  enrollment: 'var(--teal)',
  state_transition: 'var(--violet)',
  violation_detected: 'var(--error)',
  compliance_check: 'var(--cyan)',
  token_issued: 'var(--cyan)',
  token_refused: 'var(--amber)',
  tenant_created: 'var(--teal)',
  user_provisioned: 'var(--teal)',
  directory_connected: 'var(--violet)',
  discovery_enroll_requested: 'var(--amber)',
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
      timeZoneName: 'short',
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
    const days = Math.floor(hours / 24)
    if (days === 1) return 'Yesterday'
    if (days < 30) return `${days}d ago`
    return fmtDate(iso)
  } catch {
    return 'unknown'
  }
}

/**
 * Formats and syntax highlights JSON string or object into styled React elements.
 */
export function renderSyntaxHighlightedJson(val: unknown): ReactNode {
  let jsonString = ''
  try {
    if (typeof val === 'string') {
      try {
        jsonString = JSON.stringify(JSON.parse(val), null, 2)
      } catch {
        jsonString = val
      }
    } else {
      jsonString = JSON.stringify(val ?? {}, null, 2)
    }
  } catch {
    jsonString = String(val)
  }

  const regex = /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?|[{}[\],])/g

  const nodes: ReactNode[] = []
  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = regex.exec(jsonString)) !== null) {
    if (match.index > lastIndex) {
      nodes.push(jsonString.substring(lastIndex, match.index))
    }
    const token = match[0]

    if (/^"/.test(token)) {
      if (/:$/.test(token)) {
        // Key
        const keyText = token.slice(0, -1)
        nodes.push(
          <span key={`k-${match.index}`} style={{ color: 'var(--cyan, #38bdf8)', fontWeight: 600 }}>
            {keyText}
          </span>
        )
        nodes.push(':')
      } else {
        // String value
        nodes.push(
          <span key={`s-${match.index}`} style={{ color: 'var(--teal, #2dd4bf)' }}>
            {token}
          </span>
        )
      }
    } else if (/true|false/.test(token)) {
      nodes.push(
        <span key={`b-${match.index}`} style={{ color: 'var(--violet, #a78bfa)', fontWeight: 600 }}>
          {token}
        </span>
      )
    } else if (/null/.test(token)) {
      nodes.push(
        <span key={`n-${match.index}`} style={{ color: 'var(--muted, #94a3b8)', fontWeight: 600 }}>
          {token}
        </span>
      )
    } else if (/^-?\d/.test(token)) {
      nodes.push(
        <span key={`num-${match.index}`} style={{ color: 'var(--amber, #f59e0b)' }}>
          {token}
        </span>
      )
    } else {
      // Punctuation
      nodes.push(
        <span key={`p-${match.index}`} style={{ color: 'var(--muted, #64748b)' }}>
          {token}
        </span>
      )
    }
    lastIndex = regex.lastIndex
  }

  if (lastIndex < jsonString.length) {
    nodes.push(jsonString.substring(lastIndex))
  }

  return nodes
}

export default function AuditDetailDrawer({
  isOpen,
  event,
  onClose,
}: AuditDetailDrawerProps) {
  const [copied, setCopied] = useState(false)
  const closeButtonRef = useRef<HTMLButtonElement | null>(null)

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }
    },
    [onClose],
  )

  useEffect(() => {
    if (isOpen) {
      window.addEventListener('keydown', handleKeyDown)
      // Focus the close button for accessibility
      setTimeout(() => {
        closeButtonRef.current?.focus()
      }, 50)
      return () => window.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen, handleKeyDown])

  if (!isOpen || !event) return null

  const handleCopyPayload = async () => {
    const raw =
      typeof event.detail === 'string'
        ? event.detail
        : JSON.stringify(event.detail ?? {}, null, 2)
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(raw)
      } else {
        const textarea = document.createElement('textarea')
        textarea.value = raw
        textarea.style.position = 'fixed'
        textarea.style.opacity = '0'
        document.body.appendChild(textarea)
        textarea.select()
        document.execCommand('copy')
        document.body.removeChild(textarea)
      }
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // ignore
    }
  }

  const eventColor = EVENT_COLORS[event.event_type] ?? 'var(--muted, #94a3b8)'
  const spiffeId =
    event.spiffe_id ||
    (event.detail && typeof event.detail === 'object' && ('spiffe_id' in event.detail ? String(event.detail.spiffe_id) : null)) ||
    null
  const authPrincipal =
    event.authorizing_principal_id ||
    (event.detail && typeof event.detail === 'object' && ('authorizing_principal_id' in event.detail ? String(event.detail.authorizing_principal_id) : null)) ||
    null
  const execActorId =
    event.executing_actor_id ||
    (event.detail && typeof event.detail === 'object' && ('executing_actor_id' in event.detail ? String(event.detail.executing_actor_id) : null)) ||
    null
  const rationale =
    event.attribution_rationale ||
    (event.detail && typeof event.detail === 'object' && ('attribution_rationale' in event.detail ? String(event.detail.attribution_rationale) : null)) ||
    null
  const evidenceRef =
    event.evidence_ref ||
    (event.detail && typeof event.detail === 'object' && ('evidence_ref' in event.detail ? String(event.detail.evidence_ref) : null)) ||
    (event.detail && typeof event.detail === 'object' && ('root_hash' in event.detail ? String(event.detail.root_hash) : null)) ||
    null
  const kernelRef =
    event.kernel_telemetry_ref ||
    (event.detail && typeof event.detail === 'object' && ('kernel_telemetry_ref' in event.detail ? String(event.detail.kernel_telemetry_ref) : null)) ||
    null

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="audit-detail-drawer-title"
      data-testid="audit-detail-dialog"
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        zIndex: 9999,
        display: 'flex',
        justifyContent: 'flex-end',
      }}
    >
      {/* Backdrop */}
      <div
        data-testid="audit-detail-drawer-backdrop"
        onClick={onClose}
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          background: 'rgba(0, 0, 0, 0.55)',
          backdropFilter: 'blur(3px)',
        }}
      />

      {/* Drawer Panel */}
      <aside
        data-testid="audit-detail-drawer"
        style={{
          position: 'relative',
          width: 580,
          maxWidth: '92vw',
          height: '100%',
          background: 'var(--surface, #121824)',
          borderLeft: '1px solid var(--border, #1e293b)',
          display: 'flex',
          flexDirection: 'column',
          boxShadow: '-8px 0 32px rgba(0, 0, 0, 0.5)',
          overflow: 'hidden',
          zIndex: 1,
        }}
      >
        {/* Header */}
        <div
          style={{
            padding: '18px 24px',
            borderBottom: '1px solid var(--border, #1e293b)',
            background: 'var(--surface2, #182234)',
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'flex-start',
            flexShrink: 0,
          }}
        >
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
              <span
                style={{
                  display: 'inline-block',
                  width: 8,
                  height: 8,
                  borderRadius: '50%',
                  background: eventColor,
                  boxShadow: `0 0 8px ${eventColor}`,
                }}
              />
              <h2
                id="audit-detail-drawer-title"
                style={{
                  fontSize: 16,
                  fontWeight: 700,
                  color: 'var(--text, #f1f5f9)',
                  margin: 0,
                  fontFamily: 'monospace',
                }}
              >
                {event.event_type}
              </h2>
            </div>
            <div style={{ fontSize: 12, color: 'var(--muted, #94a3b8)', fontFamily: 'monospace' }}>
              ID: {event.id} ({fmtRelative(event.timestamp)})
            </div>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            onClick={onClose}
            aria-label="Close audit detail drawer"
            data-testid="audit-detail-drawer-close"
            style={{
              background: 'transparent',
              border: '1px solid var(--border, #1e293b)',
              borderRadius: 4,
              color: 'var(--muted, #94a3b8)',
              fontSize: 18,
              cursor: 'pointer',
              padding: '4px 10px',
              lineHeight: 1,
              transition: 'background 0.15s ease, color 0.15s ease',
            }}
          >
            &times;
          </button>
        </div>

        {/* Scrollable Content Body */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '20px 24px', display: 'flex', flexDirection: 'column', gap: 20 }}>
          {/* Section 1: Event Metadata */}
          <section data-testid="audit-drawer-metadata">
            <h3
              style={{
                fontSize: 11,
                fontWeight: 700,
                textTransform: 'uppercase',
                letterSpacing: '0.08em',
                color: 'var(--muted, #94a3b8)',
                marginBottom: 10,
              }}
            >
              Event Metadata
            </h3>
            <div
              style={{
                background: 'var(--surface2, #182234)',
                border: '1px solid var(--border, #1e293b)',
                borderRadius: 6,
                padding: '12px 14px',
                display: 'grid',
                gridTemplateColumns: '130px 1fr',
                rowGap: 10,
                columnGap: 12,
                fontSize: 12,
              }}
            >
              <div style={{ color: 'var(--muted, #94a3b8)' }}>Event Type:</div>
              <div>
                <span
                  style={{
                    display: 'inline-block',
                    padding: '2px 8px',
                    borderRadius: 4,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: 600,
                    background: `color-mix(in srgb, ${eventColor} 18%, transparent)`,
                    color: eventColor,
                    border: `1px solid color-mix(in srgb, ${eventColor} 40%, transparent)`,
                  }}
                >
                  {event.event_type}
                </span>
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Chronometry:</div>
              <div style={{ color: 'var(--text, #f1f5f9)', fontFamily: 'monospace', fontSize: 11 }}>
                <div>{event.timestamp}</div>
                <div style={{ color: 'var(--muted, #94a3b8)', fontSize: 11, marginTop: 2 }}>
                  {fmtDate(event.timestamp)} ({fmtRelative(event.timestamp)})
                </div>
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Target Agent:</div>
              <div>
                {event.agent_name || event.agent_id ? (
                  <AgentDeepLink
                    target={event.agent_id ? { kind: 'agent', agentId: event.agent_id } : (event.agent_name ?? '')}
                    dataTestId={`audit-drawer-agent-${event.id}`}
                    style={{ color: 'var(--cyan, #38bdf8)', display: 'inline-flex', flexDirection: 'column' }}
                  >
                    <span style={{ fontWeight: 600 }}>{event.agent_name || event.agent_id}</span>
                    {event.agent_id && (
                      <span style={{ fontSize: 10, fontFamily: 'monospace', color: 'var(--muted, #94a3b8)' }}>
                        {event.agent_id}
                      </span>
                    )}
                  </AgentDeepLink>
                ) : (
                  <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>
                )}
              </div>
            </div>
          </section>

          {/* Section 2: Actor Identity & SPIFFE */}
          <section data-testid="audit-drawer-actor">
            <h3
              style={{
                fontSize: 11,
                fontWeight: 700,
                textTransform: 'uppercase',
                letterSpacing: '0.08em',
                color: 'var(--muted, #94a3b8)',
                marginBottom: 10,
              }}
            >
              Actor Identity &amp; Provenance
            </h3>
            <div
              style={{
                background: 'var(--surface2, #182234)',
                border: '1px solid var(--border, #1e293b)',
                borderRadius: 6,
                padding: '12px 14px',
                display: 'grid',
                gridTemplateColumns: '130px 1fr',
                rowGap: 10,
                columnGap: 12,
                fontSize: 12,
              }}
            >
              <div style={{ color: 'var(--muted, #94a3b8)' }}>Actor:</div>
              <div style={{ color: 'var(--text, #f1f5f9)', fontWeight: 500 }}>
                {event.actor ? (
                  <AgentDeepLink target={event.actor} variant="subtle" dataTestId={`audit-drawer-actor-link`} />
                ) : (
                  <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>
                )}
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>SPIFFE ID:</div>
              <div>
                {spiffeId ? (
                  <code
                    style={{
                      display: 'inline-block',
                      background: 'rgba(56, 189, 248, 0.1)',
                      color: 'var(--cyan, #38bdf8)',
                      padding: '2px 6px',
                      borderRadius: 4,
                      fontSize: 11,
                      border: '1px solid rgba(56, 189, 248, 0.25)',
                      wordBreak: 'break-all',
                    }}
                  >
                    {spiffeId}
                  </code>
                ) : (
                  <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>
                )}
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Authorizing ID:</div>
              <div style={{ color: 'var(--text, #f1f5f9)', fontFamily: 'monospace', fontSize: 11 }}>
                {authPrincipal || <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>}
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Executing Actor ID:</div>
              <div style={{ color: 'var(--text, #f1f5f9)', fontFamily: 'monospace', fontSize: 11 }}>
                {execActorId || <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>}
              </div>

              {rationale && (
                <>
                  <div style={{ color: 'var(--muted, #94a3b8)' }}>Attribution:</div>
                  <div style={{ color: 'var(--text, #f1f5f9)', fontSize: 11 }}>{rationale}</div>
                </>
              )}
            </div>
          </section>

          {/* Section 3: Attestation Cryptography */}
          <section data-testid="audit-drawer-cryptography">
            <h3
              style={{
                fontSize: 11,
                fontWeight: 700,
                textTransform: 'uppercase',
                letterSpacing: '0.08em',
                color: 'var(--muted, #94a3b8)',
                marginBottom: 10,
              }}
            >
              Attestation Cryptography
            </h3>
            <div
              style={{
                background: 'var(--surface2, #182234)',
                border: '1px solid var(--border, #1e293b)',
                borderRadius: 6,
                padding: '12px 14px',
                display: 'grid',
                gridTemplateColumns: '130px 1fr',
                rowGap: 10,
                columnGap: 12,
                fontSize: 12,
              }}
            >
              <div style={{ color: 'var(--muted, #94a3b8)' }}>Evidence Ref:</div>
              <div>
                {evidenceRef ? (
                  <code
                    style={{
                      display: 'inline-block',
                      background: 'rgba(45, 212, 191, 0.1)',
                      color: 'var(--teal, #2dd4bf)',
                      padding: '2px 6px',
                      borderRadius: 4,
                      fontSize: 11,
                      border: '1px solid rgba(45, 212, 191, 0.25)',
                      wordBreak: 'break-all',
                    }}
                  >
                    {evidenceRef}
                  </code>
                ) : (
                  <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>
                )}
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Kernel Telemetry:</div>
              <div>
                {kernelRef ? (
                  <code
                    style={{
                      display: 'inline-block',
                      background: 'rgba(167, 139, 250, 0.1)',
                      color: 'var(--violet, #a78bfa)',
                      padding: '2px 6px',
                      borderRadius: 4,
                      fontSize: 11,
                      border: '1px solid rgba(167, 139, 250, 0.25)',
                      wordBreak: 'break-all',
                    }}
                  >
                    {kernelRef}
                  </code>
                ) : (
                  <span style={{ color: 'var(--muted, #94a3b8)' }}>None</span>
                )}
              </div>

              <div style={{ color: 'var(--muted, #94a3b8)' }}>Integrity State:</div>
              <div>
                <span
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 6,
                    color: 'var(--teal, #2dd4bf)',
                    fontSize: 11,
                    fontWeight: 600,
                  }}
                >
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
                    <path d="m9 12 2 2 4-4" />
                  </svg>
                  Immutable Append-Only Log
                </span>
              </div>
            </div>
          </section>

          {/* Section 4: Raw JSON Payload with Syntax Highlighting */}
          <section data-testid="audit-drawer-payload">
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                marginBottom: 10,
              }}
            >
              <h3
                style={{
                  fontSize: 11,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                  letterSpacing: '0.08em',
                  color: 'var(--muted, #94a3b8)',
                  margin: 0,
                }}
              >
                Raw Event Payload
              </h3>
              <button
                type="button"
                onClick={handleCopyPayload}
                data-testid="audit-copy-payload-button"
                style={{
                  background: copied ? 'var(--teal, #2dd4bf)' : 'var(--surface2, #182234)',
                  color: copied ? '#0f172a' : 'var(--text, #f1f5f9)',
                  border: '1px solid var(--border, #1e293b)',
                  borderRadius: 4,
                  fontSize: 11,
                  fontWeight: 600,
                  padding: '4px 10px',
                  cursor: 'pointer',
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 6,
                  transition: 'background 0.15s ease, color 0.15s ease',
                }}
              >
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                  {copied ? (
                    <polyline points="20 6 9 17 4 12" />
                  ) : (
                    <>
                      <rect width="14" height="14" x="8" y="8" rx="2" ry="2" />
                      <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />
                    </>
                  )}
                </svg>
                {copied ? 'Copied!' : 'Copy Payload'}
              </button>
            </div>

            <pre
              data-testid="audit-json-viewer"
              style={{
                background: 'var(--surface2, #182234)',
                border: '1px solid var(--border, #1e293b)',
                borderRadius: 6,
                padding: '14px 16px',
                margin: 0,
                fontFamily: 'monospace',
                fontSize: 11,
                lineHeight: 1.5,
                overflowX: 'auto',
                maxHeight: 320,
                color: 'var(--text, #f1f5f9)',
                whiteSpace: 'pre-wrap',
                wordBreak: 'break-all',
              }}
            >
              <code>{renderSyntaxHighlightedJson(event.detail)}</code>
            </pre>
          </section>
        </div>
      </aside>
    </div>
  )
}
