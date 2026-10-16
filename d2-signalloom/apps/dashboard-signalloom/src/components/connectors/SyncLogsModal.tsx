import React, { useState, useEffect, useCallback, useMemo } from 'react'
import { connectorsApi, type SyncResult } from '../../api/connectorsClient'
import { useSuperadmin } from '../../auth/superadmin'
import { useAuth0 } from '../../auth/oidc'
import ProviderLogo from '../onboarding/ProviderLogo'

export interface SyncLogsModalProps {
  isOpen: boolean
  providerId: string
  providerName: string
  onClose: () => void
  onRescan?: () => Promise<void>
  isSuperadmin?: boolean
  initialSyncResult?: SyncResult
}

type LogLevelFilter = 'ALL' | 'INFO' | 'WARN' | 'ERROR' | 'DEBUG'

function formatTimeAgo(isoString: string): string {
  try {
    const diffMs = Date.now() - new Date(isoString).getTime()
    if (diffMs < 5000) return 'just now'
    const diffSec = Math.floor(diffMs / 1000)
    if (diffSec < 60) return `${diffSec}s ago`
    const diffMin = Math.floor(diffSec / 60)
    if (diffMin < 60) return `${diffMin}m ago`
    const diffHours = Math.floor(diffMin / 60)
    return `${diffHours}h ago`
  } catch {
    return isoString
  }
}

const levelBadgeStyles: Record<string, { bg: string; color: string; border: string }> = {
  info: { bg: 'rgba(56, 189, 248, 0.12)', color: 'var(--cyan)', border: 'rgba(56, 189, 248, 0.3)' },
  debug: { bg: 'rgba(168, 85, 247, 0.12)', color: 'var(--violet)', border: 'rgba(168, 85, 247, 0.3)' },
  warn: { bg: 'rgba(251, 191, 36, 0.12)', color: 'var(--warning)', border: 'rgba(251, 191, 36, 0.3)' },
  error: { bg: 'rgba(248, 113, 113, 0.12)', color: 'var(--error)', border: 'rgba(248, 113, 113, 0.3)' },
}

