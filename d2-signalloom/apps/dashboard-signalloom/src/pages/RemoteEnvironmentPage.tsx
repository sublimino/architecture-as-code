import { useState, useEffect, useCallback, useRef } from 'react'
import type { ReactNode } from 'react'
import { useParams, Link, useSearchParams } from 'react-router-dom'
import {
  connectorsApi,
  connectorErrorMessage,
  demoRemoteEnvironment,
  isRemoteEnvironmentProvider,
  type RemoteAgent,
  type SyncResult,
} from '../api/connectorsClient'
import { syncModeLabel, useRemoteAgents, type StreamConnection } from '../hooks/useConnectorStream'
import type { RemoteEnvironmentFixture } from '../api/fakeData'
import { useAuth0 } from '../auth/oidc'
import type { TenantConnector } from '../types/connectors'
import SyncLogsModal from '../components/connectors/SyncLogsModal'
import SyncStatusPill, { type SyncTone } from '../components/connectors/SyncStatusPill'
import ButtonWait from '../components/ButtonWait'
import LoadingState from '../components/LoadingState'
import NotFoundPage from './NotFoundPage'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'

// Remote environment console for an AI provider connector.
//
// Demo mode renders the fixture in api/fakeData.ts. Live mode renders only
// what the connectors API returns: the tenant's connector record and its last
// SyncResult. The API returns no credit balance, egress configuration, policy
// results or agent identities, so live mode says so rather than inventing them.

// radius 6 has no token (global.css declares only --radius 8px and
// --radius-sm 4px); --radius-sm is the closer of the two (design-system
// audit, rule 4).
const tileStyle = { padding: 14, background: 'var(--surface2)', borderRadius: 'var(--radius-sm)', border: '1px solid var(--border)' }
const tileLabel = { fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase' as const, letterSpacing: '0.06em', marginBottom: 4 }
// background/border/borderRadius are deliberately absent: they duplicated
// .card (rule 16) and are applied together with className="card" at every
// call site. padding/marginBottom are a genuine override of .card's 20px
// default and stay.
const cardStyle = { padding: 22, marginBottom: 20 }

let sectionCounter = 0

/**
 * A single accessible disclosure: the whole header is one <button
 * aria-expanded>, not a <div onClick> wrapping a second, non-functional
 * <button> (the audit's R2 — the inner button had no onClick of its own and
 * only "worked" because the click bubbled up from the div, so it did nothing
 * for a screen-reader or keyboard user who activates it directly).
 */
function Section({
  title,
  subtitle,
  testId,
  /** When set, wires this Section as the ARIA tabpanel for `env-tab-{tabId}`. */
  tabId,
  children,
}: {
  title: string
  subtitle: string
  testId?: string
  tabId?: string
  children: ReactNode
}) {
  const [collapsed, setCollapsed] = useState(false)
  const [panelId] = useState(() => `env-section-panel-${(sectionCounter += 1)}`)
  const tabPanelProps = tabId
    ? { role: 'tabpanel' as const, id: `env-tabpanel-${tabId}`, 'aria-labelledby': `env-tab-${tabId}` }
    : null
  return (
    <section className="card" data-testid={testId} style={cardStyle} {...tabPanelProps}>
      <button
        type="button"
        aria-expanded={!collapsed}
        aria-controls={panelId}
        aria-label={`Toggle ${title} Section`}
        onClick={() => setCollapsed((c) => !c)}
        className="btn-static"
        style={{
          display: 'flex',
          width: '100%',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          marginBottom: 16,
          background: 'none',
          border: 'none',
          padding: 0,
          cursor: 'pointer',
          textAlign: 'left',
          font: 'inherit',
          color: 'inherit',
        }}
      >
        <div>
          <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>{title}</h2>
          <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>{subtitle}</p>
        </div>
        <span aria-hidden="true" style={{ color: 'var(--muted)', fontSize: 14, flexShrink: 0 }}>
          {collapsed ? '▶' : '▼'}
        </span>
      </button>
      {!collapsed && <div id={panelId}>{children}</div>}
    </section>
  )
}

function Tile({ label, children, testId }: { label: string; children: ReactNode; testId?: string }) {
  return (
    <div style={tileStyle} data-testid={testId}>
      <div style={tileLabel}>{label}</div>
      <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>{children}</div>
    </div>
  )
}

function Breadcrumb({ label }: { label: string }) {
  return (
    <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--muted)', marginBottom: 16 }}>
      <Link to="/settings" style={{ color: 'var(--muted)', textDecoration: 'none' }}>
        Settings
      </Link>
      <span>/</span>
      <Link to="/settings?tab=connectors" data-testid="link-back-connectors" style={{ color: 'var(--muted)', textDecoration: 'none' }}>
        Connectors
      </Link>
      <span>/</span>
      <span style={{ color: 'var(--text)', fontWeight: 600 }}>{label}</span>
    </nav>
  )
}

