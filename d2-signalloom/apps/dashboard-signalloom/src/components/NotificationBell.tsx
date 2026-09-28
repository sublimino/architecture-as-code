import React, { useState, useRef, useEffect, useCallback } from 'react'
import { Link } from 'react-router-dom'
import { useTenantWarnings, type TenantWarning } from '../hooks/useTenantWarnings'

export interface NotificationBellProps {
  warnings?: TenantWarning[]
  unreadWarnings?: TenantWarning[]
  unreadCount?: number
  onMarkAsRead?: (id: string) => void
  onMarkAllAsRead?: () => void
  onRefresh?: () => Promise<void>
  pollIntervalMs?: number
  token?: string
  className?: string
  style?: React.CSSProperties
}

function formatWarningType(type: string): string {
  switch (type) {
    case 'policy_violation':
    case 'violation_detected':
      return 'POLICY VIOLATION'
    case 'containment_action':
    case 'agent.stunned':
      return 'CONTAINMENT ACTION'
    case 'agent_expiry':
    case 'agent.credential_revoked':
    case 'external_agent.revoked':
      return 'AGENT EXPIRY'
    default:
      return type.replace(/[._]/g, ' ').toUpperCase()
  }
}

function getWarningTypeColor(type: string): string {
  switch (type) {
    case 'policy_violation':
    case 'violation_detected':
      return 'var(--error)'
    case 'containment_action':
    case 'agent.stunned':
      return 'var(--amber)'
    case 'agent_expiry':
    case 'agent.credential_revoked':
    case 'external_agent.revoked':
      return 'var(--amber)'
    default:
      return 'var(--cyan)'
  }
}

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  try {
    const d = new Date(iso)
    if (isNaN(d.getTime())) return iso
    return d.toISOString().replace('T', ' ').substring(0, 19) + ' UTC'
  } catch {
    return iso || '—'
  }
}