export default function SyncLogsModal({
  isOpen,
  providerId,
  providerName,
  onClose,
  onRescan,
  isSuperadmin: isSuperadminProp,
  initialSyncResult,
}: SyncLogsModalProps) {
  const [hookSuperadmin] = useSuperadmin()
  const isSuperadmin = isSuperadminProp ?? hookSuperadmin

  let auth: { getAccessTokenSilently?: () => Promise<string> } | undefined
  try {
    auth = useAuth0()
  } catch {
    // outside Auth provider in test or standalone
  }
  const authRef = React.useRef(auth)
  authRef.current = auth

  const [syncResult, setSyncResult] = useState<SyncResult | null>(initialSyncResult ?? null)
  const [loading, setLoading] = useState(false)
  const [rescanning, setRescanning] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [levelFilter, setLevelFilter] = useState<LogLevelFilter>('ALL')
  const [copied, setCopied] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchLogs = useCallback(async () => {
    if (!providerId) return
    setLoading(true)
    setError(null)
    try {
      let token = 'mock-token'
      if (authRef.current?.getAccessTokenSilently) {
        try {
          token = await authRef.current.getAccessTokenSilently()
        } catch {
          // fallback
        }
      }
      const data = await connectorsApi.getSyncLogs(token, providerId)
      setSyncResult(data)
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to retrieve sync logs')
    } finally {
      setLoading(false)
    }
  }, [providerId])

  useEffect(() => {
    if (isOpen) {
      if (initialSyncResult) {
        setSyncResult(initialSyncResult)
      } else {
        void fetchLogs()
      }
    }
  }, [isOpen, providerId, initialSyncResult, fetchLogs])

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose()
      }
    }
    if (isOpen) {
      window.addEventListener('keydown', handleKeyDown)
    }
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [isOpen, onClose])

  const handleRescan = async () => {
    setRescanning(true)
    setError(null)
    try {
      if (onRescan) {
        await onRescan()
        await fetchLogs()
      } else {
        let token = 'mock-token'
        if (authRef.current?.getAccessTokenSilently) {
          try {
            token = await authRef.current.getAccessTokenSilently()
          } catch {
            // fallback
          }
        }
        const data = await connectorsApi.triggerScan(token, providerId)
        setSyncResult(data)
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Rescan failed')
    } finally {
      setRescanning(false)
    }
  }

  const filteredLogs = useMemo(() => {
    if (!syncResult?.logs) return []
    return syncResult.logs.filter((log) => {
      if (levelFilter !== 'ALL' && log.level.toUpperCase() !== levelFilter) {
        return false
      }
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase()
        const matchMsg = log.message.toLowerCase().includes(q)
        const matchEndpoint = log.endpoint?.toLowerCase().includes(q)
        const matchDetails = log.details ? JSON.stringify(log.details).toLowerCase().includes(q) : false
        if (!matchMsg && !matchEndpoint && !matchDetails) return false
      }
      return true
    })
  }, [syncResult, levelFilter, searchQuery])

  const handleCopyLogs = async () => {
    if (!syncResult) return
    const header = `=== ${providerName} (${providerId}) Sync & Telemetry Logs ===\n` +
      `Synced: ${syncResult.synced_at} | Duration: ${syncResult.duration_ms}ms | Status: ${syncResult.status}\n` +
      `Records: Agents ${syncResult.records_scanned.agents}, Models ${syncResult.records_scanned.models}, Environments ${syncResult.records_scanned.environments}, Tools ${syncResult.records_scanned.tools}\n` +
      `Policies: Egress ${syncResult.policies_evaluated.egress_rules}, Violations ${syncResult.policies_evaluated.violations}\n` +
      `----------------------------------------------------------------------\n`

    const body = filteredLogs
      .map((l) => {
        let line = `[${l.timestamp}] [${l.level.toUpperCase()}] ${l.message}`
        if (isSuperadmin && l.endpoint) {
          line += `\n  Endpoint: ${l.endpoint} | Status: ${l.status_code ?? 200} | Latency: ${l.duration_ms ?? 0}ms`
          if (l.details) {
            line += `\n  Payload: ${JSON.stringify(l.details)}`
          }
        }
        return line
      })
      .join('\n')

    try {
      await navigator.clipboard.writeText(header + body)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      // clipboard access fallback
    }
  }

  if (!isOpen) return null

  const status = syncResult?.status ?? 'success'
  const statusColors = {
    success: { bg: 'rgba(45, 212, 191, 0.12)', text: 'var(--teal)', border: 'rgba(45, 212, 191, 0.3)' },
    warning: { bg: 'rgba(251, 191, 36, 0.12)', text: 'var(--warning)', border: 'rgba(251, 191, 36, 0.3)' },
    error: { bg: 'rgba(248, 113, 113, 0.12)', text: 'var(--error)', border: 'rgba(248, 113, 113, 0.3)' },
  }[status]

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.75)',
        backdropFilter: 'blur(4px)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 2000,
        padding: 16,
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div
        className="card slide-up"
        data-testid="sync-logs-modal"
        style={{
          width: 760,
          maxWidth: '100%',
          maxHeight: '92vh',
          display: 'flex',
          flexDirection: 'column',
          background: 'var(--surface, #1e293b)',
          borderRadius: 8,
          border: '1px solid var(--border, #334155)',
          boxShadow: '0 25px 50px -12px rgba(0, 0, 0, 0.5)',
          overflow: 'hidden',
        }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="sync-logs-title"
      >
        {/* Header */}
        <div
          style={{
            padding: '16px 20px',
            borderBottom: '1px solid var(--border, #334155)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            background: 'var(--surface2, #0f172a)',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <ProviderLogo providerId={providerId} displayName={providerName} size={36} />
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <h2 id="sync-logs-title" style={{ fontSize: 16, fontWeight: 700, margin: 0, color: 'var(--text, #f8fafc)' }}>
                  {providerName}
                </h2>
                <span
                  style={{
                    fontSize: 11,
                    fontWeight: 600,
                    textTransform: 'uppercase',
                    padding: '2px 8px',
                    borderRadius: 12,
                    background: statusColors.bg,
                    color: statusColors.text,
                    border: `1px solid ${statusColors.border}`,
                  }}
                >
                  {status === 'success' ? 'Success' : status === 'warning' ? 'Warning' : 'Error'}
                </span>
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted, #94a3b8)', marginTop: 2, display: 'flex', alignItems: 'center', gap: 8 }}>
                <span>Sync & Telemetry Logs</span>
                <span>•</span>
                <span>Last Synced: {syncResult ? formatTimeAgo(syncResult.synced_at) : '—'}</span>
                <span>•</span>
                <span>Duration: {syncResult ? `${syncResult.duration_ms} ms` : '—'}</span>
              </div>
            </div>
          </div>
          <button
            type="button"
            data-testid="btn-close-sync-logs"
            onClick={onClose}
            className="btn btn-secondary"
            style={{ padding: '6px 12px', fontSize: 13, lineHeight: 1 }}
            aria-label="Close sync logs"
          >
            ✕
          </button>
        </div>

        {/* Content body */}
        <div style={{ padding: '16px 20px', overflowY: 'auto', flex: 1, display: 'flex', flexDirection: 'column', gap: 16 }}>
          {error && (
            <div
              style={{
                padding: '10px 14px',
                borderRadius: 6,
                background: 'rgba(248, 113, 113, 0.15)',
                border: '1px solid rgba(248, 113, 113, 0.3)',
                color: 'var(--error, #f87171)',
                fontSize: 12,
              }}
            >
              {error}
            </div>
          )}

          {/* Summary statistics pills */}
          {syncResult && (
            <div
              style={{
                display: 'flex',
                flexWrap: 'wrap',
                gap: 8,
                padding: '10px 14px',
                background: 'var(--surface2, #0f172a)',
                borderRadius: 6,
                border: '1px solid var(--border, #334155)',
              }}
            >
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted, #94a3b8)', alignSelf: 'center', marginRight: 4 }}>
                SCANNED:
              </div>
              <span className="badge" style={{ fontSize: 11, padding: '3px 8px', background: 'var(--surface, #1e293b)', borderRadius: 4, border: '1px solid var(--border)' }}>
                Agents ({syncResult.records_scanned.agents})
              </span>
              <span className="badge" style={{ fontSize: 11, padding: '3px 8px', background: 'var(--surface, #1e293b)', borderRadius: 4, border: '1px solid var(--border)' }}>
                Models ({syncResult.records_scanned.models})
              </span>
              <span className="badge" style={{ fontSize: 11, padding: '3px 8px', background: 'var(--surface, #1e293b)', borderRadius: 4, border: '1px solid var(--border)' }}>
                Environments ({syncResult.records_scanned.environments})
              </span>
              <span className="badge" style={{ fontSize: 11, padding: '3px 8px', background: 'var(--surface, #1e293b)', borderRadius: 4, border: '1px solid var(--border)' }}>
                Tools ({syncResult.records_scanned.tools})
              </span>

              <div style={{ width: 1, background: 'var(--border)', margin: '0 4px' }} />

              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted, #94a3b8)', alignSelf: 'center', marginRight: 4 }}>
                CEL NETWORK RULES:
              </div>
              <span className="badge" style={{ fontSize: 11, padding: '3px 8px', background: 'var(--surface, #1e293b)', borderRadius: 4, border: '1px solid var(--border)' }}>
                Egress evaluated ({syncResult.policies_evaluated.egress_rules})
              </span>
              <span
                className="badge"
                style={{
                  fontSize: 11,
                  padding: '3px 8px',
                  background: syncResult.policies_evaluated.violations > 0 ? 'rgba(248, 113, 113, 0.15)' : 'var(--surface, #1e293b)',
                  color: syncResult.policies_evaluated.violations > 0 ? 'var(--error, #f87171)' : 'inherit',
                  borderRadius: 4,
                  border: '1px solid var(--border)',
                }}
              >
                Violations ({syncResult.policies_evaluated.violations})
              </span>
            </div>
          )}

          {/* Superadmin Advisory Banner */}
          {!isSuperadmin && (
            <div
              data-testid="superadmin-advisory-banner"
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                padding: '10px 14px',
                borderRadius: 6,
                background: 'rgba(56, 189, 248, 0.08)',
                border: '1px solid rgba(56, 189, 248, 0.25)',
                color: 'var(--cyan, #38bdf8)',
                fontSize: 12,
              }}
            >
              <span>🔒 Verbose wire traces, raw API payloads, and header telemetry are available in Superadmin mode.</span>
            </div>
          )}

          {/* Controls Bar: Search, Level Filter, Copy, Scan Now */}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flex: 1, minWidth: 260 }}>
              <input
                type="text"
                data-testid="sync-log-search"
                placeholder="Search logs, endpoints, messages..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                style={{
                  flex: 1,
                  padding: '6px 10px',
                  fontSize: 12,
                  borderRadius: 4,
                  background: 'var(--surface2, #0f172a)',
                  border: '1px solid var(--border, #334155)',
                  color: 'var(--text, #f8fafc)',
                  outline: 'none',
                }}
              />
              <select
                data-testid="sync-log-level-filter"
                value={levelFilter}
                onChange={(e) => setLevelFilter(e.target.value as LogLevelFilter)}
                style={{
                  padding: '6px 10px',
                  fontSize: 12,
                  borderRadius: 4,
                  background: 'var(--surface2, #0f172a)',
                  border: '1px solid var(--border, #334155)',
                  color: 'var(--text, #f8fafc)',
                  cursor: 'pointer',
                  outline: 'none',
                }}
              >
                <option value="ALL">ALL LEVELS</option>
                <option value="INFO">INFO</option>
                <option value="DEBUG">DEBUG</option>
                <option value="WARN">WARN</option>
                <option value="ERROR">ERROR</option>
              </select>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <button
                type="button"
                data-testid="btn-copy-sync-logs"
                className="btn btn-secondary btn-sm"
                onClick={handleCopyLogs}
                style={{ fontSize: 12, padding: '5px 12px' }}
              >
                {copied ? 'Copied!' : 'Copy Logs'}
              </button>
              <button
                type="button"
                data-testid="btn-modal-rescan"
                className="btn btn-primary btn-sm"
                onClick={handleRescan}
                disabled={loading || rescanning}
                style={{ fontSize: 12, padding: '5px 12px', minWidth: 84 }}
              >
                {rescanning ? 'Scanning...' : 'Scan Now'}
              </button>
            </div>
          </div>

          {/* Logs List Container */}
          <div
            style={{
              flex: 1,
              minHeight: 280,
              background: 'var(--surface2)',
              borderRadius: 6,
              border: '1px solid var(--border)',
              padding: 12,
              fontFamily: 'monospace',
              fontSize: 12,
              overflowY: 'auto',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            {loading ? (
              <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 24 }}>Loading sync telemetry...</div>
            ) : filteredLogs.length === 0 ? (
              <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 24 }}>
                No telemetry logs match the current filters.
              </div>
            ) : (
              filteredLogs.map((log) => {
                const badge = levelBadgeStyles[log.level] ?? levelBadgeStyles.info
                const hasWireDetails = isSuperadmin && (Boolean(log.endpoint) || Boolean(log.details))
                return (
                  <div
                    key={log.id}
                    style={{
                      padding: '8px 10px',
                      background: 'rgba(255, 255, 255, 0.02)',
                      borderRadius: 4,
                      border: '1px solid rgba(255, 255, 255, 0.05)',
                      display: 'flex',
                      flexDirection: 'column',
                      gap: 4,
                    }}
                  >
                    <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 8 }}>
                      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8, flex: 1 }}>
                        <span
                          style={{
                            fontSize: 10,
                            fontWeight: 700,
                            textTransform: 'uppercase',
                            padding: '1px 6px',
                            borderRadius: 3,
                            background: badge.bg,
                            color: badge.color,
                            border: `1px solid ${badge.border}`,
                            flexShrink: 0,
                            marginTop: 1,
                          }}
                        >
                          {log.level}
                        </span>
                        <span style={{ color: 'var(--text)', wordBreak: 'break-word', lineHeight: 1.4 }}>
                          {log.message}
                        </span>
                      </div>
                      <span style={{ color: 'var(--muted)', fontSize: 11, flexShrink: 0 }}>
                        {log.timestamp ? log.timestamp.split('T')[1]?.replace('Z', '') : ''}
                      </span>
                    </div>

                    {/* Wire trace details for Superadmin */}
                    {hasWireDetails && (
                      <div
                        style={{
                          marginTop: 4,
                          padding: '6px 8px',
                          background: 'rgba(0, 0, 0, 0.4)',
                          borderRadius: 4,
                          borderLeft: '2px solid var(--violet)',
                          display: 'flex',
                          flexDirection: 'column',
                          gap: 4,
                        }}
                      >
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 11 }}>
                          {log.endpoint && (
                            <span style={{ color: 'var(--cyan)', fontWeight: 600 }}>{log.endpoint}</span>
                          )}
                          {log.status_code && (
                            <span
                              style={{
                                color: log.status_code < 400 ? 'var(--teal)' : 'var(--error)',
                                fontWeight: 700,
                              }}
                            >
                              {log.status_code}
                            </span>
                          )}
                          {log.duration_ms != null && (
                            <span style={{ color: 'var(--muted)' }}>{log.duration_ms}ms</span>
                          )}
                        </div>

                        {log.details && (
                          <details
                            data-testid={`wire-trace-payload-${log.id}`}
                            style={{ marginTop: 2 }}
                          >
                            <summary
                              style={{
                                cursor: 'pointer',
                                color: 'var(--cyan)',
                                fontSize: 11,
                                outline: 'none',
                              }}
                            >
                              Inspect wire payload JSON
                            </summary>
                            <pre
                              style={{
                                margin: '6px 0 0 0',
                                padding: 8,
                                background: 'var(--surface)',
                                borderRadius: 4,
                                border: '1px solid var(--border)',
                                color: 'var(--text)',
                                fontSize: 11,
                                overflowX: 'auto',
                                whiteSpace: 'pre-wrap',
                                wordBreak: 'break-word',
                              }}
                            >
                              {JSON.stringify(log.details, null, 2)}
                            </pre>
                          </details>
                        )}
                      </div>
                    )}
                  </div>
                )
              })
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