// Design-system audit rule 11: --error on --red-bg measures 3.02-3.39:1
// across themes, below the 4.5:1 AA floor for this text size. The message
// goes in --text (13.98:1 worst case, per LoadingState.tsx's own
// measurement); the red tint is carried by the border instead, which only
// owes 3:1 as non-text UI.
const errorBannerStyle = {
  background: 'var(--red-bg)',
  border: '1px solid var(--red-border)',
  borderLeft: '3px solid var(--error)',
  color: 'var(--text)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 12,
}

function ErrorBanner({ message }: { message: string }) {
  return (
    <div role="alert" style={{ ...errorBannerStyle, padding: '10px 14px', marginBottom: 16 }}>
      {message}
    </div>
  )
}

function fmtTs(iso: string | null | undefined): string {
  if (!iso) return 'Never'
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString()
}

function count(n: number | null | undefined): string {
  return n == null ? 'not observed' : String(n)
}

function scanResultTone(status: SyncResult['status'] | undefined): SyncTone {
  if (status === 'success') return 'teal'
  if (status === 'warning') return 'amber'
  if (status === 'error') return 'red'
  return 'muted'
}

export default function RemoteEnvironmentPage() {
  const { providerId } = useParams<{ providerId: string }>()
  const id = providerId?.toLowerCase()
  // Re-render when the demo toggle flips. The two modes are different view
  // components, so a flip unmounts one and mounts the other: no connector,
  // scan or agent state carries across.
  const [, setDemo] = useState(isDemoMode)
  useEffect(() => subscribeDemoMode(setDemo), [])
  if (!isRemoteEnvironmentProvider(id)) {
    return (
      <div data-testid="remote-env-not-found">
        <NotFoundPage />
      </div>
    )
  }
  const demoEnv = demoRemoteEnvironment(id)
  return demoEnv ? <DemoEnvironmentView providerId={id} env={demoEnv} /> : <LiveEnvironmentView providerId={id} />

}

