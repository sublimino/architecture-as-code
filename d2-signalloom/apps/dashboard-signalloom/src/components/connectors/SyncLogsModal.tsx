import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { connectorsApi, connectorErrorMessage, type SyncResult } from '../../api/connectorsClient'
import { useServerSuperadmin } from '../../auth/superadmin'
import { useAuth0 } from '../../auth/oidc'
import ProviderLogo from '../onboarding/ProviderLogo'
import ButtonWait from '../ButtonWait'
import LoadingState from '../LoadingState'

export interface SyncLogsModalProps {
  isOpen: boolean
  providerId: string
  providerName: string
  onClose: () => void
  onRescan?: () => Promise<void>
  initialSyncResult?: SyncResult
}

type LogLevelFilter = 'ALL' | 'INFO' | 'WARN' | 'ERROR' | 'DEBUG'

function formatTimeAgo(isoString: string): string {
  const diffMs = Date.now() - new Date(isoString).getTime()
  if (Number.isNaN(diffMs)) return isoString
  if (diffMs < 5000) return 'just now'
  const diffSec = Math.floor(diffMs / 1000)
  if (diffSec < 60) return `${diffSec}s ago`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}m ago`
  return `${Math.floor(diffMin / 60)}h ago`
}

// A null count means the scan did not observe that record type.
function count(n: number | null): string {
  return n == null ? 'not observed' : String(n)
}

const tone = {
  cyan: { bg: 'var(--cyan-bg)', color: 'var(--cyan)', border: 'var(--cyan-border)' },
  violet: { bg: 'var(--violet-bg)', color: 'var(--violet)', border: 'var(--violet-border)' },
  amber: { bg: 'var(--amber-bg)', color: 'var(--warning)', border: 'var(--amber-border)' },
  red: { bg: 'var(--red-bg)', color: 'var(--error)', border: 'var(--red-border)' },
  teal: { bg: 'var(--teal-bg)', color: 'var(--teal)', border: 'var(--teal-border)' },
}

const levelTone: Record<string, (typeof tone)[keyof typeof tone]> = {
  info: tone.cyan,
  debug: tone.violet,
  warn: tone.amber,
  error: tone.red,
}

const statusTone = { success: tone.teal, warning: tone.amber, error: tone.red }
const statusLabel = { success: 'Success', warning: 'Warning', error: 'Error' }

const pillStyle = {
  fontSize: 11,
  padding: '3px 8px',
  background: 'var(--surface)',
  borderRadius: 'var(--radius-sm)',
  border: '1px solid var(--border)',
}

export default function SyncLogsModal({
  isOpen,
  providerId,
  providerName,
  onClose,
  onRescan,
  initialSyncResult,
}: SyncLogsModalProps) {
  const { user, getAccessTokenSilently } = useAuth0()
  // Visibility only: the server also nulls wire fields for non-superadmins.
  const { superadmin: isSuperadmin } = useServerSuperadmin(
    user as Record<string, unknown> | null | undefined,
    getAccessTokenSilently,
  )
  const getTokenRef = useRef(getAccessTokenSilently)
  getTokenRef.current = getAccessTokenSilently

  const [syncResult, setSyncResult] = useState<SyncResult | null>(initialSyncResult ?? null)
  const [neverScanned, setNeverScanned] = useState(false)
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
      const token = await getTokenRef.current()
      const data = await connectorsApi.getSyncLogs(token, providerId)
      setSyncResult(data)
      setNeverScanned(data === null)
    } catch (err: unknown) {
      setError(connectorErrorMessage(err, 'Failed to retrieve sync logs.'))
    } finally {
      setLoading(false)
    }
  }, [providerId])

  useEffect(() => {
    if (!isOpen) return
    if (initialSyncResult) {
      setSyncResult(initialSyncResult)
      setNeverScanned(false)
    } else {
      void fetchLogs()
    }
  }, [isOpen, providerId, initialSyncResult, fetchLogs])

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    if (isOpen) window.addEventListener('keydown', handleKeyDown)
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
        const token = await getTokenRef.current()
        const data = await connectorsApi.triggerScan(token, providerId)
        setSyncResult(data)
        setNeverScanned(false)
      }
    } catch (err: unknown) {
      setError(connectorErrorMessage(err, 'Rescan failed.'))
    } finally {
      setRescanning(false)
    }
  }

  const filteredLogs = useMemo(() => {
    if (!syncResult?.logs) return []
    return syncResult.logs.filter((log) => {
      if (levelFilter !== 'ALL' && log.level.toUpperCase() !== levelFilter) return false
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
    const r = syncResult.records_scanned
    const p = syncResult.policies_evaluated
    const header =
      `=== ${providerName} (${providerId}) Sync & Telemetry Logs ===\n` +
      `Synced: ${syncResult.synced_at} | Duration: ${syncResult.duration_ms}ms | Status: ${syncResult.status}\n` +
      `Records: Agents ${count(r.agents)}, Models ${count(r.models)}, Environments ${count(r.environments)}, Tools ${count(r.tools)}\n` +
      `Policies: ${p ? `Egress ${p.egress_rules}, Violations ${p.violations}` : 'none evaluated'}\n` +
      `----------------------------------------------------------------------\n`

    const body = filteredLogs
      .map((l) => {
        let line = `[${l.timestamp}] [${l.level.toUpperCase()}] ${l.message}`
        if (isSuperadmin && l.endpoint) {
          line += `\n  Endpoint: ${l.endpoint} | Status: ${l.status_code ?? 'n/a'} | Latency: ${l.duration_ms ?? 'n/a'}ms`
          if (l.details) line += `\n  Payload: ${JSON.stringify(l.details)}`
        }
        return line
      })
      .join('\n')

    try {
      await navigator.clipboard.writeText(header + body)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      setError('Could not copy to the clipboard.')
    }
  }

  if (!isOpen) return null

  const status = syncResult?.status
  const badge = status ? statusTone[status] : null

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
          background: 'var(--surface)',
          borderRadius: 'var(--radius)',
          border: '1px solid var(--border)',
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
            borderBottom: '1px solid var(--border)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            background: 'var(--surface2)',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <ProviderLogo providerId={providerId} displayName={providerName} size={36} />
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <h2 id="sync-logs-title" style={{ fontSize: 16, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                  {providerName}
                </h2>
                {status && badge && (
                  <span
                    data-testid="sync-status-badge"
                    style={{
                      fontSize: 11,
                      fontWeight: 600,
                      textTransform: 'uppercase',
                      padding: '2px 8px',
                      borderRadius: 'var(--radius)',
                      background: badge.bg,
                      color: badge.color,
                      border: `1px solid ${badge.border}`,
                    }}
                  >
                    {statusLabel[status]}
                  </span>
                )}
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2, display: 'flex', alignItems: 'center', gap: 8 }}>
                <span>Sync & Telemetry Logs</span>
                <span>•</span>
                <span>Last Synced: {syncResult ? formatTimeAgo(syncResult.synced_at) : 'Never'}</span>
                <span>•</span>
                <span>Duration: {syncResult ? `${syncResult.duration_ms} ms` : '-'}</span>
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
              role="alert"
              data-testid="sync-logs-error"
              style={{
                padding: '10px 14px',
                borderRadius: 'var(--radius-sm)',
                background: 'var(--red-bg)',
                border: '1px solid var(--red-border)',
                color: 'var(--error)',
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
                background: 'var(--surface2)',
                borderRadius: 'var(--radius-sm)',
                border: '1px solid var(--border)',
              }}
            >
              <div className="label" style={{ color: 'var(--muted)', alignSelf: 'center', marginRight: 4 }}>
                Scanned:
              </div>
              <span className="badge" style={pillStyle}>Agents ({count(syncResult.records_scanned.agents)})</span>
              <span className="badge" style={pillStyle}>Models ({count(syncResult.records_scanned.models)})</span>
              <span className="badge" style={pillStyle}>Environments ({count(syncResult.records_scanned.environments)})</span>
              <span className="badge" style={pillStyle}>Tools ({count(syncResult.records_scanned.tools)})</span>

              <div style={{ width: 1, background: 'var(--border)', margin: '0 4px' }} />

              <div className="label" style={{ color: 'var(--muted)', alignSelf: 'center', marginRight: 4 }}>
                Cel network rules:
              </div>
              {syncResult.policies_evaluated ? (
                <>
                  <span className="badge" style={pillStyle}>
                    Egress evaluated ({syncResult.policies_evaluated.egress_rules})
                  </span>
                  <span
                    className="badge"
                    style={{
                      ...pillStyle,
                      ...(syncResult.policies_evaluated.violations > 0
                        ? { background: 'var(--red-bg)', color: 'var(--error)' }
                        : {}),
                    }}
                  >
                    Violations ({syncResult.policies_evaluated.violations})
                  </span>
                </>
              ) : (
                <span className="badge" style={{ ...pillStyle, color: 'var(--muted)' }}>
                  No policies evaluated by this scan
                </span>
              )}
            </div>
          )}

          {neverScanned && !loading && (
            <div
              data-testid="sync-logs-never-scanned"
              style={{
                padding: '10px 14px',
                borderRadius: 'var(--radius-sm)',
                background: 'var(--surface2)',
                border: '1px dashed var(--border-subtle)',
                color: 'var(--muted)',
                fontSize: 12,
              }}
            >
              This connector has not been scanned yet. Use Scan Now to run the first scan.
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
                borderRadius: 'var(--radius-sm)',
                background: 'var(--cyan-bg)',
                border: '1px solid var(--cyan-border)',
                color: 'var(--cyan)',
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
                placeholder="Search logs, endpoints, messages…"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                style={{
                  flex: 1,
                  padding: '6px 10px',
                  fontSize: 12,
                  borderRadius: 'var(--radius-sm)',
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  color: 'var(--text)',
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
                  borderRadius: 'var(--radius-sm)',
                  background: 'var(--surface2)',
                  border: '1px solid var(--border)',
                  color: 'var(--text)',
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
                disabled={!syncResult}
              >
                {copied ? 'Copied!' : 'Copy Logs'}
              </button>
              <button
                type="button"
                data-testid="btn-modal-rescan"
                className="btn btn-primary btn-sm"
                onClick={handleRescan}
                disabled={loading || rescanning}
                aria-busy={rescanning}
                style={{ minWidth: 84, justifyContent: 'center' }}
              >
                {/* The shared in-button wait, not a bespoke "Scanning…" word. See ButtonWait. */}
                {rescanning
                  ? <ButtonWait testId="sync-logs-rescan-wait" label="Scanning" />
                  : 'Scan Now'}
              </button>
            </div>
          </div>

          {/* Logs List Container */}
          <div
            style={{
              flex: 1,
              minHeight: 280,
              background: 'var(--surface2)',
              borderRadius: 'var(--radius-sm)',
              border: '1px solid var(--border)',
              padding: 12,
              fontSize: 12,
              overflowY: 'auto',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
            className="mono"
          >
            {loading ? (
              <LoadingState variant="block" status="loading" label="sync telemetry" testId="sync-logs-loading" />
            ) : !syncResult ? (
              <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 24 }}>No scan logs to show.</div>
            ) : filteredLogs.length === 0 ? (
              <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 24 }}>
                No telemetry logs match the current filters.
              </div>
            ) : (
              filteredLogs.map((log) => {
                const lt = levelTone[log.level] ?? levelTone.info
                const hasWireDetails = isSuperadmin && (Boolean(log.endpoint) || Boolean(log.details))
                return (
                  <div
                    key={log.id}
                    style={{
                      padding: '8px 10px',
                      background: 'var(--surface)',
                      borderRadius: 'var(--radius-sm)',
                      border: '1px solid var(--border)',
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
                            borderRadius: 'var(--radius-sm)',
                            background: lt.bg,
                            color: lt.color,
                            border: `1px solid ${lt.border}`,
                            flexShrink: 0,
                            marginTop: 1,
                          }}
                        >
                          {log.level}
                        </span>
                        <span style={{ color: 'var(--text)', wordBreak: 'break-word', lineHeight: 1.4 }}>{log.message}</span>
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
                          background: 'var(--surface2)',
                          borderRadius: 'var(--radius-sm)',
                          borderLeft: '2px solid var(--violet)',
                          display: 'flex',
                          flexDirection: 'column',
                          gap: 4,
                        }}
                      >
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 11 }}>
                          {log.endpoint && <span style={{ color: 'var(--cyan)', fontWeight: 600 }}>{log.endpoint}</span>}
                          {log.status_code != null && (
                            <span style={{ color: log.status_code < 400 ? 'var(--teal)' : 'var(--error)', fontWeight: 700 }}>
                              {log.status_code}
                            </span>
                          )}
                          {log.duration_ms != null && <span style={{ color: 'var(--muted)' }}>{log.duration_ms}ms</span>}
                        </div>

                        {log.details && (
                          <details data-testid={`wire-trace-payload-${log.id}`} style={{ marginTop: 2 }}>
                            <summary style={{ cursor: 'pointer', color: 'var(--cyan)', fontSize: 11, outline: 'none' }}>
                              Inspect wire payload JSON
                            </summary>
                            <pre
                              style={{
                                margin: '6px 0 0 0',
                                padding: 8,
                                background: 'var(--surface)',
                                borderRadius: 'var(--radius-sm)',
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