export function NotificationBell({
  warnings: propWarnings,
  unreadWarnings: propUnreadWarnings,
  unreadCount: propUnreadCount,
  onMarkAsRead: propOnMarkAsRead,
  onMarkAllAsRead: propOnMarkAllAsRead,
  pollIntervalMs = 15_000,
  token,
  className,
  style,
}: NotificationBellProps) {
  const [open, setOpen] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const bellButtonRef = useRef<HTMLButtonElement>(null)

  // Use hook if props are not explicitly supplied
  const hookResult = useTenantWarnings({
    pollIntervalMs,
    token,
    enabled: propWarnings === undefined,
  })

  const warnings = propWarnings ?? hookResult.warnings
  const unreadWarnings = propUnreadWarnings ?? hookResult.unreadWarnings
  const unreadCount = propUnreadCount !== undefined ? propUnreadCount : hookResult.unreadCount
  const markAsRead = propOnMarkAsRead ?? hookResult.markAsRead
  const markAllAsRead = propOnMarkAllAsRead ?? hookResult.markAllAsRead

  // Dismiss dropdown on click outside or Escape
  useEffect(() => {
    if (!open) return

    function handleClickOutside(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setOpen(false)
      }
    }

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        setOpen(false)
        bellButtonRef.current?.focus()
      }
    }

    document.addEventListener('mousedown', handleClickOutside)
    document.addEventListener('keydown', handleKeyDown)
    return () => {
      document.removeEventListener('mousedown', handleClickOutside)
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [open])

  const toggleOpen = useCallback(() => {
    setOpen((prev) => !prev)
  }, [])

  return (
    <div
      ref={containerRef}
      className={className}
      style={{ position: 'relative', display: 'inline-flex', alignItems: 'center', ...style }}
    >
      <button
        ref={bellButtonRef}
        type="button"
        data-testid="tenant-warnings-bell"
        aria-label={
          unreadCount === 0
            ? 'Tenant warnings, none unread'
            : `Tenant warnings, ${unreadCount} unread`
        }
        aria-expanded={open}
        aria-haspopup="dialog"
        onClick={toggleOpen}
        style={{
          position: 'relative',
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: 32,
          height: 32,
          padding: 0,
          background: 'none',
          border: '1px solid var(--border-subtle)',
          borderRadius: 6,
          color: unreadCount > 0 ? 'var(--amber)' : 'var(--muted)',
          cursor: 'pointer',
          transition: 'all 0.15s ease',
        }}
      >
        {/* Bell SVG Icon */}
        <svg
          aria-hidden="true"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
          <path d="M13.73 21a2 2 0 0 1-3.46 0" />
        </svg>

        {unreadCount > 0 && (
          <span
            data-testid="tenant-warnings-count"
            aria-hidden="true"
            style={{
              position: 'absolute',
              top: -4,
              right: -4,
              background: 'var(--amber)',
              color: 'var(--bg)',
              fontSize: 10,
              fontWeight: 700,
              minWidth: 16,
              height: 16,
              borderRadius: 99,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: '0 4px',
              lineHeight: 1,
              boxShadow: '0 0 0 2px var(--surface)',
            }}
          >
            {unreadCount > 99 ? '99+' : unreadCount}
          </span>
        )}
      </button>

      {open && (
        <div
          role="dialog"
          aria-label="Tenant warnings"
          data-testid="tenant-warnings-panel"
          style={{
            position: 'absolute',
            top: 40,
            right: 0,
            width: 380,
            maxWidth: '90vw',
            maxHeight: 460,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
            boxShadow: '0 12px 32px rgba(0,0,0,0.45)',
            zIndex: 1000,
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
          }}
        >
          {/* Header */}
          <div
            style={{
              padding: '10px 14px',
              borderBottom: '1px solid var(--border)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              background: 'var(--surface2)',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>
                Warnings
              </span>
              <span
                style={{
                  fontSize: 11,
                  padding: '1px 6px',
                  borderRadius: 10,
                  background: unreadCount > 0 ? 'color-mix(in srgb, var(--amber) 20%, transparent)' : 'var(--surface)',
                  color: unreadCount > 0 ? 'var(--amber)' : 'var(--muted)',
                  fontWeight: 600,
                }}
              >
                {unreadCount} unread
              </span>
            </div>

            {warnings.length > 0 && (
              <button
                type="button"
                data-testid="tenant-warnings-mark-all"
                onClick={markAllAsRead}
                style={{
                  fontSize: 11,
                  background: 'none',
                  border: 'none',
                  color: 'var(--cyan)',
                  cursor: 'pointer',
                  padding: '2px 4px',
                }}
              >
                Mark all read
              </button>
            )}
          </div>

          {/* Body List */}
          <div
            style={{
              flex: 1,
              overflowY: 'auto',
              padding: warnings.length === 0 ? '24px 16px' : '6px 0',
            }}
          >
            {warnings.length === 0 ? (
              <div
                data-testid="tenant-warnings-empty"
                style={{
                  textAlign: 'center',
                  color: 'var(--muted)',
                  fontSize: 12,
                }}
              >
                No active tenant warnings recorded.
              </div>
            ) : (
              warnings.map((warning) => {
                const isUnread = unreadWarnings.some((w) => w.id === warning.id)
                const typeColor = getWarningTypeColor(warning.event_type)
                const typeLabel = formatWarningType(warning.event_type)
                const agentTarget = warning.agent_id || 'unknown'
                const targetHref = `/agents/${encodeURIComponent(agentTarget)}?tab=activity&audit=${encodeURIComponent(warning.id)}`

                return (
                  <div
                    key={warning.id}
                    data-testid={`tenant-warning-row-${warning.id}`}
                    style={{
                      padding: '10px 14px',
                      borderBottom: '1px solid var(--border-subtle)',
                      background: isUnread ? 'color-mix(in srgb, var(--amber) 8%, transparent)' : 'transparent',
                      display: 'flex',
                      flexDirection: 'column',
                      gap: 4,
                      position: 'relative',
                    }}
                  >
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 6 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                        <span
                          style={{
                            fontSize: 9.5,
                            fontWeight: 700,
                            letterSpacing: '0.04em',
                            padding: '2px 6px',
                            borderRadius: 3,
                            background: `color-mix(in srgb, ${typeColor} 18%, transparent)`,
                            color: typeColor,
                            border: `1px solid color-mix(in srgb, ${typeColor} 35%, transparent)`,
                          }}
                        >
                          {typeLabel}
                        </span>
                        {isUnread && (
                          <span
                            style={{
                              width: 6,
                              height: 6,
                              borderRadius: '50%',
                              background: 'var(--amber)',
                            }}
                          />
                        )}
                      </div>

                      <span style={{ fontSize: 10.5, color: 'var(--muted)' }}>
                        {formatTime(warning.timestamp)}
                      </span>
                    </div>

                    <div style={{ fontSize: 12, color: 'var(--text)', marginTop: 2 }}>
                      <strong>Agent:</strong> {warning.agent_name || warning.agent_id || 'Unspecified'}
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginTop: 4 }}>
                      <Link
                        to={targetHref}
                        data-testid={`tenant-warning-link-${warning.id}`}
                        onClick={() => {
                          markAsRead(warning.id)
                          setOpen(false)
                        }}
                        style={{
                          fontSize: 11.5,
                          color: 'var(--cyan)',
                          textDecoration: 'none',
                          display: 'inline-flex',
                          alignItems: 'center',
                          gap: 4,
                        }}
                      >
                        Audit ID: <code style={{ fontSize: 11 }}>{warning.id}</code> →
                      </Link>

                      {isUnread && (
                        <button
                          type="button"
                          data-testid={`tenant-warning-mark-read-${warning.id}`}
                          onClick={() => markAsRead(warning.id)}
                          style={{
                            fontSize: 10.5,
                            background: 'none',
                            border: '1px solid var(--border)',
                            borderRadius: 3,
                            color: 'var(--muted)',
                            cursor: 'pointer',
                            padding: '1px 5px',
                          }}
                        >
                          Mark read
                        </button>
                      )}
                    </div>
                  </div>
                )
              })
            )}
          </div>
        </div>
      )}
    </div>
  )
}

export default NotificationBell