function LiveEnvironmentView({ providerId }: { providerId: string }) {
  const { getAccessTokenSilently } = useAuth0()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [providerName, setProviderName] = useState(providerId)
  const [connector, setConnector] = useState<TenantConnector | null>(null)
  const [syncResult, setSyncResult] = useState<SyncResult | null>(null)
  const [syncing, setSyncing] = useState(false)
  const [showLogs, setShowLogs] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      const [providers, connectors, logs] = await Promise.all([
        connectorsApi.listProviders(token),
        connectorsApi.listConnectors(token),
        connectorsApi.getSyncLogs(token, providerId),
      ])
      setProviderName(providers.find((p) => p.provider_id === providerId)?.display_name ?? providerId)
      setConnector(connectors.find((c) => c.provider_id === providerId && c.status !== 'disconnected') ?? null)
      setSyncResult(logs)
    } catch (err) {
      setError(connectorErrorMessage(err, 'Could not load this connector.'))
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently, providerId])

  useEffect(() => {
    void load()
  }, [load])

  // rethrow: the logs modal's rescan must reject on failure so the modal shows
  // the error rather than re-listing old logs as if the scan had worked.
  const handleSyncNow = async (rethrow = false) => {
    setSyncing(true)
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      setSyncResult(await connectorsApi.triggerScan(token, providerId))
    } catch (err) {
      setError(connectorErrorMessage(err, 'Scan failed.'))
      if (rethrow) throw err
    } finally {
      setSyncing(false)
    }
  }

  return (
    <div className="fade-in" data-testid="remote-environment-page" style={{ maxWidth: 1200, margin: '0 auto' }}>
      <Breadcrumb label={providerName} />
      {error && <ErrorBanner message={error} />}
      {loading ? (
        <LoadingState variant="block" status="loading" label="connector" testId="live-page-loading" />
      ) : error && !connector && !syncResult ? null : !connector ? (
        <div className="card" data-testid="live-not-connected" style={cardStyle}>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--text)' }}>
            {providerName} is not connected for your tenant.{' '}
            <Link to={`/settings?tab=connectors&configure=${providerId}`}>Configure it in Connectors</Link>.
          </p>
        </div>
      ) : (
        <>
          <div className="card" style={{ ...cardStyle, padding: 24, marginBottom: 24 }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 20, flexWrap: 'wrap' }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 10 }}>
                  <h1 data-testid="env-title" style={{ fontSize: 22, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                    {connector.display_name ?? providerName}
                  </h1>
                  <SyncStatusPill tone={connector.status === 'connected' ? 'teal' : 'red'} label={connector.status} />
                  <SyncStatusPill
                    testId="live-scan-status"
                    tone={scanResultTone(syncResult?.status)}
                    label={syncResult ? `Last scan: ${syncResult.status}` : 'Not yet scanned'}
                  />
                </div>
                <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
                  <span>Provider: {providerName}</span>
                  <span>•</span>
                  <span className="mono">Connector ID: {connector.connector_id}</span>
                  <span>•</span>
                  <span>Last scanned: {fmtTs(syncResult?.synced_at)}</span>
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                <button type="button" className="btn btn-secondary btn-sm" data-testid="btn-env-sync-logs" onClick={() => setShowLogs(true)}>
                  Sync Logs
                </button>
                <button
                  type="button"
                  className="btn btn-primary btn-sm"
                  data-testid="btn-env-sync-now"
                  onClick={() => void handleSyncNow()}
                  disabled={syncing}
                  aria-busy={syncing}
                  style={{ minWidth: 96, justifyContent: 'center' }}
                >
                  {/* The shared in-button wait, not a bespoke "Scanning…" word. See ButtonWait. */}
                  {syncing
                    ? <ButtonWait testId="env-sync-now-wait" label="Scanning" />
                    : 'Sync Now'}
                </button>
                <Link to="/settings?tab=connectors" className="btn btn-secondary btn-sm" style={{ textDecoration: 'none' }}>
                  Back to Connectors
                </Link>
              </div>
            </div>
          </div>

          <Section title="Last scan" subtitle="What the most recent scan of this connector observed.">
            {syncResult ? (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12 }}>
                <Tile label="Agents" testId="live-records-agents">{count(syncResult.records_scanned.agents)}</Tile>
                <Tile label="Models" testId="live-records-models">{count(syncResult.records_scanned.models)}</Tile>
                <Tile label="Environments">{count(syncResult.records_scanned.environments)}</Tile>
                <Tile label="Tools">{count(syncResult.records_scanned.tools)}</Tile>
                <Tile label="Policies">
                  {syncResult.policies_evaluated
                    ? `${syncResult.policies_evaluated.egress_rules} evaluated, ${syncResult.policies_evaluated.violations} violations`
                    : 'None evaluated'}
                </Tile>
                <Tile label="Duration">{syncResult.duration_ms} ms</Tile>
              </div>
            ) : (
              <p data-testid="live-last-scan-empty" style={{ margin: 0, fontSize: 13, color: 'var(--muted)' }}>
                Not yet scanned. Use Sync Now to run the first scan.
              </p>
            )}
          </Section>

          <Section title="Connector" subtitle="The connector record as stored for your tenant.">
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 12, marginBottom: 12 }}>
              <Tile label="Created">{fmtTs(connector.created_at)}</Tile>
              <Tile label="Last tested">{fmtTs(connector.last_tested_at)}</Tile>
              <Tile label="Credential expires">{connector.credential_expires_at ? fmtTs(connector.credential_expires_at) : 'Not reported'}</Tile>
            </div>
            <pre className="mono" style={{ ...tileStyle, margin: 0, fontSize: 12, color: 'var(--text)', overflowX: 'auto' }}>
              {JSON.stringify(connector.metadata, null, 2)}
            </pre>
          </Section>

          <Section title="Environment & governance" subtitle="Hosting, credits, network egress and CEL policy results.">
            <p data-testid="live-env-not-available" style={{ margin: 0, fontSize: 13, color: 'var(--muted)' }}>
              Credit balance, network egress configuration and CEL policy results are not available from this provider through
              the connectors API, so none are shown.
            </p>
          </Section>

          <Section title="Connected Agents & Workloads" subtitle="Remote agents and sessions as the provider reports them, updated live.">
            <RemoteAgentsPanel providerId={providerId} />
          </Section>
        </>
      )}
      {showLogs && (
        <SyncLogsModal
          isOpen
          providerId={providerId}
          providerName={providerName}
          onClose={() => setShowLogs(false)}
          onRescan={() => handleSyncNow(true)}
        />
      )}
    </div>
  )
}

