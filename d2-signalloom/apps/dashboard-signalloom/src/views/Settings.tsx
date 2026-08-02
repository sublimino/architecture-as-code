import { useState, useEffect, useCallback } from 'react'
import type { ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import type { TenantSettingsResponse, FrameworkResponse, NHIScan, PlatformUser } from '../types/api'
import type { ConnectorProvider, TenantConnector } from '../types/connectors'
import ErrorState from '../components/ErrorState'
import ApiKeyRotateModal from '../components/ApiKeyRotateModal'
import ConfirmDialog from '../components/ConfirmDialog'
import ProviderLogo from '../components/onboarding/ProviderLogo'
import { useAppContext } from '../App'

const POLL_MS = 15 * 60 * 1000

function Field({ label, value, mono }: { label: string; value: string | number | null | undefined; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
      <span style={{ fontSize: 14, fontWeight: 500, color: value != null ? 'var(--text)' : 'var(--muted)', fontFamily: mono ? 'monospace' : undefined }}>
        {value ?? '—'}
      </span>
    </div>
  )
}

function FrameworkToggle({ active, onToggle }: { active: boolean; onToggle: () => void }) {
  return (
    <button
      role="switch"
      aria-checked={active}
      onClick={onToggle}
      style={{
        flexShrink: 0,
        width: 44,
        height: 24,
        borderRadius: 12,
        padding: 0,
        border: 'none',
        cursor: 'pointer',
        background: active ? 'var(--cyan)' : 'var(--slate-gray)',
        transition: 'background 0.2s ease',
        position: 'relative',
      }}
    >
      <span
        style={{
          position: 'absolute',
          top: 3,
          left: active ? 23 : 3,
          width: 18,
          height: 18,
          borderRadius: '50%',
          background: 'white',
          transition: 'left 0.2s ease',
          boxShadow: '0 1px 3px rgba(0,0,0,0.3)',
        }}
      />
    </button>
  )
}

function SectionCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <h2 style={{ fontSize: 11, fontWeight: 700, marginBottom: 16, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{title}</h2>
      {children}
    </div>
  )
}

function ApiKeyStatus({ status }: { status: string | null | undefined }) {
  const statusMap: Record<string, { color: string; label: string }> = {
    active: { color: 'var(--teal)', label: 'Active' },
    revoked: { color: 'var(--error)', label: 'Revoked' },
    expired: { color: 'var(--amber)', label: 'Expired' },
  }
  const info = status ? (statusMap[status] ?? { color: 'var(--muted)', label: status }) : { color: 'var(--muted)', label: '—' }
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
      <span style={{ width: 8, height: 8, borderRadius: '50%', background: info.color }} />
      <span style={{ color: info.color, fontWeight: 600 }}>{info.label}</span>
    </span>
  )
}

