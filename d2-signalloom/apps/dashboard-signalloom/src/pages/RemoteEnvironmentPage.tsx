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
import ButtonWait from '../components/ButtonWait'
import NotFoundPage from './NotFoundPage'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'

// Remote environment console for an AI provider connector.
//
// Demo mode renders the fixture in api/fakeData.ts. Live mode renders only
// what the connectors API returns: the tenant's connector record and its last
// SyncResult. The API returns no credit balance, egress configuration, policy
// results or agent identities, so live mode says so rather than inventing them.

const tone = {
  teal: { background: 'var(--teal-bg)', color: 'var(--teal)', border: '1px solid var(--teal-border)' },
  cyan: { background: 'var(--cyan-bg)', color: 'var(--cyan)', border: '1px solid var(--cyan-border)' },
  amber: { background: 'var(--amber-bg)', color: 'var(--warning)', border: '1px solid var(--amber-border)' },
  red: { background: 'var(--red-bg)', color: 'var(--error)', border: '1px solid var(--red-border)' },
  muted: { background: 'var(--surface2)', color: 'var(--muted)', border: '1px solid var(--border-subtle)' },
}

const pill = { padding: '3px 10px', borderRadius: 99, fontSize: 12, fontWeight: 600 }
const tileStyle = { padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }
const tileLabel = { fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase' as const, letterSpacing: '0.06em', marginBottom: 4 }
const cardStyle = { padding: 22, marginBottom: 20, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8 }

function Section({ title, subtitle, testId, children }: { title: string; subtitle: string; testId?: string; children: ReactNode }) {
  const [collapsed, setCollapsed] = useState(false)
  return (
    <section className="card" data-testid={testId} style={cardStyle}>
      <div
        style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16, cursor: 'pointer' }}
        onClick={() => setCollapsed((c) => !c)}
      >
        <div>
          <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>{title}</h2>
          <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>{subtitle}</p>
        </div>
        <button
          type="button"
          style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
          aria-label={`Toggle ${title} Section`}
        >
          {collapsed ? '▶ Expand' : '▼ Collapse'}
        </button>
      </div>
      {!collapsed && children}
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

function ErrorBanner({ message }: { message: string }) {
  return (
    <div role="alert" style={{ ...tone.red, padding: '10px 14px', borderRadius: 6, fontSize: 12, marginBottom: 16 }}>
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

  const scanTone = syncResult ? { success: tone.teal, warning: tone.amber, error: tone.red }[syncResult.status] : tone.muted

  return (
    <div className="fade-in" data-testid="remote-environment-page" style={{ maxWidth: 1200, margin: '0 auto' }}>
      <Breadcrumb label={providerName} />
      {error && <ErrorBanner message={error} />}
      {loading ? (
        <div style={{ color: 'var(--muted)', padding: 24 }}>Loading connector...</div>
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
                  <h1 data-testid="env-title" style={{ fontSize: 24, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                    {connector.display_name ?? providerName}
                  </h1>
                  <span style={{ ...pill, ...(connector.status === 'connected' ? tone.teal : tone.red) }}>{connector.status}</span>
                  <span data-testid="live-scan-status" style={{ ...pill, ...scanTone }}>
                    {syncResult ? `Last scan: ${syncResult.status}` : 'Not yet scanned'}
                  </span>
                </div>
                <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
                  <span>Provider: {providerName}</span>
                  <span>•</span>
                  <span style={{ fontFamily: 'monospace' }}>Connector ID: {connector.connector_id}</span>
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
            <pre style={{ ...tileStyle, margin: 0, fontSize: 12, fontFamily: 'monospace', color: 'var(--text)', overflowX: 'auto' }}>
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

function agentTone(a: RemoteAgent) {
  if (a.gone_at) return tone.muted
  const s = (a.status ?? '').toLowerCase()
  if (['running', 'active', 'busy'].includes(s)) return tone.teal
  if (['error', 'failed', 'errored'].includes(s)) return tone.red
  if (['idle', 'terminated', 'stopped', 'archived', ''].includes(s)) return tone.muted
  return tone.cyan
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
  const connTone = connection.status === 'open' ? tone.teal : connection.status === 'reconnecting' ? tone.amber : tone.muted
  return (
    <div data-testid="remote-agents-panel">
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 12, fontSize: 12 }}>
        <span data-testid="stream-connection" role="status" aria-live="polite" style={{ ...pill, ...connTone }}>
          {connectionLabel(connection)}
        </span>
        {sync && (
          <span data-testid="remote-sync-state" style={{ color: 'var(--muted)' }}>
            {syncModeLabel(sync)} • {sync.last_success_at ? `Last synced ${fmtTs(sync.last_success_at)}` : 'Never synced'}
            {sync.mode === 'poll' && sync.next_poll_at ? ` • Next poll ${fmtTs(sync.next_poll_at)}` : ''}
          </span>
        )}
      </div>
      {sync?.last_error && (
        <div data-testid="remote-sync-error" style={{ ...tone.red, padding: '8px 12px', borderRadius: 6, fontSize: 12, marginBottom: 12 }}>
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
            <div role="alert" data-testid="remote-agents-error" style={{ ...tone.red, padding: '8px 12px', borderRadius: 6, fontSize: 12, marginBottom: 12 }}>
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
                      <span style={{ ...pill, fontSize: 11, ...tone.muted }}>{a.kind}</span>
                      {a.model && <span style={{ fontSize: 11, fontFamily: 'monospace', color: 'var(--text)' }}>{a.model}</span>}
                    </div>
                    <div style={{ fontSize: 11.5, color: 'var(--muted)', fontFamily: 'monospace', marginTop: 4 }}>
                      {a.external_id}
                      {a.version != null && ` • v${a.version}`}
                      {` • Last seen ${fmtTs(a.last_seen_at)}`}
                    </div>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <span style={{ ...pill, ...agentTone(a), whiteSpace: 'nowrap' }}>
                      {a.gone_at ? `Gone ${fmtTs(a.gone_at)}` : a.status ?? 'status not reported'}
                    </span>
                    {a.external_id && (
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
              <h1 data-testid="env-title" style={{ fontSize: 24, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                {env.envName}
              </h1>
              <span style={{ ...pill, ...tone.teal }}>{syncStatus || env.status}</span>
              <span data-testid="env-credit-balance" style={{ ...pill, ...tone.cyan }}>
                {env.creditBalance}
              </span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
              <span>
                <strong>Hosting:</strong> {env.hosting} Hosting
              </span>
              <span>•</span>
              <span>Organization: {env.orgName}</span>
              <span>•</span>
              <span data-testid="env-badge-id" style={{ fontFamily: 'monospace' }}>
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
            role="tab"
            data-testid={`env-tab-${tab.id}`}
            aria-selected={activeTab === tab.id}
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
        <Section title="General" subtitle="What this environment is, and where it runs.">
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 16 }}>
            <Tile label="Hosting">
              {env.hosting}
              <div style={{ fontSize: 11.5, fontWeight: 400, color: 'var(--muted)', marginTop: 4 }}>{env.hostingNote}</div>
            </Tile>
            <Tile label="Name">{env.envName}</Tile>
            <Tile label="Description">{env.description}</Tile>
            <Tile label="Workspace / Org ID">
              <span style={{ fontFamily: 'monospace' }}>{env.workspaceId}</span>
            </Tile>
          </div>
        </Section>
      )}

      {show('network') && (
        <Section title="Network Egress & CEL Governance" subtitle="What the container can reach over the network and CEL policy conformance." testId="network-egress-section">
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
                    <span key={h} style={{ fontSize: 12, fontFamily: 'monospace' }}>
                      {h}
                    </span>
                  ))}
                </div>
              )}
            </div>
            <div data-testid="cel-policy-card" style={{ ...tileStyle, border: '1px solid var(--teal-border)' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
                <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--text)' }}>CEL Policy Assessment (Signal Loom Governance Engine)</div>
                <span style={{ ...pill, fontSize: 11, ...(passing === env.celPolicies.length ? tone.teal : tone.red) }}>
                  {passing} / {env.celPolicies.length} POLICIES PASS
                </span>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {env.celPolicies.map((pol) => (
                  <div
                    key={pol.id}
                    style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, padding: '10px 12px', background: 'var(--surface)', borderRadius: 5, border: '1px solid var(--border)' }}
                  >
                    <div>
                      <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)', fontFamily: 'monospace' }}>{pol.name}</div>
                      <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 3 }}>{pol.description}</div>
                    </div>
                    <span style={{ padding: '2px 8px', borderRadius: 4, fontSize: 11, fontWeight: 700, whiteSpace: 'nowrap', ...(pol.status === 'PASS' ? tone.teal : tone.red) }}>
                      {pol.status}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </Section>
      )}

      {show('packages') && (
        <Section title="Container Packages & Metadata" subtitle="Preinstalled runtime packages and operator bookkeeping metadata.">
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16 }}>
            <Tile label="Packages">{env.packagesDescription}</Tile>
            <div style={tileStyle}>
              <div style={tileLabel}>Metadata</div>
              <pre style={{ margin: 0, fontSize: 12, fontFamily: 'monospace', color: 'var(--text)', overflowX: 'auto' }}>
                {JSON.stringify(env.metadata, null, 2)}
              </pre>
            </div>
          </div>
        </Section>
      )}

      {show('agents') && (
        <Section title="Connected Agents & Workloads" subtitle="Agents discovered running in this remote container environment.">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {env.connectedAgents.map((ag) => (
              <div
                key={ag.id}
                style={{ ...tileStyle, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12, padding: '12px 14px' }}
              >
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)' }}>{ag.name}</span>
                    <span style={{ padding: '1px 6px', borderRadius: 99, fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', ...(ag.status === 'active' ? tone.teal : tone.muted) }}>
                      {ag.status}
                    </span>
                    {ag.model && <span style={{ fontSize: 11, fontFamily: 'monospace', color: 'var(--text)' }}>{ag.model}</span>}
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--muted)', fontFamily: 'monospace', marginTop: 4 }}>
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