function connectionLabel(c: StreamConnection): string {
  switch (c.status) {
    case 'open':
      return 'Live updates connected'
    case 'connecting':
      return 'Connecting to live updates…'
    case 'reconnecting':
      return `Connection lost, reconnecting in ${Math.ceil((c.retryInMs ?? 0) / 1000)} s${c.error ? ` (${c.error})` : ''}`
    case 'demo':
      return 'Demo data'
    default:
      return 'Live updates not connected'
  }
}

function agentTone(a: RemoteAgent): SyncTone {
  if (a.gone_at) return 'muted'
  const s = (a.status ?? '').toLowerCase()
  if (['running', 'active', 'busy'].includes(s)) return 'teal'
  if (['error', 'failed', 'errored'].includes(s)) return 'red'
  if (['idle', 'terminated', 'stopped', 'archived', ''].includes(s)) return 'muted'
  return 'cyan'
}

const agentLabel = (a: RemoteAgent) => a.name ?? a.external_id

/** Polite announcements for changes after the first load: never for the initial list. */
function useChangeAnnouncement(agents: RemoteAgent[], ready: boolean): string {
  const prev = useRef<Map<string, RemoteAgent> | null>(null)
  const [message, setMessage] = useState('')
  useEffect(() => {
    if (!ready) return
    const before = prev.current
    prev.current = new Map(agents.map((a) => [a.external_id, a]))
    if (!before) return
    const changes: string[] = []
    for (const a of agents) {
      const was = before.get(a.external_id)
      if (!was) changes.push(`${agentLabel(a)} appeared`)
      else if (a.gone_at && !was.gone_at) changes.push(`${agentLabel(a)} is gone`)
      else if (a.status !== was.status) changes.push(`${agentLabel(a)} is now ${a.status ?? 'unknown'}`)
    }
    // Keep the last few so changes landing in consecutive renders are all read.
    if (changes.length) setMessage((m) => [...(m ? m.split('. ') : []), ...changes].slice(-3).join('. '))
  }, [agents, ready])
  return message
}