export default function Settings() {
  const { getAccessTokenSilently, user } = useAuth0()
  const navigate = useNavigate()
  const { apiKeyReveal, setApiKeyReveal, refreshOnboardingState } = useAppContext()
  const [settings, setSettings] = useState<TenantSettingsResponse | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkResponse[]>([])
  const [lastScan, setLastScan] = useState<NHIScan | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedFrameworks, setSelectedFrameworks] = useState<string[]>([])
  const [toastError, setToastError] = useState<string | null>(null)
  const [rotateModalOpen, setRotateModalOpen] = useState(false)
  const [revealAlreadyUsed, setRevealAlreadyUsed] = useState(false)
  const [revealing, setRevealing] = useState(false)
  const [providers, setProviders] = useState<ConnectorProvider[]>([])
  const [connectors, setConnectors] = useState<TenantConnector[]>([])
  const [disconnectTarget, setDisconnectTarget] = useState<TenantConnector | null>(null)
  const [disconnecting, setDisconnecting] = useState(false)
  const [cadenceHours, setCadenceHours] = useState(24)
  const [alertEmail, setAlertEmail] = useState('')
  const [alertThreshold, setAlertThreshold] = useState(1)
  const [preferencesSaving, setPreferencesSaving] = useState(false)
  const [preferencesSaved, setPreferencesSaved] = useState(false)
  const [preferencesError, setPreferencesError] = useState<string | null>(null)
  const [teamMembers, setTeamMembers] = useState<PlatformUser[]>([])

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [settingsRes, frameworksRes, scansRes, providersRes, connectorsRes, usersRes] = await Promise.allSettled([
        api.settings(token),
        api.compliance.frameworks(token),
        api.nhi.scans(token),
        connectorsApi.listProviders(token),
        connectorsApi.listConnectors(token),
        api.users(token),
      ])
      if (settingsRes.status === 'fulfilled') {
        setSettings(settingsRes.value)
        setSelectedFrameworks(settingsRes.value.selected_frameworks ?? [])
        setCadenceHours(settingsRes.value.preferred_scan_cadence_hours)
        setAlertEmail(settingsRes.value.alert_email ?? '')
        setAlertThreshold(settingsRes.value.alert_threshold)
      }
      if (frameworksRes.status === 'fulfilled') setFrameworks(frameworksRes.value)
      if (scansRes.status === 'fulfilled') {
        const scans = scansRes.value.scans
        if (scans.length) {
          const sorted = [...scans].sort((a, b) =>
            new Date(b.started_at ?? 0).getTime() - new Date(a.started_at ?? 0).getTime()
          )
          setLastScan(sorted[0])
        }
      }
      if (providersRes.status === 'fulfilled') setProviders(providersRes.value)
      if (connectorsRes.status === 'fulfilled') setConnectors(connectorsRes.value)
      if (usersRes.status === 'fulfilled') setTeamMembers(usersRes.value.users)
      if (settingsRes.status === 'rejected') {
        const msg = settingsRes.reason instanceof Error ? settingsRes.reason.message : ''
        if (msg.includes('401') || msg.includes('403')) setError('Your session has expired. Please sign in again.')
        else setError('Something went wrong loading this view. Please try refreshing.')
      } else {
        setError(null)
      }
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  async function handleRevealApiKey() {
    if (!settings) return
    setRevealing(true)
    try {
      const token = await getAccessTokenSilently()
      const result = await api.apiKeys.revealInitial(token, settings.tenant_id)
      setApiKeyReveal({ key: result.key, prefix_hint: result.prefix_hint })
      setRevealAlreadyUsed(false)
    } catch (e: unknown) {
      const status = (e as { response?: { status?: number } })?.response?.status
      if (status === 410) {
        // Already revealed once — the plaintext key can never be shown
        // again, so the only way to see a working key now is to rotate.
        setRevealAlreadyUsed(true)
        setRotateModalOpen(true)
      } else {
        setToastError('Failed to reveal API key. Please try again.')
      }
    } finally {
      setRevealing(false)
    }
  }

  async function handleSavePreferences() {
    setPreferencesSaving(true)
    setPreferencesError(null)
    setPreferencesSaved(false)
    try {
      const token = await getAccessTokenSilently()
      const updated = await api.patchPreferences(token, {
        preferred_scan_cadence_hours: cadenceHours,
        alert_email: alertEmail.trim() || null,
        alert_threshold: alertThreshold,
      })
      setCadenceHours(updated.preferred_scan_cadence_hours)
      setAlertEmail(updated.alert_email ?? '')
      setAlertThreshold(updated.alert_threshold)
      setPreferencesSaved(true)
      setTimeout(() => setPreferencesSaved(false), 3000)
    } catch {
      setPreferencesError('Could not save preferences. Please try again.')
    } finally {
      setPreferencesSaving(false)
    }
  }

  async function handleConfirmDisconnect() {
    if (!disconnectTarget) return
    setDisconnecting(true)
    try {
      const token = await getAccessTokenSilently()
      await connectorsApi.deleteConnector(token, disconnectTarget.connector_id)
      setConnectors((prev) =>
        prev.map((c) =>
          c.connector_id === disconnectTarget.connector_id ? { ...c, status: 'disconnected' as const } : c,
        ),
      )
      refreshOnboardingState() // a connector just dropped — re-check the auto-trigger gate/banner
    } finally {
      setDisconnecting(false)
      setDisconnectTarget(null)
    }
  }

  useEffect(() => {
    load()
    const t = setInterval(load, POLL_MS)
    return () => clearInterval(t)
  }, [load])

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={load} />

  function fmtTs(iso: string | null) {
    if (!iso) return null
    return new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })
  }

  const scanStatusColor: Record<string, string> = {
    completed: 'var(--teal)', running: 'var(--cyan)', failed: 'var(--error)',
  }

  return (
    <div style={{ maxWidth: 720, paddingBottom: 32 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 24 }}>Settings</h1>

      {/* Organization */}
      <SectionCard title="Organization">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <Field label="Organization Name" value={settings?.org_name || 'Unnamed'} />
          <Field label="Tenant ID" value={settings?.tenant_id} mono />
          <Field label="Plan Tier" value={settings?.plan_tier} />
          <Field label="Billing Tier" value={settings?.billing_tier} />
          <Field label="Enrolled Agents" value={settings?.agent_count} />
        </div>
      </SectionCard>

      {/* API Access */}
      <SectionCard title="API Access">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 16 }}>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>API Key Status</div>
            <ApiKeyStatus status={settings?.api_key_status} />
          </div>
        </div>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 4 }}>
          API keys grant programmatic access to the Signal Loom agent registry. Keys are scoped to your tenant.
        </p>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 12 }}>
          We never store your key in plaintext, so it can only be shown once. If you haven't seen it yet,
          reveal it below; if you have, revealing it again requires rotating — your old key is revoked
          immediately and a new one takes its place.
        </p>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          <button
            className="btn btn-primary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            onClick={handleRevealApiKey}
            disabled={revealing}
          >
            {revealing ? 'Revealing…' : 'Reveal my API key'}
          </button>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            onClick={() => { setRevealAlreadyUsed(false); setRotateModalOpen(true) }}
          >
            Rotate API Key
          </button>
        </div>
        {revealAlreadyUsed && (
          <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 8 }}>
            Your key was already revealed once and can't be shown again — rotate to get a new one.
          </p>
        )}
        {rotateModalOpen && settings && (
          <ApiKeyRotateModal
            currentPrefixHint={apiKeyReveal?.prefix_hint ?? 'sl_live_'}
            doRotate={async () => {
              const token = await getAccessTokenSilently()
              return api.apiKeys.rotate(token, settings.tenant_id)
            }}
            onRotated={(result) => setApiKeyReveal({ key: result.key, prefix_hint: result.prefix_hint })}
            onClose={() => setRotateModalOpen(false)}
          />
        )}
      </SectionCard>

      {/* Service Connectors */}
      <SectionCard title="Service Connectors">
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 14 }}>
          Enable or disable third-party identity providers and AI service connectors.
          Disabling a connected provider stops future scans but preserves discovered records.
        </p>
        {providers.length === 0 ? (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No providers available.</p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {providers.map((p) => {
              const connector = connectors.find((c) => c.provider_id === p.provider_id && c.status === 'connected')
              const isConnected = !!connector
              return (
                <div
                  key={p.provider_id}
                  style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 14px', background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <ProviderLogo providerId={p.provider_id} displayName={p.display_name} size={32} />
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>{p.display_name}</div>
                      <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                        {isConnected
                          ? connector.last_tested_at ? `Connected · Last tested ${fmtTs(connector.last_tested_at)}` : 'Connected'
                          : 'Not configured'}
                      </div>
                    </div>
                  </div>
                  <FrameworkToggle
                    active={isConnected}
                    onToggle={() => {
                      if (isConnected) {
                        setDisconnectTarget(connector)
                      } else {
                        navigate('/onboarding')
                      }
                    }}
                  />
                </div>
              )
            })}
          </div>
        )}
        {disconnectTarget && (
          <ConfirmDialog
            title="Disconnect provider?"
            body={`This stops future scans from ${disconnectTarget.display_name || disconnectTarget.provider_id}. Previously discovered NHI records stay in your history, marked as source-disconnected — nothing is deleted.`}
            confirmLabel="Disconnect"
            loading={disconnecting}
            onConfirm={handleConfirmDisconnect}
            onCancel={() => setDisconnectTarget(null)}
          />
        )}
      </SectionCard>

      {/* Compliance Frameworks */}
      <SectionCard title="Compliance Frameworks">
        {toastError && (
          <div style={{ marginBottom: 12, padding: '8px 12px', background: 'rgba(220,38,38,0.08)', border: '1px solid rgba(220,38,38,0.25)', borderRadius: 6, fontSize: 12, color: 'var(--error)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            {toastError}
            <button onClick={() => setToastError(null)} style={{ background: 'none', border: 'none', color: 'var(--error)', cursor: 'pointer', marginLeft: 8, fontSize: 14, lineHeight: 1 }}>✕</button>
          </div>
        )}
        {frameworks.length === 0 ? (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No frameworks available for this plan tier.</p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {frameworks.map(fw => {
              const active = selectedFrameworks.includes(fw.id)
              return (
                <div
                  key={fw.id}
                  style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 14px', background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}
                >
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>{fw.name}</div>
                    <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                      {[fw.version && `v${fw.version}`, fw.regulatory_body, `${fw.control_count} controls`].filter(Boolean).join(' · ')}
                    </div>
                  </div>
                  <FrameworkToggle
                    active={active}
                    onToggle={async () => {
                      const prev = selectedFrameworks
                      const next = active
                        ? prev.filter(id => id !== fw.id)
                        : [...prev, fw.id]
                      setSelectedFrameworks(next)
                      setToastError(null)
                      try {
                        const token = await getAccessTokenSilently()
                        const updated = await api.patchFrameworks(token, next)
                        setSelectedFrameworks(updated.selected_frameworks ?? next)
                      } catch {
                        setSelectedFrameworks(prev)
                        setToastError('Failed to update framework selection. Please try again.')
                      }
                    }}
                  />
                </div>
              )
            })}
          </div>
        )}
      </SectionCard>

      {/* Scan Preferences (Slice 1b, 86cajpvar QA item 4) */}
      <SectionCard title="Scan Preferences">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 16 }}>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>
              Scan Cadence
            </div>
            <select
              value={cadenceHours}
              onChange={(e) => setCadenceHours(Number(e.target.value))}
              style={{ width: '100%' }}
            >
              <option value={24}>Daily</option>
              <option value={168}>Weekly</option>
            </select>
            <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
              Applies to providers you connect from here on.
            </p>
          </div>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>
              Alert Email
            </div>
            <input
              type="email"
              value={alertEmail}
              onChange={(e) => setAlertEmail(e.target.value)}
              placeholder="you@company.com"
              style={{ width: '100%' }}
            />
            <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
              Leave blank to use your account's contact email.
            </p>
          </div>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>
              Alert Threshold
            </div>
            <input
              type="number"
              min={1}
              value={alertThreshold}
              onChange={(e) => setAlertThreshold(Math.max(1, Number(e.target.value) || 1))}
              style={{ width: '100%' }}
            />
            <p style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
              At-risk accounts found in a scan before we email you.
            </p>
          </div>
        </div>
        {preferencesError && (
          <p style={{ fontSize: 12, color: 'var(--error)', marginBottom: 12 }}>{preferencesError}</p>
        )}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <button
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            onClick={handleSavePreferences}
            disabled={preferencesSaving}
          >
            {preferencesSaving ? 'Saving…' : 'Save Preferences'}
          </button>
          {preferencesSaved && (
            <span style={{ fontSize: 12, color: 'var(--teal)', fontWeight: 600 }}>Saved</span>
          )}
        </div>
      </SectionCard>

      {/* NHI Discovery */}
      <SectionCard title="NHI Discovery">
        {lastScan ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>Last Scan</div>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
                <span style={{ width: 8, height: 8, borderRadius: '50%', background: scanStatusColor[lastScan.status] ?? 'var(--muted)' }} />
                <span style={{ color: scanStatusColor[lastScan.status] ?? 'var(--muted)', fontWeight: 600, textTransform: 'capitalize' }}>{lastScan.status}</span>
              </span>
            </div>
            <Field label="Scan Source" value={lastScan.scan_source} />
            <Field label="Started" value={fmtTs(lastScan.started_at)} />
            <Field label="Completed" value={fmtTs(lastScan.completed_at)} />
            <Field label="Entries Scanned" value={lastScan.total_entries_scanned} />
            <Field label="Service Accounts Found" value={lastScan.service_accounts_found} />
            {lastScan.total_at_risk != null && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>At Risk</div>
                <span style={{ fontSize: 14, fontWeight: 700, color: lastScan.total_at_risk > 0 ? 'var(--error)' : 'var(--teal)' }}>
                  {lastScan.total_at_risk}
                </span>
              </div>
            )}
          </div>
        ) : (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No scans recorded. Connect an identity provider to begin discovering non-human identities in your environment.</p>
        )}
        <div style={{ marginTop: 14, display: 'flex', gap: 16 }}>
          <a href="/onboarding" style={{ fontSize: 12, color: 'var(--cyan)', textDecoration: 'none' }}>
            Connect a provider →
          </a>
          <a href="/agents?tab=discovered" style={{ fontSize: 12, color: 'var(--cyan)', textDecoration: 'none' }}>
            View discovered accounts →
          </a>
        </div>
      </SectionCard>

      {/* Team */}
      {teamMembers.length > 0 && (
        <SectionCard title="Team">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 0 }}>
            {teamMembers.map((m) => (
              <div
                key={m.id}
                style={{
                  display: 'grid',
                  gridTemplateColumns: '28px 1fr auto',
                  alignItems: 'center',
                  gap: 12,
                  padding: '10px 0',
                  borderBottom: '1px solid var(--border)',
                }}
              >
                <div style={{
                  width: 28, height: 28, borderRadius: '50%',
                  background: m.role === 'admin' ? 'var(--violet)' : m.role === 'editor' ? 'var(--cyan)' : 'var(--border)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 12, fontWeight: 700, color: 'var(--on-accent)', flexShrink: 0,
                }}>
                  {m.display_name.charAt(0).toUpperCase()}
                </div>
                <div style={{ overflow: 'hidden', minWidth: 0 }}>
                  <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {m.display_name}
                    {m.title && <span style={{ color: 'var(--muted)', fontWeight: 400 }}> — {m.title}</span>}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                    {m.email}{m.department ? ` · ${m.department}` : ''}
                  </div>
                </div>
                <span style={{
                  fontSize: 10,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                  padding: '2px 8px',
                  borderRadius: 99,
                  color: m.role === 'admin' ? 'var(--violet)' : m.role === 'editor' ? 'var(--cyan)' : 'var(--muted)',
                  background: m.role === 'admin' ? 'rgba(167,139,250,0.12)' : m.role === 'editor' ? 'rgba(6,182,212,0.10)' : 'rgba(148,163,184,0.10)',
                }}>
                  {m.role}
                </span>
              </div>
            ))}
          </div>
        </SectionCard>
      )}

      {/* Account */}
      <SectionCard title="Account">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <Field label="Email" value={user?.email} />
          <Field label="Name" value={user?.name} />
        </div>
      </SectionCard>

      <p style={{ marginTop: 4, color: 'var(--muted)', fontSize: 12, textAlign: 'center' }}>
        For billing or plan changes contact{' '}
        <a href="mailto:support@signal-loom.ai" style={{ color: 'var(--cyan)', textDecoration: 'none' }}>support@signal-loom.ai</a>.
      </p>
    </div>
  )
}