function RemoteAgentsPanel({ providerId }: { providerId: string }) {
  const { view, connection } = useRemoteAgents(providerId)
  const announcement = useChangeAnnouncement(view.agents, view.status === 'ready')
  const sync = view.syncState
  const connTone: SyncTone = connection.status === 'open' ? 'teal' : connection.status === 'reconnecting' ? 'amber' : 'muted'
  return (
    <div data-testid="remote-agents-panel">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 12, fontSize: 12 }}>
        <SyncStatusPill testId="stream-connection" role="status" ariaLive="polite" tone={connTone} label={connectionLabel(connection)} />
        {sync && (
          <span data-testid="remote-sync-state" style={{ color: 'var(--muted)' }}>
            {syncModeLabel(sync)} • {sync.last_success_at ? `Last synced ${fmtTs(sync.last_success_at)}` : 'Never synced'}
            {sync.mode === 'poll' && sync.next_poll_at ? ` • Next poll ${fmtTs(sync.next_poll_at)}` : ''}
          </span>
        )}
      </div>
      {sync?.last_error && (
        <div data-testid="remote-sync-error" style={{ ...errorBannerStyle, padding: '8px 12px', marginBottom: 12 }}>
          Last sync error: {sync.last_error}
        </div>
      )}
      <div className="sr-only" aria-live="polite" data-testid="remote-agents-announcer">
        {announcement}
      </div>
      {view.status === 'loading' ? (
        <p style={{ margin: 0, fontSize: 13, color: 'var(--muted)' }}>Loading remote agents…</p>
      ) : view.status === 'not_configured' ? (
        <p data-testid="remote-agents-not-configured" style={{ margin: 0, fontSize: 13, color: 'var(--muted)' }}>
          The connectors API reports no configured connector for this provider, so there is no remote runtime state to show.
        </p>
      ) : (
        <>
          {view.status === 'error' && (
            <div role="alert" data-testid="remote-agents-error" style={{ ...errorBannerStyle, padding: '8px 12px', marginBottom: 12 }}>
              {view.error}
            </div>
          )}
          {view.agents.length === 0 && view.status === 'ready' ? (
            <p data-testid="remote-agents-empty" style={{ margin: 0, fontSize: 13, color: 'var(--muted)' }}>
              The provider reports no agents or sessions for this connector.
            </p>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {view.agents.map((a) => (
                <div
                  key={a.external_id}
                  data-testid={`remote-agent-${a.external_id}`}
                  data-gone={a.gone_at ? 'true' : 'false'}
                  style={{ ...tileStyle, padding: '10px 14px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', opacity: a.gone_at ? 0.7 : 1 }}
                >
                  <div style={{ minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)' }}>{agentLabel(a)}</span>
                      <SyncStatusPill tone="muted" label={a.kind} style={{ fontSize: 11 }} />
                      {a.model && <span className="mono" style={{ fontSize: 11, color: 'var(--text)' }}>{a.model}</span>}
                    </div>
                    <div className="mono" style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 4 }}>
                      {a.external_id}
                      {a.version != null && ` • v${a.version}`}
                      {` • Last seen ${fmtTs(a.last_seen_at)}`}
                    </div>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <SyncStatusPill
                      tone={agentTone(a)}
                      label={a.gone_at ? `Gone ${fmtTs(a.gone_at)}` : a.status ?? 'status not reported'}
                      style={{ whiteSpace: 'nowrap' }}
                    />
                    {a.claimed_agent_id ? (
                      // Claimed into the tenant registry (POST .../claim): link to that agent.
                      <Link
                        to={`/agents?selected=${encodeURIComponent(a.claimed_agent_id)}`}
                        className="btn btn-secondary btn-sm"
                        data-testid={`remote-claimed-link-${a.external_id}`}
                        title="Open the registry agent this was claimed as"
                        style={{ textDecoration: 'none', color: 'var(--teal)' }}
                      >
                        Claimed →
                      </Link>
                    ) : a.external_id && (
                      // Claiming happens in Discovery; this page only links there.
                      <Link
                        to={`/discovery?provider=${encodeURIComponent(providerId)}&selected=${encodeURIComponent(a.external_id)}`}
                        className="btn btn-secondary btn-sm"
                        data-testid={`claim-in-discovery-${a.external_id}`}
                        style={{ textDecoration: 'none' }}
                      >
                        Claim in Discovery
                      </Link>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}

const ENV_TABS = ['all', 'general', 'network', 'packages', 'agents'] as const
type EnvTabId = (typeof ENV_TABS)[number]

function parseTab(value: string | null): EnvTabId {
  const t = (value ?? 'all').toLowerCase()
  return (ENV_TABS as readonly string[]).includes(t) ? (t as EnvTabId) : 'all'
}

function DemoEnvironmentView({ providerId, env }: { providerId: string; env: RemoteEnvironmentFixture }) {
  const { getAccessTokenSilently } = useAuth0()
  // The ?tab= query parameter is the source of truth, so a tab can be linked to.
  const [searchParams, setSearchParams] = useSearchParams()
  const activeTab = parseTab(searchParams.get('tab'))
  const setActiveTab = (tab: EnvTabId) =>
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        if (tab === 'all') next.delete('tab')
        else next.set('tab', tab)
        return next
      },
      { replace: true },
    )
  const [syncStatus, setSyncStatus] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [showLogs, setShowLogs] = useState(false)
  const [claimedAgents, setClaimedAgents] = useState<Record<string, boolean>>({})
  const passing = env.celPolicies.filter((p) => p.status === 'PASS').length

  const handleSyncNow = async (rethrow = false) => {
    setError(null)
    try {
      const token = await getAccessTokenSilently()
      await connectorsApi.triggerScan(token, providerId)
      setSyncStatus('Synchronized just now')
    } catch (err) {
      setError(connectorErrorMessage(err, 'Scan failed.'))
      if (rethrow) throw err
    }
  }

  const show = (tab: typeof activeTab) => activeTab === 'all' || activeTab === tab

  return (
    <div className="fade-in" data-testid="remote-environment-page" style={{ maxWidth: 1200, margin: '0 auto' }}>
      <Breadcrumb label={`${env.providerName} (${env.envName})`} />
      {error && <ErrorBanner message={error} />}

      <div className="card" style={{ ...cardStyle, padding: 24, marginBottom: 24 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 20, flexWrap: 'wrap' }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 10 }}>
              <h1 data-testid="env-title" style={{ fontSize: 22, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                {env.envName}
              </h1>
              <SyncStatusPill role="status" ariaLive="polite" tone="teal" label={syncStatus || env.status} />
              <SyncStatusPill testId="env-credit-balance" tone="cyan" label={env.creditBalance} />
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
              <span>
                <strong>Hosting:</strong> {env.hosting} Hosting
              </span>
              <span>•</span>
              <span>Organization: {env.orgName}</span>
              <span>•</span>
              <span data-testid="env-badge-id" className="mono">
                ID: {env.envId}
              </span>
              <span>•</span>
              <span>Last updated: {env.lastUpdated}</span>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <button type="button" className="btn btn-secondary btn-sm" data-testid="btn-env-sync-logs" onClick={() => setShowLogs(true)}>
              Sync Logs
            </button>
            <button type="button" className="btn btn-primary btn-sm" data-testid="btn-env-sync-now" onClick={() => void handleSyncNow()}>
              Sync Now
            </button>
            <Link to="/settings?tab=connectors" className="btn btn-secondary btn-sm" style={{ textDecoration: 'none' }}>
              Back to Connectors
            </Link>
          </div>
        </div>
      </div>

      <div role="tablist" aria-label="Environment sections" style={{ display: 'flex', gap: 8, marginBottom: 20, borderBottom: '1px solid var(--border)', paddingBottom: 8 }}>
        {[
          { id: 'all', label: 'All Sections' },
          { id: 'general', label: 'General' },
          { id: 'network', label: 'Network Egress & CEL Governance' },
          { id: 'packages', label: 'Container Packages & Metadata' },
          { id: 'agents', label: 'Connected Agents & Workloads' },
        ].map((tab) => (
          <button
            key={tab.id}
            id={`env-tab-${tab.id}`}
            role="tab"
            data-testid={`env-tab-${tab.id}`}
            aria-selected={activeTab === tab.id}
            // "all" shows every section at once rather than a single panel,
            // so it has no one tabpanel to point at.
            aria-controls={tab.id === 'all' ? undefined : `env-tabpanel-${tab.id}`}
            onClick={() => setActiveTab(tab.id as EnvTabId)}
            style={{
              background: 'none',
              border: 'none',
              padding: '6px 14px',
              fontSize: 13,
              fontWeight: activeTab === tab.id ? 600 : 500,
              color: activeTab === tab.id ? 'var(--text)' : 'var(--muted)',
              cursor: 'pointer',
              borderBottom: activeTab === tab.id ? '2px solid var(--cyan)' : '2px solid transparent',
              marginBottom: -9,
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {show('general') && (
        <Section title="General" subtitle="What this environment is, and where it runs." tabId="general">
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 16 }}>
            <Tile label="Hosting">
              {env.hosting}
              <div style={{ fontSize: 11.5, fontWeight: 400, color: 'var(--muted)', marginTop: 4 }}>{env.hostingNote}</div>
            </Tile>
            <Tile label="Name">{env.envName}</Tile>
            <Tile label="Description">{env.description}</Tile>
            <Tile label="Workspace / Org ID">
              <span className="mono">{env.workspaceId}</span>
            </Tile>
          </div>
        </Section>
      )}

      {show('network') && (
        <Section title="Network Egress & CEL Governance" subtitle="What the container can reach over the network and CEL policy conformance." testId="network-egress-section" tabId="network">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
            <Tile label="Outbound Policy">{env.outboundPolicy}</Tile>
            <div style={tileStyle}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>Allowed hosts</span>
                <span data-testid="allowed-hosts-list" style={{ fontSize: 12, fontWeight: 600, color: 'var(--cyan)' }}>
                  {env.allowedHosts.length}/{env.maxAllowedHosts} configured
                </span>
              </div>
              {env.allowedHosts.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--muted)' }}>No explicit host overrides.</div>
              ) : (
                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                  {env.allowedHosts.map((h) => (
                    <span key={h} className="mono" style={{ fontSize: 12 }}>
                      {h}
                    </span>
                  ))}
                </div>
              )}
            </div>
            <div data-testid="cel-policy-card" style={{ ...tileStyle, border: '1px solid var(--teal-border)' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
                <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--text)' }}>CEL Policy Assessment (Signal Loom Governance Engine)</div>
                <SyncStatusPill
                  tone={passing === env.celPolicies.length ? 'teal' : 'red'}
                  label={`${passing} / ${env.celPolicies.length} POLICIES PASS`}
                  style={{ fontSize: 11 }}
                />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {env.celPolicies.map((pol) => (
                  <div
                    key={pol.id}
                    style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, padding: '10px 12px', background: 'var(--surface)', borderRadius: 5, border: '1px solid var(--border)' }}
                  >
                    <div>
                      <div className="mono" style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)' }}>{pol.name}</div>
                      <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 3 }}>{pol.description}</div>
                    </div>
                    <SyncStatusPill tone={pol.status === 'PASS' ? 'teal' : 'red'} label={pol.status} style={{ whiteSpace: 'nowrap' }} />
                  </div>
                ))}
              </div>
            </div>
          </div>
        </Section>
      )}

      {show('packages') && (
        <Section title="Container Packages & Metadata" subtitle="Preinstalled runtime packages and operator bookkeeping metadata." tabId="packages">
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16 }}>
            <Tile label="Packages">{env.packagesDescription}</Tile>
            <div style={tileStyle}>
              <div style={tileLabel}>Metadata</div>
              <pre className="mono" style={{ margin: 0, fontSize: 12, color: 'var(--text)', overflowX: 'auto' }}>
                {JSON.stringify(env.metadata, null, 2)}
              </pre>
            </div>
          </div>
        </Section>
      )}

      {show('agents') && (
        <Section title="Connected Agents & Workloads" subtitle="Agents discovered running in this remote container environment." tabId="agents">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {env.connectedAgents.map((ag) => (
              <div
                key={ag.id}
                style={{ ...tileStyle, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12, padding: '12px 14px' }}
              >
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)' }}>{ag.name}</span>
                    <SyncStatusPill tone={ag.status === 'active' ? 'teal' : 'muted'} label={ag.status} style={{ fontSize: 10.5 }} />
                    {ag.model && <span className="mono" style={{ fontSize: 11, color: 'var(--text)' }}>{ag.model}</span>}
                  </div>
                  <div className="mono" style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 4 }}>
                    Session: {ag.sessionId} • Last active {ag.lastActive}
                    {ag.createdBy && ` • Created by ${ag.createdBy}`}
                  </div>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <Link
                    to={`/agents?selected=${encodeURIComponent(ag.id)}&drawer=${encodeURIComponent(ag.id)}`}
                    className="btn btn-secondary btn-sm"
                    data-testid={`btn-view-dossier-${ag.id}`}
                    style={{ textDecoration: 'none' }}
                  >
                    View Dossier ↗
                  </Link>
                  <button
                    type="button"
                    className="btn btn-secondary btn-sm"
                    data-testid={`btn-claim-agent-${ag.id}`}
                    onClick={() => setClaimedAgents((prev) => ({ ...prev, [ag.id]: true }))}
                    disabled={claimedAgents[ag.id]}
                  >
                    {claimedAgents[ag.id] ? 'Claimed ✓' : 'Claim to Tenant'}
                  </button>
                </div>
              </div>
            ))}
          </div>
        </Section>
      )}

      {showLogs && (
        <SyncLogsModal isOpen providerId={providerId} providerName={env.providerName} onClose={() => setShowLogs(false)} onRescan={() => handleSyncNow(true)} />
      )}
    </div>
  )
}
